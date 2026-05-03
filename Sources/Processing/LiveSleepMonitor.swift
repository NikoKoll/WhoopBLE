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

    // Updated by CMMotionActivityManager; true until first update (conservative default).
    private var isStationary = true
    private let motionManager = CMMotionActivityManager()

    // Called on main actor when a sleep session is confirmed.
    var onSessionEnd: ((SleepSession) -> Void)?

    init() { startMotionUpdates() }

    // MARK: - Feed live HR (~1 Hz from BLEManager.acceptMetrics)

    func observe(_ metrics: WhoopMetrics) {
        hrBuffer.append(Double(metrics.heartRate))
        if hrBuffer.count > bufferMax { hrBuffer.removeFirst() }
        guard hrBuffer.count >= 8 else { return }
        step(at: metrics.timestamp)
    }

    // MARK: - State machine (§2.3 + brief wake sub-state)

    private func step(at now: Date) {
        let avg = hrBuffer.reduce(0, +) / Double(hrBuffer.count)
        let min = hrBuffer.min()!

        // Sleep signal: HR within 5 BPM of rolling minimum AND device stationary.
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
                briefWakeCount = 0; briefWakeTotalSecs = 0; briefWakeStart = nil
                let isoFmt = ISO8601DateFormatter()
                print("[Sleep] session opened onset=\(isoFmt.string(from: cs))")
            }

        case .sleeping:
            if sleepLike {
                // All good, remain sleeping.
                break
            } else {
                // Conditions broke — enter brief wake sub-state.
                briefWakeStart = now
                state = .briefWake
                print("[Sleep] brief wake detected at \(now.formatted(date: .omitted, time: .shortened))")
            }

        case .briefWake:
            if sleepLike {
                // Conditions restored — absorb as brief wake.
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
                // Sustained 10-min wake — finalize session.
                if let onset = sleepOnset {
                    let sessionDurSecs = Int(bws.timeIntervalSince(onset))
                    let h = sessionDurSecs / 3600; let m = (sessionDurSecs % 3600) / 60
                    let sleepSecs = sessionDurSecs - Int(briefWakeTotalSecs)
                    let efficiency = sessionDurSecs > 0 ? Double(sleepSecs) / Double(sessionDurSecs) : 0
                    print("[Sleep] session finalized duration=\(h)h\(m)m brief_wakes=\(briefWakeCount) efficiency=\(String(format: "%.2f", efficiency))")
                    let session = SleepSession(
                        start: onset,
                        end: bws,
                        briefWakeCount: briefWakeCount,
                        briefWakeTotalSeconds: Int(briefWakeTotalSecs)
                    )
                    onSessionEnd?(session)
                }
                state = .awake
                sleepOnset = nil; candidateStart = nil
                briefWakeStart = nil; briefWakeCount = 0; briefWakeTotalSecs = 0
            }
        }
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
