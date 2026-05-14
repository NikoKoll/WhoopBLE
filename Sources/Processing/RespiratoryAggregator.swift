import Foundation

/// Aggregates stored RR samples into a single daily mean respiratory rate
/// computed over sleep windows. Mirrors BLEManager.estimateRespiratoryRate
/// (RSA autocorrelation of linearly-detrended RR series) but operates on
/// `RawDataStore.RRSample` slices instead of the live RR buffer.
///
/// Approach: slice each sleep session into 5-minute buckets, estimate respiratory
/// rate per bucket via autocorr, return the mean across valid buckets. Confidence
/// = validBuckets / totalBuckets.
struct RespiratoryAggregator: Sendable {

    /// Returns (rate breaths/min, confidence 0..1). Both nil if no sleep RR or
    /// no buckets yielded a confident estimate.
    static func meanRRDuringSleep(
        rrSamples: [RawDataStore.RRSample],
        sleepSessions: [SleepSession]
    ) -> (rate: Double?, confidence: Double) {
        guard !sleepSessions.isEmpty, !rrSamples.isEmpty else { return (nil, 0) }

        let bucketSec = 300
        var estimates: [Double] = []
        var totalBuckets = 0

        for session in sleepSessions {
            let startTs = Int(session.start.timeIntervalSince1970)
            let endTs   = Int(session.end.timeIntervalSince1970)
            guard endTs > startTs else { continue }

            var t = startTs
            while t + bucketSec <= endTs {
                totalBuckets += 1
                let upper = t + bucketSec
                let bucket = rrSamples.filter { $0.timestamp >= t && $0.timestamp < upper }
                t = upper
                if bucket.count < 32 { continue }
                let intervalsMs = bucket.map { Double($0.intervalMs) }
                if let rate = estimateRespiratoryRate(intervalsMs) {
                    estimates.append(rate)
                }
            }
        }

        guard !estimates.isEmpty, totalBuckets > 0 else { return (nil, 0) }
        let mean = estimates.reduce(0, +) / Double(estimates.count)
        let confidence = min(1.0, Double(estimates.count) / Double(max(1, totalBuckets)))
        return (mean, confidence)
    }

    // MARK: - RSA autocorrelation (copied from BLEManager.estimateRespiratoryRate)

    /// Lag 4–10 → 6–15 breaths/min. Requires 32+ RR intervals and a prominent
    /// autocorrelation peak (≥ 20% over each immediate neighbor).
    private static func estimateRespiratoryRate(_ rr: [Double]) -> Double? {
        guard rr.count >= 32 else { return nil }
        let n = rr.count
        let xMean = (Double(n) - 1) / 2
        let yMean = rr.reduce(0.0, +) / Double(n)
        let sxx = (0..<n).reduce(0.0) { $0 + (Double($1) - xMean) * (Double($1) - xMean) }
        guard sxx > 0 else { return nil }
        let sxy = rr.enumerated().reduce(0.0) { acc, pair in
            acc + (Double(pair.offset) - xMean) * (pair.element - yMean)
        }
        let slope = sxy / sxx
        let detrended = rr.enumerated().map { pair in
            pair.element - (yMean + slope * (Double(pair.offset) - xMean))
        }
        let maxLag = min(10, n - 4)
        guard maxLag >= 4 else { return nil }
        var corrs: [Int: Double] = [:]
        for lag in 4...maxLag {
            corrs[lag] = (0..<(n - lag)).reduce(0.0) { $0 + detrended[$1] * detrended[$1 + lag] }
        }
        guard let bestLag = corrs.max(by: { $0.value < $1.value })?.key,
              let bestCorr = corrs[bestLag], bestCorr > 0 else { return nil }
        let prevCorr = corrs[bestLag - 1] ?? 0
        let nextCorr = corrs[bestLag + 1] ?? 0
        guard bestCorr >= prevCorr * 1.20, bestCorr >= nextCorr * 1.20 else { return nil }
        let breathsPerMin = 60.0 / Double(bestLag)
        return (breathsPerMin >= 6 && breathsPerMin <= 15) ? breathsPerMin : nil
    }
}
