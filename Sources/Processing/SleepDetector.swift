import Foundation

// Detects sleep sessions from historical samples using a rule-based heuristic.
// Scores each 10-minute window on motion variance and HR; classifies as asleep/awake.
// Session starts after 20 min continuous sleep; ends after 10 min continuous activity.
final class SleepDetector {

    private let windowSize: TimeInterval         = 10 * 60  // 10-minute windows
    private let sleepOnsetThreshold: TimeInterval = 20 * 60  // 20 min to confirm sleep start
    private let wakeThreshold: TimeInterval       = 10 * 60  // 10 min to confirm wake

    private let lowMotionVariance: Double = 0.05  // g² — below this = low motion
    private let restingHRMargin: Double   = 5      // BPM above estimated resting HR

    func process(_ samples: [HistoricalSample]) -> [SleepSession] {
        guard samples.count >= 2 else { return [] }
        let windows = buildWindows(from: samples)
        let states = windows.map { classify($0) }
        return extractSessions(windows: windows, states: states)
    }

    // MARK: - Window building
    private struct Window {
        let start: Date
        let end: Date
        let samples: [HistoricalSample]
    }

    private func buildWindows(from samples: [HistoricalSample]) -> [Window] {
        guard let first = samples.first, let last = samples.last else { return [] }
        var windows: [Window] = []
        var windowStart = first.timestamp
        while windowStart < last.timestamp {
            let windowEnd = windowStart.addingTimeInterval(windowSize)
            let bucket = samples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
            if !bucket.isEmpty {
                windows.append(Window(start: windowStart, end: windowEnd, samples: bucket))
            }
            windowStart = windowEnd
        }
        return windows
    }

    // MARK: - Window classification (true = asleep)
    private func classify(_ window: Window) -> Bool {
        let samples = window.samples
        let hrs = samples.map { Double($0.heartRate) }
        let minHR = hrs.min() ?? 60
        let avgHR = hrs.reduce(0, +) / Double(hrs.count)

        let hrSleepLike = avgHR < minHR + restingHRMargin

        if let motionVar = accelVariance(from: samples) {
            // Both signals available — require both to agree.
            return hrSleepLike && motionVar < lowMotionVariance
        } else {
            // Historical WHOOP batches carry no accelerometer — HR alone is the signal.
            return hrSleepLike
        }
    }

    // MARK: - Session extraction
    private func extractSessions(windows: [Window], states: [Bool]) -> [SleepSession] {
        guard windows.count == states.count else { return [] }
        var sessions: [SleepSession] = []
        var sleepStart: Date? = nil
        var sleepRunStart: Date? = nil
        var wakeRunStart: Date? = nil

        for i in windows.indices {
            let w = windows[i]
            let isAsleep = states[i]
            if isAsleep {
                wakeRunStart = nil
                if sleepRunStart == nil { sleepRunStart = w.start }
                let runDuration = w.end.timeIntervalSince(sleepRunStart!)
                if sleepStart == nil, runDuration >= sleepOnsetThreshold {
                    sleepStart = sleepRunStart
                }
            } else {
                sleepRunStart = nil
                if sleepStart != nil {
                    if wakeRunStart == nil { wakeRunStart = w.start }
                    let wakeDuration = w.end.timeIntervalSince(wakeRunStart!)
                    if wakeDuration >= wakeThreshold {
                        sessions.append(SleepSession(start: sleepStart!, end: wakeRunStart!))
                        sleepStart = nil
                        wakeRunStart = nil
                    }
                }
            }
        }
        // Close any open sleep session at end of data
        if let start = sleepStart, let last = windows.last {
            sessions.append(SleepSession(start: start, end: last.end))
        }
        return sessions
    }

    // MARK: - Helpers
    private func accelVariance(from samples: [HistoricalSample]) -> Double? {
        let magnitudes = samples.compactMap { $0.accelerometer.map { Double($0.magnitude) } }
        guard magnitudes.count >= 2 else { return nil }
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let squaredDiffs = magnitudes.map { ($0 - mean) * ($0 - mean) }
        return squaredDiffs.reduce(0, +) / Double(magnitudes.count - 1)
    }
}
