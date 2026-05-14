import Foundation

struct CircadianMetrics: Sendable {
    let habitualMidpointMin: Int     // minutes from midnight (local)
    let sessionMidpointMin: Int      // minutes from midnight (local) for this session
    let deviationMinutes: Double     // absolute deviation from habitual
    let penalty: Double              // 0.0–1.0
    let isAdapting: Bool             // true during phase-shift adaptation window
    let adaptationDaysRemaining: Int // 0 when stable
    let rollingConsistencyMinutes: Double // std-dev of last 7 midpoints
}

final class CircadianEngine {
    private var midpointHistory: [Date: Int] = [:]  // session end date → midpoint minutes from midnight local
    private var habitualMidpoint: Int?               // minutes from midnight local

    private let adaptationWindowDays = 5
    private let phaseShiftThreshold: Double = 120   // minutes
    private let phaseShiftConsecutiveSessions = 3
    private let penaltyHalfWindow: Double = 180     // minutes for penalty to reach ~0.5
    private let maxHistoryDays = 60
    private let minHistoryForBaseline = 3

    private var consecutiveDeviations: Int = 0
    private var adaptingSince: Date?
    private var targetMidpoint: Int?

    init() {}

    func recordSession(session: SleepSession, localMidpointMin: Int) {
        let key = Calendar.current.startOfDay(for: session.end)
        midpointHistory[key] = localMidpointMin
        pruneHistory()
        recomputeBaseline()
    }

    /// Type-gated overload. Only main + delayed-main sessions contribute to the
    /// habitual midpoint baseline. Naps and compensatory sleep have midpoints in
    /// the wrong window and would saturate the penalty to ~1.0 on real sleep.
    func recordSession(session: SleepSession, type: SleepEpisodeType, localMidpointMin: Int) {
        guard type == .mainSleep || type == .delayedMainSleep else { return }
        recordSession(session: session, localMidpointMin: localMidpointMin)
    }

    func compute(for session: SleepSession) -> CircadianMetrics {
        let localMid = midpointMinutes(from: session)
        let habitual = habitualMidpoint ?? localMid
        let dev = abs(Double(localMid - habitual))
        let penalty = dev > 0 ? pow(min(1.0, dev / penaltyHalfWindow), 1.5) : 0

        let isAdapting = adaptingSince != nil
        let daysRemaining: Int
        if let start = adaptingSince {
            let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
            daysRemaining = max(0, adaptationWindowDays - elapsed)
        } else {
            daysRemaining = 0
        }

        let consistency = rollingMidpointStdDev()

        return CircadianMetrics(
            habitualMidpointMin: habitual,
            sessionMidpointMin: localMid,
            deviationMinutes: dev,
            penalty: penalty,
            isAdapting: isAdapting,
            adaptationDaysRemaining: daysRemaining,
            rollingConsistencyMinutes: consistency
        )
    }

    func clearHistory() {
        midpointHistory.removeAll()
        habitualMidpoint = nil
        consecutiveDeviations = 0
        adaptingSince = nil
        targetMidpoint = nil
    }

    var baselineExists: Bool {
        habitualMidpoint != nil && midpointHistory.count >= minHistoryForBaseline
    }

    // MARK: - Private

    private func midpointMinutes(from session: SleepSession) -> Int {
        let duration = session.end.timeIntervalSince(session.start)
        let mid = session.start.addingTimeInterval(duration / 2)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: mid)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func pruneHistory() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) else { return }
        midpointHistory = midpointHistory.filter { $0.key >= cutoff }
    }

    private func recomputeBaseline() {
        let recent = midpointHistory.sorted { $0.key > $1.key }
        guard recent.count >= minHistoryForBaseline else { return }

        let weighted = recent.enumerated().map { idx, entry in
            let weight = 1.0 / Double(idx + 1)  // recent sessions weighted higher
            return (weight: weight, value: Double(entry.value))
        }
        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        let weightedAvg = weighted.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
        let newMidpoint = Int(weightedAvg.rounded())

        if let current = habitualMidpoint {
            let shift = abs(Double(newMidpoint - current))
            if shift > phaseShiftThreshold {
                consecutiveDeviations += 1
            } else {
                consecutiveDeviations = 0
                adaptingSince = nil
                targetMidpoint = nil
            }

            if consecutiveDeviations >= phaseShiftConsecutiveSessions && adaptingSince == nil {
                adaptingSince = Date()
                targetMidpoint = newMidpoint
            }

            if let target = targetMidpoint, let since = adaptingSince {
                let elapsed = Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0
                let progress = min(1.0, Double(elapsed) / Double(adaptationWindowDays))
                let interpolated = Double(current) + (Double(target) - Double(current)) * progress
                habitualMidpoint = Int(interpolated.rounded())
            } else {
                habitualMidpoint = newMidpoint
            }
        } else {
            habitualMidpoint = newMidpoint
        }
    }

    private func rollingMidpointStdDev() -> Double {
        let recent = midpointHistory.sorted { $0.key > $1.key }.prefix(7).map { Double($0.value) }
        guard recent.count >= 2 else { return 0 }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.map { pow($0 - mean, 2) }.reduce(0, +) / Double(recent.count - 1)
        return sqrt(variance)
    }
}
