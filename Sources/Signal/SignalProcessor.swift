import Foundation

// Confidence-scored wrapper for any computed metric.
struct Metric<T: Sendable>: Sendable {
    let value: T
    /// 0.0–1.0: fraction of input samples that survived artifact rejection.
    let confidence: Double
    let sampleCount: Int
    let computedAt: Date
}

extension Metric: Codable where T: Codable {}

// Stateless signal processor. All functions are pure / nonisolated so callers
// can invoke them from any actor without hopping.
struct SignalProcessor: Sendable {

    // MARK: - RR artifact rejection

    /// Removes physiologically impossible and statistically outlier RR intervals,
    /// returns cleaned intervals in milliseconds with a confidence score.
    ///
    /// Pipeline:
    ///   1. Hard reject: RR < 300 ms or > 2000 ms.
    ///   2. Rolling 20% deviation filter vs 10-sample trailing mean.
    func filterRR(_ intervalsMs: [Double]) -> Metric<[Double]> {
        guard !intervalsMs.isEmpty else {
            return Metric(value: [], confidence: 0, sampleCount: 0, computedAt: Date())
        }
        var clean: [Double] = []
        for rr in intervalsMs {
            // Hard physiological bounds
            guard rr >= 300, rr <= 2000 else { continue }
            // Rolling mean deviation gate (mirrors DayRecomputer.computeHRV logic)
            if clean.count >= 5 {
                let window = clean.suffix(10)
                let mean = window.reduce(0, +) / Double(window.count)
                guard mean > 1.0 else { continue }
                if abs(rr - mean) / mean > 0.20 { continue }
            }
            clean.append(rr)
        }
        let confidence = intervalsMs.isEmpty ? 0.0 : min(1.0, Double(clean.count) / Double(intervalsMs.count))
        return Metric(value: clean, confidence: confidence, sampleCount: intervalsMs.count, computedAt: Date())
    }

    // MARK: - HRV computation

    /// Computes RMSSD from already-filtered RR intervals (milliseconds).
    /// Returns nil-wrapped in Metric if < 5 valid pairs.
    func computeRMSSD(_ filteredMs: [Double]) -> Metric<Double?> {
        guard filteredMs.count >= 2 else {
            return Metric(value: nil, confidence: 0, sampleCount: filteredMs.count, computedAt: Date())
        }
        var squaredDiffs: [Double] = []
        for i in 0..<(filteredMs.count - 1) {
            let d = filteredMs[i + 1] - filteredMs[i]
            squaredDiffs.append(d * d)
        }
        guard squaredDiffs.count >= 5 else {
            return Metric(value: nil, confidence: Double(squaredDiffs.count) / 5.0, sampleCount: filteredMs.count, computedAt: Date())
        }
        let rmssd = sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))
        return Metric(value: rmssd, confidence: 1.0, sampleCount: filteredMs.count, computedAt: Date())
    }

    /// Computes SDNN from already-filtered RR intervals (milliseconds).
    func computeSDNN(_ filteredMs: [Double]) -> Metric<Double?> {
        guard filteredMs.count >= 2 else {
            return Metric(value: nil, confidence: 0, sampleCount: filteredMs.count, computedAt: Date())
        }
        let mean = filteredMs.reduce(0, +) / Double(filteredMs.count)
        let variance = filteredMs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(filteredMs.count - 1)
        let sdnn = sqrt(variance)
        return Metric(value: sdnn, confidence: 1.0, sampleCount: filteredMs.count, computedAt: Date())
    }

    // MARK: - Signal quality

    /// Returns 0.0–1.0 signal quality score for a batch of HistoricalSamples.
    /// Factors: sample density (expected ~1/min), RR availability, HR range sanity.
    func signalQuality(_ samples: [HistoricalSample]) -> Double {
        guard samples.count >= 2 else { return 0 }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let spanMin = sorted.last!.timestamp.timeIntervalSince(sorted.first!.timestamp) / 60
        guard spanMin > 0 else { return 0 }

        let densityScore = min(1.0, Double(samples.count) / max(1, spanMin))

        let rrCount = samples.filter { !($0.rrIntervals?.isEmpty ?? true) }.count
        let rrScore = Double(rrCount) / Double(samples.count)

        let hrs = samples.map { Double($0.heartRate) }
        let hrRange = (hrs.max() ?? 0) - (hrs.min() ?? 0)
        let hrSanityScore: Double = hrRange > 5 && hrRange < 120 ? 1.0 : 0.5

        return (densityScore * 0.4 + rrScore * 0.4 + hrSanityScore * 0.2)
    }
}
