1. Got some sleep data but very worng. 

3. syncing takes for ever to finish, if i restart the app finished instantly but didnt retrive any data the second time 

4. maybe implemnt the data storage now to have soem data to see over time 


5. last edit to be added to handoff if needed 

Plan: recomputeDay Pipeline + RecomputeQueue

 Context

 The app computes metrics (HR, HRV) in memory only — no way to recompute a past day from
 raw
 data. Algorithms doc §10.2 mandates deterministic reprocessing from persisted raw data,
 with
 version stamps so algorithm upgrades auto-trigger backfills. This adds that full
 pipeline.

 ---
 New Files (4)

 1. Sources/Processing/RawDataStore.swift

 Swift actor. Persists raw HR and RR samples to per-day JSON files in Documents/.

 raw_hr_2025-04-27.json   ← [HRSample]
 raw_rr_2025-04-27.json   ← [RRSample]

 Types:
 struct HRSample: Codable, Sendable { let timestamp: Int; let bpm: Int }
 struct RRSample: Codable, Sendable { let timestamp: Int; let intervalMs: Int }

 Key rules:
 - 30s throttle on appendHR (one sample per 30s, using lastHRTimestamp field)
 - RR intervals stored every notification (sparse, unthrottled)
 - In-memory buffer flushed to disk every 60 seconds via a background Task
 - flush() also called explicitly before recompute starts
 - loadHR(for:) / loadRR(for:) return disk data + pending buffer, sorted by timestamp
 - pruneOlderThan(days: 90) deletes files beyond 90-day window; called on init

 Public API:
 func appendHR(timestamp: Int, bpm: Int)
 func appendRR(timestamp: Int, intervalMs: Int)
 func appendHRBatch(_ samples: [(timestamp: Int, bpm: Int)])  // for historical sync
 func loadHR(for date: Date) async -> [HRSample]
 func loadRR(for date: Date) async -> [RRSample]
 func flush() async

 ---
 2. Sources/Processing/DailyMetricsStore.swift

 Swift actor. Two JSON files:

 daily_metrics_v1.json        ← [DailyMetrics]
 algorithm_versions_v1.json   ← [AlgorithmVersion]

 Types:
 struct DailyMetrics: Codable, Sendable {
     let date: String          // "2025-04-27" UTC ISO
     var rhr: Double?
     var hrvRmssd: Double?
     var hrvSdnn: Double?
     var strainScore: Double?
     var sleepMinutes: Int?
     var hrvVersion: Int       // algorithm version stamps
     var strainVersion: Int
     var sleepVersion: Int
 }

 struct AlgorithmVersion: Codable, Sendable {
     let name: String          // "hrv" | "strain" | "sleep"
     var version: Int
     var updatedAt: Int        // unix seconds
 }

 Public API:
 func upsert(_ metrics: DailyMetrics) async
 func delete(date: String) async
 func load(date: String) async -> DailyMetrics?
 func loadAll() async -> [DailyMetrics]
 func datesNeedingRecompute(metric: String, below version: Int) async -> [String]
 func loadVersions() async -> [AlgorithmVersion]
 func saveVersion(_ v: AlgorithmVersion) async

 ---
 3. Sources/Processing/DayRecomputer.swift

 Plain struct. All functions pure — no side effects, no stored state. Takes raw data in,
 returns computed values. Calls RawDataStore and DailyMetricsStore only via the
 recomputeDay orchestrator.

 Algorithm version constants (bump these to trigger backfill):
 enum AlgoVersions {
     static let hrv    = 1
     static let strain = 1   // exponential zone weights
     static let sleep  = 1
 }

 Pure compute functions:

 computeRHR(hrSamples: [HRSample]) -> Double?
   - Slide 5-min windows (step = 1 min) over samples
   - Window average if ≥ 5 samples in window
   - Return minimum window average across day
   - Return nil if no window has enough samples

 computeHRV(rrSamples: [RRSample]) -> (rmssd: Double, sdnn: Double)?
   - Require ≥ 2 samples
   - RMSSD = sqrt(sum((rr[i+1]-rr[i])^2) / (n-1))   intervals in ms
   - SDNN  = sqrt(sum((rr[i]-mean)^2) / (n-1))
   - Return nil if < 2

 computeStrain(hrSamples: [HRSample]) -> Double
   - Default maxHR = 185 (age 35 estimate; no user profile yet)
   - Zone boundaries: [50%, 60%, 70%, 80%, 90%] of maxHR
   - Zone weights: [0.50, 1.01, 2.03, 4.08, 8.20] (exponential from §9.9)
   - Each sample contributes weight * (30.0 / 3600.0) — 30s per sample
   - Normalize to 0-21: (raw / MAX_REALISTIC_STRAIN) * 21, clamped 0–21
   - MAX_REALISTIC_STRAIN = 60 min Zone5 + 720 min Zone1, in the same units

 detectSleep(hrSamples: [HRSample]) -> [SleepSession]
   - Convert HRSample → HistoricalSample (no accelerometer)
   - Call existing SleepDetector().process(_:) — reuse, no duplication

 Orchestrator:
 recomputeDay(date: Date, rawStore: RawDataStore, dailyStore: DailyMetricsStore,
              existingSleepSessions: [SleepSession]) async
   1. await rawStore.flush()                           // ensure buffers are on disk
   2. let hr = await rawStore.loadHR(for: date)
   3. let rr = await rawStore.loadRR(for: date)
   4. Compute rhr, hrv, strain, sleep from pure functions above
   5. await dailyStore.delete(date: isoDate(date))     // overwrite
   6. await dailyStore.upsert(DailyMetrics(
        date, rhr, hrv.rmssd, hrv.sdnn, strain,
        sleepMinutes,
        hrvVersion: AlgoVersions.hrv,
        strainVersion: AlgoVersions.strain,
        sleepVersion: AlgoVersions.sleep))
   7. Print summary line for each recomputed day

 ---
 4. Sources/Processing/RecomputeQueue.swift

 Swift actor. Deduplicates pending dates and drains serially at .background priority.

 actor RecomputeQueue {
     private var pending: Set<String> = []   // ISO date strings
     private var isRunning = false
     private let recomputer = DayRecomputer()

     // Called from SyncManager after sync, and on launch for version mismatch
     func enqueue(dates: [Date], rawStore: RawDataStore, dailyStore: DailyMetricsStore,
                  sleepSessions: [SleepSession]) async

     // Drains queue serially, one date at a time
     private func drain(rawStore: RawDataStore, dailyStore: DailyMetricsStore,
                        sleepSessions: [SleepSession]) async
 }

 drain loop:
 while pending is not empty:
     pop one date from pending
     await Task(priority: .background) { recomputer.recomputeDay(date, rawStore,
 dailyStore, sessions) }.value

 ---
 Modified Files (3)

 Sources/BLE/BLEManager.swift

 Add to properties:
 let rawDataStore    = RawDataStore()
 let dailyMetrics    = DailyMetricsStore()
 let recomputeQueue  = RecomputeQueue()

 In acceptMetrics (inside the Task { @MainActor } block), after existing metric updates:
 let ts = Int(metrics.timestamp.timeIntervalSince1970)
 Task { await self.rawDataStore.appendHR(timestamp: ts, bpm: metrics.heartRate) }
 for rr in metrics.rrIntervals where rr >= 0.3 && rr <= 2.0 {
     Task { await self.rawDataStore.appendRR(timestamp: ts, intervalMs: Int(rr * 1000)) }
 }

 Add public method called from WhoopBLEApp:
 func checkVersionMismatch() async {
     let stored = await dailyMetrics.loadVersions()
     var datesToRecompute: [Date] = []
     let versionMap: [(name: String, current: Int)] = [
         ("hrv", AlgoVersions.hrv), ("strain", AlgoVersions.strain), ("sleep",
 AlgoVersions.sleep)
     ]
     for (name, current) in versionMap {
         let storedVer = stored.first(where: { $0.name == name })?.version ?? 0
         if storedVer < current {
             let dates = await dailyMetrics.datesNeedingRecompute(metric: name +
 "Version", below: current)
             datesToRecompute.append(contentsOf: dates.compactMap { parseISODate($0) })
             await dailyMetrics.saveVersion(AlgorithmVersion(name: name, version: current,
                                                              updatedAt:
 Int(Date().timeIntervalSince1970)))
         }
     }
     if !datesToRecompute.isEmpty {
         let sessions = syncManager.sleepSessions
         await recomputeQueue.enqueue(dates: Array(Set(datesToRecompute)), rawStore:
 rawDataStore,
                                       dailyStore: dailyMetrics, sleepSessions: sessions)
     }
 }

 Sources/BLE/SyncManager.swift

 In finalizeBatch, after parsing samples, write HR samples to rawStore via BLEManager:
 if let rawStore = bleManager?.rawDataStore {
     let hrBatch = samples.map { (timestamp: Int($0.timestamp.timeIntervalSince1970), bpm:
  $0.heartRate) }
     Task { await rawStore.appendHRBatch(hrBatch) }
 }

 In runSleepDetectionIfDone(), after sleep detection completes, collect affected dates and
  enqueue:
 let affectedDates = Array(Set(accumulatedSamples.map {
     Calendar.current.startOfDay(for: $0.timestamp)
 }))
 if let ble = bleManager, !affectedDates.isEmpty {
     let sessions = sleepSessions
     Task {
         await ble.recomputeQueue.enqueue(dates: affectedDates, rawStore:
 ble.rawDataStore,
                                           dailyStore: ble.dailyMetrics, sleepSessions:
 sessions)
     }
 }

 Similarly enqueue today's date when sync finishes with no batches (idle finish paths).

 Sources/WhoopBLEApp.swift

 Add version mismatch trigger in .task:
 .task {
     await bleManager.healthKit.requestAuthorization()
     await bleManager.checkVersionMismatch()   // ← add this line
 }

 ---
 Verification Steps

     Verification Steps

     1. Build: xcodegen generate && open WhoopBLE.xcodeproj → must compile with zero Swift
     6 errors
     2. Live session: connect strap → check raw_hr_<today>.json appears in Documents after
     60s flush
     3. Sync: trigger sync → verify raw_hr_<date>.json files for historical dates appear
     4. Recompute: after sync, daily_metrics_v1.json must contain entries with version
     stamps
     5. Version bump: change AlgoVersions.hrv = 2 → relaunch → all existing days should
     requeue
     6. Determinism: recompute same date twice → assert identical DailyMetrics output

     ---
     Files NOT changed

     - project.yml — no new deps
     - CRCCalculator.swift, PacketDecoder.swift, LiveSleepMonitor.swift, StepDetector.swift
     - All Views
     - HealthKitWriter.swift

⏺ Now implementing. Starting with all 4 new files, then modifying the 3 existing ones.

⏺ Write(Sources/Processing/RawDataStore.swift)
  ⎿  Wrote 159 lines to Sources/Processing/RawDataStore.swift
       2 import Foundation
       3 /// Persists raw HR and RR samples to per-day JSON files.
       4 /// Files: raw_hr_<date>.json, raw_rr_<date>.json in Documents/
       5 /// 90-day retention; 30-second throttle on live HR; full capture for batch
          sync.
       6 actor RawDataStore {
       7
       8     struct HRSample: Codable, Sendable {
       9         let timestamp: Int  // unix seconds UTC
      10         let bpm: Int
     … +161 lines (ctrl+o to expand)

⏺ Write(Sources/Processing/DailyMetricsStore.swift)
  ⎿  Wrote 113 lines to Sources/Processing/DailyMetricsStore.swift
       2 import Foundation
       3 /// Persists DailyMetrics (one row per UTC calendar day) and algorithm vers
         ion stamps.
       4 /// Files: daily_metrics_v1.json, algorithm_versions_v1.json in Documents/
       5 actor DailyMetricsStore {
       6
       7     struct DailyMetrics: Codable, Sendable {
       8         let date: String        // "2025-04-27" UTC ISO
       9         var rhr: Double?        // resting HR in BPM
      10         var hrvRmssd: Double?   // RMSSD in ms
     … +112 lines (ctrl+o to expand)

⏺ Write(Sources/Processing/DayRecomputer.swift)
  ⎿  Wrote 135 lines to Sources/Processing/DayRecomputer.swift
       2 import Foundation
       3 /// Bump these to trigger automatic backfill of all existing daily_metrics
         rows on next launch.
       4 enum AlgoVersions {
       5     static let hrv    = 1   // RMSSD + SDNN from per-day RR samples
       6     static let strain = 1   // exponential zone weights (§9.9)
       7     static let sleep  = 1   // SleepDetector window-based heuristic
       8 }
       9
      10 /// Pure compute functions + recomputeDay orchestrator.
     … +148 lines (ctrl+o to expand)

⏺ Write(Sources/Processing/RecomputeQueue.swift)
  ⎿  Wrote 58 lines to Sources/Processing/RecomputeQueue.swift
       2 import Foundation
       3 /// Deduplicating background queue for day recomputation.
       4 /// Accepts date strings, deduplicates, drains serially at background prior
         ity.
       5 actor RecomputeQueue {
       7     private var pending:    Set<String> = []  // ISO date strings "2025-04-
         27"
       8     private var isRunning:  Bool = false
       9     private var rawStore:   RawDataStore?
      10     private var dailyStore: DailyMetricsStore?
     … +50 lines (ctrl+o to expand)

⏺ Now modifying the 3 existing files. Starting with BLEManager:

⏺ Update(Sources/BLE/BLEManager.swift)
  ⎿  Added 7 lines, removed 4 lines
      54      private var rrBuffer: [Double] = []
      55      private var hrvHistory: [Double] = []
      56
      57 -    let healthKit    = HealthKitWriter()
      58 -    let syncManager  = SyncManager()
      59 -    let liveSleep    = LiveSleepMonitor()
      60 -    let metricsStore = MetricsStore()
      57 +    let healthKit      = HealthKitWriter()
      58 +    let syncManager    = SyncManager()
      59 +    let liveSleep      = LiveSleepMonitor()
      60 +    let metricsStore   = MetricsStore()
      61 +    let rawDataStore   = RawDataStore()
      62 +    let dailyMetrics   = DailyMetricsStore()
      63 +    let recomputeQueue = RecomputeQueue()
      64
      65      // Live step count from CMPedometer — today's total, refreshed in real
           time.
      66      @Published var dailySteps: Int = 0
  ⎿  You've hit your limit · resets 1:20am (Europe/Athens)

✻ Sautéed for 10m 49s
