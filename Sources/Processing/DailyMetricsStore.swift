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
        var sleepNeedMinutes: Int? = nil  // personalized nightly need (SleepNeedCalculator)
        var recoveryScore: Double? = nil // 0–100
        // Algorithm version stamps — bump AlgoVersions constants to trigger backfill.
        var hrvVersion: Int
        var strainVersion: Int
        var sleepVersion: Int
        var recoveryVersion: Int = 0
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
            case "hrv":      return m.hrvVersion      < version
            case "strain":   return m.strainVersion   < version
            case "sleep":    return m.sleepVersion    < version
            case "recovery": return m.recoveryVersion < version
            default:         return false
            }
        }.map(\.date)
    }

    // MARK: - Baselines

    /// Rolling N-day mean and std for any Double? field. Excludes `excludingDate` so today's
    /// partial data doesn't bias its own baseline.
    func rollingBaseline(
        _ extract: (DailyMetrics) -> Double?,
        excluding excludingDate: String? = nil,
        days: Int = 30
    ) -> (mean: Double, std: Double)? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let values = metrics.filter { m in
            m.date != excludingDate && isoToDate(m.date) >= cutoff
        }.compactMap { extract($0) }
        guard values.count >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return (mean, sqrt(variance))
    }

    private func isoToDate(_ s: String) -> Date {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        return cal.date(from: dc) ?? .distantPast
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

// Custom decoder in extension so the struct retains its synthesized memberwise init.
// Old JSON lacks recoveryScore/recoveryVersion — decodeIfPresent + defaults handle that.
extension DailyMetricsStore.DailyMetrics {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date            = try c.decode(String.self,          forKey: .date)
        rhr             = try c.decodeIfPresent(Double.self, forKey: .rhr)
        hrvRmssd        = try c.decodeIfPresent(Double.self, forKey: .hrvRmssd)
        hrvSdnn         = try c.decodeIfPresent(Double.self, forKey: .hrvSdnn)
        strainScore     = try c.decodeIfPresent(Double.self, forKey: .strainScore)
        sleepMinutes     = try c.decodeIfPresent(Int.self,    forKey: .sleepMinutes)
        sleepNeedMinutes = try c.decodeIfPresent(Int.self,    forKey: .sleepNeedMinutes)
        recoveryScore    = try c.decodeIfPresent(Double.self, forKey: .recoveryScore)
        hrvVersion      = try c.decodeIfPresent(Int.self,    forKey: .hrvVersion)      ?? 0
        strainVersion   = try c.decodeIfPresent(Int.self,    forKey: .strainVersion)   ?? 0
        sleepVersion    = try c.decodeIfPresent(Int.self,    forKey: .sleepVersion)    ?? 0
        recoveryVersion = try c.decodeIfPresent(Int.self,    forKey: .recoveryVersion) ?? 0
    }
}
