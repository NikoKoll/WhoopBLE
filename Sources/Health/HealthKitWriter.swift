import HealthKit

@MainActor
final class HealthKitWriter {
    private let store = HKHealthStore()
    private var lastWriteDate: Date = .distantPast

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType()
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis)
        ]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Live HR (throttled to 5-second minimum interval)
    func write(_ metrics: WhoopMetrics) {
        guard metrics.timestamp.timeIntervalSince(lastWriteDate) >= 5 else { return }
        lastWriteDate = metrics.timestamp
        saveHR(metrics)
        if let hrv = metrics.hrv { saveHRV(hrv, date: metrics.timestamp) }
    }

    private func saveHR(_ metrics: WhoopMetrics) {
        let qty = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()),
                             doubleValue: Double(metrics.heartRate))
        let sample = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: qty,
                                      start: metrics.timestamp, end: metrics.timestamp)
        store.save(sample) { @Sendable _, error in
            if let error { print("❤️ HR write error: \(error.localizedDescription)") }
            else { print("❤️ HR \(metrics.heartRate) BPM written to HealthKit") }
        }
    }

    private func saveHRV(_ rmssdMs: Double, date: Date) {
        let qty = HKQuantity(unit: .second(), doubleValue: rmssdMs / 1000.0)
        let sample = HKQuantitySample(type: HKQuantityType(.heartRateVariabilitySDNN), quantity: qty,
                                      start: date, end: date)
        store.save(sample) { @Sendable _, error in
            if let error { print("❤️ HRV write error: \(error.localizedDescription)") }
        }
    }

    // MARK: - Historical HR batch (writes all samples in one call, no throttle)
    func writeHistoricalSamples(_ samples: [HistoricalSample]) {
        guard !samples.isEmpty else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let hkSamples: [HKSample] = samples.map { s in
            let qty = HKQuantity(unit: unit, doubleValue: Double(s.heartRate))
            return HKQuantitySample(type: HKQuantityType(.heartRate), quantity: qty,
                                    start: s.timestamp, end: s.timestamp)
        }
        store.save(hkSamples) { @Sendable _, error in
            if let error { print("[HealthKit] historical HR write error: \(error.localizedDescription)") }
            else { print("[HealthKit] wrote \(hkSamples.count) historical HR samples") }
        }
    }

    // MARK: - Step count
    func writeSteps(count: Int, start: Date, end: Date) {
        guard count > 0, end > start else { return }
        let qty = HKQuantity(unit: .count(), doubleValue: Double(count))
        let sample = HKQuantitySample(type: HKQuantityType(.stepCount), quantity: qty,
                                      start: start, end: end)
        store.save(sample) { @Sendable _, error in
            if let error { print("[HealthKit] step write error: \(error.localizedDescription)") }
            else { print("[HealthKit] wrote \(count) steps (\(start) – \(end))") }
        }
    }

    // MARK: - Workout (Exercise + Move rings)
    // Writes ONE HKWorkout with linked activeEnergyBurned + heartRate samples.
    // All samples are clamped to [start, end] so the Workout detail view in Health groups them.
    // Caller is responsible for Watch-suppression check before invoking.
    func writeWorkoutSession(start: Date, end: Date, kcal: Double,
                             energyBuckets: [(Date, Date, Double)],
                             hrSamples: [(ts: Date, bpm: Int)],
                             activity: HKWorkoutActivityType) {
        guard end > start, kcal > 0 else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        // Build sample array. Clamp every sample window into [start, end].
        var samples: [HKSample] = []
        let energyType = HKQuantityType(.activeEnergyBurned)
        let kcalUnit = HKUnit.kilocalorie()
        var droppedEnergy = 0
        for (bs, be, kc) in energyBuckets where kc > 0 {
            let s = max(bs, start), e = min(be, end)
            guard e > s else { droppedEnergy += 1; continue }
            let q = HKQuantity(unit: kcalUnit, doubleValue: kc)
            samples.append(HKQuantitySample(type: energyType, quantity: q, start: s, end: e))
        }
        if droppedEnergy > 0 { print("[HK] Sample window mismatch: dropped \(droppedEnergy) energy bucket(s)") }

        let hrType = HKQuantityType(.heartRate)
        let hrUnit = HKUnit.count().unitDivided(by: .minute())
        for h in hrSamples {
            guard h.ts >= start, h.ts <= end, h.bpm >= 30, h.bpm <= 220 else { continue }
            let q = HKQuantity(unit: hrUnit, doubleValue: Double(h.bpm))
            samples.append(HKQuantitySample(type: hrType, quantity: q, start: h.ts, end: h.ts))
        }

        builder.beginCollection(withStart: start) { @Sendable success, error in
            if let error { print("[HK] Workout begin error: \(error.localizedDescription)"); return }
            guard success else { return }

            let finish: @Sendable (Bool, Error?) -> Void = { _, addErr in
                if let addErr { print("[HK] Workout add error: \(addErr.localizedDescription)") }
                builder.endCollection(withEnd: end) { @Sendable _, endErr in
                    if let endErr { print("[HK] Workout end error: \(endErr.localizedDescription)"); return }
                    builder.finishWorkout { @Sendable workout, finErr in
                        if let finErr { print("[HK] Workout finish error: \(finErr.localizedDescription)") }
                        else if workout != nil {
                            let mins = end.timeIntervalSince(start) / 60.0
                            let nE = samples.filter { $0 is HKQuantitySample && ($0 as! HKQuantitySample).quantityType == energyType }.count
                            let nH = samples.count - nE
                            print("[HK] Workout linked: \(nE) energy + \(nH) HR samples — \(String(format: "%.1f", mins)) min, \(String(format: "%.1f", kcal)) kcal, type=\(activity.rawValue)")
                        }
                    }
                }
            }

            if samples.isEmpty { finish(true, nil) }
            else { builder.add(samples, completion: finish) }
        }
    }

    // MARK: - Active Energy (Move ring)
    func writeActiveEnergy(kcal: Double, start: Date, end: Date) {
        guard kcal > 0, end > start else { return }
        let qty = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: qty,
                                      start: start, end: end)
        store.save(sample) { @Sendable _, error in
            if let error { print("[HK] Energy write error: \(error.localizedDescription)") }
            else { print("[HK] Energy written: \(String(format: "%.1f", kcal)) kcal (\(start) → \(end))") }
        }
    }

    // Returns true if any HealthKit source containing "Watch" wrote an activeEnergyBurned sample in
    // the last `lookback` seconds. Used to suppress live writes when Apple Watch is on the wrist
    // (avoids double-counting against Move ring).
    func watchEnergyActiveRecently(lookback: TimeInterval = 300) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let type = HKQuantityType(.activeEnergyBurned)
            let end = Date()
            let start = end.addingTimeInterval(-lookback)
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(sampleType: type, predicate: pred, limit: 50,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                let watchActive = samples?.contains { sample in
                    let name = sample.sourceRevision.source.name.lowercased()
                    let bundle = sample.sourceRevision.source.bundleIdentifier.lowercased()
                    return name.contains("watch") || bundle.contains("com.apple.health.")
                } ?? false
                cont.resume(returning: watchActive)
            }
            store.execute(query)
        }
    }

    // appleExerciseTime is read-only (Apple Watch exclusive) — cannot be written by third-party apps.

    // MARK: - Delete sleep entries written by this app
    func deleteSleepSamples() {
        let type = HKCategoryType(.sleepAnalysis)
        let pred = HKQuery.predicateForObjects(from: HKSource.default())
        let query = HKSampleQuery(sampleType: type, predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, _ in
            guard let samples, !samples.isEmpty else {
                print("[HealthKit] no sleep samples to delete")
                return
            }
            self?.store.delete(samples) { _, error in
                if let error { print("[HealthKit] sleep delete error: \(error.localizedDescription)") }
                else { print("[HealthKit] deleted \(samples.count) sleep entry(s)") }
            }
        }
        store.execute(query)
    }

    // MARK: - Sleep analysis
    // If `stages` are present, emit per-stage HKCategorySamples (asleepDeep/Core/REM/awake).
    // Otherwise fall back to one asleepUnspecified sample per session.
    func writeSleep(_ sessions: [SleepSession]) {
        guard !sessions.isEmpty else { return }
        let maxSleepDuration: TimeInterval = 86400
        let now = Date()
        let type = HKCategoryType(.sleepAnalysis)
        var samples: [HKSample] = []

        for session in sessions {
            let start = session.start
            let end   = min(session.end, start.addingTimeInterval(maxSleepDuration))
            guard end > start, end <= now.addingTimeInterval(3600) else {
                print("[HealthKit] sleep session skipped: invalid range \(start) → \(end)")
                continue
            }
            if let stages = session.stages, !stages.isEmpty {
                for seg in stages {
                    guard seg.end > seg.start, seg.end <= end.addingTimeInterval(60) else { continue }
                    let value: HKCategoryValueSleepAnalysis = {
                        switch seg.stage {
                        case .deep:  return .asleepDeep
                        case .core:  return .asleepCore
                        case .rem:   return .asleepREM
                        case .awake: return .awake
                        }
                    }()
                    samples.append(HKCategorySample(type: type, value: value.rawValue, start: seg.start, end: seg.end))
                }
            } else {
                samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, start: start, end: end))
            }
        }

        guard !samples.isEmpty else { return }
        store.save(samples) { @Sendable _, error in
            if let error { print("[HealthKit] sleep write error: \(error.localizedDescription)") }
            else { print("[HealthKit] wrote \(samples.count) sleep sample(s)") }
        }
    }
}
