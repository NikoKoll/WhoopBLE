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
    // 30 min in-bed wake absorbed (was 60 — absorbed quiet mornings into session, producing
    // 13–17h sessions ending late morning).
    private let maxWakeAbsorbWindows: Int = 6
    private let mergeGap: TimeInterval    = 90 * 60     // merge sessions within 90 min
    private let baselineWindow: TimeInterval = 60 * 60  // trailing 60 min for local baseline

    // Stage thresholds vs localBaseline (BPM above baseline).
    // remHRMargin lowered 20→15: 20 BPM REM gate over-classified mid-night HR rises as AWAKE,
    // fragmenting sessions. WHOOP/research literature places REM HR rises at 7–15 BPM above
    // sleeping baseline; 15 keeps real awakening (≥15 BPM rise) flagged correctly.
    private let deepHRMargin: Double  = 3
    private let coreHRMargin: Double  = 8
    private let remHRMargin: Double   = 15
    private let deepStdMax: Double    = 3

    func process(_ samples: [HistoricalSample]) -> [SleepSession] {
        guard samples.count >= 4 else { return [] }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }

        // Global p5 anchors the baseline floor to the user's true RHR for this night.
        // Without it, a long quiet pre-bed sit at HR ~65 drags the local 60-min p10 down to
        // ~63, making sitting qualify as "asleep" (avg < min+5). globalP5 ≈ true RHR (~52),
        // so floored baseline forces real sleep gate to be HR ≤ globalP5 + 5.
        let allHR = sorted.map { Double($0.heartRate) }.sorted()
        let globalP5  = allHR[max(0, Int(Double(allHR.count) * 0.05))]
        let globalP10 = allHR[max(0, Int(Double(allHR.count) * 0.10))]
        print("[SleepDetector] globalP5=\(Int(globalP5)) globalP10=\(Int(globalP10)) min=\(Int(allHR.first ?? 0)) max=\(Int(allHR.last ?? 0)) n=\(allHR.count)")

        let windows = buildWindows(from: sorted)
        guard !windows.isEmpty else { return [] }

        // Per-window features
        let features = windows.map { feature(for: $0) }

        // Rolling baseline per window (trailing 60 min p10), floored to globalP5 so quiet
        // pre-bed sitting can't drag the gate down enough to falsely classify as sleep.
        let baselines = windows.indices.map { i -> Double in
            let cutoff = windows[i].end.addingTimeInterval(-baselineWindow)
            let pool = sorted.filter { $0.timestamp >= cutoff && $0.timestamp < windows[i].end }
                             .map { Double($0.heartRate) }
                             .sorted()
            let localP10: Double
            if pool.count >= 12 {
                localP10 = pool[max(0, Int(Double(pool.count) * 0.10))]
            } else {
                localP10 = globalP10
            }
            return max(localP10, globalP5)
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
                    // Onset: require N consecutive non-awake to start. If fewer than
                    // onsetWindows windows remain, defer to trailing close-out (lines below
                    // handle open startIdx at end of stream) instead of confirming on a
                    // truncated lookahead — avoids vacuous allSatisfy on empty range.
                    let end = i + onsetWindows
                    if end <= stages.count {
                        let confirmed = (i..<end).allSatisfy { stages[$0] != .awake }
                        if confirmed { startIdx = i }
                    }
                }
                if startIdx != nil {
                    lastAsleepIdx = i
                    consecutiveAwake = 0
                }
            } else if startIdx != nil {
                consecutiveAwake += 1
                if consecutiveAwake > maxWakeAbsorbWindows {
                    // Wake persisted long enough — close session at last sleep window
                    if let s = startIdx, let e = lastAsleepIdx,
                       let session = buildSession(windows: windows, stages: stages, from: s, to: e) {
                        sessions.append(session)
                    }
                    startIdx = nil
                    lastAsleepIdx = nil
                    consecutiveAwake = 0
                }
            }
        }

        if let s = startIdx, let e = lastAsleepIdx,
           let session = buildSession(windows: windows, stages: stages, from: s, to: e) {
            sessions.append(session)
        }
        return sessions
    }

    private func buildSession(windows: [Window], stages: [SleepStage], from s: Int, to e: Int) -> SleepSession? {
        // Trim session boundaries to first/last DEEP-stage window when DEEP exists.
        // CORE often includes quiet sitting (misclassified by HR-only detector) — trimming
        // to DEEP-only boundaries excludes those tails. When no DEEP is found, fall back
        // to non-AWAKE boundaries so borderline sessions aren't silently dropped.
        let sleepIndices = (s...e).filter { stages[$0] == .deep }
        let trimS: Int
        let trimE: Int
        var briefWakeOnlyFromGap = false
        if let first = sleepIndices.first, let last = sleepIndices.last {
            trimS = first; trimE = last
        } else {
            // No DEEP — use non-AWAKE boundaries as best guess.
            let awakeSet = Set((s...e).filter { stages[$0] == .awake })
            let nonAwake = (s...e).filter { !awakeSet.contains($0) }
            guard let fs = nonAwake.first, let fe = nonAwake.last else {
                print("[SleepDetector] dropped raw session \(windows[s].start) → \(windows[e].end) — all windows AWAKE")
                return nil
            }
            trimS = fs; trimE = fe
            briefWakeOnlyFromGap = true
            print("[SleepDetector] no DEEP in session \(windows[s].start) — using non-AWAKE boundaries")
        }

        let segments = (trimS...trimE).map {
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
        // Awake windows within the trimmed sleep period count as brief wakes.
        let awakeCount = (trimS...trimE).filter { stages[$0] == .awake }.count
        let briefWakeSecs = awakeCount * Int(windowSize)
        return SleepSession(start: windows[trimS].start, end: windows[trimE].end, stages: merged,
                            briefWakeCount: awakeCount, briefWakeTotalSeconds: briefWakeSecs)
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
                cur = SleepSession(
                    start: cur.start,
                    end: max(cur.end, next.end),
                    stages: mergedStages,
                    briefWakeCount: cur.briefWakeCount + next.briefWakeCount,
                    briefWakeTotalSeconds: cur.briefWakeTotalSeconds + next.briefWakeTotalSeconds
                )
            } else {
                out.append(cur)
                cur = next
            }
        }
        out.append(cur)
        return out
    }

    // MARK: - Full-window classification (no session trimming)

    /// Classifies every 5-min window within [windowStart, windowEnd] without
    /// extracting/detecting contiguous sessions or trimming to deep-stage boundaries.
    /// Returns stage segments covering the full user-specified range.
    func classifyFullWindow(_ samples: [HistoricalSample], windowStart: Date, windowEnd: Date) -> [SleepStageSegment] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 4 else { return [] }

        // Global p5 anchors baseline floor
        let allHR = sorted.map { Double($0.heartRate) }.sorted()
        let globalP5  = allHR[max(0, Int(Double(allHR.count) * 0.05))]
        let globalP10 = allHR[max(0, Int(Double(allHR.count) * 0.10))]

        // Build windows from user bounds
        var windows: [Window] = []
        var ws = windowStart
        while ws < windowEnd {
            let we = min(ws.addingTimeInterval(windowSize), windowEnd)
            let bucket = sorted.filter { $0.timestamp >= ws && $0.timestamp < we }
            if !bucket.isEmpty { windows.append(Window(start: ws, end: we, samples: bucket)) }
            ws = we
        }
        guard !windows.isEmpty else { return [] }

        let features = windows.map { self.feature(for: $0) }

        // Rolling baseline per window (trailing 60 min p10, floored to globalP5)
        let baselines = windows.indices.map { i -> Double in
            let cutoff = windows[i].end.addingTimeInterval(-baselineWindow)
            let pool = sorted.filter { $0.timestamp >= cutoff && $0.timestamp < windows[i].end }
                .map { Double($0.heartRate) }.sorted()
            let localP10: Double
            if pool.count >= 12 {
                localP10 = pool[max(0, Int(Double(pool.count) * 0.10))]
            } else {
                localP10 = globalP10
            }
            return max(localP10, globalP5)
        }

        // Build merged stage segments
        var segments: [SleepStageSegment] = []
        for i in windows.indices {
            let stage = self.classify(feature: features[i], baseline: baselines[i])
            let seg = SleepStageSegment(start: windows[i].start, end: windows[i].end, stage: stage)
            // Coalesce adjacent same-stage segments
            if var last = segments.last, last.stage == seg.stage, last.end == seg.start {
                segments.removeLast()
                segments.append(SleepStageSegment(start: last.start, end: seg.end, stage: seg.stage))
            } else {
                segments.append(seg)
            }
        }
        return segments
    }
}
