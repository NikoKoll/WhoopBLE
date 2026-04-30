import Foundation

/// Bump these to trigger automatic backfill of all existing daily_metrics rows on next launch.
enum AlgoVersions {
    static let hrv    = 1   // RMSSD + SDNN from per-day RR samples
    static let strain = 1   // exponential zone weights (§9.9)
    static let sleep  = 1   // SleepDetector window-based heuristic
}

/// Pure compute functions + recomputeDay orchestrator.
/// No stored state — all functions are deterministic given the same raw data.
struct DayRecomputer {

    // MARK: - RHR

    /// Lowest 5-minute window average across the day. Returns nil if insufficient data.
    func computeRHR(hrSamples: [RawDataStore.HRSample]) -> Double? {
        guard hrSamples.count >= 5 else { return nil }
        guard let first = hrSamples.first, let last = hrSamples.last else { return nil }
        let windowSecs = 300
        let stepSecs   = 60
        var minAvg: Double = .infinity
        var t = first.timestamp
        while t <= last.timestamp {
            let bucket = hrSamples.filter { $0.timestamp >= t && $0.timestamp < t + windowSecs }
            if bucket.count >= 5 {
                let avg = Double(bucket.map(\.bpm).reduce(0, +)) / Double(bucket.count)
                minAvg = min(minAvg, avg)
            }
            t += stepSecs
        }
        return minAvg == .infinity ? nil : minAvg
    }

    // MARK: - HRV

    /// RMSSD and SDNN from RR intervals in milliseconds. Returns nil if < 2 samples.
    /// RMSSD only uses consecutive pairs with timestamp gap ≤ 10 s — skips cross-session pairs.
    func computeHRV(rrSamples: [RawDataStore.RRSample]) -> (rmssd: Double, sdnn: Double)? {
        let rr = rrSamples.map { Double($0.intervalMs) }
        guard rr.count >= 2 else { return nil }

        // Only consecutive pairs without a gap (guard against cross-reconnect junk pairs).
        var squaredDiffs: [Double] = []
        for i in 0..<(rrSamples.count - 1) {
            guard rrSamples[i+1].timestamp - rrSamples[i].timestamp <= 10 else { continue }
            let d = rr[i+1] - rr[i]
            squaredDiffs.append(d * d)
        }
        guard !squaredDiffs.isEmpty else { return nil }
        let rmssd = sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))

        let mean = rr.reduce(0, +) / Double(rr.count)
        let sdnn = sqrt(rr.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rr.count - 1))

        return (rmssd, sdnn)
    }

    // MARK: - Strain

    /// Exponential zone-weighted cardiovascular load, normalized to 0–21 scale.
    /// Uses actual timestamp gaps between samples so batch (1s) and live (30s) data
    /// both produce correct time-in-zone without overcounting.
    func computeStrain(hrSamples: [RawDataStore.HRSample]) -> Double {
        guard hrSamples.count >= 2 else { return 0 }
        let maxHR      = 185  // 220 – 35 (default age 35; no user profile yet)
        let boundaries = [0.50, 0.60, 0.70, 0.80, 0.90].map { Int(Double(maxHR) * $0) }
        let weights    = [0.50, 1.01, 2.03, 4.08, 8.20]  // exp zone weights from §9.9
        // Realistic max: 60 min Zone5 + 720 min Zone1 — weight × hours.
        let maxStrain  = 1.0 * weights[4] + 12.0 * weights[0]  // 8.20 + 6.00 = 14.20
        // Gaps > 2 min capped — beyond that the user is not active (strap off, paused, etc).
        let maxGapSec  = 120.0

        var accumulated = 0.0
        // First sample: default 30 s (no previous timestamp available).
        let firstZone = zoneIndex(bpm: hrSamples[0].bpm, boundaries: boundaries)
        accumulated += weights[firstZone] * (30.0 / 3600.0)

        for i in 1..<hrSamples.count {
            let gap  = min(Double(hrSamples[i].timestamp - hrSamples[i-1].timestamp), maxGapSec)
            let zone = zoneIndex(bpm: hrSamples[i].bpm, boundaries: boundaries)
            accumulated += weights[zone] * (gap / 3600.0)
        }
        return min(max((accumulated / maxStrain) * 21.0, 0), 21)
    }

    private func zoneIndex(bpm: Int, boundaries: [Int]) -> Int {
        for i in (0..<boundaries.count).reversed() {
            if bpm >= boundaries[i] { return i }
        }
        return 0
    }

    // MARK: - Sleep

    /// Reuse existing SleepDetector — converts HRSamples to HistoricalSamples (no accel).
    func detectSleep(hrSamples: [RawDataStore.HRSample]) -> [SleepSession] {
        let historical = hrSamples.map {
            HistoricalSample(
                timestamp: Date(timeIntervalSince1970: Double($0.timestamp)),
                heartRate: $0.bpm,
                accelerometer: nil
            )
        }
        return SleepDetector().process(historical)
    }

    // MARK: - Orchestrator

    /// Load raw data for `date`, run all algorithms, overwrite DailyMetrics row with version stamps.
    func recomputeDay(date: Date, rawStore: RawDataStore, dailyStore: DailyMetricsStore) async {
        await rawStore.flush()
        let hr = await rawStore.loadHR(for: date)
        let rr = await rawStore.loadRR(for: date)

        let rhr    = computeRHR(hrSamples: hr)
        let hrv    = computeHRV(rrSamples: rr)
        let strain = computeStrain(hrSamples: hr)
        let sleep  = detectSleep(hrSamples: hr)
        let sleepMin = sleep.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }

        let key = isoDate(for: date)
        await dailyStore.delete(date: key)
        await dailyStore.upsert(DailyMetricsStore.DailyMetrics(
            date:          key,
            rhr:           rhr,
            hrvRmssd:      hrv?.rmssd,
            hrvSdnn:       hrv?.sdnn,
            strainScore:   strain > 0 ? strain : nil,
            sleepMinutes:  sleepMin > 0 ? sleepMin : nil,
            hrvVersion:    AlgoVersions.hrv,
            strainVersion: AlgoVersions.strain,
            sleepVersion:  AlgoVersions.sleep
        ))

        let rhrStr    = rhr.map  { String(format: "%.1f", $0) }  ?? "nil"
        let rmsdStr   = hrv.map  { String(format: "%.1f ms", $0.rmssd) } ?? "nil"
        let sdnnStr   = hrv.map  { String(format: "%.1f ms", $0.sdnn) }  ?? "nil"
        print("[Recompute] \(key) → RHR=\(rhrStr) RMSSD=\(rmsdStr) SDNN=\(sdnnStr) Strain=\(String(format: "%.2f", strain)) Sleep=\(sleepMin)min (hr=\(hr.count) rr=\(rr.count))")
    }

    // MARK: - Helpers

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
