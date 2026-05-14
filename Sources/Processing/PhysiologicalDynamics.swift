import Foundation

/// Pure stateless physiological-state update math.
///
/// All functions operate on scalar inputs + a `Prev` snapshot of the previous bio-day's
/// hidden state and return the new value. No persistence, no async — easy to unit test
/// and reason about independently of the DayRecomputer pipeline that drives them.
///
/// Math reference (Phase 2 plan):
///   ATL  α = 0.27   (≈ 2 / (7 + 1))
///   CTL  α = 0.069  (≈ 2 / (28 + 1))
///   AutoStress α = 0.4
///   SleepDebt decay = 0.85/day, clamp [0, 600] min
///   Capacity update α = 0.35, clamp [0.2, 1.0]
///   Tolerance = chronicLoad / 10, clamp [0.5, 1.5]
struct PhysiologicalDynamics: Sendable {

    // MARK: - Cold-start seeds

    static let seedAcuteFatigue:      Double = 8.0
    static let seedChronicLoad:       Double = 8.0
    static let seedAutonomicStress:   Double = 0.0
    static let seedSleepDebt:         Double = 0.0
    static let seedReadinessCapacity: Double = 0.6
    static let seedStrainTolerance:   Double = 1.0

    /// Prior bio-day hidden-state snapshot. Cold-start defaults applied when caller
    /// passes nil (first-ever day with no prior `DailyMetrics`).
    struct Prev: Sendable {
        var acuteFatigue:      Double
        var chronicLoad:       Double
        var autonomicStress:   Double
        var sleepDebt:         Double          // minutes
        var readinessCapacity: Double

        static let seed = Prev(
            acuteFatigue:      seedAcuteFatigue,
            chronicLoad:       seedChronicLoad,
            autonomicStress:   seedAutonomicStress,
            sleepDebt:         seedSleepDebt,
            readinessCapacity: seedReadinessCapacity
        )
    }

    // MARK: - Nonlinear strain

    /// Logistic mapping of zone-weighted HR accumulation → 0..21 strain.
    /// Inflection at midpoint 12; slope peak ~10–14. 16→18 costs ~3× more than 8→10.
    static func nonlinearStrain(rawAccum: Double) -> Double {
        let k = 0.18, midpoint = 12.0
        let s = 21.0 / (1 + exp(-k * (rawAccum - midpoint)))
        return clamp(s, 0, 21)
    }

    // MARK: - Strain tolerance

    /// Training adaptation: chronically loaded users tolerate equivalent strain more easily.
    /// populationCTL ≈ 10 (raw strain units).
    static func strainTolerance(chronicLoad: Double) -> Double {
        clamp(chronicLoad / 10.0, 0.5, 1.5)
    }

    // MARK: - ATL / CTL (EWMA of normalized strain load)

    /// Strain load entering the fatigue chain = nonlinearStrain / tolerance.
    /// On gap-days (no strain measured) pass `nil` and we hold ATL/CTL neutral
    /// at prev.chronicLoad to prevent collapse-to-zero artifacts.
    static func acuteFatigue(strainLoad: Double?, prev: Prev) -> Double {
        let x = strainLoad ?? prev.chronicLoad
        return 0.27 * x + 0.73 * prev.acuteFatigue
    }

    static func chronicLoad(strainLoad: Double?, prev: Prev) -> Double {
        let x = strainLoad ?? prev.chronicLoad
        return 0.069 * x + 0.931 * prev.chronicLoad
    }

    // MARK: - Autonomic stress

    /// Positive value = stressed. RR replaces strainZ from the old formula.
    /// z-scores are already confidence-shrunk by caller before being passed in here.
    /// Missing RR → drop term (caller can pass `rrZ_eff = 0` after renormalizing weights).
    static func autonomicStress(hrvZ_eff: Double, rhrZ_eff: Double, rrZ_eff: Double, prev: Prev) -> Double {
        let raw = (-hrvZ_eff + rhrZ_eff + rrZ_eff) / 3.0
        return 0.4 * raw + 0.6 * prev.autonomicStress
    }

    // MARK: - Sleep debt

    /// Cumulative minute-shortfall with 0.85/day exponential decay, clamped [0, 600].
    static func sleepDebt(sleepNeedMin: Int, sleepActualMin: Int, prev: Prev) -> Double {
        let shortfall = max(0, Double(sleepNeedMin - sleepActualMin))
        return clamp(0.85 * prev.sleepDebt + shortfall, 0, 600)
    }

    // MARK: - Readiness capacity

    /// Hidden 0..1 capacity. Modulates Recovery output without being a primary ring.
    /// Damped 0.35 update toward target → avoids day-to-day capacity flapping.
    static func readinessCapacity(
        acuteFatigue: Double,
        chronicLoad: Double,
        autonomicStress: Double,
        sleepDebt: Double,
        illnessFlag: Bool,
        prev: Prev
    ) -> Double {
        let damp      = illnessFlag ? 0.7 : 1.0
        let tsb       = (chronicLoad - acuteFatigue) / 10.0       // training-stress balance
        let stressPen = clamp(1 - 0.25 * autonomicStress, 0.4, 1.2)
        let debtPen   = clamp(1 - sleepDebt / 600.0, 0.5, 1.0)
        let baseTarget = clamp(0.5 + 0.5 * tanh(tsb), 0, 1)
        let target    = baseTarget * stressPen * debtPen * damp
        let next      = prev.readinessCapacity + 0.35 * (target - prev.readinessCapacity)
        return clamp(next, 0.2, 1.0)
    }

    // MARK: - Sleep-need adjustment

    /// Extra-need minutes from accumulated fatigue + autonomic stress.
    /// Replaces the old linear `min(60, strain/21*60)` adjustment.
    static func fatigueAdjMinutes(acuteFatigue: Double, autonomicStress: Double) -> Int {
        let fatigueAdj = 75.0 * tanh(acuteFatigue / 12.0)         // 0..~75 min asymptotic
        let stressAdj  = 30.0 * max(0, autonomicStress)           // 0..~30 min
        return Int((fatigueAdj + stressAdj).rounded())
    }

    // MARK: - Confidence-damped state delta

    /// Apply confidence-aware damping to a state update so noisy days move state less.
    /// Returns prev blended toward `next` by factor `(0.2 + 0.8*minConf)`.
    static func confidenceDamp(prev: Double, next: Double, minConfidence: Double) -> Double {
        let alpha = 0.2 + 0.8 * clamp(minConfidence, 0, 1)
        return prev + alpha * (next - prev)
    }

    // MARK: - Helpers

    @inlinable
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return min(hi, max(lo, v))
    }
}
