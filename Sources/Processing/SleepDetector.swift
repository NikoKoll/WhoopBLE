import Foundation

// Detects sleep sessions from historical HR samples.
// Uses a global resting HR baseline so REM spikes don't break sessions.
// Sessions within 45 min of each other are merged into one.
final class SleepDetector {

    private let windowSize: TimeInterval          = 10 * 60   // 10-minute windows
    private let sleepOnsetThreshold: TimeInterval = 20 * 60   // 2 consecutive sleep windows to confirm onset
    private let wakeThreshold: TimeInterval       = 40 * 60   // 4 consecutive awake windows to end session
    private let mergeGap: TimeInterval            = 45 * 60   // merge sessions closer than this
    private let restingHRMargin: Double           = 15        // BPM above global resting HR = still sleep-like

    func process(_ samples: [HistoricalSample]) -> [SleepSession] {
        guard samples.count >= 2 else { return [] }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }

        // Global resting HR: 10th-percentile of all HR values.
        // More robust than per-window min — unaffected by brief REM spikes.
        let allHR = sorted.map { Double($0.heartRate) }.sorted()
        let p10idx = max(0, Int(Double(allHR.count) * 0.10) - 1)
        let restingHR = allHR[p10idx]

        let windows = buildWindows(from: sorted)
        let states = windows.map { classify($0, restingHR: restingHR) }
        let raw = extractSessions(windows: windows, states: states)
        return mergeSessions(raw)
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
    private func classify(_ window: Window, restingHR: Double) -> Bool {
        let hrs = window.samples.map { Double($0.heartRate) }
        let avgHR = hrs.reduce(0, +) / Double(hrs.count)
        let hrSleepLike = avgHR < restingHR + restingHRMargin

        if let motionVar = accelVariance(from: window.samples) {
            return hrSleepLike && motionVar < 0.05
        }
        return hrSleepLike
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
        if let start = sleepStart, let last = windows.last {
            sessions.append(SleepSession(start: start, end: last.end))
        }
        return sessions
    }

    // MARK: - Merge nearby sessions
    private func mergeSessions(_ sessions: [SleepSession]) -> [SleepSession] {
        guard sessions.count > 1 else { return sessions }
        var merged: [SleepSession] = []
        var current = sessions[0]
        for next in sessions.dropFirst() {
            if next.start.timeIntervalSince(current.end) <= mergeGap {
                current = SleepSession(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
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
