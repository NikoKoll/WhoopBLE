import Foundation

struct WhoopMetrics: Sendable {
    let timestamp: Date
    let heartRate: Int
    let rrIntervals: [Double]   // seconds

    var hrv: Double? {
        guard rrIntervals.count >= 2 else { return nil }
        let squaredDiffs = zip(rrIntervals, rrIntervals.dropFirst()).map { a, b -> Double in
            let diffMs = (b - a) * 1000
            return diffMs * diffMs
        }
        return sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))
    }
}

struct AccelerometerSample: Sendable {
    let timestamp: Date
    let x: Float   // g
    let y: Float   // g
    let z: Float   // g

    var magnitude: Float { (x*x + y*y + z*z).squareRoot() }
}

struct HistoricalSample: Sendable {
    let timestamp: Date
    let heartRate: Int
    let accelerometer: AccelerometerSample?
}

struct SleepSession: Sendable, Codable {
    let start: Date
    let end: Date
}
