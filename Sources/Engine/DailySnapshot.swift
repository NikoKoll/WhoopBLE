import Foundation

/// Immutable summary of a finalized physiological day.
///
/// Created after each `recomputeDay` completes. Today's snapshot is `isMutable = true`
/// until the next biological day begins (new wake after 6h of prior sleep end).
/// Persisted to Documents/snapshots_v1.json — available on cold launch before BLE connects.
struct DailySnapshot: Codable, Sendable, Identifiable {
    var id: String { dateKey }

    let dateKey: String           // "yyyy-MM-dd" bio-day key (UTC)
    let finalizedAt: Date
    let recoveryScore: Double?
    let strain: Double?
    let sleepMinutes: Int?
    let sleepNeedMinutes: Int?
    let sleepDebt: Double         // hours below need
    let hrvRMSSD: Double?
    let rhr: Double?
    let algorithmVersion: Int
    var isMutable: Bool           // false once next bio-day begins
}

// MARK: - SnapshotStore

/// Manages DailySnapshot persistence in Documents/snapshots_v1.json.
/// Retains last 30 days; prunes older entries on write.
actor SnapshotStore {

    private let url: URL
    private let maxDays = 30

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("snapshots_v1.json")
    }

    // MARK: - Read

    func loadAll() -> [DailySnapshot] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DailySnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    func load(dateKey: String) -> DailySnapshot? {
        loadAll().first { $0.dateKey == dateKey }
    }

    func loadToday() -> DailySnapshot? {
        load(dateKey: todayKey())
    }

    // MARK: - Write

    func upsert(_ snapshot: DailySnapshot) {
        var all = loadAll().filter { $0.dateKey != snapshot.dateKey }
        all.append(snapshot)
        // Prune to last maxDays
        let sorted = all.sorted { $0.dateKey > $1.dateKey }
        let pruned = Array(sorted.prefix(maxDays))
        persist(pruned)
    }

    /// Finalize all mutable snapshots older than today (called on bio-day transition).
    func finalizeOlderThan(dateKey: String) {
        var all = loadAll()
        for i in all.indices where all[i].dateKey < dateKey {
            all[i].isMutable = false
        }
        persist(all.sorted { $0.dateKey > $1.dateKey })
    }

    // MARK: - Private

    private func persist(_ snapshots: [DailySnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func todayKey() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
