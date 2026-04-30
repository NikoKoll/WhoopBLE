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
            HKCategoryType(.sleepAnalysis)
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
    func writeSleep(_ sessions: [SleepSession]) {
        guard !sessions.isEmpty else { return }
        let maxSleepDuration: TimeInterval = 86400  // HealthKit cap: 24h
        let now = Date()
        let samples: [HKSample] = sessions.compactMap {
            let start = $0.start
            let end   = min($0.end, start.addingTimeInterval(maxSleepDuration))
            guard end > start, end <= now.addingTimeInterval(3600) else {
                print("[HealthKit] sleep session skipped: invalid range \(start) → \(end)")
                return nil
            }
            return HKCategorySample(
                type: HKCategoryType(.sleepAnalysis),
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: start, end: end
            )
        }
        store.save(samples) { @Sendable _, error in
            if let error { print("[HealthKit] sleep write error: \(error.localizedDescription)") }
            else { print("[HealthKit] wrote \(samples.count) sleep session(s)") }
        }
    }
}
