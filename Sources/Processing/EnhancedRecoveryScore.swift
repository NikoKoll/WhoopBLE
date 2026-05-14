import Foundation

/// 7-component recovery score with per-component timing penalties.
/// Only timing-sensitive components (Quantity, Efficiency, Stage Quality) are penalized.
/// Autonomic Recovery, Consistency, and Fragmentation pass through unmodified.
struct EnhancedRecoveryScore {

    static let popHRV: (mean: Double, std: Double) = (45, 20)
    static let popRHR: (mean: Double, std: Double) = (62, 8)
    static let popSleep: (mean: Double, std: Double) = (420, 60)
    static let popStrain: (mean: Double, std: Double) = (10, 4)
    static let popRR: (mean: Double, std: Double) = (14.0, 2.0)   // adult sleep mean RR ≈ 12–16 bpm

    static func compute(
        hrv: Double?,
        rhr: Double?,
        sleepMinutes: Int,
        sleepEfficiencyPct: Double,
        briefWakeCount: Int,
        totalSleepHours: Double,
        deepPct: Double,
        remPct: Double,
        strain: Double?,
        sleepType: SleepEpisodeType,
        circadianPenalty: Double,
        circadianAlignment: Double,
        consistencyScore: Double,
        hrvBaseline: (mean: Double, std: Double)?,
        rhrBaseline: (mean: Double, std: Double)?,
        sleepBaseline: (mean: Double, std: Double)?,
        strainBaseline: (mean: Double, std: Double)?,
        biologicalDateKey: String,
        // Phase 2 additions
        respiratoryRate: Double? = nil,
        respiratoryBaseline: (mean: Double, std: Double)? = nil,
        confHRV: Double = 1.0,
        confRHR: Double = 1.0,
        confRR: Double = 0.0,
        readinessCapacity: Double = 1.0,
        illnessFlag: Bool = false
    ) -> RecoveryBreakdown {

        let hb = hrvBaseline ?? popHRV
        let rb = rhrBaseline ?? popRHR
        let sb = sleepBaseline ?? popSleep
        let stb = strainBaseline ?? (mean: 10.0, std: 4.0)
        let rrb = respiratoryBaseline ?? popRR
        _ = stb  // retained for breakdown completeness; strain no longer subtracts from composite

        func z(_ v: Double, _ b: (mean: Double, std: Double)) -> Double {
            guard b.std > 1e-6 else { return 0 }
            return max(-3.0, min(3.0, (v - b.mean) / b.std))
        }

        func zToScore(_ z: Double, _ positive: Bool) -> Double {
            let signed = positive ? z : -z
            return 50.0 + 40.0 * tanh(signed)
        }

        // --- 1. Autonomic Recovery (Phase 2: HRV + RHR + RR + balance, NO strain) ---
        //
        // Confidence-shrunk z-scores: low signal quality blends toward population mean (z=0).
        // Effective weights renormalize when RR is unavailable.
        let rawHrvZ = hrv.map { z($0, hb) } ?? 0
        let rawRhrZ = rhr.map { z($0, rb) } ?? 0
        let rawRrZ  = respiratoryRate.map { z($0, rrb) } ?? 0

        let hrvZ_eff = rawHrvZ * confHRV
        let rhrZ_eff = rawRhrZ * confRHR
        let rrZ_eff  = rawRrZ  * confRR

        // Coupled response: HRV up + RHR down rewarded. (Both eff terms move opposite → negative sum → positive balance.)
        let balance = -((hrvZ_eff + rhrZ_eff) / 2.0)

        let autonomicComposite: Double
        if confRR > 0 {
            autonomicComposite =
                0.45 * hrvZ_eff
              - 0.25 * rhrZ_eff
              - 0.20 * rrZ_eff
              + 0.10 * balance
        } else {
            // RR unavailable — renormalize HRV/RHR to 0.55/0.30, balance 0.05.
            autonomicComposite =
                0.55 * hrvZ_eff
              - 0.30 * rhrZ_eff
              + 0.05 * balance
        }
        let autonomicRecovery = clampScore(zToScore(autonomicComposite, true))

        // --- 2. Sleep Quantity vs Personalized Need ---
        // Meeting need = 100. Falling short scales linearly. Sleeping past need
        // doesn't earn extra (no oversleep bonus).
        let sleepNeedMin = sb.mean
        let quantityRatio = sleepNeedMin > 0 ? min(Double(sleepMinutes) / sleepNeedMin, 1.0) : 0
        let rawQuantity = clampScore(quantityRatio * 100)

        // --- 3. Sleep Efficiency ---
        let rawEfficiency = clampScore(sleepEfficiencyPct)

        // --- 4. Circadian Alignment (asymptotic floor: never hard-zero) ---
        let rawCircadian = 15 + 85 * circadianAlignment

        // --- 5. Sleep Consistency (no timing penalty; naps get 25% credit) ---
        let rawConsistency = clampScore(consistencyScore)
        let napConsistencyFactor: Double = sleepType == .nap ? 0.25 : 1.0

        // --- 6. Sleep Fragmentation (no timing penalty; naps get 25% credit) ---
        let fragPerHour = totalSleepHours > 0 ? Double(briefWakeCount) / totalSleepHours : 0
        let fragScore: Double
        if fragPerHour <= 1.0 { fragScore = 90 }
        else if fragPerHour <= 2.0 { fragScore = 70 + 20 * (1.0 - (fragPerHour - 1.0)) }
        else if fragPerHour <= 4.0 { fragScore = 40 + 30 * (1.0 - (fragPerHour - 2.0) / 2.0) }
        else { fragScore = 20 }
        let rawFragmentation = clampScore(fragScore)

        // --- 7. Stage Quality ---
        let expectedDeep = 0.20
        let expectedREM = 0.25
        // Guard against malformed stage percentages from upstream detector.
        let deepClamped = (0...1).contains(deepPct) ? deepPct : 0
        let remClamped  = (0...1).contains(remPct)  ? remPct  : 0
        let deepScore = min(deepClamped / expectedDeep, 1.0)
        let remScore  = min(remClamped  / expectedREM, 1.0)
        let rawStage = clampScore((deepScore * 0.5 + remScore * 0.5) * 100)

        // --- Per-component timing modifiers ---
        let (qtyMod, effMod, stageMod) = sleepTypeModifiers(for: sleepType, circadianPenalty: circadianPenalty)

        let effectiveQuantity = clampScore(rawQuantity * qtyMod)
        let effectiveEfficiency = clampScore(rawEfficiency * effMod)
        let effectiveStageQuality = clampScore(rawStage * stageMod)

        // --- Composite (naps: consistency + fragmentation at 25% credit) ---
        var finalScore = clampScore(
            autonomicRecovery     * RecoveryBreakdown.weightAutonomic
            + effectiveQuantity   * RecoveryBreakdown.weightQuantity
            + effectiveEfficiency * RecoveryBreakdown.weightEfficiency
            + rawCircadian        * RecoveryBreakdown.weightCircadian
            + rawConsistency * napConsistencyFactor * RecoveryBreakdown.weightConsistency
            + rawFragmentation * napConsistencyFactor * RecoveryBreakdown.weightFragmentation
            + effectiveStageQuality * RecoveryBreakdown.weightStageQuality
        )

        // --- Phase 2 hidden-state modulation ---
        // Capacity 0..1 dampens output ±15%. Illness latch further damps ×0.85.
        let capacityClamped = max(0.2, min(1.0, readinessCapacity))
        finalScore = clampScore(finalScore * (0.85 + 0.15 * capacityClamped))
        if illnessFlag { finalScore = clampScore(finalScore * 0.85) }

        // --- Confidence ---
        let hasHRV = hrv != nil ? 1.0 : 0.0
        let hasRHR = rhr != nil ? 1.0 : 0.0
        let hasStages = sleepMinutes > 0 && deepPct >= 0 && remPct >= 0 ? 1.0 : 0.0
        let hasStrain = strain != nil ? 1.0 : 0.0
        let confidence = 0.30 * hasHRV + 0.30 * hasRHR + 0.20 * hasStages + 0.20 * hasStrain

        let breakdown = RecoveryBreakdown(
            overallScore: finalScore.isFinite ? finalScore : 0,
            autonomicRecovery: autonomicRecovery.isFinite ? autonomicRecovery : 0,
            sleepQuantity: rawQuantity.isFinite ? rawQuantity : 0,
            sleepEfficiency: rawEfficiency.isFinite ? rawEfficiency : 0,
            circadianAlignment: rawCircadian.isFinite ? rawCircadian : 0,
            sleepConsistency: rawConsistency.isFinite ? rawConsistency : 0,
            sleepFragmentation: rawFragmentation.isFinite ? rawFragmentation : 0,
            stageQuality: rawStage.isFinite ? rawStage : 0,
            effectiveQuantity: effectiveQuantity.isFinite ? effectiveQuantity : 0,
            effectiveEfficiency: effectiveEfficiency.isFinite ? effectiveEfficiency : 0,
            effectiveStageQuality: effectiveStageQuality.isFinite ? effectiveStageQuality : 0,
            confidence: confidence.isFinite ? confidence : 0,
            circadianPenalty: circadianPenalty.isFinite ? circadianPenalty : 0,
            sleepTypeModifier: qtyMod.isFinite ? qtyMod : 0,
            biologicalDateKey: biologicalDateKey
        )
        return breakdown
    }

    // MARK: - Sleep Type Modifiers

    /// Per-component timing modifiers per sleep type.
    /// Only Quantity, Efficiency, and Stage Quality are modified.
    /// Autonomic, Consistency, Fragmentation pass through.
    private static func sleepTypeModifiers(
        for type: SleepEpisodeType,
        circadianPenalty: Double
    ) -> (quantity: Double, efficiency: Double, stageQuality: Double) {
        let cp = circadianPenalty
        switch type {
        case .mainSleep:
            return (1.0, 1.0, 1.0)
        case .delayedMainSleep:
            return (0.85 * (1.0 - 0.20 * cp),
                    0.90 * (1.0 - 0.10 * cp),
                    0.85 * (1.0 - 0.15 * cp))
        case .compensatorySleep:
            return (0.50 * (1.0 - 0.20 * cp),
                    0.75 * (1.0 - 0.10 * cp),
                    0.60 * (1.0 - 0.15 * cp))
        case .nap:
            return (0.0, 0.0, 0.0)
        }
    }

    private static func clampScore(_ v: Double) -> Double {
        guard !v.isNaN, !v.isInfinite else { return 0 }
        return max(0, min(100, v))
    }
}
