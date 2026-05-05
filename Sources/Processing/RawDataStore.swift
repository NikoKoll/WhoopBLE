import Foundation

/// Persists raw HR and RR samples to per-day JSON files.
/// Files: raw_hr_<date>.json, raw_rr_<date>.json in Documents/
/// 90-day retention; 30-second throttle on live HR; full capture for batch sync.
actor RawDataStore {

    struct HRSample: Codable, Sendable {
        let timestamp: Int  // unix seconds UTC
        let bpm: Int
    }

    struct RRSample: Codable, Sendable {
        let timestamp: Int  // unix seconds UTC
        let intervalMs: Int // milliseconds, 300–2000
    }

    private let docsDir: URL
    private var hrBuffer: [(dateKey: String, sample: HRSample)] = []
    private var rrBuffer: [(dateKey: String, sample: RRSample)] = []
    private var lastHRTimestamp: Int = 0  // 30s throttle gate for live HR

    init() {
        docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pruneOlderThan(days: 14)
        startPeriodicFlush()
    }

    // MARK: - Public API

    /// Live HR — throttled to one sample per 30 s.
    func appendHR(timestamp: Int, bpm: Int) {
        guard bpm >= 30, bpm <= 220 else { return }
        guard timestamp - lastHRTimestamp >= 30 else { return }
        lastHRTimestamp = timestamp
        hrBuffer.append((isoDate(from: timestamp), HRSample(timestamp: timestamp, bpm: bpm)))
    }

    /// Live RR interval — unthrottled; actor validates range.
    func appendRR(timestamp: Int, intervalMs: Int) {
        guard intervalMs >= 300, intervalMs <= 2000 else { return }
        rrBuffer.append((isoDate(from: timestamp), RRSample(timestamp: timestamp, intervalMs: intervalMs)))
    }

    /// Historical HR from batch sync — no 30 s throttle; all samples stored.
    /// Deduplicates against in-memory buffer by timestamp (on-disk dedup handled at flush).
    func appendHRBatch(_ samples: [(timestamp: Int, bpm: Int)]) {
        let bufferedTimestamps = Set(hrBuffer.map { $0.sample.timestamp })
        var added = 0
        for s in samples {
            guard s.bpm >= 30, s.bpm <= 220 else { continue }
            guard !bufferedTimestamps.contains(s.timestamp) else { continue }
            hrBuffer.append((isoDate(from: s.timestamp), HRSample(timestamp: s.timestamp, bpm: s.bpm)))
            added += 1
        }
        if added < samples.count {
            print("[Raw] appendHRBatch: \(added)/\(samples.count) added (\(samples.count - added) duplicate timestamps skipped)")
        }
    }

    /// Historical RR from batch sync — no throttle; validates range; deduplicates by timestamp.
    func appendRRBatch(_ samples: [(timestamp: Int, intervalMs: Int)]) {
        let bufferedTimestamps = Set(rrBuffer.map { $0.sample.timestamp })
        var added = 0
        for s in samples {
            guard s.intervalMs >= 300, s.intervalMs <= 2000 else { continue }
            guard !bufferedTimestamps.contains(s.timestamp) else { continue }
            rrBuffer.append((isoDate(from: s.timestamp), RRSample(timestamp: s.timestamp, intervalMs: s.intervalMs)))
            added += 1
        }
        if added > 0 {
            print("[Raw] appendRRBatch: \(added)/\(samples.count) RR intervals added")
        }
    }

    /// Returns on-disk samples + pending buffer for the date, sorted by timestamp.
    func loadHR(for date: Date) -> [HRSample] {
        let key = isoDate(for: date)
        var result = read(hrURL(for: key), as: [HRSample].self) ?? []
        result += hrBuffer.filter { $0.dateKey == key }.map(\.sample)
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Returns on-disk samples + pending buffer for the date, sorted by timestamp.
    func loadRR(for date: Date) -> [RRSample] {
        let key = isoDate(for: date)
        var result = read(rrURL(for: key), as: [RRSample].self) ?? []
        result += rrBuffer.filter { $0.dateKey == key }.map(\.sample)
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Flush in-memory buffers to disk. Called every 60 s and before recomputation.
    func flush() {
        flushBuffer(&hrBuffer, fileFor: hrURL)
        flushBuffer(&rrBuffer, fileFor: rrURL)
    }

    // MARK: - Pruning

    nonisolated func pruneOlderThan(days: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: docsDir,
                                                                        includingPropertiesForKeys: nil) else { return }
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("raw_hr_") || name.hasPrefix("raw_rr_") else { continue }
            let dateStr = name
                .replacingOccurrences(of: "raw_hr_", with: "")
                .replacingOccurrences(of: "raw_rr_", with: "")
                .replacingOccurrences(of: ".json", with: "")
            if let fileDate = parseISODate(dateStr), fileDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private

    private func flushBuffer<T: Codable>(
        _ buffer: inout [(dateKey: String, sample: T)],
        fileFor url: (String) -> URL
    ) {
        let groups = Dictionary(grouping: buffer, by: { $0.dateKey })
        for (key, entries) in groups {
            let existing = read(url(key), as: [T].self) ?? []
            let merged   = (existing + entries.map(\.sample))
            write(merged, to: url(key))
        }
        buffer = []
    }

    nonisolated private func startPeriodicFlush() {
        Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await flush()
            }
        }
    }

    private func hrURL(for key: String) -> URL {
        docsDir.appendingPathComponent("raw_hr_\(key).json")
    }

    private func rrURL(for key: String) -> URL {
        docsDir.appendingPathComponent("raw_rr_\(key).json")
    }

    private func read<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func isoDate(from timestamp: Int) -> String {
        isoDate(for: Date(timeIntervalSince1970: Double(timestamp)))
    }

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    nonisolated private func parseISODate(_ str: String) -> Date? {
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
