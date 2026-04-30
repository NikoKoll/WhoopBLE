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

    private enum State { case awake, candidate, sleeping }
    private var state: State = .awake
    private var candidateStart: Date?
    private var sleepOnset: Date?
    private var wakeCandidate: Date?

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

    // MARK: - State machine (§2.3)

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
                wakeCandidate = nil
                print("[LiveSleep] onset \(cs.formatted(date: .omitted, time: .shortened))")
            }

        case .sleeping:
            if sleepLike {
                wakeCandidate = nil
            } else {
                if wakeCandidate == nil { wakeCandidate = now }
                // Require 5 min of non-sleep conditions to confirm wake.
                if let wc = wakeCandidate, now.timeIntervalSince(wc) >= 300 {
                    if let onset = sleepOnset {
                        let session = SleepSession(start: onset, end: wc)
                        print("[LiveSleep] wake \(wc.formatted(date: .omitted, time: .shortened))")
                        onSessionEnd?(session)
                    }
                    state = .awake
                    sleepOnset = nil; wakeCandidate = nil; candidateStart = nil
                }
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
