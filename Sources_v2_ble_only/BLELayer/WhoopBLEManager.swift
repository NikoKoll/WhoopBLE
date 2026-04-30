import CoreBluetooth
import Combine
import Foundation

// MARK: - Public types

struct BLERawEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let characteristicName: String
    let bytes: [UInt8]

    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connected(deviceName: String)

    var displayText: String {
        switch self {
        case .disconnected:              return "Disconnected"
        case .scanning:                  return "Scanning…"
        case .connected(let name):       return "Connected — \(name)"
        }
    }
}

// MARK: - UUID constants

private enum WUUID {
    static var service:   CBUUID { CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6") }
    static var hrService: CBUUID { CBUUID(string: "180D") }

    // 8-char lowercase prefixes used for hasPrefix matching
    static let cmdTo    = "61080002"
    static let cmdFrom  = "61080003"
    static let events   = "61080004"
    static let data     = "61080005"
    static let standardHR = "00002a37"

    static func name(for uuid: CBUUID) -> String {
        let s = uuid.uuidString.lowercased()
        if s.hasPrefix(cmdTo)     { return "CMD_TO_STRAP" }
        if s.hasPrefix(cmdFrom)   { return "CMD_FROM_STRAP" }
        if s.hasPrefix(events)    { return "EVENTS_FROM_STRAP" }
        if s.hasPrefix(data)      { return "DATA_FROM_STRAP" }
        if s.hasPrefix(standardHR){ return "STANDARD_HR" }
        return s
    }
}

// MARK: - Manager

@MainActor
final class WhoopBLEManager: NSObject, ObservableObject {

    @Published private(set) var connectionState: BLEConnectionState = .disconnected
    @Published private(set) var rawEventLog: [BLERawEvent] = []

    // ParserLayer subscribes to this publisher (Section 10.4 boundary)
    let rawNotificationPublisher = PassthroughSubject<BLERawEvent, Never>()

    // nonisolated(unsafe): written only from MainActor, read only from nonisolated delegate
    // callbacks — safe by convention (same pattern as V1 BLEManager)
    nonisolated(unsafe) private var central: CBCentralManager!
    nonisolated(unsafe) private var peripheral: CBPeripheral?
    nonisolated(unsafe) private var cmdToStrap:      CBCharacteristic?
    nonisolated(unsafe) private var cmdFromStrap:    CBCharacteristic?
    nonisolated(unsafe) private var eventsFromStrap: CBCharacteristic?
    nonisolated(unsafe) private var dataFromStrap:   CBCharacteristic?
    nonisolated(unsafe) private var standardHRChar:  CBCharacteristic?

    // Reconnect state (Section 9.4)
    nonisolated(unsafe) private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private let maxReconnectDelay: TimeInterval = 60

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "com.personal.WhoopBLE.central"
            ]
        )
    }

    // MARK: - Public API

    func startScanning() {
        guard central.state == .poweredOn else {
            bleLog("startScanning: Bluetooth not ready (state=\(central.state.rawValue))")
            return
        }
        connectionState = .scanning
        bleLog("scanning for WHOOP service \(WUUID.service)")
        central.scanForPeripherals(
            withServices: [WUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        central.stopScan()
        bleLog("scan stopped")
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Internal helpers

    private func bleLog(_ message: String) {
        print("[BLE] \(message)")
    }

    private func logRawEvent(direction: String, characteristic: CBCharacteristic, bytes: [UInt8]) {
        let name = WUUID.name(for: characteristic.uuid)
        let hex  = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        bleLog("\(direction) \(name) \(hex)")
    }

    private func appendEvent(_ event: BLERawEvent) {
        rawEventLog.append(event)
        if rawEventLog.count > 50 {
            rawEventLog.removeFirst(rawEventLog.count - 50)
        }
        rawNotificationPublisher.send(event)
    }

    // MARK: - Reconnect (Section 9.4 — exponential backoff: 1s, 2s, 4s … max 60s)

    private func clearCharacteristicRefs() {
        cmdToStrap = nil
        cmdFromStrap = nil
        eventsFromStrap = nil
        dataFromStrap = nil
        standardHRChar = nil
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        bleLog("reconnect attempt \(reconnectAttempt) in \(Int(delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.startScanning() }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension WhoopBLEManager: CBCentralManagerDelegate {

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            peripheral = p
            p.delegate = self
            Task { @MainActor [weak self] in
                self?.bleLog("state restored: \(p.name ?? "unknown")")
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let restoredPeripheral = peripheral
        Task { @MainActor [weak self] in
            guard let self else { return }
            bleLog("central state: \(state.rawValue)")
            switch state {
            case .poweredOn:
                if let p = restoredPeripheral {
                    connectionState = .scanning
                    self.central.connect(p, options: [
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                    bleLog("reconnecting to restored peripheral")
                } else {
                    startScanning()
                }
            default:
                connectionState = .disconnected
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? "unknown"
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            bleLog("discovered: \(name) RSSI=\(RSSI)")
            connectionState = .scanning  // still scanning until didConnect
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let name = peripheral.name ?? "WHOOP"
        // discoverServices must be called from nonisolated context — CBPeripheral is not Sendable
        peripheral.discoverServices([WUUID.service, WUUID.hrService])
        Task { @MainActor [weak self] in
            guard let self else { return }
            bleLog("connected: \(name)")
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionState = .connected(deviceName: name)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            bleLog("failed to connect: \(error?.localizedDescription ?? "unknown")")
            connectionState = .disconnected
            clearCharacteristicRefs()
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            bleLog("disconnected (\(error?.localizedDescription ?? "clean"))")
            connectionState = .disconnected
            clearCharacteristicRefs()
            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WhoopBLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            Task { @MainActor [weak self] in
                self?.bleLog("discoverServices error: \(error)")
            }
            return
        }
        for service in peripheral.services ?? [] {
            let uuidStr = service.uuid.uuidString  // extract before Task — CBService is not Sendable
            peripheral.discoverCharacteristics(nil, for: service)
            Task { @MainActor [weak self] in
                self?.bleLog("discovered service: \(uuidStr)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            Task { @MainActor [weak self] in
                self?.bleLog("discoverCharacteristics error: \(error)")
            }
            return
        }
        for char in service.characteristics ?? [] {
            let uuidStr = char.uuid.uuidString.lowercased()
            let name    = WUUID.name(for: char.uuid)

            if uuidStr.hasPrefix(WUUID.cmdTo)     { cmdToStrap      = char }
            if uuidStr.hasPrefix(WUUID.cmdFrom)   { cmdFromStrap    = char }
            if uuidStr.hasPrefix(WUUID.events)    { eventsFromStrap = char }
            if uuidStr.hasPrefix(WUUID.data)      { dataFromStrap   = char }
            if uuidStr.hasPrefix(WUUID.standardHR){ standardHRChar  = char }

            // Subscribe to all notify/indicate characteristics
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: char)
                Task { @MainActor [weak self] in
                    self?.bleLog("subscribed → \(name)")
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.bleLog("discovered \(name) (no notify, skipping subscribe)")
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let name       = WUUID.name(for: characteristic.uuid)
        let isNotifying = characteristic.isNotifying  // read before Task — CBCharacteristic is not Sendable
        Task { @MainActor [weak self] in
            if let error {
                self?.bleLog("notify state error for \(name): \(error)")
            } else {
                self?.bleLog("notify \(isNotifying ? "ON" : "OFF") for \(name)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value, error == nil else {
            let name = WUUID.name(for: characteristic.uuid)
            Task { @MainActor [weak self] in
                self?.bleLog("value error for \(name): \(error?.localizedDescription ?? "no data")")
            }
            return
        }
        let bytes    = [UInt8](data)
        let charName = WUUID.name(for: characteristic.uuid)
        let now      = Date()

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Section 10.8 log
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            bleLog("← \(charName) \(hex)")

            let event = BLERawEvent(
                id: UUID(),
                timestamp: now,
                characteristicName: charName,
                bytes: bytes
            )
            appendEvent(event)
            // BLE Layer boundary: raw bytes only. Parser layer subscribes via rawNotificationPublisher.
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let name = WUUID.name(for: characteristic.uuid)
        Task { @MainActor [weak self] in
            if let error {
                self?.bleLog("→ \(name) write failed: \(error)")
            } else {
                self?.bleLog("→ \(name) write confirmed")
            }
        }
    }
}
