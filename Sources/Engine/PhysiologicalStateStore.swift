import Foundation

/// Single source of truth for derived physiological state.
///
/// Architecture:
///   - Accepts `PhysiologyEvent`s from any caller (BLEManager, SyncManager, BackgroundEngine).
///   - Decides which subsystems to invalidate based on the event type.
///   - Delegates actual computation to the existing RecomputeQueue + DayRecomputer pipeline.
///   - Publishes state changes back to the @MainActor UI layer via `onStateChanged` callback.
///
/// This is deliberately a thin wrapper in its first iteration — it intercepts all
/// enqueue call sites without changing computation behavior, establishing the event bus
/// and single-dispatch point before deeper refactors in later steps.
actor PhysiologicalStateStore {

    // MARK: - Public state

    struct PhysiologicalState: Sendable {
        var acuteFatigue: Double       = 0   // 7-day rolling avg strain
        var chronicLoad: Double        = 0   // 28-day rolling avg strain
        var sleepDebt: Double          = 0   // hours below sleep need, rolling 7d
        var autonomicStress: Double    = 0   // HRV z-score vs 60d baseline (negative = stressed)
        var readinessCapacity: Double  = 0   // 0–100 composite recovery score
        var lastUpdated: Date          = .distantPast
        var algorithmVersion: Int      = AlgoVersions.recovery
    }

    private(set) var currentState = PhysiologicalState()

    // MARK: - Dependencies (injected)

    private let queue: RecomputeQueue
    let featureCache    = FeatureCache()
    let snapshotStore   = SnapshotStore()
    private var rawStore: RawDataStore?
    private var dailyStore: DailyMetricsStore?

    /// Called on @MainActor after state changes so BLEManager can update @Published vars.
    var onStateChanged: (@MainActor @Sendable (PhysiologicalState) -> Void)?

    // MARK: - Init

    init(queue: RecomputeQueue) {
        self.queue = queue
    }

    func configure(rawStore: RawDataStore, dailyStore: DailyMetricsStore) {
        self.rawStore   = rawStore
        self.dailyStore = dailyStore
    }

    // MARK: - Event handling

    func handle(_ event: PhysiologyEvent) async {
        switch event {

        case .recomputeRequested(let date):
            await featureCache.markDirty([.hrv, .rhr, .sleep, .strain], for: isoKey(date))
            await enqueue(dates: [date])

        case .batchSyncCompleted(let dates):
            for date in dates {
                await featureCache.markDirty([.hrv, .rhr, .sleep, .strain], for: isoKey(date))
            }
            await enqueue(dates: dates)

        case .forceRecomputeAll:
            await featureCache.markAllDirty([.hrv, .rhr, .sleep, .strain, .respiratory])
            let today = Date()
            var days: [Date] = []
            for offset in 0..<14 {
                if let d = Calendar.current.date(byAdding: .day, value: -offset, to: today) {
                    days.append(d)
                }
            }
            await enqueue(dates: days)

        case .sleepEnded(let session):
            await featureCache.markDirty([.sleep, .hrv], for: isoKey(session.start))
            await featureCache.markDirty([.sleep, .hrv], for: isoKey(session.end))
            await enqueue(dates: [session.start, session.end])

        case .sleepDeleted(let id):
            // Evict today + yesterday — we don't have the session dates anymore
            let today = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
            await featureCache.markDirty([.sleep], for: isoKey(today))
            await featureCache.markDirty([.sleep], for: isoKey(yesterday))
            await enqueue(dates: [today, yesterday])
            _ = id  // referenced in event for future targeted eviction

        case .workoutCompleted(let start, let end, _):
            await featureCache.markDirty([.strain], for: isoKey(start))
            await featureCache.markDirty([.strain], for: isoKey(end))
            await enqueue(dates: [start, end])

        case .baselineShifted:
            // Baseline shift affects all derived features across all days
            await featureCache.markAllDirty([.hrv, .rhr, .sleep, .strain])
            currentState.lastUpdated = Date()
            await notifyUI()

        case .hrvUpdated, .respiratoryUpdated:
            // Live stream events — update state timestamp, no heavy recompute
            currentState.lastUpdated = Date()
            await notifyUI()
        }
    }

    // MARK: - Date helper

    private func isoKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - State update (called from DailyMetricsStore after recompute)

    /// Merge freshly computed scores into the live state and notify UI.
    func updateScores(
        readiness: Double,
        acuteFatigue: Double,
        chronicLoad: Double,
        sleepDebt: Double,
        autonomicStress: Double
    ) async {
        currentState.readinessCapacity = readiness
        currentState.acuteFatigue      = acuteFatigue
        currentState.chronicLoad       = chronicLoad
        currentState.sleepDebt         = sleepDebt
        currentState.autonomicStress   = autonomicStress
        currentState.lastUpdated       = Date()
        await notifyUI()
    }

    // MARK: - Private helpers

    private func enqueue(dates: [Date], completion: (@Sendable () async -> Void)? = nil) async {
        guard let raw = rawStore, let daily = dailyStore else {
            print("[PhysiologicalStateStore] enqueue skipped — stores not configured")
            return
        }
        let store = self
        await queue.enqueue(dates: dates, rawStore: raw, dailyStore: daily) {
            await store.notifyUI()
            await completion?()
        }
    }

    private func notifyUI() async {
        let state = currentState
        let callback = onStateChanged
        await MainActor.run {
            callback?(state)
        }
    }
}
