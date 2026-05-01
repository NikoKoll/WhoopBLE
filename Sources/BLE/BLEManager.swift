import CoreBluetooth
import CoreMotion
import Combine

// Active MET above resting (BMR excluded). Continuous curve so sedentary HR still credits Move ring.
// metTotal = 1.0 + max(0, (pct - 0.30) * 14), capped at 11. metActive = metTotal - 1.0.
// At HR 70 (pct ~0.36) → metActive ~0.84; at HR 110 (pct ~0.56) → ~3.6; at HR 170 (pct ~0.87) → ~8.0.
func metForHR(_ bpm: Int, maxHR: Double = 196) -> Double {
    let pct = Double(bpm) / maxHR
    let metTotal = min(11.0, 1.0 + max(0, (pct - 0.30) * 14.0))
    return max(0, metTotal - 1.0)
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

    // Active energy accumulator — flushed to HealthKit every 3 minutes (Move ring)
    private var pendingEnergyKcal: Double = 0
    private var activityWindowStart: Date = .distantPast
    private var lastActivityFlush: Date = .distantPast
    private let activityFlushInterval: TimeInterval = 180  // 3 minutes
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

    // Live step count from CMPedometer — today's total, refreshed in real time.
    @Published var dailySteps: Int = 0
    private let pedometer = CMPedometer()

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

    override init() {
        super.init()
        syncManager.bleManager = self
        liveSleep.onSessionEnd = { [weak self] session in
            Task { @MainActor [weak self] in self?.syncManager.addSleepSession(session) }
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
        let staleHRV    = await dailyMetrics.datesNeedingRecompute(metric: "hrv",    below: AlgoVersions.hrv)
        let staleStrain = await dailyMetrics.datesNeedingRecompute(metric: "strain", below: AlgoVersions.strain)
        let staleSleep  = await dailyMetrics.datesNeedingRecompute(metric: "sleep",  below: AlgoVersions.sleep)
        let allKeys = Set(staleHRV + staleStrain + staleSleep)
        guard !allKeys.isEmpty else { return }
        let dates = allKeys.compactMap { parseISODateString($0) }
        await recomputeQueue.enqueue(dates: dates, rawStore: rawDataStore, dailyStore: dailyMetrics)
        print("[BLEManager] version mismatch: enqueued \(dates.count) date(s) for recompute")
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
        }

        let durationHours = 1.0 / 3600.0  // assume ~1 sample/sec
        let met = metForHR(metrics.heartRate)
        let kcalDelta = met * userWeightKg * durationHours
        pendingEnergyKcal += kcalDelta
        if met >= exerciseMETThreshold { pendingExerciseSec += 1.0 }

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
        // Suppress live write if Apple Watch wrote activeEnergyBurned in the last 5 min — Watch dominates Move ring.
        Task { [healthKit, kcal, windowStart, windowEnd] in
            let watchActive = await healthKit.watchEnergyActiveRecently()
            if watchActive {
                print("[HK] Energy suppressed: watch active (\(String(format: "%.1f", kcal)) kcal skipped)")
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

            // 15-sample smoothed HR (~15 s window at 1 Hz)
            let window = self.hrHistory.suffix(15)
            self.smoothedHR = window.map(\.heartRate).reduce(0, +) / window.count

            // Rolling RR buffer — append valid intervals, cap at 60 values (~1 min)
            for rr in metrics.rrIntervals where rr >= 0.3 && rr <= 2.0 {
                self.rrBuffer.append(rr)
            }
            if self.rrBuffer.count > 60 { self.rrBuffer.removeFirst(self.rrBuffer.count - 60) }

            // Recompute RMSSD from rolling buffer if we have enough (never clears lastHRV on empty-RR updates)
            var freshHRV: Double? = nil
            if self.rrBuffer.count >= 4 {
                let diffs = zip(self.rrBuffer, self.rrBuffer.dropFirst()).map { a, b -> Double in
                    let d = (b - a) * 1000; return d * d
                }
                let rmssd = sqrt(diffs.reduce(0, +) / Double(diffs.count))
                freshHRV = rmssd
                self.lastHRV = rmssd
                self.hrvHistory.append(rmssd)
                if self.hrvHistory.count > 5 { self.hrvHistory.removeFirst() }
                self.smoothedHRV = self.hrvHistory.reduce(0, +) / Double(self.hrvHistory.count)
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

        // Trigger on EVENTS (61080004) — original working sequence.
        guard uuid.hasPrefix(WUUID.events),
              characteristic.isNotifying,
              !enableSent,
              let char = self.cmdToStrap else { return }
        enableSent = true
        peripheral.writeValue(WhoopCRC.enableHealth, for: char, type: .withoutResponse)
        // Request HR broadcast on standard BLE HR service (0x180D / 0x2A37).
        peripheral.writeValue(WhoopCRC.enableHRBroadcast, for: char, type: .withoutResponse)
        print("📤 enableHealth + enableHRBroadcast sent")

        // Send (0x03, 0x02) at 5s. In every working session this was present alongside
        // enableHealth; removing it caused total silence from the strap.
        // Also trigger historical sync at the same point once the strap is settled.
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
            self.bleQueue.async { p.writeValue(WhoopCRC.buildCommand(category: 0x03, value: 0x02), for: c, type: .withoutResponse) }
            print("▶️ (0x03,0x02) sent")
            await MainActor.run { self.syncManager.onConnected() }
        }

        // Heartbeat every 10s.
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, let p = self.peripheral, let c = self.cmdToStrap else { return }
                self.bleQueue.async { p.writeValue(WhoopCRC.enableHealth, for: c, type: .withoutResponse) }
                print("💓 heartbeat sent")
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

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        let uuidShort = String(characteristic.uuid.uuidString.prefix(8)).lowercased()

        // Battery level (standard BLE 0x2A19).
        // CoreBluetooth returns short 16-bit UUIDs as "2A19", not the full 128-bit form.
        if uuidShort.hasPrefix("2a19") {
            if let val = data.first {
                print("🔋 battery: \(val)%")
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
                print("⚠️ std HR jump \(lastDecodedHR)→\(hr) rejected"); return
            }
            lastDecodedHR = hr
            print("❤️‍🔥 std HR: \(hr) BPM")
            acceptMetrics(WhoopMetrics(timestamp: Date(), heartRate: hr, rrIntervals: rrIntervals))
            return
        }

        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("📡 [\(uuidShort)] \(data.count) bytes: \(hex)")

        if uuidShort.hasPrefix(WUUID.cmdFrom) {
            print("📨 CMD_FROM_STRAP: \(hex)")
            // Also route through SyncManager — batch acks may arrive here, not on DATA_FROM_STRAP
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

        guard uuidShort.hasPrefix(WUUID.events) else { return }

        if let metrics = PacketDecoder.decode(data) {
            // Reject readings that jump more than 25 BPM from the last accepted value.
            let hr = metrics.heartRate
            if lastDecodedHR > 0, abs(hr - lastDecodedHR) > 25 {
                print("⚠️ HR jump \(lastDecodedHR)→\(hr) rejected")
                return
            }
            lastDecodedHR = hr
            acceptMetrics(metrics)
        } else {
            print("⚠️ rejected (count=\(data.count) byte3=\(data.count > 3 ? String(format: "%02x", data[3]) : "?"))")
        }
    }
}
