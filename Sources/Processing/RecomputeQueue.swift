import Foundation
import HealthKit

/// Deduplicating background queue for day recomputation.
/// Accepts date strings, deduplicates, drains serially at background priority.
actor RecomputeQueue {

    private var pending:       Set<String> = []  // ISO date strings "2025-04-27"
    private var processed:     Set<String> = []  // dates already drained this session
    private var isRunning:     Bool = false
    private var rawStore:      RawDataStore?
    private var dailyStore:    DailyMetricsStore?
    private var healthKit:     HealthKitWriter?
    private var featureCache:  FeatureCache?
    private var snapshotStore: SnapshotStore?
    private let recomputer     = DayRecomputer()
    private var onComplete: [@Sendable () async -> Void] = []
    private var onScoresUpdated: DayRecomputer.ScoresUpdate?

    /// Inject dependencies for recompute calls. `onScoresUpdated` fires per bio-day with
    /// newly computed hidden physiological state; PhysiologicalStateStore wires this to
    /// `updateScores` so the @MainActor UI sees fresh capacity/ATL/CTL/debt/stress.
    func configure(
        healthKit: HealthKitWriter,
        featureCache: FeatureCache? = nil,
        snapshotStore: SnapshotStore? = nil,
        onScoresUpdated: DayRecomputer.ScoresUpdate? = nil
    ) {
        self.healthKit       = healthKit
        self.featureCache    = featureCache
        self.snapshotStore   = snapshotStore
        if let cb = onScoresUpdated { self.onScoresUpdated = cb }
    }

    /// Enqueue one or more dates. Starts drain loop if not already running.
    /// `completion` fires on the caller's context after drain finishes (or immediately if idle).
    func enqueue(
        dates: [Date],
        rawStore: RawDataStore,
        dailyStore: DailyMetricsStore,
        completion: (@Sendable () async -> Void)? = nil
    ) {
        self.rawStore   = rawStore
        self.dailyStore = dailyStore
        if let c = completion { self.onComplete.append(c) }
        var rebuiltCount = 0
        for date in dates {
            let key = isoDate(for: date)
            pending.insert(key)
            // Hidden-state prev-chain repair: if this date predates any already-processed
            // date, those downstream rows ran without correct prev physiology. Push them
            // back so ATL/CTL/capacity/sleepDebt reconstruct in order.
            if let earliest = processed.min(), key < earliest {
                for p in processed where p >= key {
                    pending.insert(p)
                    rebuiltCount += 1
                }
                processed.subtract(pending)
            }
        }
        if rebuiltCount > 0 {
            print("[Recompute] prev-chain repair: re-enqueued \(rebuiltCount) downstream date(s)")
        }
        print("[Recompute] queued \(dates.count) date(s) — pending=\(pending.count)")
        guard !isRunning else { return }
        isRunning = true
        Task.detached(priority: .background) { [weak self] in
            await self?.drain()
        }
    }

    // MARK: - Private

    private func drain() async {
        while !pending.isEmpty {
            // Drain ascending so hidden-state prev-chain (ATL/CTL/capacity/sleepDebt)
            // reconstructs forward through history. Random Set order would corrupt
            // EWMA continuity for backfills > 1 day.
            let key = pending.sorted().first!
            pending.remove(key)
            guard let date = parseISODate(key),
                  let raw = rawStore,
                  let daily = dailyStore else { continue }
            print("[Recompute] processing \(key)")
            await recomputer.recomputeDay(date: date, rawStore: raw, dailyStore: daily, healthKit: healthKit, featureCache: featureCache, snapshotStore: snapshotStore, onScoresUpdated: onScoresUpdated)
            processed.insert(key)
        }
        isRunning = false
        print("[RecomputeQueue] drain complete")
        let callbacks = onComplete
        onComplete = []
        for cb in callbacks { await cb() }
    }

    // MARK: - Date helpers

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func parseISODate(_ str: String) -> Date? {
        let parts = str.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        dc.hour = 0; dc.minute = 0; dc.second = 0
        return cal.date(from: dc)
    }
}
