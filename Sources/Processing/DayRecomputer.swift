import Foundation
import HealthKit

/// Bump these to trigger automatic backfill of all existing daily_metrics rows on next launch.
enum AlgoVersions {
    static let hrv      = 3   // stage 2 deviation filter (§9.5): rejects RR >20% from rolling mean
    static let strain   = 3   // recalibrated zone weights — Z1 dropped to 0.1, maxStrain → 11
    static let sleep    = 7   // REM threshold 20→15 BPM (P1 stage tuning)
    static let recovery = 10  // recomputes downstream of new strain + sleep
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
    /// Stage 2 deviation filter (§9.5) applied before computation: rejects values >20% from
    /// rolling 10-sample mean. Stage 1 (300–2000 ms range) applied at storage time.
    func computeHRV(rrSamples: [RawDataStore.RRSample]) -> (rmssd: Double, sdnn: Double)? {
        guard rrSamples.count >= 2 else { return nil }

        // Stage 2: deviation filter — reject RR values >20% from rolling 10-sample mean.
        var clean: [RawDataStore.RRSample] = []
        for s in rrSamples {
            let rr = Double(s.intervalMs)
            if clean.count >= 5 {
                let window = clean.suffix(10)
                let mean = window.reduce(0.0) { $0 + Double($1.intervalMs) } / Double(window.count)
                if abs(rr - mean) / mean > 0.20 { continue }
            }
            clean.append(s)
        }
        guard clean.count >= 2 else { return nil }

        let rr = clean.map { Double($0.intervalMs) }

        // Only consecutive pairs without a gap (guard against cross-reconnect junk pairs).
        var squaredDiffs: [Double] = []
        for i in 0..<(clean.count - 1) {
            guard clean[i+1].timestamp - clean[i].timestamp <= 10 else { continue }
            let d = rr[i+1] - rr[i]
            squaredDiffs.append(d * d)
        }
        guard !squaredDiffs.isEmpty else { return nil }
        let rmssd = sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))

        let mean = rr.reduce(0, +) / Double(rr.count)
        let sdnn = sqrt(rr.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rr.count - 1))

        return (rmssd, sdnn)
    }

    // MARK: - HRV (sleep-windowed)

    /// RMSSD computed on the lowest-HR 10-min window during sleep.
    /// Falls back to nil when no sleep sessions overlap the day or insufficient RR data.
    func computeHRVSleep(
        rrSamples: [RawDataStore.RRSample],
        hrSamples: [RawDataStore.HRSample],
        sleepSessions: [SleepSession],
        date: Date
    ) -> Double? {
        // Accept sessions that overlap [day−1, day+1] to capture overnight sleep.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let prevDay  = cal.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart

        let relevant = sleepSessions.filter { $0.start < dayEnd && $0.end > prevDay }
        guard !relevant.isEmpty else { return nil }

        let sleepRR = rrSamples.filter { s in
            let ts = Date(timeIntervalSince1970: Double(s.timestamp))
            return relevant.contains { $0.start <= ts && ts <= $0.end }
        }
        guard sleepRR.count >= 10 else { return nil }

        let windowSec = 600
        let stepSec   = 60
        var bestHR    = Double.infinity
        var bestRMSSD: Double? = nil

        var t = sleepRR.first!.timestamp
        let last = sleepRR.last!.timestamp
        while t <= last - windowSec {
            let winRR = sleepRR.filter { $0.timestamp >= t && $0.timestamp < t + windowSec }
            let winHR = hrSamples.filter { $0.timestamp >= t && $0.timestamp < t + windowSec }
            guard winRR.count >= 4, !winHR.isEmpty else { t += stepSec; continue }
            let avgHR = Double(winHR.map(\.bpm).reduce(0, +)) / Double(winHR.count)
            if avgHR < bestHR {
                let diffs = zip(winRR, winRR.dropFirst()).compactMap { a, b -> Double? in
                    guard b.timestamp - a.timestamp <= 10 else { return nil }
                    let d = Double(b.intervalMs - a.intervalMs)
                    return d * d
                }
                if !diffs.isEmpty {
                    bestHR    = avgHR
                    bestRMSSD = sqrt(diffs.reduce(0, +) / Double(diffs.count))
                }
            }
            t += stepSec
        }
        return bestRMSSD
    }

    // MARK: - Strain

    /// Exponential zone-weighted cardiovascular load, normalized to 0–21 scale.
    /// Uses actual timestamp gaps between samples so batch (1s) and live (30s) data
    /// both produce correct time-in-zone without overcounting.
    func computeStrain(hrSamples: [RawDataStore.HRSample], maxHR: Int) -> Double {
        guard hrSamples.count >= 2 else { return 0 }
        let boundaries = [0.50, 0.60, 0.70, 0.80, 0.90].map { Int(Double(maxHR) * $0) }
        // Recalibrated zone weights (P1): prior [0.50, 1.01, 2.03, 4.08, 8.20] gave Z1 (sedentary
        // awake HR) the same order of magnitude as Z2, so 16 h of awake-but-resting saturated
        // strain at ~21 with no actual workout. New weights drop Z1 to 0.1 so sedentary time
        // contributes minimally; Z3+ remain steep so real exertion still drives strain up.
        let weights    = [0.10, 0.50, 1.50, 4.00, 8.00]
        // Realistic athlete day: 12 h Z1 + 4 h Z2 + 1 h Z3 + 30 min Z4 + 30 min Z5
        //   = 1.2 + 2.0 + 1.5 + 2.0 + 4.0 = 10.7  → strain 21.
        // Resting day (16 h Z1) = 1.6 → strain ~3. Reasonable spread.
        let maxStrain: Double = 11.0
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
    /// `healthKit` is optional — when provided, used as fallback source for RHR and HRV when Whoop data is nil.
    func recomputeDay(date: Date, rawStore: RawDataStore, dailyStore: DailyMetricsStore,
                      healthKit: HealthKitWriter? = nil) async {
        await rawStore.flush()
        let hr = await rawStore.loadHR(for: date)
        let rr = await rawStore.loadRR(for: date)

        let rhr    = computeRHR(hrSamples: hr)
        // User age drives maxHR (220 − age). Default 35 if not yet set in Settings.
        let storedAge = UserDefaults.standard.integer(forKey: "userAge")
        let userAge   = storedAge > 0 ? max(10, min(100, storedAge)) : 35
        let maxHR     = 220 - userAge
        let strain  = computeStrain(hrSamples: hr, maxHR: maxHR)

        // Detect overnight sleep on a tight nightly window [prev 18:00, today 12:00]. Feeding
        // the full 48h to SleepDetector caused its 60-min wake-gap absorption to merge daytime
        // resting periods with overnight sleep into single multi-hour sessions. Restricting
        // input keeps the detector focused on actual sleep hours. Sessions still attributed to
        // wake date so pre-midnight portion lands in the correct day.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart   = cal.startOfDay(for: date)
        let dayEnd     = cal.date(byAdding: .day,  value:  1, to: dayStart) ?? dayStart
        let prevDay    = cal.date(byAdding: .day,  value: -1, to: dayStart) ?? dayStart
        let nightStart = cal.date(byAdding: .hour, value: 18, to: prevDay)  ?? prevDay
        let nightEnd   = cal.date(byAdding: .hour, value: 12, to: dayStart) ?? dayStart

        let hrPrev = await rawStore.loadHR(for: prevDay)
        let nightHR = (hrPrev + hr).filter {
            let t = Date(timeIntervalSince1970: Double($0.timestamp))
            return t >= nightStart && t < nightEnd
        }.sorted { $0.timestamp < $1.timestamp }

        let detected = detectSleep(hrSamples: nightHR)
        let sleep = detected
            .filter { $0.end >= dayStart && $0.end < dayEnd }
            .filter { $0.end.timeIntervalSince($0.start) <= 14 * 3600 }
        // True sleep time: sum only segments between first and last DEEP/REM. Leading/trailing
        // CORE runs are typically quiet wakefulness (couch sitting) misclassified by the HR-only
        // detector — there is no accel data on historical 0xa1 batches to distinguish them.
        let sleepMin = sleep.reduce(0) { acc, s in
            guard let segs = s.stages, !segs.isEmpty else {
                return acc + Int(s.end.timeIntervalSince(s.start) / 60)
            }
            guard let first = segs.firstIndex(where: { $0.stage == .deep || $0.stage == .rem }),
                  let last  = segs.lastIndex(where:  { $0.stage == .deep || $0.stage == .rem }) else {
                return acc  // no DEEP/REM at all → not real sleep
            }
            let kept = segs[first...last].filter { $0.stage != .awake }
            return acc + kept.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
        }

        // Prefer sleep-windowed HRV; fall back to full-day RMSSD when no sleep detected.
        let storedSessions = loadSleepSessions()
        let allSessions = (sleep + storedSessions).sorted { $0.start < $1.start }
        let sleepHRV = computeHRVSleep(rrSamples: rr, hrSamples: hr, sleepSessions: allSessions, date: date)
        let fullHRV  = computeHRV(rrSamples: rr)
        let whoopHRV = sleepHRV ?? fullHRV?.rmssd
        let hrvSdnn  = fullHRV?.sdnn

        let key = isoDate(for: date)

        // Source fusion: use HealthKit as fallback when Whoop data is nil.
        let effectiveRHR: Double?
        if let w = rhr {
            effectiveRHR = w
        } else if let hk = healthKit, let fallback = await hk.readLatestRHR(for: date) {
            effectiveRHR = fallback
            print("[DayRecomputer] \(key) RHR from HealthKit fallback=\(String(format: "%.1f", fallback))")
        } else {
            effectiveRHR = nil
        }

        let hrvRmssd: Double?
        if let w = whoopHRV {
            hrvRmssd = w
        } else if let hk = healthKit, let fallback = await hk.readLatestHRV(for: date) {
            hrvRmssd = fallback
            print("[DayRecomputer] \(key) HRV from HealthKit fallback=\(String(format: "%.1f", fallback))ms")
        } else {
            hrvRmssd = nil
        }

        // Load baselines before upserting today so today doesn't bias its own score.
        let allMetrics = await dailyStore.loadAll()
        let hrvBase    = await dailyStore.rollingBaseline({ $0.hrvRmssd },                      excluding: key)
        let rhrBase    = await dailyStore.rollingBaseline({ $0.rhr },                           excluding: key)
        let sleepBase  = await dailyStore.rollingBaseline({ $0.sleepMinutes.map(Double.init) }, excluding: key)
        let strainBase = await dailyStore.rollingBaseline({ $0.strainScore },                   excluding: key)

        // Personalized sleep need — uses past metrics + sessions, not current day.
        let need = SleepNeedCalculator().compute(
            for: date,
            dailyMetrics: allMetrics,
            sleepSessions: allSessions
        )
        print("[SleepNeed] computed for date=\(key) baseline=\(need.baselineMinutes) strain_adj=\(need.strainAdjMinutes) debt=\(need.debtMinutes) napcredit=\(need.napCreditMinutes) total=\(need.totalMinutes)")

        // Recovery uses personalized need as the "target" mean so sleep z-score reflects
        // "did you sleep enough for your personal need" rather than population average.
        let sleepBasePersonalized: (mean: Double, std: Double)?
        if let std = sleepBase?.std {
            sleepBasePersonalized = (mean: Double(need.totalMinutes), std: std)
        } else {
            sleepBasePersonalized = sleepBase
        }

        let recovery = RecoveryScore.compute(
            hrv: hrvRmssd, rhr: effectiveRHR, sleepMinutes: sleepMin > 0 ? sleepMin : nil,
            strain: strain > 0 ? strain : nil,
            hrvBaseline: hrvBase, rhrBaseline: rhrBase,
            sleepBaseline: sleepBasePersonalized, strainBaseline: strainBase
        )

        await dailyStore.delete(date: key)
        await dailyStore.upsert(DailyMetricsStore.DailyMetrics(
            date:             key,
            rhr:              effectiveRHR,
            hrvRmssd:         hrvRmssd,
            hrvSdnn:          hrvSdnn,
            strainScore:      strain > 0 ? strain : nil,
            sleepMinutes:     sleepMin > 0 ? sleepMin : nil,
            sleepNeedMinutes: need.totalMinutes,
            recoveryScore:    recovery,
            hrvVersion:       AlgoVersions.hrv,
            strainVersion:    AlgoVersions.strain,
            sleepVersion:     AlgoVersions.sleep,
            recoveryVersion:  AlgoVersions.recovery
        ))

        let rhrStr  = effectiveRHR.map { String(format: "%.1f", $0) }     ?? "nil"
        let rmsdStr = hrvRmssd.map { String(format: "%.1f ms", $0) }      ?? "nil"
        let sdnnStr = hrvSdnn.map  { String(format: "%.1f ms", $0) }      ?? "nil"
        let recStr  = recovery.map { String(format: "%.0f", $0) }         ?? "nil"
        let hkNote  = (effectiveRHR != nil && rhr == nil) || (hrvRmssd != nil && whoopHRV == nil) ? " [HK fallback]" : ""
        print("[Recompute] \(key) → RHR=\(rhrStr) RMSSD=\(rmsdStr) SDNN=\(sdnnStr) Strain=\(String(format: "%.2f", strain)) Sleep=\(sleepMin)min Recovery=\(recStr)\(hkNote) (hr=\(hr.count) rr=\(rr.count) sleepRR=\(sleepHRV != nil ? "✓" : "fallback"))")
    }

    private func loadSleepSessions() -> [SleepSession] {
        guard let data = UserDefaults.standard.data(forKey: "whoopSleepSessions_v1"),
              let sessions = try? JSONDecoder().decode([SleepSession].self, from: data) else { return [] }
        return sessions
    }

    // MARK: - Helpers

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
