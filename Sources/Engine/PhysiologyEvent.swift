import Foundation

/// All events that can trigger physiological recalculation.
/// Each case carries only the data needed to scope the recomputation — not
/// the full state — so the store can decide which subsystems to invalidate.
enum PhysiologyEvent: Sendable {
    /// A workout session completed.
    case workoutCompleted(start: Date, end: Date, energyKcal: Double)
    /// A sleep session was added or confirmed (live or from batch sync).
    case sleepEnded(session: SleepSession)
    /// A sleep session was manually deleted.
    case sleepDeleted(id: String)
    /// Live HRV updated from streaming RR intervals.
    case hrvUpdated(rmssd: Double, timestamp: Date)
    /// A long-term baseline shifted significantly (HRV or RHR).
    case baselineShifted(metric: String, newBaseline: Double)
    /// Respiratory rate updated from RSA derivation.
    case respiratoryUpdated(rate: Double, timestamp: Date)
    /// Batch sync completed; only the affected dates need recomputation.
    case batchSyncCompleted(dates: [Date])
    /// Recompute a single calendar day (existing RecomputeQueue.enqueue equivalent).
    case recomputeRequested(date: Date)
    /// Wipe feature cache and requeue all stored days (force-resync path).
    case forceRecomputeAll
}
