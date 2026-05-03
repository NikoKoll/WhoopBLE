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
    let rrIntervals: [Double]?   // seconds; nil when chunk format carries no RR data

    init(timestamp: Date, heartRate: Int, accelerometer: AccelerometerSample? = nil, rrIntervals: [Double]? = nil) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.accelerometer = accelerometer
        self.rrIntervals = rrIntervals
    }
}

enum SleepStage: String, Sendable, Codable {
    case deep, core, rem, awake
}

struct SleepStageSegment: Sendable, Codable {
    let start: Date
    let end: Date
    let stage: SleepStage
}

struct SleepSession: Sendable, Codable {
    let start: Date
    let end: Date
    let stages: [SleepStageSegment]?
    let briefWakeCount: Int
    let briefWakeTotalSeconds: Int

    init(start: Date, end: Date, stages: [SleepStageSegment]? = nil,
         briefWakeCount: Int = 0, briefWakeTotalSeconds: Int = 0) {
        self.start = start
        self.end = end
        self.stages = stages
        self.briefWakeCount = briefWakeCount
        self.briefWakeTotalSeconds = briefWakeTotalSeconds
    }

    // Custom decoder — legacy persisted sessions missing new keys decode to defaults.
    private enum CodingKeys: String, CodingKey {
        case start, end, stages, briefWakeCount, briefWakeTotalSeconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.start = try c.decode(Date.self, forKey: .start)
        self.end = try c.decode(Date.self, forKey: .end)
        self.stages = try c.decodeIfPresent([SleepStageSegment].self, forKey: .stages)
        self.briefWakeCount = (try? c.decodeIfPresent(Int.self, forKey: .briefWakeCount)) ?? 0
        self.briefWakeTotalSeconds = (try? c.decodeIfPresent(Int.self, forKey: .briefWakeTotalSeconds)) ?? 0
    }
}
