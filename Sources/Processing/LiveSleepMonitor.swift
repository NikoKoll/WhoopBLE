import CoreMotion
import Foundation

// Real-time sleep detection per whoop-algorithms-plan §2.3.
// Feed each live HR reading via observe(_:). Fires onSessionEnd when a
// confirmed sleep→wake transition occurs.
//
// Motion source: CMMotionActivityManager if available; falls back to HR-only
// classification when motion hardware is absent (per plan §9.11 degraded mode).
@MainActor
final class LiveSleepMonitor {

    private enum State { case awake, candidate, sleeping, briefWake }
    private var state: State = .awake
    private var candidateStart: Date?
    private var sleepOnset: Date?

    // briefWake sub-state tracking
    private var briefWakeStart: Date?
    private var briefWakeCount: Int = 0
    private var briefWakeTotalSecs: Double = 0

    // ~4-minute rolling HR buffer (240 samples at 1 Hz).
    // avg + min of this window drive the sleep signal.
    private var hrBuffer: [Double] = []
    private let bufferMax = 240

    // Timestamped HR history for retroactive stage classification at session end.
    private var sleepHRHistory: [(date: Date, bpm: Int)] = []

    // Updated by CMMotionActivityManager; true until first update (conservative default).
    private var isStationary = true
    private let motionManager = CMMotionActivityManager()

    // Wrist-wear state from GET_HELLO_HARVARD ACK. nil = unknown (don't gate sleep).
    var wristOn: Bool? = nil

    // Called on main actor when a sleep session is confirmed.
    var onSessionEnd: ((SleepSession) -> Void)?

    init() { startMotionUpdates() }

    // MARK: - Feed live HR (~1 Hz from BLEManager.acceptMetrics)

    func observe(_ metrics: WhoopMetrics) {
        hrBuffer.append(Double(metrics.heartRate))
        if hrBuffer.count > bufferMax { hrBuffer.removeFirst() }
        guard hrBuffer.count >= 8 else { return }
        step(at: metrics.timestamp, hr: metrics.heartRate)
    }

    // MARK: - State machine (§2.3 + brief wake sub-state)

    private func step(at now: Date, hr: Int) {
        let avg = hrBuffer.reduce(0, +) / Double(hrBuffer.count)
        let min = hrBuffer.min()!

        // Sleep signal: HR within 5 BPM of rolling minimum AND device stationary.
        // wristOn from 0x35 ACK observed but NOT used to gate — bit-layout unverified
        // and prior gating blocked overnight detection when bit read false.
        let sleepLike = avg < (min + 5) && isStationary

        // Soft time prior (§9.7): 10 min inside 21:00–11:00, 20 min outside.
        let hour = Calendar.current.component(.hour, from: now)
        let inWindow = hour >= 21 || hour < 11
        let candidateDuration: TimeInterval = inWindow ? 600 : 1200

        switch state {
        case .awake:
            if sleepLike { candidateStart = now; state = .candidate }

        case .candidate:
            if !sleepLike {
                state = .awake; candidateStart = nil
            } else if let cs = candidateStart, now.timeIntervalSince(cs) >= candidateDuration {
                sleepOnset = cs
                state = .sleeping
                sleepHRHistory.removeAll(keepingCapacity: true)
                briefWakeCount = 0; briefWakeTotalSecs = 0; briefWakeStart = nil
                let isoFmt = ISO8601DateFormatter()
                print("[Sleep] session opened onset=\(isoFmt.string(from: cs))")
            }

        case .sleeping:
            sleepHRHistory.append((now, hr))
            if sleepLike {
                break
            } else {
                briefWakeStart = now
                state = .briefWake
                print("[Sleep] brief wake detected at \(now.formatted(date: .omitted, time: .shortened))")
            }

        case .briefWake:
            sleepHRHistory.append((now, hr))
            if sleepLike {
                if let bws = briefWakeStart {
                    let dur = now.timeIntervalSince(bws)
                    briefWakeTotalSecs += dur
                    briefWakeCount += 1
                    let durMins = Int(dur / 60)
                    print("[Sleep] brief wake absorbed (under 10min threshold) duration=\(durMins)m interruption_count=\(briefWakeCount)")
                }
                briefWakeStart = nil
                state = .sleeping
            } else if let bws = briefWakeStart, now.timeIntervalSince(bws) >= 600 {
                if let onset = sleepOnset {
                    let sessionDurSecs = Int(bws.timeIntervalSince(onset))
                    let h = sessionDurSecs / 3600; let m = (sessionDurSecs % 3600) / 60
                    let sleepSecs = sessionDurSecs - Int(briefWakeTotalSecs)
                    let efficiency = sessionDurSecs > 0 ? Double(sleepSecs) / Double(sessionDurSecs) : 0
                    let stages = classifyLiveStages()
                    print("[Sleep] session finalized duration=\(h)h\(m)m brief_wakes=\(briefWakeCount) efficiency=\(String(format: "%.2f", efficiency)) stages=\(stages?.count ?? 0)")
                    let session = SleepSession(
                        start: onset,
                        end: bws,
                        stages: stages,
                        briefWakeCount: briefWakeCount,
                        briefWakeTotalSeconds: Int(briefWakeTotalSecs)
                    )
                    onSessionEnd?(session)
                }
                state = .awake
                sleepOnset = nil; candidateStart = nil
                briefWakeStart = nil; briefWakeCount = 0; briefWakeTotalSecs = 0
                sleepHRHistory = []
            }
        }
    }

    // MARK: - Retroactive stage classification

    private func classifyLiveStages() -> [SleepStageSegment]? {
        guard sleepHRHistory.count >= 8 else { return nil }
        let sorted = sleepHRHistory.sorted { $0.date < $1.date }

        let allHR = sorted.map { Double($0.bpm) }.sorted()
        let baseline = allHR[max(0, Int(Double(allHR.count) * 0.10))]

        let windowSecs: TimeInterval = 300
        var windows: [(start: Date, end: Date, samples: [Int])] = []
        var ws = sorted.first!.date
        let last = sorted.last!.date
        while ws < last {
            let we = ws.addingTimeInterval(windowSecs)
            let bucket = sorted.filter { $0.date >= ws && $0.date < we }.map(\.bpm)
            if !bucket.isEmpty { windows.append((ws, we, bucket)) }
            ws = we
        }
        guard !windows.isEmpty else { return nil }

        var segments: [SleepStageSegment] = []
        for i in windows.indices {
            let w = windows[i]
            let avgHR = Double(w.samples.reduce(0, +)) / Double(w.samples.count)
            let hrStd = {
                let m = avgHR
                let sq = w.samples.map { (Double($0) - m) * (Double($0) - m) }
                return sqrt(sq.reduce(0, +) / Double(max(1, sq.count)))
            }()

            let cutoff = w.start.addingTimeInterval(-3600)
            let pool = sorted.filter { $0.date >= cutoff && $0.date < w.end }.map { Double($0.bpm) }.sorted()
            let localP10: Double
            if pool.count >= 12 {
                localP10 = pool[max(0, Int(Double(pool.count) * 0.10))]
            } else {
                localP10 = baseline
            }
            let localBaseline = max(localP10, baseline)

            let delta = avgHR - localBaseline
            let stage: SleepStage
            if delta > 15 { stage = .awake }
            else if delta <= 3 && hrStd < 3 { stage = .deep }
            else if delta <= 8 { stage = .core }
            else { stage = .rem }

            segments.append(SleepStageSegment(start: w.start, end: w.end, stage: stage))
        }

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
        return merged
    }

    // MARK: - CoreMotion

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("[LiveSleep] CoreMotion unavailable — using HR-only classification")
            return
        }
        motionManager.startActivityUpdates(to: .main) { @Sendable [weak self] activity in
            guard let a = activity else { return }
            let stationary = a.stationary || (!a.walking && !a.running && !a.cycling && !a.automotive)
            Task { @MainActor [weak self] in self?.isStationary = stationary }
        }
    }
}
