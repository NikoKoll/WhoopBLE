import Foundation
import HealthKit

// One-time consolidation of fragmented HKWorkout objects written by this app.
// Runs on first launch after install/update; subsequent launches skip via UserDefaults flag.
// Groups workouts by (local calendar date, activityType); merges consecutive workouts
// that are ≤30 min apart into a single workout with summed energy and all HR samples.
actor WorkoutMigrator {

    private let store: HKHealthStore
    private let doneKey = "hkWorkoutMigration_v1"

    init(store: HKHealthStore) { self.store = store }

    // Returns ISO date strings for every day that had workouts merged — caller should re-enqueue those dates.
    func migrateIfNeeded() async -> [String] {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return [] }
        let affectedDates = await consolidate()
        UserDefaults.standard.set(true, forKey: doneKey)
        return affectedDates
    }

    // MARK: - Private

    private func consolidate() async -> [String] {
        let workouts = await fetchAppWorkouts()
        guard !workouts.isEmpty else { return [] }

        // Group by (local ISO date, activityType rawValue)
        var groups: [String: [HKWorkout]] = [:]
        let cal = Calendar.current
        for w in workouts {
            let comps = cal.dateComponents([.year, .month, .day], from: w.startDate)
            let key = "\(comps.year!)-\(String(format: "%02d", comps.month!))-\(String(format: "%02d", comps.day!))||\(w.workoutActivityType.rawValue)"
            groups[key, default: []].append(w)
        }

        var affectedDates: Set<String> = []
        for (key, group) in groups {
            guard group.count > 1 else { continue }
            let sorted = group.sorted { $0.startDate < $1.startDate }
            // Find runs of workouts where consecutive gap ≤ 30 min
            let runs = fragmentRuns(sorted, maxGap: 1800)
            guard runs.contains(where: { $0.count > 1 }) else { continue }

            let dateStr = String(key.prefix(10))
            for run in runs where run.count > 1 {
                await mergeRun(run)
                affectedDates.insert(dateStr)
            }
        }

        return Array(affectedDates)
    }

    private func fragmentRuns(_ sorted: [HKWorkout], maxGap: TimeInterval) -> [[HKWorkout]] {
        var runs: [[HKWorkout]] = []
        var current: [HKWorkout] = [sorted[0]]
        for i in 1..<sorted.count {
            let gap = sorted[i].startDate.timeIntervalSince(sorted[i-1].endDate)
            if gap <= maxGap {
                current.append(sorted[i])
            } else {
                runs.append(current)
                current = [sorted[i]]
            }
        }
        runs.append(current)
        return runs
    }

    private func mergeRun(_ workouts: [HKWorkout]) async {
        guard workouts.count > 1,
              let start  = workouts.map(\.startDate).min(),
              let end    = workouts.map(\.endDate).max() else { return }

        let activityType = workouts[0].workoutActivityType
        let totalKcal    = workouts.reduce(0.0) { $0 + ($1.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0) }
        let dateStr      = start.formatted(date: .abbreviated, time: .omitted)
        let n            = workouts.count

        // Fetch linked HR samples from originals
        let hrSamples = await fetchLinkedHRSamples(for: workouts)

        // Delete originals
        let deleted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            store.delete(workouts) { _, _ in cont.resume(returning: true) }
        }
        guard deleted else { return }

        // Write merged workout
        let config = HKWorkoutConfiguration()
        config.activityType = activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            builder.beginCollection(withStart: start) { _, _ in cont.resume() }
        }

        if !hrSamples.isEmpty {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                builder.add(hrSamples) { _, _ in cont.resume() }
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            builder.endCollection(withEnd: end) { _, _ in cont.resume() }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            builder.finishWorkout { _, _ in cont.resume() }
        }

        let dur = end.timeIntervalSince(start) / 60.0
        print("[Migration] consolidated \(n) workout fragments into 1 session for date=\(dateStr) duration=\(String(format: "%.0f", dur))m energy=\(String(format: "%.0f", totalKcal))kcal")
    }

    private func fetchAppWorkouts() async -> [HKWorkout] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HKWorkout], Never>) in
            let pred = HKQuery.predicateForObjects(from: HKSource.default())
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    private func fetchLinkedHRSamples(for workouts: [HKWorkout]) async -> [HKSample] {
        var result: [HKSample] = []
        for workout in workouts {
            let samples: [HKSample] = await withCheckedContinuation { (cont: CheckedContinuation<[HKSample], Never>) in
                let pred = HKQuery.predicateForObjects(from: workout)
                let q = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                    cont.resume(returning: s ?? [])
                }
                store.execute(q)
            }
            result.append(contentsOf: samples)
        }
        return result
    }
}
