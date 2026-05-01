import Foundation

// Staged sleep detector. Replaces fragmenting HR-only classifier.
//
// Pipeline:
//   1. Bucket samples into 5-min windows (avgHR, hrStd, rrCV).
//   2. Compute trailing 60-min p10 of HR per window → localBaseline.
//   3. Stage classify each window (DEEP / CORE / REM / AWAKE).
//   4. Build sessions: onset = 2 consecutive non-awake windows; absorb wake gaps ≤ 60 min;
//      end when AWAKE persists ≥ 60 min.
//   5. Merge sessions within 90 min.
//
// Designed to tolerate REM HR spikes that previously fragmented sessions.
final class SleepDetector {

    private let windowSize: TimeInterval  = 5 * 60      // 5-minute windows
    private let onsetWindows: Int         = 2           // 10 min of non-awake to confirm onset
    private let maxWakeAbsorbWindows: Int = 12          // 60 min in-bed wake absorbed into session
    private let mergeGap: TimeInterval    = 90 * 60     // merge sessions within 90 min
    private let baselineWindow: TimeInterval = 60 * 60  // trailing 60 min for local baseline

    // Stage thresholds vs localBaseline (BPM above baseline)
    private let deepHRMargin: Double  = 3
    private let coreHRMargin: Double  = 8
    private let remHRMargin: Double   = 20
    private let deepStdMax: Double    = 3

    func process(_ samples: [HistoricalSample]) -> [SleepSession] {
        guard samples.count >= 4 else { return [] }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }

        // Global p10 fallback for the first hour (before rolling window has data).
        let allHR = sorted.map { Double($0.heartRate) }.sorted()
        let globalP10 = allHR[max(0, Int(Double(allHR.count) * 0.10) - 1)]

        let windows = buildWindows(from: sorted)
        guard !windows.isEmpty else { return [] }

        // Per-window features
        let features = windows.map { feature(for: $0) }

        // Rolling baseline per window (trailing 60 min p10 of HR samples)
        let baselines = windows.indices.map { i -> Double in
            let cutoff = windows[i].end.addingTimeInterval(-baselineWindow)
            let pool = sorted.filter { $0.timestamp >= cutoff && $0.timestamp <= windows[i].end }
                             .map { Double($0.heartRate) }
                             .sorted()
            guard pool.count >= 12 else { return globalP10 }
            return pool[max(0, Int(Double(pool.count) * 0.10) - 1)]
        }

        let stages = features.indices.map { i -> SleepStage in
            classify(feature: features[i], baseline: baselines[i])
        }

        let sessions = extractSessions(windows: windows, stages: stages)
        return mergeSessions(sessions)
    }

    // MARK: - Windows + features

    private struct Window {
        let start: Date
        let end: Date
        let samples: [HistoricalSample]
    }

    private struct Feature {
        let avgHR: Double
        let hrStd: Double
        let rrCV: Double?     // coefficient of variation across RR intervals (proxy for HRV irregularity)
    }

    private func buildWindows(from samples: [HistoricalSample]) -> [Window] {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else { return [] }
        var windows: [Window] = []
        var ws = first
        while ws < last {
            let we = ws.addingTimeInterval(windowSize)
            let bucket = samples.filter { $0.timestamp >= ws && $0.timestamp < we }
            if !bucket.isEmpty { windows.append(Window(start: ws, end: we, samples: bucket)) }
            ws = we
        }
        return windows
    }

    private func feature(for w: Window) -> Feature {
        let hrs: [Double] = w.samples.map { Double($0.heartRate) }
        let avg: Double = hrs.reduce(0.0, +) / Double(hrs.count)
        var sumSq: Double = 0
        for h in hrs { let d = h - avg; sumSq += d * d }
        let denom = Double(max(1, hrs.count - 1))
        let std: Double = sqrt(sumSq / denom)

        var rrs: [Double] = []
        for s in w.samples {
            guard let arr = s.rrIntervals else { continue }
            for r in arr where r >= 0.3 && r <= 2.0 { rrs.append(r) }
        }
        var rrCV: Double? = nil
        if rrs.count >= 4 {
            let m: Double = rrs.reduce(0.0, +) / Double(rrs.count)
            let v: Double = rrs.map { ($0 - m) * ($0 - m) }.reduce(0.0, +) / Double(rrs.count - 1)
            if m > 0 { rrCV = sqrt(v) / m }
        }
        return Feature(avgHR: avg, hrStd: std, rrCV: rrCV)
    }

    // MARK: - Stage classifier

    private func classify(feature f: Feature, baseline: Double) -> SleepStage {
        let delta = f.avgHR - baseline
        if delta > remHRMargin { return .awake }
        if delta <= deepHRMargin && f.hrStd < deepStdMax { return .deep }
        if delta <= coreHRMargin { return .core }
        // Between core and awake: REM if RR variability high, else core (conservative).
        if let cv = f.rrCV, cv > 0.08 { return .rem }
        return .core
    }

    // MARK: - Session extraction

    private func extractSessions(windows: [Window], stages: [SleepStage]) -> [SleepSession] {
        guard windows.count == stages.count, !windows.isEmpty else { return [] }
        var sessions: [SleepSession] = []
        var startIdx: Int? = nil
        var lastAsleepIdx: Int? = nil
        var consecutiveAwake = 0

        for i in windows.indices {
            let isAsleep = stages[i] != .awake

            if isAsleep {
                if startIdx == nil {
                    // Onset: require N consecutive non-awake to start
                    let lookahead = min(stages.count, i + onsetWindows)
                    let confirmed = (i..<lookahead).allSatisfy { stages[$0] != .awake }
                    if confirmed { startIdx = i }
                }
                if startIdx != nil {
                    lastAsleepIdx = i
                    consecutiveAwake = 0
                }
            } else if startIdx != nil {
                consecutiveAwake += 1
                if consecutiveAwake > maxWakeAbsorbWindows {
                    // Wake persisted long enough — close session at last sleep window
                    if let s = startIdx, let e = lastAsleepIdx {
                        sessions.append(buildSession(windows: windows, stages: stages, from: s, to: e))
                    }
                    startIdx = nil
                    lastAsleepIdx = nil
                    consecutiveAwake = 0
                }
            }
        }

        if let s = startIdx, let e = lastAsleepIdx {
            sessions.append(buildSession(windows: windows, stages: stages, from: s, to: e))
        }
        return sessions
    }

    private func buildSession(windows: [Window], stages: [SleepStage], from s: Int, to e: Int) -> SleepSession {
        let segments = (s...e).map {
            SleepStageSegment(start: windows[$0].start, end: windows[$0].end, stage: stages[$0])
        }
        // Coalesce adjacent same-stage segments
        var merged: [SleepStageSegment] = []
        for seg in segments {
            if var last = merged.last, last.stage == seg.stage, last.end == seg.start {
                merged.removeLast()
                merged.append(SleepStageSegment(start: last.start, end: seg.end, stage: seg.stage))
                _ = last
            } else {
                merged.append(seg)
            }
        }
        return SleepSession(start: windows[s].start, end: windows[e].end, stages: merged)
    }

    // MARK: - Merge nearby sessions

    private func mergeSessions(_ sessions: [SleepSession]) -> [SleepSession] {
        guard sessions.count > 1 else { return sessions }
        var out: [SleepSession] = []
        var cur = sessions[0]
        for next in sessions.dropFirst() {
            if next.start.timeIntervalSince(cur.end) <= mergeGap {
                let mergedStages: [SleepStageSegment]?
                switch (cur.stages, next.stages) {
                case (let a?, let b?): mergedStages = a + b
                case (let a?, nil):    mergedStages = a
                case (nil, let b?):    mergedStages = b
                default:               mergedStages = nil
                }
                cur = SleepSession(start: cur.start, end: max(cur.end, next.end), stages: mergedStages)
            } else {
                out.append(cur)
                cur = next
            }
        }
        out.append(cur)
        return out
    }
}
