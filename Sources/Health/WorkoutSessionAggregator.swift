import Foundation
import HealthKit

// Aggregates ~1 Hz HR/MET samples into ONE HKWorkout per logical activity session.
//
// Idle → opens a session when MET ≥ exerciseMETThreshold sustains for ≥ openSec.
// Active → buffers HR + per-sample kcal until MET stays below threshold for cooldownSec,
// then emits a single linked HKWorkout (energy + HR samples attached).
@MainActor
final class WorkoutSessionAggregator {

    struct Sample {
        let ts: Date
        let hr: Int
        let met: Double
        let kcal: Double
    }

    private let healthKit: HealthKitWriter
    private let exerciseMETThreshold: Double = 3.0
    private let openSec: TimeInterval = 60
    private let cooldownSec: TimeInterval = 300
    private let minWorkoutSec: TimeInterval = 300

    private(set) var isSessionActive = false
    private var sessionStart: Date?
    private var lastBriskAt: Date?
    // Candidate brisk run while idle — first sample of an unbroken MET ≥ threshold streak.
    private var briskRunStart: Date?
    // Recent samples retained while idle so a retroactive session can include the pre-open window.
    private var idleRing: [Sample] = []
    private var sessionBuf: [Sample] = []

    init(healthKit: HealthKitWriter) { self.healthKit = healthKit }

    // Called from BLEManager.accumulateActivity per HR sample.
    func observe(timestamp: Date, hr: Int, met: Double, kcalDelta: Double) {
        let s = Sample(ts: timestamp, hr: hr, met: met, kcal: kcalDelta)
        if isSessionActive {
            sessionBuf.append(s)
            if met >= exerciseMETThreshold { lastBriskAt = timestamp }
            // Cool-down → close
            if let last = lastBriskAt, timestamp.timeIntervalSince(last) >= cooldownSec {
                close(end: last)
            }
            return
        }

        // Idle path
        idleRing.append(s)
        // Trim ring to 120s
        let cutoff = timestamp.addingTimeInterval(-120)
        if let firstKeep = idleRing.firstIndex(where: { $0.ts >= cutoff }), firstKeep > 0 {
            idleRing.removeFirst(firstKeep)
        }

        if met >= exerciseMETThreshold {
            if briskRunStart == nil { briskRunStart = timestamp }
            if let start = briskRunStart, timestamp.timeIntervalSince(start) >= openSec {
                open(at: start, now: timestamp)
            }
        } else {
            briskRunStart = nil
        }
    }

    // Force-close on disconnect or app teardown. Emits if duration ≥ minWorkoutSec.
    func flush(now: Date) {
        guard isSessionActive else { return }
        let end = lastBriskAt ?? now
        close(end: end)
    }

    private func open(at start: Date, now: Date) {
        isSessionActive = true
        sessionStart = start
        lastBriskAt = now
        sessionBuf = idleRing.filter { $0.ts >= start }
        idleRing.removeAll()
        briskRunStart = nil
        print("[Session] open start=\(start)")
    }

    private func close(end: Date) {
        guard let start = sessionStart else { isSessionActive = false; return }
        let buf = sessionBuf.filter { $0.ts >= start && $0.ts <= end }
        let dur = end.timeIntervalSince(start)
        let kcal = buf.reduce(0) { $0 + $1.kcal }
        let avgMET = buf.isEmpty ? 0 : buf.reduce(0) { $0 + $1.met } / Double(buf.count)
        let activity = activityType(avgMET: avgMET)

        // Reset state BEFORE async emit so a new session can start cleanly.
        isSessionActive = false
        sessionStart = nil
        lastBriskAt = nil
        sessionBuf.removeAll()

        guard dur >= minWorkoutSec, kcal > 0 else {
            print("[Session] close discarded dur=\(Int(dur))s kcal=\(String(format: "%.1f", kcal))")
            return
        }
        print("[Workout] session finalized writing single HKWorkout duration=\(String(format: "%.0f", dur/60))m energy=\(String(format: "%.0f", kcal))kcal samples=\(buf.count) type=\(activity.rawValue)")

        let energyBuckets = bucketEnergy(buf: buf, start: start, end: end)
        let hrSamples = buf.map { (ts: $0.ts, bpm: $0.hr) }

        Task { [healthKit] in
            let watchActive = await healthKit.watchEnergyActiveRecently()
            if watchActive {
                print("[Session] suppressed: watch active")
                return
            }
            await MainActor.run {
                healthKit.writeWorkoutSession(start: start, end: end, kcal: kcal,
                                              energyBuckets: energyBuckets,
                                              hrSamples: hrSamples,
                                              activity: activity)
            }
        }
    }

    private func activityType(avgMET: Double) -> HKWorkoutActivityType {
        if avgMET < 4.0 { return .walking }
        if avgMET >= 6.0 { return .running }
        return .mixedCardio
    }

    // Bucket per-sample kcal into ≤60-second segments so the Move ring sees a curve, not a flat block.
    private func bucketEnergy(buf: [Sample], start: Date, end: Date) -> [(Date, Date, Double)] {
        guard !buf.isEmpty else { return [(start, end, 0)] }
        var out: [(Date, Date, Double)] = []
        var bStart = start
        var bKcal: Double = 0
        for s in buf {
            if s.ts.timeIntervalSince(bStart) >= 60 {
                out.append((bStart, s.ts, bKcal))
                bStart = s.ts
                bKcal = 0
            }
            bKcal += s.kcal
        }
        out.append((bStart, end, bKcal))
        return out
    }
}
