import Foundation

actor DailyMetricsStore {

    struct DailyMetrics: Codable, Sendable {
        let date: String
        var rhr: Double?
        var hrvRmssd: Double?
        var hrvSdnn: Double?
        var strainScore: Double?
        var sleepMinutes: Int?
        var sleepNeedMinutes: Int? = nil
        var recoveryScore: Double? = nil
        var biologicalDate: String? = nil
        var circadianPenalty: Double? = nil
        var sleepTypeCode: Int? = nil
        var recoveryConfidence: Double? = nil
        var sleepMidpointMin: Int? = nil
        var recoveryComponents: RecoveryBreakdown? = nil
        // Phase 2 — respiratory + hidden physiological state
        var respiratoryRate: Double? = nil          // breaths/min, sleep-window mean
        var respiratoryConfidence: Double? = nil    // 0..1
        var acuteFatigue: Double? = nil             // ATL (EWMA strainLoad, α=0.27)
        var chronicLoad: Double? = nil              // CTL (EWMA strainLoad, α=0.069)
        var autonomicStress: Double? = nil          // EWMA of -hrvZ+rhrZ+rrZ
        var sleepDebtMinutes: Double? = nil         // cumulative debt minutes, 0..600
        var readinessCapacity: Double? = nil        // 0..1 hidden modulator
        var strainTolerance: Double? = nil          // 0.5..1.5
        var illnessFlag: Bool? = nil
        var hrvVersion: Int
        var strainVersion: Int
        var sleepVersion: Int
        var recoveryVersion: Int = 0
        var physiologyVersion: Int = 0
        var respiratoryRateVersion: Int = 0
    }

    struct AlgorithmVersion: Codable, Sendable {
        let name: String
        var version: Int
        var updatedAt: Int
    }

    private let metricsURL: URL
    private let versionsURL: URL
    private var metrics:  [DailyMetrics]     = []
    private var versions: [AlgorithmVersion] = []

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        metricsURL  = docs.appendingPathComponent("daily_metrics_v1.json")
        versionsURL = docs.appendingPathComponent("algorithm_versions_v1.json")
        let decoder = JSONDecoder()
        // If stale file contains NaN tokens, delete it entirely.
        // NSJSONSerialization throws an ObjC exception on NaN (caught by All Exceptions
        // breakpoint) even with try?. Deleting avoids any parse attempt entirely.
        // Metrics recompute from raw HR/RR data on next launch.
        if let raw = try? Data(contentsOf: metricsURL) {
            let text = String(decoding: raw, as: UTF8.self)
            if text.contains("NaN") || text.contains("Inf") {
                try? FileManager.default.removeItem(at: metricsURL)
                print("[DailyMetricsStore] deleted stale metrics file containing NaN")
            }
        }
        if let data = try? Data(contentsOf: metricsURL),
           let decoded = try? decoder.decode([DailyMetrics].self, from: data) {
            metrics = decoded.filter(\.isFinite)
        }
        if let data = try? Data(contentsOf: versionsURL),
           let decoded = try? decoder.decode([AlgorithmVersion].self, from: data) {
            versions = decoded
        }
    }

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

    func deleteAll() {
        metrics.removeAll()
        saveMetrics()
    }

    func load(date: String) -> DailyMetrics? {
        metrics.first { $0.date == date }
    }

    func loadAll() -> [DailyMetrics] { metrics }

    func datesNeedingRecompute(metric: String, below version: Int) -> [String] {
        metrics.filter { m in
            switch metric {
            case "hrv":             return m.hrvVersion             < version
            case "strain":          return m.strainVersion          < version
            case "sleep":           return m.sleepVersion           < version
            case "recovery":        return m.recoveryVersion        < version
            case "physiology":      return m.physiologyVersion      < version
            case "respiratoryRate": return m.respiratoryRateVersion < version
            default:                return false
            }
        }.map(\.date)
    }

    /// Exponential weighted moving average + std, walking days backward from `asOf`.
    /// `alpha` ≈ 2 / (N + 1) where N is the equivalent SMA window. Suggested values:
    ///   HRV α≈0.033 (≈60d), RHR α≈0.022 (≈90d), RR α≈0.033, sleepMinutes α≈0.071 (≈28d).
    /// Returns nil if fewer than 2 values present in the rolling buffer.
    func ewmaBaseline(
        _ extract: (DailyMetrics) -> Double?,
        excluding excludingDate: String? = nil,
        alpha: Double,
        asOf: Date = Date()
    ) -> (mean: Double, std: Double, count: Int)? {
        let sorted = metrics
            .filter { $0.date != excludingDate && isoToDate($0.date) < asOf }
            .compactMap { m -> (date: Date, val: Double)? in
                guard let v = extract(m), v.isFinite else { return nil }
                return (isoToDate(m.date), v)
            }
            .sorted { $0.date < $1.date }   // chronological — older → newer
        guard sorted.count >= 2 else { return nil }
        var mean = sorted[0].val
        var variance = 0.0
        for i in 1..<sorted.count {
            let x = sorted[i].val
            let prevMean = mean
            mean = alpha * x + (1 - alpha) * mean
            // EWMA variance update (West 1979 style): track exp-weighted squared dev around running mean
            let dev = x - prevMean
            variance = (1 - alpha) * (variance + alpha * dev * dev)
        }
        return (mean, sqrt(max(0, variance)), sorted.count)
    }

    func rollingBaseline(
        _ extract: (DailyMetrics) -> Double?,
        excluding excludingDate: String? = nil,
        days: Int = 30
    ) -> (mean: Double, std: Double, count: Int)? {
        // Use UTC throughout to match isoToDate() — date keys are biological-date strings
        // and mixing Calendar.current with UTC parsing caused ±1-day baseline drift near midnight.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let cutoff = utcCal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let values = metrics.filter { m in
            m.date != excludingDate && isoToDate(m.date) >= cutoff
        }.compactMap { extract($0) }
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        // Sample variance (n-1). For tiny windows, population variance underestimates spread,
        // inflating z-scores and making recovery jumpy.
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
        return (mean, sqrt(variance), values.count)
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

extension DailyMetricsStore.DailyMetrics {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date              = try c.decode(String.self,               forKey: .date)
        rhr               = try c.decodeIfPresent(Double.self,       forKey: .rhr)
        hrvRmssd          = try c.decodeIfPresent(Double.self,       forKey: .hrvRmssd)
        hrvSdnn           = try c.decodeIfPresent(Double.self,       forKey: .hrvSdnn)
        strainScore       = try c.decodeIfPresent(Double.self,       forKey: .strainScore)
        sleepMinutes      = try c.decodeIfPresent(Int.self,          forKey: .sleepMinutes)
        sleepNeedMinutes  = try c.decodeIfPresent(Int.self,          forKey: .sleepNeedMinutes)
        recoveryScore     = try c.decodeIfPresent(Double.self,       forKey: .recoveryScore)
        biologicalDate    = try c.decodeIfPresent(String.self,       forKey: .biologicalDate)
        circadianPenalty  = try c.decodeIfPresent(Double.self,       forKey: .circadianPenalty)
        sleepTypeCode     = try c.decodeIfPresent(Int.self,          forKey: .sleepTypeCode)
        recoveryConfidence = try c.decodeIfPresent(Double.self,      forKey: .recoveryConfidence)
        sleepMidpointMin  = try c.decodeIfPresent(Int.self,          forKey: .sleepMidpointMin)
        recoveryComponents = try c.decodeIfPresent(RecoveryBreakdown.self, forKey: .recoveryComponents)
        respiratoryRate       = try c.decodeIfPresent(Double.self, forKey: .respiratoryRate)
        respiratoryConfidence = try c.decodeIfPresent(Double.self, forKey: .respiratoryConfidence)
        acuteFatigue          = try c.decodeIfPresent(Double.self, forKey: .acuteFatigue)
        chronicLoad           = try c.decodeIfPresent(Double.self, forKey: .chronicLoad)
        autonomicStress       = try c.decodeIfPresent(Double.self, forKey: .autonomicStress)
        sleepDebtMinutes      = try c.decodeIfPresent(Double.self, forKey: .sleepDebtMinutes)
        readinessCapacity     = try c.decodeIfPresent(Double.self, forKey: .readinessCapacity)
        strainTolerance       = try c.decodeIfPresent(Double.self, forKey: .strainTolerance)
        illnessFlag           = try c.decodeIfPresent(Bool.self,   forKey: .illnessFlag)
        hrvVersion        = try c.decodeIfPresent(Int.self,          forKey: .hrvVersion)      ?? 0
        strainVersion     = try c.decodeIfPresent(Int.self,          forKey: .strainVersion)   ?? 0
        sleepVersion      = try c.decodeIfPresent(Int.self,          forKey: .sleepVersion)    ?? 0
        recoveryVersion   = try c.decodeIfPresent(Int.self,          forKey: .recoveryVersion) ?? 0
        physiologyVersion = try c.decodeIfPresent(Int.self,          forKey: .physiologyVersion) ?? 0
        respiratoryRateVersion = try c.decodeIfPresent(Int.self,     forKey: .respiratoryRateVersion) ?? 0
    }

    var isFinite: Bool {
        let doubles: [Double?] = [
            rhr, hrvRmssd, hrvSdnn, strainScore, recoveryScore, circadianPenalty, recoveryConfidence,
            respiratoryRate, respiratoryConfidence, acuteFatigue, chronicLoad, autonomicStress,
            sleepDebtMinutes, readinessCapacity, strainTolerance
        ]
        guard doubles.compactMap({ $0 }).allSatisfy({ $0.isFinite }) else { return false }
        return recoveryComponents?.isFinite ?? true
    }
}
