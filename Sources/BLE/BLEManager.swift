import CoreBluetooth
import CoreMotion
import Combine
import HealthKit

// Active MET above resting (BMR excluded). Continuous curve so sedentary HR still credits Move ring.
// metTotal = 1.0 + max(0, (pct - 0.30) * 14), capped at 11. metActive = metTotal - 1.0.
// maxHR defaults to 220 − age (age 35 if not set in Settings).
func metForHR(_ bpm: Int, maxHR: Double? = nil) -> Double {
    let resolvedMax = maxHR ?? {
        let stored = UserDefaults.standard.integer(forKey: "userAge")
        let age = stored > 0 ? max(10, min(100, stored)) : 35
        return Double(220 - age)
    }()
    let pct = Double(bpm) / resolvedMax
    let metTotal = min(11.0, 1.0 + max(0, (pct - 0.30) * 14.0))
    return max(0, metTotal - 1.0)
}

// RSA (respiratory sinus arrhythmia): autocorrelation of linearly-detrended RR series.
// Lag search 4–10 s → 6–15 breaths/min. Lags 2–3 excluded: dominated by HR inertia.
// Requires 32+ samples and a clear autocorrelation peak (prominence ≥ 20% over neighbors).
private func estimateRespiratoryRate(_ rr: [Double]) -> Double? {
    guard rr.count >= 32 else { return nil }
    let n = rr.count
    // Linear detrend to remove HR drift before autocorrelation.
    let xMean = (Double(n) - 1) / 2
    let yMean = rr.reduce(0.0, +) / Double(n)
    let sxx = (0..<n).reduce(0.0) { $0 + (Double($1) - xMean) * (Double($1) - xMean) }
    let sxy = rr.enumerated().reduce(0.0) { acc, pair in acc + (Double(pair.offset) - xMean) * (pair.element - yMean) }
    let slope = sxy / sxx
    let detrended = rr.enumerated().map { pair in pair.element - (yMean + slope * (Double(pair.offset) - xMean)) }
    // Lag 4–10 → 6–15 breaths/min.
    let maxLag = min(10, n - 4)
    guard maxLag >= 4 else { return nil }
    var corrs: [Int: Double] = [:]
    for lag in 4...maxLag {
        corrs[lag] = (0..<(n - lag)).reduce(0.0) { $0 + detrended[$1] * detrended[$1 + lag] }
    }
    guard let bestLag = corrs.max(by: { $0.value < $1.value })?.key,
          let bestCorr = corrs[bestLag], bestCorr > 0 else { return nil }
    // Prominence: best lag must be ≥ 20% stronger than each immediate neighbor.
    let prevCorr = corrs[bestLag - 1] ?? 0
    let nextCorr = corrs[bestLag + 1] ?? 0
    guard bestCorr >= prevCorr * 1.20, bestCorr >= nextCorr * 1.20 else { return nil }
    let breathsPerMin = 60.0 / Double(bestLag)
    return (breathsPerMin >= 6 && breathsPerMin <= 15) ? breathsPerMin : nil
}

private enum WUUID {
    static let service       = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
    static let cmdTo         = "61080002"
    static let cmdFrom       = "61080003"
    static let events        = "61080004"
    static let data          = "61080005"
    static let memfault      = "61080007"
    static let hrService     = "180D"   // Standard BLE Heart Rate Service
    static let hrMeasurement = "2A37"   // Heart Rate Measurement characteristic
}

@MainActor
final class BLEManager: NSObject, ObservableObject {

    enum ConnectionState: String {
        case disconnected, scanning, connecting
        case discoveringServices, discoveringCharacteristics
        case subscribing, sendingCommand, streaming

        var displayText: String {
            switch self {
            case .disconnected:               return "Disconnected"
            case .scanning:                   return "Scanning…"
            case .connecting:                 return "Connecting…"
            case .discoveringServices:        return "Finding Services…"
            case .discoveringCharacteristics: return "Finding Characteristics…"
            case .subscribing:               return "Subscribing…"
            case .sendingCommand:            return "Starting Stream…"
            case .streaming:                 return "WHOOP Connected"
            }
        }

        var isLive: Bool { self == .streaming }
        var isTransitioning: Bool { self != .disconnected && self != .streaming }
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var latestMetrics: WhoopMetrics?
    @Published var hrHistory: [WhoopMetrics] = []
    @Published var batteryLevel: Int?
    @Published var bluetoothUnavailableReason: String?
    // 15-sample (~15 s) rolling average of HR — avoids single-packet jitter in the ring display
    @Published var smoothedHR: Int = 0
    // Sticky HRV — never cleared on RR-less updates; persists until a new valid reading arrives
    @Published var lastHRV: Double?
    // 5-sample rolling average of RMSSD — smooths outliers, same pattern as smoothedHR
    @Published var smoothedHRV: Double?

    // Rolling buffer of the last 60 valid RR intervals for RMSSD (§2.2)
    private var rrBuffer: [Double] = []
    private var hrvHistory: [Double] = []
    private var lastRespRateLog: Date = .distantPast
    private var respRateBuffer: [Double] = []   // rolling last 5 RSA estimates → published median

    // Active energy accumulator — flushed to HealthKit every 3 minutes (Move ring)
    private var pendingEnergyKcal: Double = 0
    private var activityWindowStart: Date = .distantPast
    private var lastActivityFlush: Date = .distantPast
    // Tracks the most recent HR-sample timestamp so per-sample MET cost integrates the real
    // sample interval (live throttle ~30 s, batch 1 s) instead of assuming 1 Hz.
    private var lastEnergySampleAt: Date? = nil
    private let activityFlushInterval: TimeInterval = 180  // 3 minutes
    // Cap a single sample's contribution at 60 s — anything larger means strap-off / paused stream.
    private let maxEnergySampleGapSec: TimeInterval = 60
    private var stepsAtWindowStart: Int = 0
    private let minWalkingKcalPerMin: Double = 4.5
    // Seconds within the current activity window where metActive ≥ 3 (brisk-walk equivalent).
    // Flushed as Apple Exercise Time minutes alongside active energy.
    private var pendingExerciseSec: Double = 0
    private let exerciseMETThreshold: Double = 3.0

    let healthKit      = HealthKitWriter()
    lazy var workoutAggregator = WorkoutSessionAggregator(healthKit: healthKit)
    let syncManager    = SyncManager()
    let liveSleep      = LiveSleepMonitor()
    let metricsStore   = MetricsStore()
    let rawDataStore   = RawDataStore()
    let dailyMetrics   = DailyMetricsStore()
    let recomputeQueue = RecomputeQueue()
    lazy var physiologicalStore = PhysiologicalStateStore(queue: recomputeQueue)

    // Wrist-wear state from GET_HELLO_HARVARD (0x35) ACK. nil until first strap response.
    @Published var isWristOn: Bool? = nil
    // WHOOP-style HRV score: ln(RMSSD_ms) / 6.5 × 100 (0–100 scale). Updated with smoothedHRV.
    @Published var whoopHRVScore: Double? = nil

    // Most recent recovery score (0–100) from DailyMetricsStore. Sleep that ends this morning
    // is bucketed into today's UTC row (post-midnight HR samples), so the freshest score is
    // typically today's; falls back to the latest prior day with a non-nil value.
    @Published var recoveryScore: Double? = nil
    // ISO date (YYYY-MM-DD UTC) of the row backing `recoveryScore`. nil when no score yet.
    // Dashboard uses this to flag "as of <date>" when score is older than today.
    @Published var recoveryDateKey: String? = nil
    // Recovery breakdown with component scores (circadian-aware).
    @Published var recoveryBreakdown: RecoveryBreakdown? = nil
    @Published var recoveryConfidence: Double? = nil
    @Published var recoveryCircadianPenalty: Double? = nil
    @Published var recoverySleepType: SleepEpisodeType? = nil
    // Daily strain (0–21), sleep duration (minutes), and sleep need (minutes) from DailyMetricsStore.
    @Published var todayStrain: Double? = nil
    @Published var todaySleepMinutes: Int? = nil
    @Published var todaySleepNeedMinutes: Int? = nil
    // Most recent SpO2 reading (%) from HealthKit, nil if no sample in last 24h.
    @Published var latestSpO2: Double? = nil
    // RSA-derived respiratory rate (breaths/min), updated every ~10s when RR data is available.
    @Published var respiratoryRate: Double? = nil

    // Pre-computed ring values — updated by refreshRecoveryFromStore so DashboardView does pure layout.
    // sleepProgress: actual/need clamped 0–1; updated also when lastSleepSession changes.
    @Published var sleepProgress: Double = 0
    // strainTargetBand: recommended strain range based on recovery score.
    @Published var strainTargetBand: (lo: Double, hi: Double) = (10.0, 14.0)

    // HealthKit capability flags (§9.11) — refreshed after authorization.
    @Published var hkRespRateAvailable = false
    @Published var hkSpO2Available     = false
    @Published var hkAppleWatchPaired  = false

    // Live step count from CMPedometer — today's total, refreshed in real time.
    @Published var dailySteps: Int = 0
    // Most recent sleep session from SyncManager. Mirrors what SleepView shows as "Last Night".
    @Published var lastSleepSession: SleepSession? = nil
    private let pedometer = CMPedometer()
    private var cancellables = Set<AnyCancellable>()

    // nonisolated(unsafe): constant let, safe to read from any thread/Task.
    nonisolated(unsafe) private let bleQueue = DispatchQueue(label: "com.personal.WhoopBLE.ble", qos: .userInitiated)

    nonisolated(unsafe) private var central: CBCentralManager!
    nonisolated(unsafe) private var peripheral: CBPeripheral?
    nonisolated(unsafe) private var cmdToStrap:      CBCharacteristic?
    nonisolated(unsafe) private var cmdFromStrap:    CBCharacteristic?
    nonisolated(unsafe) private var eventsFromStrap: CBCharacteristic?
    nonisolated(unsafe) private var dataFromStrap:   CBCharacteristic?
    nonisolated(unsafe) private var memfault:        CBCharacteristic?
    nonisolated(unsafe) private var batteryChar:     CBCharacteristic?
    nonisolated(unsafe) private var hrChar:          CBCharacteristic?
    nonisolated(unsafe) private var enableSent = false
    nonisolated(unsafe) private var lastDecodedHR: Int = 0
    nonisolated(unsafe) private var stalenessTask: Task<Void, Never>?
    nonisolated(unsafe) private var heartbeatTask: Task<Void, Never>?
    // Fires if we reach .streaming but receive no data within 25s — strap is silent, reconnect.
    nonisolated(unsafe) private var silenceWatchdog: Task<Void, Never>?
    // Tracks whether we've performed the CCCD off→on cycle on 61080003 this session.
    // Forces strap-side notification state to re-init in case a stale CCCD from a prior
    // session is wedging the ACK channel.
    nonisolated(unsafe) private var cmdFromCccdCycled: Bool = false
    nonisolated(unsafe) private var enableTask: Task<Void, Never>?

    override init() {
        super.init()
        syncManager.bleManager = self
        syncManager.onWristState = { [weak self] worn in
            Task { @MainActor [weak self] in
                self?.isWristOn = worn
                self?.liveSleep.wristOn = worn
            }
        }
        liveSleep.onSessionEnd = { [weak self] session in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncManager.addSleepSession(session)
                await self.physiologicalStore.handle(.sleepEnded(session: session))
                await self.refreshRecoveryFromStore()
            }
        }
        syncManager.$sleepSessions
            .map { $0.sorted { $0.start > $1.start }.first }
            .assign(to: &$lastSleepSession)
        $lastSleepSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDerivedRingValues() }
            .store(in: &cancellables)
        // Configure physiological store — must happen after rawDataStore + dailyMetrics are set.
        Task { [weak self] in
            guard let self else { return }
            await self.physiologicalStore.configure(rawStore: self.rawDataStore, dailyStore: self.dailyMetrics)
            // Register hidden-state callback so each per-bio-day recompute flows into
            // PhysiologicalStateStore.updateScores → @MainActor UI.
            let store = self.physiologicalStore
            await self.recomputeQueue.configure(
                healthKit: self.healthKit,
                featureCache: store.featureCache,
                snapshotStore: store.snapshotStore,
                onScoresUpdated: { [weak self] _, capacity, atl, ctl, debtHours, stress in
                    await store.updateScores(
                        readiness: capacity * 100.0,   // capacity is 0..1; readinessCapacity field is 0..100
                        acuteFatigue: atl,
                        chronicLoad: ctl,
                        sleepDebt: debtHours,
                        autonomicStress: stress
                    )
                    await self?.refreshRecoveryFromStore()
                }
            )
            // Publish cached scores from last session immediately — before BLE connects.
            await self.publishSnapshotIfAvailable()
        }
        startPedometer()
        // RestoreIdentifierKey enables iOS to relaunch the app after killing it under memory
        // pressure — the system calls centralManager(_:willRestoreState:) on relaunch so we
        // can pick up the peripheral reference without re-scanning.
        central = CBCentralManager(delegate: self, queue: bleQueue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: "com.personal.WhoopBLE.central"
        ])
    }

    // Called by SyncManager to write commands to CMD_TO_STRAP.
    func sendSyncCommand(_ data: Data) {
        guard let p = peripheral, let char = cmdToStrap else {
            print("[SyncManager] sendSyncCommand: no peripheral/char"); return
        }
        bleQueue.async { p.writeValue(data, for: char, type: .withoutResponse) }
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        connectionState = .scanning
        let uuid = CBUUID(string: WUUID.service)
        central.scanForPeripherals(withServices: [uuid],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func reEnableIfStreaming() {
        guard connectionState == .streaming,
              let p = peripheral, let char = cmdToStrap else { return }
        bleQueue.async { p.writeValue(WhoopCRC.enableHealth, for: char, type: .withoutResponse) }
        print("📤 foreground re-enable sent")
    }

    // Restarts pedometer from today's midnight — call on foreground to reset at day boundary.
    func refreshPedometer() { startPedometer() }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.stopUpdates()
        let today = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: today, to: Date()) { @Sendable [weak self] data, _ in
            guard let n = data?.numberOfSteps.intValue else { return }
            Task { @MainActor [weak self] in
                self?.dailySteps = n
                self?.metricsStore.setTodaySteps(n)
            }
        }
        pedometer.startUpdates(from: today) { @Sendable [weak self] data, _ in
            guard let n = data?.numberOfSteps.intValue else { return }
            Task { @MainActor [weak self] in
                self?.dailySteps = n
                self?.metricsStore.setTodaySteps(n)
            }
        }
    }

    func checkVersionMismatch() async {
        // Load whatever is already persisted — shown immediately while recompute runs.
        await refreshRecoveryFromStore()

        let staleHRV      = await dailyMetrics.datesNeedingRecompute(metric: "hrv",             below: AlgoVersions.hrv)
        let staleStrain   = await dailyMetrics.datesNeedingRecompute(metric: "strain",          below: AlgoVersions.strain)
        let staleSleep    = await dailyMetrics.datesNeedingRecompute(metric: "sleep",           below: AlgoVersions.sleep)
        let staleRecovery = await dailyMetrics.datesNeedingRecompute(metric: "recovery",        below: AlgoVersions.recovery)
        let stalePhysio   = await dailyMetrics.datesNeedingRecompute(metric: "physiology",      below: AlgoVersions.physiology)
        let staleResp     = await dailyMetrics.datesNeedingRecompute(metric: "respiratoryRate", below: AlgoVersions.respiratoryRate)
        // Always include today — a missing row (no prior recompute yet) would otherwise be skipped.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let c = utcCal.dateComponents([.year, .month, .day], from: Date())
        let todayKey = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let allKeys = Set(staleHRV + staleStrain + staleSleep + staleRecovery + stalePhysio + staleResp + [todayKey])
        let dates = allKeys.compactMap { parseISODateString($0) }
        print("[BLEManager] enqueuing \(dates.count) date(s) for recompute")
        await recomputeQueue.configure(healthKit: healthKit, featureCache: physiologicalStore.featureCache, snapshotStore: physiologicalStore.snapshotStore)
        for date in dates {
            await physiologicalStore.handle(.recomputeRequested(date: date))
        }
        await refreshRecoveryFromStore()
    }

    /// Force-recompute every stored day plus the last 14 calendar days.
    /// Bypasses version-mismatch gating — use when algorithm changes haven't
    /// triggered a backfill (e.g., user re-installed mid-update or wants to
    /// force-refresh after tweaking inputs).
    func forceRecomputeAll() async {
        let stored = await dailyMetrics.loadAll().map(\.date)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let today = utcCal.startOfDay(for: Date())
        var keys = Set(stored)
        for offset in 0...14 {
            if let d = utcCal.date(byAdding: .day, value: -offset, to: today) {
                let c = utcCal.dateComponents([.year, .month, .day], from: d)
                keys.insert(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
            }
        }
        let dates = keys.compactMap { parseISODateString($0) }
        // Wipe stale rows first — bio-day key convention may have changed,
        // leaving orphan rows under old keys that no recompute will overwrite.
        await dailyMetrics.deleteAll()
        print("[BLEManager] forceRecomputeAll → \(dates.count) day(s) after wipe")
        await recomputeQueue.configure(healthKit: healthKit, featureCache: physiologicalStore.featureCache, snapshotStore: physiologicalStore.snapshotStore)
        await physiologicalStore.handle(.forceRecomputeAll)
        await refreshRecoveryFromStore()
    }

    /// Refresh HealthKit capability flags and run one-time workout migration.
    func refreshCapabilities() async {
        async let resp  = healthKit.hasRecentSamples(HKQuantityType(.respiratoryRate))
        async let spo2  = healthKit.hasRecentSamples(HKQuantityType(.oxygenSaturation))
        async let watch = healthKit.appleWatchPaired()
        hkRespRateAvailable = await resp
        hkSpO2Available     = await spo2
        hkAppleWatchPaired  = await watch
        latestSpO2 = await healthKit.readLatestSpO2()

        // One-time workout fragment migration
        let migrator = WorkoutMigrator(store: healthKit.store)
        let affectedDates = await migrator.migrateIfNeeded()
        if !affectedDates.isEmpty {
            let dates = affectedDates.compactMap { parseISODateString($0) }
            await recomputeQueue.configure(healthKit: healthKit, featureCache: physiologicalStore.featureCache, snapshotStore: physiologicalStore.snapshotStore)
            await physiologicalStore.handle(.batchSyncCompleted(dates: dates))
        }
    }

    /// Reloads published daily metrics from DailyMetricsStore: recovery, strain, sleep.
    /// Recovery: most recent non-nil (any day). Strain + sleep: today or yesterday only.
    func refreshRecoveryFromStore() async {
        let all = await dailyMetrics.loadAll()
        let sorted = all.sorted { $0.date > $1.date }

        // Recovery: fall back across days (morning lock-in may lag by a day).
        let scoreRowRaw = sorted.first(where: { $0.recoveryScore != nil })
        // Cap displayed score age at 3 days. Older than that → no current
        // recovery, show nothing rather than mislead with stale week-old value.
        var utcCalForAge = Calendar(identifier: .gregorian)
        utcCalForAge.timeZone = TimeZone(identifier: "UTC")!
        let todayStart = utcCalForAge.startOfDay(for: Date())
        let scoreRow: DailyMetricsStore.DailyMetrics?
        if let row = scoreRowRaw, let rowDate = parseISODateString(row.date) {
            let ageDays = utcCalForAge.dateComponents([.day], from: rowDate, to: todayStart).day ?? 99
            scoreRow = ageDays <= 3 ? row : nil
        } else {
            scoreRow = scoreRowRaw
        }
        let score    = scoreRow?.recoveryScore
        let scoreKey = scoreRow?.date
        let breakdown = scoreRow?.recoveryComponents
        let confidence = scoreRow?.recoveryConfidence
        let circadianPenalty = scoreRow?.circadianPenalty
        let sleepType = scoreRow?.sleepTypeCode.map { SleepEpisodeType(rawValue: $0) ?? nil } ?? nil

        // Strain + sleep: scan last 2 days of bio-day-keyed rows. Bio-day key may
        // not align with UTC calendar day (wake-date depends on local-vs-UTC offset),
        // so filtering by exact todayKey/yesterdayKey can miss the relevant row.
        // Cap at 2 days age — anything older is stale.
        var utcCalForStrain = Calendar(identifier: .gregorian)
        utcCalForStrain.timeZone = TimeZone(identifier: "UTC")!
        let todayStartStrain = utcCalForStrain.startOfDay(for: Date())
        func ageDaysStrain(_ row: DailyMetricsStore.DailyMetrics) -> Int {
            guard let d = parseISODateString(row.date) else { return 99 }
            return utcCalForStrain.dateComponents([.day], from: d, to: todayStartStrain).day ?? 99
        }
        let recent = sorted.filter { ageDaysStrain($0) <= 2 }

        let strain    = recent.first(where: { $0.strainScore      != nil })?.strainScore
        let sleepMin  = recent.first(where: { $0.sleepMinutes     != nil })?.sleepMinutes
        let sleepNeed = recent.first(where: { $0.sleepNeedMinutes != nil })?.sleepNeedMinutes

        await MainActor.run {
            self.recoveryScore             = score
            self.recoveryDateKey           = scoreKey
            self.recoveryBreakdown         = breakdown
            self.recoveryConfidence        = confidence
            self.recoveryCircadianPenalty  = circadianPenalty
            self.recoverySleepType         = sleepType
            self.todayStrain               = strain
            self.todaySleepMinutes         = sleepMin
            self.todaySleepNeedMinutes     = sleepNeed
            self.updateDerivedRingValues()
        }
    }

    // Recomputes pre-published ring values from current @Published state.
    // Called after any update to sleep/strain/recovery data.
    @MainActor func updateDerivedRingValues() {
        // Sleep progress: session minutes vs need
        let sessionMin: Int
        if let s = lastSleepSession {
            let total = Int(s.end.timeIntervalSince(s.start) / 60)
            let wake  = s.briefWakeTotalSeconds / 60
            sessionMin = max(0, total - wake)
        } else {
            sessionMin = todaySleepMinutes ?? 0
        }
        if sessionMin > 0, let need = todaySleepNeedMinutes, need > 0 {
            sleepProgress = min(Double(sessionMin) / Double(need), 1.0)
        } else {
            sleepProgress = 0
        }

        // Strain target band: recovery-gated recommended range
        if let recovery = recoveryScore {
            if recovery >= 67 { strainTargetBand = (14.0, 18.0) }
            else if recovery >= 34 { strainTargetBand = (10.0, 14.0) }
            else { strainTargetBand = (6.0, 10.0) }
        } else {
            strainTargetBand = (10.0, 14.0)
        }
    }

    // MARK: - Cold-launch snapshot publish

    /// Reads today's DailySnapshot from disk and populates published vars immediately —
    /// before BLE connects and before recompute runs. Gives instant dashboard on app open.
    private func publishSnapshotIfAvailable() async {
        let snapshot = await physiologicalStore.snapshotStore.loadToday()
        guard let snap = snapshot else { return }
        await MainActor.run {
            if recoveryScore == nil    { recoveryScore    = snap.recoveryScore }
            if todayStrain  == nil     { todayStrain      = snap.strain }
            if todaySleepMinutes == nil { todaySleepMinutes = snap.sleepMinutes }
            if todaySleepNeedMinutes == nil { todaySleepNeedMinutes = snap.sleepNeedMinutes }
        }
        print("[BLEManager] cold-launch snapshot loaded for \(snap.dateKey) — recovery=\(snap.recoveryScore.map { String(format: "%.0f", $0) } ?? "nil")")
    }

    // MARK: - Re-detect sleep from stored HR
    //
    // Re-runs SleepDetector over already-stored HR samples for the last N days. Used when
    // the algorithm has been updated but the strap-side batch cursor has already advanced
    // past the relevant data, so re-syncing won't deliver the same batches again. Detected
    // sessions are deduped against existing `syncManager.sleepSessions` and merged into
    // the same UI-backed list + HealthKit + DailyMetrics recompute queue.
    func redetectSleepFromStoredHR(daysBack: Int = 2) async -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: Date())
        var newSessions: [SleepSession] = []
        var affectedDates: [Date] = []

        // Purge stale sessions in the redetect window FIRST so dedupe doesn't shadow new
        // detections produced by the updated algorithm. Cutoff = start of (today - daysBack).
        let purgeFrom = cal.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let removed = syncManager.removeSleepSessions(after: purgeFrom)
        healthKit.deleteSleepSamples(after: purgeFrom)
        print("[Redetect] purge cutoff=\(purgeFrom) — removed \(removed) stored session(s)")

        for offset in 0...daysBack {
            guard let dayStart = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let nextDay    = cal.date(byAdding: .day,  value:  1, to: dayStart) ?? dayStart
            let prevDay    = cal.date(byAdding: .day,  value: -1, to: dayStart) ?? dayStart
            // Wider window: [prevDay 12:00, nextDay 12:00] catches post-midnight + morning sleep
            let nightStart = cal.date(byAdding: .hour, value: 12, to: prevDay) ?? prevDay
            let nightEnd   = cal.date(byAdding: .hour, value: 12, to: nextDay) ?? nextDay

            await rawDataStore.flush()
            let hrToday = await rawDataStore.loadHR(for: dayStart)
            let hrPrev  = await rawDataStore.loadHR(for: prevDay)

            let nightHR = (hrPrev + hrToday).filter {
                let t = Date(timeIntervalSince1970: Double($0.timestamp))
                return t >= nightStart && t < nightEnd
            }.sorted { $0.timestamp < $1.timestamp }

            guard nightHR.count >= 30 else { continue }

            let historical = nightHR.map {
                HistoricalSample(
                    timestamp: Date(timeIntervalSince1970: Double($0.timestamp)),
                    heartRate: $0.bpm,
                    accelerometer: nil
                )
            }
            let raw = SleepDetector().process(historical)

            let detected = raw
                .filter { $0.end <= nextDay }
                .filter { $0.end.timeIntervalSince($0.start) >= 1800 }
                .filter { $0.end.timeIntervalSince($0.start) <= 14 * 3600 }
                // Filter afternoon couch sessions that SleepDetector may misclassify as sleep
                .filter { s in
                    let mid = s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2)
                    let midHour = Calendar.current.component(.hour, from: mid)
                    return !(midHour >= 13 && midHour < 18 && s.end.timeIntervalSince(s.start) < 10800)
                }

            for s in detected {
                let dup = syncManager.sleepSessions.contains {
                    abs($0.start.timeIntervalSince(s.start)) < 3600
                }
                let alreadyQueued = newSessions.contains {
                    abs($0.start.timeIntervalSince(s.start)) < 3600
                }
                if !dup && !alreadyQueued {
                    newSessions.append(s)
                    affectedDates.append(dayStart)
                }
            }
        }

        guard !newSessions.isEmpty else { return 0 }

        for s in newSessions { syncManager.addSleepSession(s) }
        healthKit.writeSleep(newSessions)

        // Trigger recompute of affected days so DailyMetrics rows pick up new sleepMinutes.
        let uniqueDates = Array(Set(affectedDates))
        await recomputeQueue.configure(healthKit: healthKit, featureCache: physiologicalStore.featureCache, snapshotStore: physiologicalStore.snapshotStore)
        await physiologicalStore.handle(.batchSyncCompleted(dates: uniqueDates))
        await refreshRecoveryFromStore()
        print("[Redetect] added \(newSessions.count) session(s), recompute queued for \(uniqueDates.count) date(s)")
        return newSessions.count
    }

    private func parseISODateString(_ str: String) -> Date? {
        let parts = str.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        return cal.date(from: dc)
    }

    func disconnect() {
        guard let c = central else { return }
        let p = peripheral
        let char = cmdToStrap
        bleQueue.async {
            if let p, let char { p.writeValue(WhoopCRC.disableHealth, for: char, type: .withoutResponse) }
            if let p { c.cancelPeripheralConnection(p) }
        }
    }

    nonisolated private func clearPeripheralState() {
        peripheral = nil
        cmdToStrap = nil; cmdFromStrap = nil
        eventsFromStrap = nil; dataFromStrap = nil
        memfault = nil; batteryChar = nil; hrChar = nil
        enableSent = false
        lastDecodedHR = 0
        stalenessTask?.cancel(); stalenessTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        silenceWatchdog?.cancel(); silenceWatchdog = nil
        enableTask?.cancel(); enableTask = nil
        cmdFromCccdCycled = false
    }

    // MARK: - Activity ring accumulation

    private static let defaultWeightKg: Double = 78

    // Configurable user weight backing AppStorage("userWeightKg"). Read each sample so live updates take effect.
    private var userWeightKg: Double {
        let v = UserDefaults.standard.double(forKey: "userWeightKg")
        return v > 0 ? v : BLEManager.defaultWeightKg
    }

    private func accumulateActivity(_ metrics: WhoopMetrics) {
        // Initialize window start on first sample after connection/flush
        if activityWindowStart == .distantPast {
            activityWindowStart = metrics.timestamp
            lastActivityFlush   = metrics.timestamp
            stepsAtWindowStart  = dailySteps
            lastEnergySampleAt  = metrics.timestamp
        }

        // Real interval since previous sample (capped). First sample after init contributes
        // 0 because lastEnergySampleAt was just set. Live-stream throttle of 30 s now
        // correctly attributes 30 s/sample instead of 1 s — fixes prior ~30× undercount.
        let prev = lastEnergySampleAt ?? metrics.timestamp
        let gapSec = max(0, min(maxEnergySampleGapSec, metrics.timestamp.timeIntervalSince(prev)))
        lastEnergySampleAt = metrics.timestamp
        let durationHours = gapSec / 3600.0
        let met = metForHR(metrics.heartRate)
        let kcalDelta = met * userWeightKg * durationHours
        pendingEnergyKcal += kcalDelta
        if met >= exerciseMETThreshold { pendingExerciseSec += gapSec }

        // Feed session aggregator. Aggregator owns the workout emit; this method only owns Move-ring standalone writes.
        workoutAggregator.observe(timestamp: metrics.timestamp, hr: metrics.heartRate, met: met, kcalDelta: kcalDelta)

        // Flush every 3 minutes
        let elapsed = metrics.timestamp.timeIntervalSince(lastActivityFlush)
        guard elapsed >= activityFlushInterval else { return }

        let windowEnd = metrics.timestamp
        let windowStart = activityWindowStart
        let windowDurationMin = elapsed / 60.0
        var kcal = pendingEnergyKcal

        // Walking floor: if steps increased during window, ensure minimum burn
        let currentSteps = dailySteps
        if currentSteps > stepsAtWindowStart {
            kcal = max(kcal, minWalkingKcalPerMin * windowDurationMin)
        }
        stepsAtWindowStart = currentSteps

        let exerciseSec = pendingExerciseSec
        pendingEnergyKcal = 0
        pendingExerciseSec = 0
        activityWindowStart = windowEnd
        lastActivityFlush = windowEnd

        _ = exerciseSec  // exercise-minute credit now comes from HKWorkout (aggregator emits one per session)

        guard kcal > 0, kcal < 100 else { return }
        // While a workout session is active the aggregator owns energy → skip standalone write
        // to avoid double-counting against Move ring.
        if workoutAggregator.isSessionActive {
            print("[HK] Energy skipped: session active (\(String(format: "%.1f", kcal)) kcal absorbed by workout)")
            return
        }
        // Only suppress when Watch already wrote energy covering THIS write window — true
        // double-count case. Prior 5-min "recently active" check always fired when Watch was
        // paired (Watch logs energy every minute idle), permanently stalling the Move ring.
        Task { [healthKit, kcal, windowStart, windowEnd] in
            let watchCovers = await healthKit.watchEnergyOverlapping(start: windowStart, end: windowEnd)
            if watchCovers {
                print("[HK] Energy suppressed: watch already covered window (\(String(format: "%.1f", kcal)) kcal skipped)")
                return
            }
            await MainActor.run {
                healthKit.writeActiveEnergy(kcal: kcal, start: windowStart, end: windowEnd)
                print("[HK] Energy: \(String(format: "%.1f", kcal)) kcal (\(windowStart) → \(windowEnd))")
            }
        }
    }

    // MARK: - Shared helper: update published metrics from any HR source.
    nonisolated private func acceptMetrics(_ metrics: WhoopMetrics) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestMetrics = metrics
            self.hrHistory.append(metrics)
            if self.hrHistory.count > 60 { self.hrHistory.removeFirst() }

            // 15-sample smoothed HR (~15 s window at 1 Hz). Skip publish if unchanged.
            let window = self.hrHistory.suffix(15)
            let newSmoothed = window.map(\.heartRate).reduce(0, +) / window.count
            if newSmoothed != self.smoothedHR { self.smoothedHR = newSmoothed }

            // Rolling RR buffer — append valid intervals, cap at 60 values (~1 min)
            for rr in metrics.rrIntervals where rr >= 0.3 && rr <= 2.0 {
                self.rrBuffer.append(rr)
            }
            if self.rrBuffer.count > 60 { self.rrBuffer.removeFirst(self.rrBuffer.count - 60) }

            // Recompute RMSSD via SignalProcessor (never clears lastHRV on empty-RR updates)
            var freshHRV: Double? = nil
            if self.rrBuffer.count >= 4 {
                let metric = SignalProcessor().computeRMSSD(self.rrBuffer.map { $0 * 1000 })
                if let rmssd = metric.value {
                    freshHRV = rmssd
                    self.lastHRV = rmssd
                    self.hrvHistory.append(rmssd)
                    if self.hrvHistory.count > 5 { self.hrvHistory.removeFirst() }
                    self.smoothedHRV = self.hrvHistory.reduce(0, +) / Double(self.hrvHistory.count)
                    // WHOOP-style normalized score: ln(RMSSD_ms) / 6.5 × 100
                    self.whoopHRVScore = min(100, max(0, log(rmssd) / 6.5 * 100))
                    // Notify physiological store — enables dirty-flag invalidation without blocking UI
                    let ts = metrics.timestamp
                    Task { [weak self] in
                        guard let self else { return }
                        await self.physiologicalStore.handle(.hrvUpdated(rmssd: rmssd, timestamp: ts))
                    }
                }
            }

            // Respiratory rate (RSA autocorrelation, updated every 10s)
            let rrCount = self.rrBuffer.count
            if rrCount >= 32, Date().timeIntervalSince(self.lastRespRateLog) >= 10 {
                self.lastRespRateLog = Date()
                if let resp = estimateRespiratoryRate(self.rrBuffer) {
                    // Median-of-5 smoothing. RSA autocorr bestLag flips between 5 and 8
                    // across runs even on a steady wearer; single-sample publish exposed
                    // that noise (logged 12, UI showed 7). 5-tick window ≈ 50 s.
                    self.respRateBuffer.append(resp)
                    if self.respRateBuffer.count > 5 { self.respRateBuffer.removeFirst() }
                    let sorted = self.respRateBuffer.sorted()
                    let median = sorted[sorted.count / 2]
                    self.respiratoryRate = median
                    print("[RespRate] inst=\(String(format: "%.1f", resp)) median=\(String(format: "%.1f", median)) (rrBuf=\(rrCount), n=\(sorted.count))")
                }
            }

            self.metricsStore.record(timestamp: metrics.timestamp,
                                     heartRate: metrics.heartRate,
                                     hrv: freshHRV)

            self.healthKit.write(metrics)
            self.accumulateActivity(metrics)
            self.liveSleep.observe(metrics)

            // Feed raw stores for recompute pipeline
            let ts = Int(metrics.timestamp.timeIntervalSince1970)
            await self.rawDataStore.appendHR(timestamp: ts, bpm: metrics.heartRate)
            for rr in metrics.rrIntervals {
                let ms = Int(rr * 1000)
                await self.rawDataStore.appendRR(timestamp: ts, intervalMs: ms)
            }
            self.silenceWatchdog?.cancel()
            self.silenceWatchdog = nil
            self.stalenessTask?.cancel()
            self.stalenessTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
                    await MainActor.run {
                        self?.latestMetrics = nil
                        self?.smoothedHR = 0
                        // lastHRV intentionally kept — shows last known value dimmed when stale
                    }
                } catch {}
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {

    // Called when iOS relaunches the app after killing it under memory pressure.
    // `peripheral` is already set by willRestoreState before poweredOn fires.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            peripheral = p
            p.delegate = self
            print("♻️ state restored: \(p.name ?? "unknown") state=\(p.state.rawValue)")
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let restoredPeripheral = peripheral   // capture before Task hop
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .poweredOn:
                bluetoothUnavailableReason = nil
                // If iOS restored a peripheral, reconnect directly — no need to scan.
                if let p = restoredPeripheral {
                    self.central.connect(p, options: [
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                    print("♻️ reconnecting to restored peripheral")
                } else {
                    startScanning()
                }
            case .poweredOff:
                bluetoothUnavailableReason = "Bluetooth is off — enable it in Settings."
                connectionState = .disconnected
            case .unauthorized:
                bluetoothUnavailableReason = "Bluetooth access denied — check Settings > Privacy."
                connectionState = .disconnected
            default:
                bluetoothUnavailableReason = "Bluetooth unavailable (code \(state.rawValue))."
                connectionState = .disconnected
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        guard peripheral.name?.uppercased().contains("WHOOP") == true else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        Task { @MainActor [weak self] in self?.connectionState = .connecting }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([
            CBUUID(string: WUUID.service),
            CBUUID(string: "180F"),
            CBUUID(string: WUUID.hrService)
        ])
        Task { @MainActor [weak self] in self?.connectionState = .discoveringServices }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        clearPeripheralState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            latestMetrics = nil
            hrHistory = []
            smoothedHR = 0
            rrBuffer = []
            hrvHistory = []
            smoothedHRV = nil
            batteryLevel = nil
            connectionState = .disconnected
            // Close any open workout session first (emits ONE workout if duration ≥ 60s).
            workoutAggregator.flush(now: Date())
            // Flush pending kcal before clearing — don't discard partial window
            if pendingEnergyKcal > 0, activityWindowStart != .distantPast, !workoutAggregator.isSessionActive {
                let now = Date()
                let kcal = min(pendingEnergyKcal, 99)
                if kcal > 0 {
                    healthKit.writeActiveEnergy(kcal: kcal, start: activityWindowStart, end: now)
                    print("[HK] Energy (disconnect flush): \(String(format: "%.1f", kcal)) kcal")
                }
            }
            pendingEnergyKcal = 0
            activityWindowStart = .distantPast
            lastActivityFlush = .distantPast
            lastEnergySampleAt = nil
            stepsAtWindowStart = 0
            startScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        clearPeripheralState()
        Task { @MainActor [weak self] in self?.connectionState = .disconnected }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("❌ discoverServices error: \(error?.localizedDescription ?? "nil services")")
            return
        }
        for service in services {
            if service.uuid == CBUUID(string: WUUID.service) {
                peripheral.discoverCharacteristics(nil, for: service)
            } else if service.uuid == CBUUID(string: "180F") {
                peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: service)
            } else if service.uuid == CBUUID(string: WUUID.hrService) {
                peripheral.discoverCharacteristics([CBUUID(string: WUUID.hrMeasurement)], for: service)
            }
        }
        Task { @MainActor [weak self] in self?.connectionState = .discoveringCharacteristics }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            print("❌ discoverCharacteristics error: \(error?.localizedDescription ?? "nil chars")")
            return
        }

        // Standard BLE Heart Rate Service (0x180D)
        if service.uuid == CBUUID(string: WUUID.hrService) {
            for char in chars where char.uuid == CBUUID(string: WUUID.hrMeasurement) {
                hrChar = char
                peripheral.setNotifyValue(true, for: char)
                print("❤️ standard HR characteristic found")
            }
            return
        }

        // Battery service
        if service.uuid == CBUUID(string: "180F") {
            for char in chars where char.uuid == CBUUID(string: "2A19") {
                batteryChar = char
                peripheral.readValue(for: char)
                peripheral.setNotifyValue(true, for: char)
                print("🔋 battery characteristic found")
            }
            return
        }

        // WHOOP main service
        for char in chars {
            let uuid = char.uuid.uuidString.lowercased()
            if uuid.hasPrefix(WUUID.cmdTo) {
                self.cmdToStrap = char
            } else if uuid.hasPrefix(WUUID.cmdFrom) {
                self.cmdFromStrap = char
                peripheral.setNotifyValue(true, for: char)
            } else if uuid.hasPrefix(WUUID.events) {
                self.eventsFromStrap = char
                peripheral.setNotifyValue(true, for: char)
            } else if uuid.hasPrefix(WUUID.data) {
                self.dataFromStrap = char
                peripheral.setNotifyValue(true, for: char)
            } else if uuid.hasPrefix(WUUID.memfault) {
                self.memfault = char
                peripheral.setNotifyValue(true, for: char)
            } else {
                // Unknown characteristic — log for RE analysis (may carry SpO2, skin temp, etc.)
                let props = char.properties
                var propStr: [String] = []
                if props.contains(.notify) { propStr.append("notify") }
                if props.contains(.read)   { propStr.append("read") }
                if props.contains(.write)  { propStr.append("write") }
                print("[CharScan] unknown char: \(uuid) props=[\(propStr.joined(separator: ","))]")
                if props.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
                else if props.contains(.read) { peripheral.readValue(for: char) }
            }
        }
        print("✅ characteristics found — cmdTo:\(cmdToStrap != nil) events:\(eventsFromStrap != nil) data:\(dataFromStrap != nil)")
        Task { @MainActor [weak self] in self?.connectionState = .subscribing }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid.uuidString.lowercased()
        if let error {
            print("❌ notify error for \(uuid.prefix(8)): \(error.localizedDescription)")
            return
        }
        print("🔔 notify \(characteristic.isNotifying ? "ON" : "OFF") for \(uuid.prefix(8))")

        // Gate enable sequence on CMD_FROM_STRAP (61080003) being live, not EVENTS.
        // Writes to 61080002 before the ACK channel's CCCD has settled on the strap side
        // can leave the strap unable to route 0xfc replies — observed as silent ACK channel
        // post-fuzzing. EVENTS notifying tells us nothing about whether the strap is
        // ready to deliver command responses.
        guard uuid.hasPrefix(WUUID.cmdFrom), self.cmdToStrap != nil else { return }

        // CCCD off→on cycle on 61080003. First isNotifying=true → write 0x0000.
        // Resulting isNotifying=false → 500 ms delay → re-write 0x0100. Second
        // isNotifying=true → drop into the enable burst. Forces strap-side ACK channel
        // re-init when a stale CCCD from a prior session is suspected.
        if characteristic.isNotifying && !cmdFromCccdCycled {
            cmdFromCccdCycled = true
            print("🔁 CCCD cycle on 61080003 — disabling")
            peripheral.setNotifyValue(false, for: characteristic)
            return
        }
        if !characteristic.isNotifying && cmdFromCccdCycled && !enableSent {
            print("🔁 CCCD cycle on 61080003 — re-enabling in 500ms")
            Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, let p = self.peripheral, let c = self.cmdFromStrap else { return }
                p.setNotifyValue(true, for: c)
            }
            return
        }
        guard characteristic.isNotifying, cmdFromCccdCycled, !enableSent else { return }
        enableSent = true

        // Sequenced enable burst:
        //   t=0       (after 500ms settle): enableHealth (withResponse — forces ATT ack)
        //   t=+250ms : enableHRBroadcast
        //   t=+500ms : getHelloHarvard
        //   t=+5s    : (0x03,0x02) + IMU historical + syncManager.onConnected()
        // 250ms inter-cmd spacing avoids overrunning the strap parser.
        enableTask?.cancel()
        enableTask = Task { [weak self] in
            // Each step verifies (a) the Task wasn't cancelled (e.g. by disconnect →
            // clearPeripheralState) and (b) the peripheral is still connected. Without
            // these guards CBPeripheral logs "API MISUSE" when a write fires post-disconnect.
            func stillLive(_ s: BLEManager) -> (CBPeripheral, CBCharacteristic)? {
                guard !Task.isCancelled,
                      let p = s.peripheral,
                      let c = s.cmdToStrap,
                      p.state == .connected else { return nil }
                return (p, c)
            }

            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, let (p0, c0) = stillLive(self) else { return }
            self.bleQueue.async { p0.writeValue(WhoopCRC.enableHealth, for: c0, type: .withResponse) }
            print("📤 enableHealth sent (withResponse)")

            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let (p1, c1) = stillLive(self) else { return }
            self.bleQueue.async { p1.writeValue(WhoopCRC.enableHRBroadcast, for: c1, type: .withoutResponse) }
            print("📤 enableHRBroadcast sent")

            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let (p2, c2) = stillLive(self) else { return }
            self.bleQueue.async { p2.writeValue(WhoopCRC.getHelloHarvard, for: c2, type: .withoutResponse) }
            print("📤 getHelloHarvard sent")

            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard let (p3, c3) = stillLive(self) else { return }
            self.bleQueue.async { p3.writeValue(WhoopCRC.buildCommand(category: 0x03, value: 0x02), for: c3, type: .withoutResponse) }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let (p4, c4) = stillLive(self) else { return }
            self.bleQueue.async { p4.writeValue(WhoopCRC.toggleIMUHistorical, for: c4, type: .withoutResponse) }
            print("▶️ (0x03,0x02) + IMU historical enable sent")
            await MainActor.run { self.syncManager.onConnected() }
        }

        // Heartbeat every 10s.
        heartbeatTask = Task { [weak self] in
            var beatCount = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
                self.bleQueue.async { p.writeValue(WhoopCRC.keepaliveHealth, for: c, type: .withoutResponse) }
                beatCount += 1
                // Re-read battery every 60 s (every 6th heartbeat)
                if beatCount % 6 == 0, let bat = self.batteryChar {
                    self.bleQueue.async { p.readValue(for: bat) }
                }
            }
        }

        Task { @MainActor [weak self] in self?.connectionState = .streaming }

        silenceWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self else { return }
            let hasData = await MainActor.run { self.latestMetrics != nil }
            guard !hasData else { return }
            print("🔇 silence watchdog: no data in 25s — reconnecting")
            await MainActor.run { self.disconnect() }
        }
    }

    // .withResponse writes (currently just enableHealth) report success/failure here.
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            print("❌ write failed for \(characteristic.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        let uuidShort = String(characteristic.uuid.uuidString.prefix(8)).lowercased()

        // Battery level (standard BLE 0x2A19).
        // CoreBluetooth returns short 16-bit UUIDs as "2A19", not the full 128-bit form.
        if uuidShort.hasPrefix("2a19") {
            if let val = data.first {
                Task { @MainActor [weak self] in self?.batteryLevel = Int(val) }
            }
            return
        }

        // Standard BLE Heart Rate Measurement (0x2A37).
        // Format: byte[0]=flags, byte[1](or [1-2])=HR, optional RR intervals in 1/1024 s units.
        // This path is preferred when 0x180D service is present; EVENTS stream is the fallback.
        if uuidShort.hasPrefix("2a37") {
            guard data.count >= 2 else { return }
            let bytes = [UInt8](data)
            let flags = bytes[0]
            let hrIsUInt16 = (flags & 0x01) != 0
            let hasRR      = (flags & 0x10) != 0
            let hr: Int
            let rrStart: Int
            if hrIsUInt16 {
                guard data.count >= 3 else { return }
                hr = Int(bytes[1]) | (Int(bytes[2]) << 8)
                rrStart = 3
            } else {
                hr = Int(bytes[1])
                rrStart = 2
            }
            guard hr >= 30, hr <= 220 else { return }
            var rrIntervals: [Double] = []
            if hasRR {
                var offset = rrStart
                while offset + 1 < bytes.count {
                    let raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    offset += 2
                    let ms = Double(raw) * 1000.0 / 1024.0
                    if ms >= 300, ms <= 2000 { rrIntervals.append(ms / 1000.0) }
                }
            }
            if lastDecodedHR > 0, abs(hr - lastDecodedHR) > 25 {
                #if DEBUG
                print("⚠️ std HR jump \(lastDecodedHR)→\(hr) rejected")
                #endif
                return
            }
            lastDecodedHR = hr
            acceptMetrics(WhoopMetrics(timestamp: Date(), heartRate: hr, rrIntervals: rrIntervals))
            return
        }

        if uuidShort.hasPrefix(WUUID.cmdFrom) {
            let bytes = [UInt8](data)
            Task { @MainActor [weak self] in self?.syncManager.handleDataPacket(bytes) }
            return
        }

        // DATA_FROM_STRAP (0x61080005) → SyncManager for historical batch protocol
        if uuidShort.hasPrefix(WUUID.data) {
            let bytes = [UInt8](data)
            Task { @MainActor [weak self] in self?.syncManager.handleDataPacket(bytes) }
            return
        }

        // Log unknown characteristic data for RE analysis (SpO2, skin temp candidates)
        let isKnownUUID = uuidShort.hasPrefix("2a19") || uuidShort.hasPrefix("2a37")
            || uuidShort.hasPrefix(WUUID.cmdFrom) || uuidShort.hasPrefix(WUUID.data)
            || uuidShort.hasPrefix(WUUID.events) || uuidShort.hasPrefix(WUUID.memfault)
        if !isKnownUUID {
            let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[CharScan] data from \(uuidShort.prefix(8)): \(hex) (\(data.count)B)")
            return
        }

        guard uuidShort.hasPrefix(WUUID.events) else { return }

        if let metrics = PacketDecoder.decode(data) {
            // Reject readings that jump more than 25 BPM from the last accepted value.
            let hr = metrics.heartRate
            if lastDecodedHR > 0, abs(hr - lastDecodedHR) > 25 {
                #if DEBUG
                print("⚠️ HR jump \(lastDecodedHR)→\(hr) rejected")
                #endif
                return
            }
            lastDecodedHR = hr
            acceptMetrics(metrics)
        } else {
            // HR (byte[10]) is out of range on most 0x57 packets (~228), but RR intervals
            // at bytes[11+] are independent and can still feed RMSSD.
            // Extract RR from any 0x57/0xab/0x52 packet that was rejected for bad HR.
            let bytes = [UInt8](data)
            guard bytes.count >= 12,
                  bytes[0] == 0xaa,
                  (bytes[3] == 0x57 || bytes[3] == 0xab || bytes[3] == 0x52),
                  lastDecodedHR > 0 else {
                #if DEBUG
                print("⚠️ rejected (count=\(data.count) byte3=\(data.count > 3 ? String(format: "%02x", data[3]) : "?"))")
                #endif
                return
            }
            let rrCount = min(Int(bytes[11]), 4)
            var rrs: [Double] = []
            for i in 0..<rrCount {
                let base = 12 + i * 2
                guard base + 1 < bytes.count else { break }
                let raw = UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
                if raw >= 300, raw <= 2000 { rrs.append(Double(raw) / 1000.0) }
            }
            guard !rrs.isEmpty else { return }
            // Use last known HR so the RR data lands in acceptMetrics with a valid heartRate.
            acceptMetrics(WhoopMetrics(timestamp: Date(), heartRate: lastDecodedHR, rrIntervals: rrs))
            #if DEBUG
            print("💓 RR-only from 0x\(String(format: "%02x", bytes[3])): \(rrs.map { Int($0 * 1000) })")
            #endif
        }
    }
}
