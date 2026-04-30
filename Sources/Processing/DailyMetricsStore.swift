import Foundation

/// Persists DailyMetrics (one row per UTC calendar day) and algorithm version stamps.
/// Files: daily_metrics_v1.json, algorithm_versions_v1.json in Documents/
actor DailyMetricsStore {

    struct DailyMetrics: Codable, Sendable {
        let date: String        // "2025-04-27" UTC ISO
        var rhr: Double?        // resting HR in BPM
        var hrvRmssd: Double?   // RMSSD in ms
        var hrvSdnn: Double?    // SDNN in ms
        var strainScore: Double? // 0.0–21.0
        var sleepMinutes: Int?
        // Algorithm version stamps — bump AlgoVersions constants to trigger backfill.
        var hrvVersion: Int
        var strainVersion: Int
        var sleepVersion: Int
    }

    struct AlgorithmVersion: Codable, Sendable {
        let name: String    // "hrv" | "strain" | "sleep"
        var version: Int
        var updatedAt: Int  // unix seconds
    }

    private let metricsURL: URL
    private let versionsURL: URL
    private var metrics:  [DailyMetrics]     = []
    private var versions: [AlgorithmVersion] = []

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        metricsURL  = docs.appendingPathComponent("daily_metrics_v1.json")
        versionsURL = docs.appendingPathComponent("algorithm_versions_v1.json")
        if let data = try? Data(contentsOf: metricsURL),
           let decoded = try? JSONDecoder().decode([DailyMetrics].self, from: data) {
            metrics = decoded
        }
        if let data = try? Data(contentsOf: versionsURL),
           let decoded = try? JSONDecoder().decode([AlgorithmVersion].self, from: data) {
            versions = decoded
        }
    }

    // MARK: - DailyMetrics CRUD

    func upsert(_ m: DailyMetrics) {
        if let idx = metrics.firstIndex(where: { $0.date == m.date }) {
            metrics[idx] = m
        } else {
            metrics.append(m)
        }
        saveMetrics()
    }

    func delete(date: String) {
        metrics.removeAll { $0.date == date }
        saveMetrics()
    }

    func load(date: String) -> DailyMetrics? {
        metrics.first { $0.date == date }
    }

    func loadAll() -> [DailyMetrics] { metrics }

    /// Returns ISO date strings where the named metric's stored version is below `version`.
    func datesNeedingRecompute(metric: String, below version: Int) -> [String] {
        metrics.filter { m in
            switch metric {
            case "hrv":    return m.hrvVersion    < version
            case "strain": return m.strainVersion < version
            case "sleep":  return m.sleepVersion  < version
            default:       return false
            }
        }.map(\.date)
    }

    // MARK: - Algorithm versions

    func loadVersions() -> [AlgorithmVersion] { versions }

    func storedVersion(name: String) -> Int {
        versions.first(where: { $0.name == name })?.version ?? 0
    }

    func saveVersion(_ v: AlgorithmVersion) {
        if let idx = versions.firstIndex(where: { $0.name == v.name }) {
            versions[idx] = v
        } else {
            versions.append(v)
        }
        saveVersions()
    }

    // MARK: - Persistence

    private func saveMetrics() {
        let snapshot = metrics; let url = metricsURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveVersions() {
        let snapshot = versions; let url = versionsURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
