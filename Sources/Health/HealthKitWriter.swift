import HealthKit

@MainActor
final class HealthKitWriter {
    // Internal so WorkoutMigrator can reuse the same store instance.
    let store = HKHealthStore()
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
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.bodyTemperature),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType()
        ]
        try? await store.requestAuthorization(toShare: share, read: read)

        // Log grant/deny status per §10.8 (iOS returns determined states only after first prompt).
        let labels: [(HKObjectType, String)] = [
            (HKQuantityType(.heartRateVariabilitySDNN), "hrv"),
            (HKQuantityType(.restingHeartRate),         "rhr"),
            (HKQuantityType(.respiratoryRate),          "resp"),
            (HKQuantityType(.oxygenSaturation),         "spo2"),
            (HKQuantityType(.bodyTemperature),          "bodytemp"),
            (HKCategoryType(.sleepAnalysis),            "sleep"),
        ]
        var granted: [String] = []
        var denied:  [String] = []
        for (type, label) in labels {
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized:    granted.append(label)
            case .sharingDenied:        denied.append(label)
            default: break
            }
        }
        if !granted.isEmpty { print("[HealthKit] authorization granted for: \(granted.joined(separator: ","))") }
        if !denied.isEmpty  { print("[HealthKit] authorization denied for: \(denied.joined(separator: ","))") }
    }

    // MARK: - Capability checks (§9.11)

    /// Returns true when at least one sample of `type` exists in the last `lookback` seconds.
    func hasRecentSamples(_ type: HKSampleType, lookback: TimeInterval = 7 * 86400) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let end   = Date()
            let start = end.addingTimeInterval(-lookback)
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: 1,
                                  sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: !(samples?.isEmpty ?? true))
            }
            store.execute(q)
        }
    }

    /// Returns true if any activeEnergyBurned sample in the last 7 days came from an Apple Watch source.
    func appleWatchPaired() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let type  = HKQuantityType(.activeEnergyBurned)
            let end   = Date()
            let start = end.addingTimeInterval(-7 * 86400)
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: 100,
                                  sortDescriptors: nil) { _, samples, _ in
                let found = samples?.contains { s in
                    let name   = s.sourceRevision.source.name.lowercased()
                    let bundle = s.sourceRevision.source.bundleIdentifier.lowercased()
                    return name.contains("watch") || bundle.contains("com.apple.health.")
                } ?? false
                cont.resume(returning: found)
            }
            store.execute(q)
        }
    }

    // MARK: - Fallback readers (source fusion for DayRecomputer)

    /// Most recent restingHeartRate sample within ±1 day of `date`.
    func readLatestRHR(for date: Date) async -> Double? {
        await readLatestQuantity(HKQuantityType(.restingHeartRate),
                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                 for: date)
    }

    /// Most recent heartRateVariabilitySDNN sample within ±1 day of `date` (converted ms → ms).
    func readLatestHRV(for date: Date) async -> Double? {
        guard let raw = await readLatestQuantity(HKQuantityType(.heartRateVariabilitySDNN),
                                                 unit: .second(), for: date) else { return nil }
        return raw * 1000.0  // HK stores in seconds; app uses milliseconds
    }

    private func readLatestQuantity(_ type: HKQuantityType, unit: HKUnit, for date: Date) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let start = date.addingTimeInterval(-86400)
            let end   = date.addingTimeInterval(86400)
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort  = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: 1,
                                  sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                cont.resume(returning: value)
            }
            store.execute(q)
        }
    }

    /// Most recent SpO2 sample within the last 24 hours as a percentage (0–100), or nil if none.
    func readLatestSpO2() async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let type  = HKQuantityType(.oxygenSaturation)
            let end   = Date()
            let start = end.addingTimeInterval(-24 * 3600)
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort  = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: 1,
                                  sortDescriptors: [sort]) { _, samples, _ in
                // HK stores oxygenSaturation as a fraction via HKUnit.percent() (0.98 = 98%).
                let frac = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: HKUnit.percent())
                cont.resume(returning: frac.map { $0 * 100 })
            }
            self.store.execute(q)
        }
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
    // Writes ONE asleepUnspecified HKCategorySample per session (full window).
    // Per-stage writing was removed — it produced one Health entry per stage segment,
    // causing the night to appear as multiple fragmented entries.
    func writeSleep(_ sessions: [SleepSession]) {
        guard !sessions.isEmpty else { return }
        let type = HKCategoryType(.sleepAnalysis)
        let now = Date()

        for session in sessions {
            let start = session.start
            let end   = session.end
            guard end > start, end <= now.addingTimeInterval(3600) else {
                print("[HealthKit] sleep session skipped: invalid range \(start) → \(end)")
                continue
            }
            let metadata: [String: Any] = [HKMetadataKeyTimeZone: TimeZone.current.identifier]
            let sample = HKCategorySample(
                type: type,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: start, end: end,
                metadata: metadata
            )
            store.save(sample) { @Sendable _, error in
                if let error {
                    print("[Sleep] HK write failed: \(error.localizedDescription) — SLEEP_HK_WRITE_FAILED")
                } else {
                    print("[Sleep] HK sample written for date=\(start)")
                }
            }
        }
    }
}
