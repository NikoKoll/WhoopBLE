import Foundation

@MainActor
final class MetricsStore: ObservableObject {

    // MARK: - HR / HRV entries (1 per 30 s, 7-day retention)

    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let heartRate: Int
        let hrv: Double?

        init(timestamp: Date, heartRate: Int, hrv: Double?) {
            self.id        = UUID()
            self.timestamp = timestamp
            self.heartRate = heartRate
            self.hrv       = hrv
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let entriesURL: URL
    private var lastSavedTimestamp: Date?
    private let minInterval: TimeInterval = 30
    private let maxAge:      TimeInterval = 7 * 24 * 3600

    // MARK: - Daily steps

    struct DailySteps: Codable, Identifiable, Sendable {
        var id: Date    // start of calendar day
        var steps: Int
    }

    @Published private(set) var dailySteps: [DailySteps] = []
    private let stepsURL: URL

    // Cached daySummaries — invalidated only when entries or dailySteps actually mutate.
    private var cachedSummaries: [DaySummary]?

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        entriesURL = docs.appendingPathComponent("metrics_history_v1.json")
        stepsURL   = docs.appendingPathComponent("steps_history_v1.json")
        loadEntries()
        loadSteps()
    }

    // MARK: - HR/HRV recording

    func record(timestamp: Date, heartRate: Int, hrv: Double?) {
        if let last = lastSavedTimestamp, timestamp.timeIntervalSince(last) < minInterval { return }
        lastSavedTimestamp = timestamp
        entries.append(Entry(timestamp: timestamp, heartRate: heartRate, hrv: hrv))
        pruneEntries()
        cachedSummaries = nil
        saveEntries()
    }

    // MARK: - Steps recording

    /// Called from CMPedometer — count is today's running total (replace, not add).
    func setTodaySteps(_ count: Int) {
        guard count > 0 else { return }
        let day = Calendar.current.startOfDay(for: Date())
        upsertSteps(day: day, count: count, additive: false)
    }

    /// Called from SyncManager per batch — count is a partial batch total (accumulate per day).
    func addHistoricalSteps(_ count: Int, for date: Date) {
        guard count > 0 else { return }
        let day = Calendar.current.startOfDay(for: date)
        upsertSteps(day: day, count: count, additive: true)
    }

    private func upsertSteps(day: Date, count: Int, additive: Bool) {
        if let idx = dailySteps.firstIndex(where: { $0.id == day }) {
            let newVal = additive ? dailySteps[idx].steps + count : max(dailySteps[idx].steps, count)
            guard newVal != dailySteps[idx].steps else { return }
            dailySteps[idx].steps = newVal
        } else {
            dailySteps.append(DailySteps(id: day, steps: count))
            dailySteps.sort { $0.id < $1.id }
        }
        cachedSummaries = nil
        saveSteps()
    }

    // MARK: - Computed aggregates

    struct DaySummary: Identifiable {
        let id: Date
        let avgHR: Int
        let minHR: Int
        let maxHR: Int
        let avgHRV: Double?
        let steps: Int?
    }

    var daySummaries: [DaySummary] {
        if let cached = cachedSummaries { return cached }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.timestamp) }
        let stepsByDay = Dictionary(uniqueKeysWithValues: dailySteps.map { ($0.id, $0.steps) })
        let allDays = Set(grouped.keys).union(stepsByDay.keys)
        let result = allDays.compactMap { day -> DaySummary? in
            let es = grouped[day] ?? []
            let hrs = es.map(\.heartRate)
            let hrvs = es.compactMap(\.hrv)
            let steps = stepsByDay[day]
            guard !hrs.isEmpty || steps != nil else { return nil }
            if hrs.isEmpty {
                return DaySummary(id: day, avgHR: 0, minHR: 0, maxHR: 0, avgHRV: nil, steps: steps)
            }
            return DaySummary(
                id: day,
                avgHR: hrs.reduce(0, +) / hrs.count,
                minHR: hrs.min()!,
                maxHR: hrs.max()!,
                avgHRV: hrvs.isEmpty ? nil : hrvs.reduce(0, +) / Double(hrvs.count),
                steps: steps
            )
        }.sorted { $0.id < $1.id }
        cachedSummaries = result
        return result
    }

    var last24hEntries: [Entry] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return entries.filter { $0.timestamp > cutoff }
    }

    var todaySteps: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return dailySteps.first(where: { $0.id == today })?.steps ?? 0
    }

    // MARK: - Persistence

    private func pruneEntries() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = entries.count
        entries = entries.filter { $0.timestamp > cutoff }
        if entries.count != before { cachedSummaries = nil }
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: entriesURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
        lastSavedTimestamp = decoded.last?.timestamp
    }

    private func saveEntries() {
        let snapshot = entries; let url = entriesURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadSteps() {
        guard let data = try? Data(contentsOf: stepsURL),
              let decoded = try? JSONDecoder().decode([DailySteps].self, from: data) else { return }
        dailySteps = decoded.sorted { $0.id < $1.id }
    }

    private func saveSteps() {
        let snapshot = dailySteps; let url = stepsURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
