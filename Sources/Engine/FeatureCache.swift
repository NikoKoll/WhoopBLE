import Foundation

/// In-memory cache for derived rolling-window features, keyed by ISO date string.
///
/// Prevents redundant computation when `recomputeDay` fires for a date whose
/// inputs haven't changed. The cache is invalidated per-feature via dirty flags
/// that `PhysiologicalStateStore` sets whenever a relevant `PhysiologyEvent` arrives.
///
/// This is a pure performance layer — it never changes output values.
actor FeatureCache {

    // MARK: - Types

    enum DirtyFlag: Hashable {
        case hrv
        case rhr
        case sleep
        case strain
        case respiratory
    }

    struct CachedFeatures {
        var hrvDeviation: Metric<Double>?
        var rhrDeviation: Metric<Double>?
        var respiratoryDeviation: Metric<Double>?
        var sleepDebt: Metric<Double>?
        var sleepConsistency: Metric<Double>?
        var chronicLoad: Metric<Double>?       // CTL — EWMA strainLoad α=0.069
        var acuteFatigue: Metric<Double>?      // ATL — EWMA strainLoad α=0.27
        var autonomicStress: Metric<Double>?   // EWMA of -hrvZ + rhrZ + rrZ
        var readinessCapacity: Metric<Double>? // 0..1 hidden modulator
        var strainTolerance: Metric<Double>?   // 0.5..1.5
        var illnessFlag: Bool?
        var dirtyFlags: Set<DirtyFlag>
        var computedAt: Date
    }

    // MARK: - Storage

    private var cache: [String: CachedFeatures] = [:]

    // MARK: - Public API

    /// Returns cached features for `dateKey` if they exist and are not dirty.
    /// Returns nil if the cache is cold or any feature is stale.
    func features(for dateKey: String) -> CachedFeatures? {
        guard let entry = cache[dateKey] else { return nil }
        return entry.dirtyFlags.isEmpty ? entry : nil
    }

    /// Store computed features for `dateKey`. Merges with existing entry so
    /// clean fields from a prior call are preserved.
    func upsert(_ partial: CachedFeatures, for dateKey: String) {
        var merged = cache[dateKey] ?? CachedFeatures(dirtyFlags: [], computedAt: Date())
        if let v = partial.hrvDeviation         { merged.hrvDeviation         = v }
        if let v = partial.rhrDeviation         { merged.rhrDeviation         = v }
        if let v = partial.respiratoryDeviation { merged.respiratoryDeviation = v }
        if let v = partial.sleepDebt            { merged.sleepDebt            = v }
        if let v = partial.sleepConsistency     { merged.sleepConsistency     = v }
        if let v = partial.chronicLoad          { merged.chronicLoad          = v }
        if let v = partial.acuteFatigue         { merged.acuteFatigue         = v }
        if let v = partial.autonomicStress      { merged.autonomicStress      = v }
        if let v = partial.readinessCapacity    { merged.readinessCapacity    = v }
        if let v = partial.strainTolerance      { merged.strainTolerance      = v }
        if let v = partial.illnessFlag          { merged.illnessFlag          = v }
        // Clear only the flags whose features were just recomputed
        merged.dirtyFlags.subtract(flagsPresent(in: partial))
        merged.computedAt = Date()
        cache[dateKey] = merged
    }

    /// Mark features dirty for a date. Called by PhysiologicalStateStore on event dispatch.
    func markDirty(_ flags: Set<DirtyFlag>, for dateKey: String) {
        cache[dateKey, default: CachedFeatures(dirtyFlags: [], computedAt: Date())]
            .dirtyFlags.formUnion(flags)
    }

    /// Mark all cached dates dirty for a set of flags (e.g., after baseline shift).
    func markAllDirty(_ flags: Set<DirtyFlag>) {
        for key in cache.keys {
            cache[key]?.dirtyFlags.formUnion(flags)
        }
    }

    /// Remove a specific date from cache (e.g., after delete).
    func evict(dateKey: String) {
        cache.removeValue(forKey: dateKey)
    }

    /// Evict all entries older than `days`.
    func pruneOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        cache = cache.filter { _, entry in entry.computedAt >= cutoff }
    }

    // MARK: - Helpers

    private func flagsPresent(in features: CachedFeatures) -> Set<DirtyFlag> {
        var present: Set<DirtyFlag> = []
        if features.hrvDeviation         != nil { present.insert(.hrv) }
        if features.rhrDeviation         != nil { present.insert(.rhr) }
        if features.respiratoryDeviation != nil { present.insert(.respiratory) }
        if features.sleepDebt            != nil { present.insert(.sleep) }
        if features.sleepConsistency     != nil { present.insert(.sleep) }
        if features.chronicLoad          != nil { present.insert(.strain) }
        if features.acuteFatigue         != nil { present.insert(.strain) }
        if features.autonomicStress      != nil { present.insert(.hrv) }
        return present
    }
}

// Convenience: allow CachedFeatures to be created with defaults
extension FeatureCache.CachedFeatures {
    init(dirtyFlags: Set<FeatureCache.DirtyFlag>, computedAt: Date) {
        self.dirtyFlags         = dirtyFlags
        self.computedAt         = computedAt
        self.hrvDeviation       = nil
        self.rhrDeviation       = nil
        self.respiratoryDeviation = nil
        self.sleepDebt          = nil
        self.sleepConsistency   = nil
        self.chronicLoad        = nil
        self.acuteFatigue       = nil
        self.autonomicStress    = nil
        self.readinessCapacity  = nil
        self.strainTolerance    = nil
        self.illnessFlag        = nil
    }
}
