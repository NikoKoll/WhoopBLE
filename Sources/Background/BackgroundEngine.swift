import Foundation
import BackgroundTasks
import HealthKit

/// Manages background processing for overnight score generation.
///
/// Registers a BGProcessingTask that fires in the 3–5 AM window when the device
/// is charging. Recomputes yesterday + today so recovery/strain/sleep scores are
/// ready before the user opens the app in the morning.
///
/// Usage — call `register()` from WhoopBLEApp.init() and `scheduleOvernightTask()`
/// from the `.onBackground` scene phase.
final class BackgroundEngine: @unchecked Sendable {

    static let shared = BackgroundEngine()
    static let processingTaskID = "com.personal.WhoopBLE.overnight"

    private init() {}

    // MARK: - Registration (call once at app launch)

    func register() {
        // BGTaskScheduler closure is a legacy ObjC callback — not Swift concurrency aware.
        // nonisolated(unsafe) is safe here: BackgroundEngine is a singleton with no mutable state.
        nonisolated(unsafe) let engine = BackgroundEngine.shared
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskID,
            using: nil
        ) { task in
            guard let pt = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            nonisolated(unsafe) let processingTask = pt
            Task { await engine.runOvernightRecompute(task: processingTask) }
        }
        print("[BackgroundEngine] registered task \(Self.processingTaskID)")
    }

    // MARK: - Scheduling (call when app enters background)

    func scheduleOvernightTask() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        // Prefer charging — overnight recompute is CPU-heavy
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        // Earliest fire: 1 hour from now — system picks actual time (typically 3–5 AM)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundEngine] overnight task scheduled")
        } catch {
            print("[BackgroundEngine] schedule failed: \(error)")
        }
    }

    // MARK: - Task handler

    private func runOvernightRecompute(task: BGProcessingTask) async {
        // Reschedule for next night before doing any work
        scheduleOvernightTask()

        let rawStore   = RawDataStore()
        let dailyStore = DailyMetricsStore()
        let healthKit  = HealthKitWriter()
        let recomputer = DayRecomputer()
        let snapStore  = SnapshotStore()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today     = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

        // Expiry handler — mark incomplete if system reclaims time budget
        let workItem = Task {
            await rawStore.flush()
            for date in [yesterday, today] {
                await recomputer.recomputeDay(
                    date:          date,
                    rawStore:      rawStore,
                    dailyStore:    dailyStore,
                    healthKit:     healthKit,
                    featureCache:  nil,   // in-memory cache not shared across processes
                    snapshotStore: snapStore
                )
            }
            print("[BackgroundEngine] overnight recompute complete")
        }

        task.expirationHandler = {
            workItem.cancel()
            task.setTaskCompleted(success: false)
            print("[BackgroundEngine] task expired before completion")
        }

        await workItem.value
        task.setTaskCompleted(success: true)
    }
}
