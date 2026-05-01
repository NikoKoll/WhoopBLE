import Foundation

@MainActor
final class SyncManager: ObservableObject {

    // MARK: - Debug flag
    static let debugLogging = true

    // MARK: - Published state
    @Published var isSyncing = false
    @Published var syncedBatchCount = 0
    @Published var totalSteps: Int = 0
    @Published var sleepSessions: [SleepSession] = []
    // Controls banner visibility: true while syncing + 8 s after completion
    @Published var syncBannerVisible = false

    // MARK: - Internal state
    weak var bleManager: BLEManager?

    private var batchQueue: [UInt32] = []
    private var activeBatchID: UInt32?
    private var activeChunks: [Data] = []
    private var activeBatchTimestamp: Date?    // unix ts from batch ACK — anchors 0xa1 chunk timestamps
    private var processedBatches: Set<UInt32> = []
    private var expectedBatchCount: Int = 0     // from 0xfc ACK data byte
    private var lastReceivedBatchID: UInt32?    // for gap detection (IDs may not be sequential — log only)
    private var batchIDGapCount: Int = 0
    private var totalSamplesReceived: Int = 0
    private var minBatchID: UInt32 = UInt32.max
    private var maxBatchID: UInt32 = 0
    private var receivedBatchIDs: [UInt32] = [] // insertion-ordered, for first/last 10 log
    private var syncACKTime: Date? = nil        // when 0xfc ACK arrived, for first-batch delay measurement
    private var syncTimeoutTask: Task<Void, Never>?
    private var chunkIdleTask: Task<Void, Never>?
    // Offset to convert WHOOP internal clock to Unix epoch, derived from live DATA_FROM_STRAP packets.
    // WHOOP counts seconds from its own epoch (device activation); this offset = unixNow - whoopNow.
    // Only updated from the most-recent packet (highest WHOOP timestamp = live data).
    private var whoopToUnixOffset: Double?
    private var latestWhoopTs: UInt32 = 0
    private var accumulatedSamples: [HistoricalSample] = []
    // HR batch data buffered here, flushed atomically to RawDataStore before recompute enqueue.
    // Avoids race where fire-and-forget appendHRBatch Task could lose to the recompute Task.
    private var pendingBatchHR: [(timestamp: Int, bpm: Int)] = []

    private let processedKey = "whoopSyncedBatches"
    private let sleepKey     = "whoopSleepSessions_v1"

    init() {
        loadProcessedBatches()
        loadSleepSessions()
    }

    // MARK: - Entry point: called by BLEManager at +5 s after stream starts

    func onConnected() {
        guard let ble = bleManager else { return }
        isSyncing = true
        syncBannerVisible = true
        expectedBatchCount = 0
        lastReceivedBatchID = nil
        batchIDGapCount = 0
        totalSamplesReceived = 0
        minBatchID = UInt32.max
        maxBatchID = 0
        receivedBatchIDs = []
        syncACKTime = nil
        // Reset in-flight state from any prior session
        batchQueue = []
        activeBatchID = nil
        activeChunks = []
        activeBatchTimestamp = nil
        accumulatedSamples = []
        pendingBatchHR = []
        chunkIdleTask?.cancel(); chunkIdleTask = nil
        ble.sendSyncCommand(WhoopCRC.syncTrigger)
        print("[SyncManager] trigger sent — waiting for batch acks")

        // Stop spinning if the strap sends no acks within 20 s.
        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isSyncing && self.batchQueue.isEmpty && self.activeBatchID == nil {
                self.isSyncing = false
                self.runSleepDetectionIfDone()
                print("[SyncManager] timeout — strap sent no batch acks")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await MainActor.run { self?.syncBannerVisible = false }
                }
            }
        }
    }

    // MARK: - Packet routing (called from BLEManager for DATA_FROM_STRAP)

    func handleDataPacket(_ bytes: [UInt8]) {
        if SyncManager.debugLogging {
            let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            let tail = bytes.count > 32 ? "…(\(bytes.count)B)" : ""
            print("[SyncManager] DATA: \(hex)\(tail)")
        }

        guard bytes.count >= 4, bytes[0] == 0xaa else {
            print("[SyncManager] unexpected sync byte 0x\(String(format: "%02x", bytes.first ?? 0))")
            return
        }

        switch bytes[3] {
        case 0xab:
            parseBatchAck(bytes)
        case 0xfc:
            parseCommandAck(bytes)
        case 0xa1:
            receiveChunk(Data(bytes))
        case 0xf0:
            receiveChunk(Data(bytes))
        case 0xff where bytes.count == 28:
            guard bytes.count >= 10 else { break }
            let whoopTs = readU32LE(bytes, at: 6)
            // Only update epoch offset from the most-recent (highest timestamp) packet — live data.
            // Historical packets have lower timestamps and must not corrupt the offset.
            if whoopTs > latestWhoopTs {
                latestWhoopTs = whoopTs
                whoopToUnixOffset = Date().timeIntervalSince1970 - Double(whoopTs)
            }
            // Route to historical chunk collection only when syncing AND packet is old (> 5 min).
            // Live packets (age ≈ 0) are excluded so they don't keep the idle timer alive.
            if isSyncing, let offset = whoopToUnixOffset {
                let ageSeconds = Date().timeIntervalSince1970 - (Double(whoopTs) + offset)
                if ageSeconds > 300 { receiveChunk(Data(bytes)) }
            }
        default:
            print("[SyncManager] unknown type 0x\(String(format: "%02x", bytes[3])) size=\(bytes.count)")
        }
    }

    // MARK: - Command ack (0xfc on CMD_FROM_STRAP)
    // Layout: aa 0c 00 fc 24 [seq] [cmd_echo] 70 [status] [data] ...
    // For sync trigger (cmd_echo=0x16): data byte = batch count available on strap.
    private func parseCommandAck(_ bytes: [UInt8]) {
        guard bytes.count >= 10 else { return }
        let cmdEcho   = bytes[6]
        let status    = bytes[8]
        let dataByte  = bytes[9]
        print("[SyncManager] 0xfc ACK: cmd=0x\(String(format: "%02x", cmdEcho)) status=\(status) data=\(dataByte)")

        // Sync trigger ACK — strap reports how many batches are queued.
        guard cmdEcho == 0x16 else { return }
        expectedBatchCount = Int(dataByte)
        print("[SyncManager] sync ACK: \(dataByte) batch(es) available on strap")
        guard dataByte > 0 else {
            print("[SyncManager] strap reports 0 batches — nothing to sync")
            return
        }
        syncACKTime = Date()
        syncTimeoutTask?.cancel()
        syncTimeoutTask = nil
        print("[Sync] ACK received — sending probe batchID=0")
        bleManager?.sendSyncCommand(WhoopCRC.buildBatchRequest(batchID: 0))

        // Multi-stage retry if strap doesn't auto-stream 0xab ACKs:
        //   t+15s: probe batchID=1
        //   t+30s: re-send syncTrigger
        //   t+60s: give up
        syncTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.isSyncing && self.batchQueue.isEmpty && self.activeBatchID == nil else { return }
            print("[Sync] No 0xab after 15s — retrying probe batchID=1")
            self.bleManager?.sendSyncCommand(WhoopCRC.buildBatchRequest(batchID: 1))

            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.isSyncing && self.batchQueue.isEmpty && self.activeBatchID == nil else { return }
            print("[Sync] No 0xab after 30s — re-sending syncTrigger")
            self.bleManager?.sendSyncCommand(WhoopCRC.syncTrigger)

            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            if self.isSyncing && self.batchQueue.isEmpty && self.activeBatchID == nil {
                self.isSyncing = false
                self.runSleepDetectionIfDone()
                print("[Sync] No batch stream after 60s — all probes ignored")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await MainActor.run { self?.syncBannerVisible = false }
                }
            }
        }
    }

    // MARK: - Batch ack
    // Layout §6.4: aa 1c 00 ab 31 [counter] 02 [unix_ts 4B LE] [6B don't-care] [batch_id 4B LE] ...
    // batch_id at bytes[18-21], ts at bytes[7-10]

    private func parseBatchAck(_ bytes: [UInt8]) {
        guard bytes.count >= 22 else {
            print("[SyncManager] ack too short (\(bytes.count)B)"); return
        }
        syncTimeoutTask?.cancel(); syncTimeoutTask = nil

        // Finalize previous batch BEFORE updating activeBatchTimestamp for the new one.
        if let currentID = activeBatchID {
            chunkIdleTask?.cancel(); chunkIdleTask = nil
            finalizeBatch(currentID, chunks: activeChunks)
            activeBatchID = nil; activeChunks = []
        }

        let rawTs   = readU32LE(bytes, at: 7)
        let batchID = readU32LE(bytes, at: 17)
        // Validate: plausible Unix timestamps are between 2020 and 2035.
        // Values outside that range are WHOOP internal clock ticks — convert via whoopToUnixOffset.
        let unixTs: Double
        let minPlausible: Double = 1_577_836_800  // 2020-01-01
        let maxPlausible: Double = 2_051_222_400  // 2035-01-01
        let raw = Double(rawTs)
        if raw >= minPlausible && raw <= maxPlausible {
            unixTs = raw
        } else if let offset = whoopToUnixOffset, (raw + offset) >= minPlausible {
            unixTs = raw + offset
            print("[SyncManager] batch \(batchID) ts converted via whoopOffset: raw=\(rawTs) → \(Date(timeIntervalSince1970: unixTs))")
        } else {
            unixTs = Date().timeIntervalSince1970
            print("[SyncManager] batch \(batchID) ts unresolvable (raw=\(rawTs)) — using now")
        }
        let date    = Date(timeIntervalSince1970: unixTs)
        activeBatchTimestamp = date   // set AFTER finalizing previous batch

        if receivedBatchIDs.isEmpty, let ackTime = syncACKTime {
            let delay = Date().timeIntervalSince(ackTime)
            print("[Sync] First batch received after \(String(format: "%.1f", delay))s — strap auto-streams confirmed")
        }
        print("[SyncManager] ack: batch=\(batchID) ts=\(date)")

        guard !processedBatches.contains(batchID) else {
            print("[SyncManager] batch \(batchID) already synced, skipping")
            downloadNextBatchIfIdle()
            // If nothing is pending, schedule a short idle finish — without this,
            // isSyncing stays true forever when every ack is a known batch.
            if batchQueue.isEmpty && activeBatchID == nil { scheduleIdleFinish() }
            return
        }

        // Gap detection — WHOOP batchIDs may not be contiguous integers; treat as observation only.
        if let prev = lastReceivedBatchID, batchID != prev + 1 {
            print("[Sync] BatchID gap: expected \(prev + 1), got \(batchID) (delta=\(Int(batchID) - Int(prev)))")
            batchIDGapCount += 1
        }
        lastReceivedBatchID = batchID
        if batchID < minBatchID { minBatchID = batchID }
        if batchID > maxBatchID { maxBatchID = batchID }
        receivedBatchIDs.append(batchID)

        batchQueue.append(batchID)
        downloadNextBatchIfIdle()
    }

    // MARK: - Sequential batch downloading

    private func downloadNextBatchIfIdle() {
        guard activeBatchID == nil, !batchQueue.isEmpty else { return }
        let id = batchQueue.removeFirst()
        activeBatchID = id
        activeChunks = []
        print("[SyncManager] requesting batch \(id)")
        bleManager?.sendSyncCommand(WhoopCRC.buildBatchRequest(batchID: id))

        // Fallback: finalize after 8s even if strap sends zero chunks for this batch.
        chunkIdleTask?.cancel()
        chunkIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, let id = self.activeBatchID else { return }
            self.finalizeBatch(id, chunks: self.activeChunks)
            self.activeBatchID = nil; self.activeChunks = []; self.chunkIdleTask = nil
            self.downloadNextBatchIfIdle()
            if self.batchQueue.isEmpty && self.activeBatchID == nil {
                self.isSyncing = false
                self.runSleepDetectionIfDone()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await MainActor.run { self?.syncBannerVisible = false }
                }
            }
        }
    }

    private func receiveChunk(_ data: Data) {
        // No explicit batch ack — create an implicit streaming batch (id=0, not persisted).
        if activeBatchID == nil {
            activeBatchID = 0
            activeChunks = []
            // Implicit batches have no ACK timestamp; use current time as anchor.
            if activeBatchTimestamp == nil { activeBatchTimestamp = Date() }
            print("[SyncManager] implicit streaming batch started")
        }
        guard let batchID = activeBatchID else { return }
        activeChunks.append(data)
        print("[SyncManager] chunk \(activeChunks.count) for batch \(batchID)")

        // Reset 3-second idle timer — finalize once chunks stop arriving
        chunkIdleTask?.cancel()
        chunkIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if let id = self.activeBatchID {
                self.finalizeBatch(id, chunks: self.activeChunks)
                self.activeBatchID = nil
                self.activeChunks = []
                self.chunkIdleTask = nil
                self.downloadNextBatchIfIdle()
                if self.batchQueue.isEmpty && self.activeBatchID == nil {
                    self.isSyncing = false
                    self.runSleepDetectionIfDone()
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        await MainActor.run { self?.syncBannerVisible = false }
                    }
                }
            }
        }
    }

    // MARK: - Finalize: parse → HealthKit + update published state

    private func finalizeBatch(_ id: UInt32, chunks: [Data]) {
        print("[SyncManager] finalizing batch \(id): \(chunks.count) chunk(s)")
        let batchTs = activeBatchTimestamp
        // For 0xa1 chunks: precompute max sequence so we can anchor timestamps to batchTs.
        // batchTs is treated as the END time of the batch (most recent sample = batchTs).
        let maxA1Seq = chunks.compactMap { d -> Int? in
            let b = [UInt8](d); return (b.count > 11 && b[3] == 0xa1) ? Int(b[11]) : nil
        }.max() ?? 0
        let samples = chunks.compactMap { parseChunk([UInt8]($0), batchTimestamp: batchTs, maxChunkSeq: maxA1Seq) }

        let a1Count = chunks.filter { $0.count > 3 && $0[3] == 0xa1 }.count
        print("[SyncManager] batch \(id): \(chunks.count) chunks (\(a1Count) x 0xa1), batchTs=\(batchTs?.description ?? "nil"), maxA1Seq=\(maxA1Seq), samples=\(samples.count)")
        guard !samples.isEmpty else {
            print("[SyncManager] batch \(id) yielded no usable samples — check logs above for rejection reasons")
            markProcessed(id); return
        }

        let hk = bleManager?.healthKit
        hk?.writeHistoricalSamples(samples)

        // Active energy — 1 sample ≈ 1 second; metActive × weight × (1/3600 h)
        if let first = samples.first?.timestamp, let last = samples.last?.timestamp {
            let weight = UserDefaults.standard.double(forKey: "userWeightKg")
            let weightKg = weight > 0 ? weight : 78.0
            let kcal = samples.reduce(0.0) { $0 + metForHR($1.heartRate) * weightKg / 3600.0 }
            if kcal > 0 { hk?.writeActiveEnergy(kcal: kcal, start: first, end: last) }
        }

        // Step detection
        let stepDetector = StepDetector()
        for s in samples { if let a = s.accelerometer { stepDetector.process(a) } }
        if stepDetector.stepCount > 0,
           let start = samples.first?.timestamp, let end = samples.last?.timestamp {
            hk?.writeSteps(count: stepDetector.stepCount, start: start, end: end)
            bleManager?.metricsStore.addHistoricalSteps(stepDetector.stepCount, for: start)
            totalSteps += stepDetector.stepCount
            print("[SyncManager] batch \(id): +\(stepDetector.stepCount) steps (total \(totalSteps))")
        }

        totalSamplesReceived += samples.count

        // Accumulate samples for post-sync sleep detection (runs once after all batches done).
        let now = Date().timeIntervalSince1970
        let validSamples = samples.filter {
            let ts = $0.timestamp.timeIntervalSince1970
            return ts >= 1_672_531_200 && ts <= now + 86400  // ≥ 2023-01-01 and ≤ tomorrow
        }
        accumulatedSamples.append(contentsOf: validSamples)
        if validSamples.count < samples.count {
            print("[SyncManager] batch \(id): dropped \(samples.count - validSamples.count) sample(s) with pre-2023 timestamp")
        }

        // Buffer HR batch for atomic flush to RawDataStore before recompute (avoids Task race).
        let batchSamples = samples.map { (timestamp: Int($0.timestamp.timeIntervalSince1970), bpm: $0.heartRate) }
        pendingBatchHR.append(contentsOf: batchSamples)

        markProcessed(id)
        syncedBatchCount += 1
        if batchQueue.isEmpty && activeBatchID == nil {
            isSyncing = false
            runSleepDetectionIfDone()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run { self?.syncBannerVisible = false }
            }
        }
    }

    // MARK: - Chunk parsing
    // Two historical packet formats (bWanShiTong reverse-engineering-whoop-post):
    // 0xff 28B: aa 18 00 ff 28 02  [ts 4B LE @6]   [?? 2B]  [hr @12]  [rr-count @13] ...
    // 0xf0 96B: aa 5c 00 f0 2f 0c  [counter 2B @6] [ts 4B LE @8]  [?? 4B]  [hr @16] ...

    private func parseChunk(_ bytes: [UInt8], batchTimestamp: Date? = nil, maxChunkSeq: Int = 0) -> HistoricalSample? {
        if SyncManager.debugLogging {
            let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            let tail = bytes.count > 16 ? "…(\(bytes.count)B)" : ""
            print("[SyncManager] chunk type=0x\(String(format: "%02x", bytes.count > 3 ? bytes[3] : 0)): \(hex)\(tail)")
        }

        guard bytes.count >= 4 else { return nil }

        // 0xa1: confirmed batch history format (104 bytes).
        // bytes[11] = chunk sequence within batch; bytes[21] = HR BPM.
        // Timestamp anchored to batch ACK unix ts (= batch end time); each chunk is
        // (maxSeq - seq) seconds before that anchor.
        if bytes[3] == 0xa1 {
            guard bytes.count >= 22 else { return nil }
            guard let batchTs = batchTimestamp else {
                print("[SyncManager] 0xa1 chunk dropped: no batch timestamp"); return nil
            }
            let chunkSeq = Int(bytes[11])
            let hr = Int(bytes[21])
            guard hr >= 30, hr <= 220 else {
                print("[SyncManager] 0xa1 chunk rejected: hr=\(hr)"); return nil
            }
            // RR intervals: count at byte[22], up to 4 UInt16 LE ms values starting at byte[23].
            var rrs: [Double] = []
            if bytes.count >= 31 {
                let rrCount = min(4, Int(bytes[22]))
                for i in 0..<rrCount {
                    let off = 23 + i * 2
                    guard off + 1 < bytes.count else { break }
                    let ms = UInt16(bytes[off]) | (UInt16(bytes[off + 1]) << 8)
                    let secs = Double(ms) / 1000.0
                    if secs >= 0.3 && secs <= 2.0 { rrs.append(secs) }
                }
            }
            let offsetSecs = Double(chunkSeq - maxChunkSeq)  // ≤ 0, so timestamp ≤ batchTs
            let timestamp = batchTs.addingTimeInterval(offsetSecs)
            return HistoricalSample(timestamp: timestamp, heartRate: hr, accelerometer: nil,
                                    rrIntervals: rrs.isEmpty ? nil : rrs)
        }

        let tsAt: Int
        let hrAt: Int
        switch bytes[3] {
        case 0xff:
            guard bytes.count >= 13 else { return nil }
            tsAt = 6; hrAt = 12
        case 0xf0:
            guard bytes.count >= 17 else { return nil }
            tsAt = 8; hrAt = 16
        default:
            print("[SyncManager] parseChunk: unknown type 0x\(String(format: "%02x", bytes[3]))"); return nil
        }
        let rawTs = readU32LE(bytes, at: tsAt)
        let hr = Int(bytes[hrAt])

        // 0xf0 chunks carry real Unix timestamps (> 1B); 0xff uses WHOOP internal clock.
        let unixTs: Double
        if rawTs > 1_000_000_000 {
            unixTs = Double(rawTs)
        } else if let offset = whoopToUnixOffset {
            unixTs = Double(rawTs) + offset
        } else {
            print("[SyncManager] chunk rejected: no epoch offset yet ts=\(rawTs)"); return nil
        }

        guard unixTs > 1_000_000_000 else {
            print("[SyncManager] chunk rejected: invalid ts=\(rawTs) converted=\(unixTs)"); return nil
        }
        guard hr >= 30, hr <= 220 else {
            print("[SyncManager] chunk rejected: hr=\(hr)"); return nil
        }

        let timestamp = Date(timeIntervalSince1970: unixTs)
        return HistoricalSample(timestamp: timestamp, heartRate: hr, accelerometer: nil)
    }

    // MARK: - Persistence

    private func loadProcessedBatches() {
        // UserDefaults stores numbers as NSNumber which bridges to [Int], not [UInt32].
        // [Any] as? [UInt32] always fails — must cast through [Int].
        if let arr = UserDefaults.standard.array(forKey: processedKey) as? [Int] {
            processedBatches = Set(arr.map { UInt32($0) })
        }
    }

    private func markProcessed(_ id: UInt32) {
        guard id != 0 else { return }  // streaming batch (id=0) is not persisted
        processedBatches.insert(id)
        UserDefaults.standard.set(processedBatches.map { Int($0) }, forKey: processedKey)
    }

    // Called by LiveSleepMonitor (via BLEManager) when a live sleep session is confirmed.
    func addSleepSession(_ session: SleepSession) {
        let isDuplicate = sleepSessions.contains { abs($0.start.timeIntervalSince(session.start)) < 300 }
        guard !isDuplicate else { return }
        sleepSessions.append(session)
        sleepSessions.sort { $0.start < $1.start }
        saveSleepSessions()
        bleManager?.healthKit.writeSleep([session])
        print("[SyncManager] live sleep session added: \(session.start.formatted(date: .abbreviated, time: .shortened)) → \(session.end.formatted(date: .omitted, time: .shortened))")
    }

    private func loadSleepSessions() {
        guard let data = UserDefaults.standard.data(forKey: sleepKey),
              let sessions = try? JSONDecoder().decode([SleepSession].self, from: data) else { return }
        // Deduplicate on load — prior bug (processedBatches never persisted) caused
        // the same batches to be reprocessed on every launch, producing duplicate sessions.
        var seen: [SleepSession] = []
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            guard s.end.timeIntervalSince(s.start) >= 1800 else { continue }
            if !seen.contains(where: { abs($0.start.timeIntervalSince(s.start)) < 3600 }) {
                seen.append(s)
            }
        }
        sleepSessions = seen
    }

    private func saveSleepSessions() {
        guard let data = try? JSONEncoder().encode(sleepSessions) else { return }
        UserDefaults.standard.set(data, forKey: sleepKey)
    }

    // Wipes all sleep sessions from app storage + HealthKit and clears the processed-batch
    // cache so every batch re-downloads on next connect.
    func clearAllSleepData() {
        sleepSessions = []
        accumulatedSamples = []
        pendingBatchHR = []
        UserDefaults.standard.removeObject(forKey: sleepKey)
        UserDefaults.standard.removeObject(forKey: processedKey)
        processedBatches = []
        syncedBatchCount = 0
        print("[SyncManager] sleep + batch cache cleared — will re-sync on next connect")
    }

    // Called when all pending batch acks are already-processed (known batches).
    // Waits 3 s for any stragglers, then clears the syncing flag.
    // Guard: don't restart if already scheduled — a stream of known-batch acks
    // would otherwise keep resetting the 3 s timer and sync would never finish.
    private func scheduleIdleFinish() {
        guard syncTimeoutTask == nil else { return }
        syncTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isSyncing && self.batchQueue.isEmpty && self.activeBatchID == nil {
                self.isSyncing = false
                self.runSleepDetectionIfDone()
                print("[SyncManager] all batches already synced — done")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await MainActor.run { self?.syncBannerVisible = false }
                }
            }
        }
    }

    // MARK: - Post-sync sleep detection + recompute enqueue

    private func runSleepDetectionIfDone() {
        // ── Batch ID statistics ────────────────────────────────────────────────
        let expectedStr = expectedBatchCount > 0 ? "\(expectedBatchCount)" : "unknown"
        let idSpan      = (minBatchID <= maxBatchID) ? Int(maxBatchID) - Int(minBatchID) + 1 : 0
        let contiguous  = idSpan > 0 && idSpan == syncedBatchCount
        if SyncManager.debugLogging {
            print("[Sync Summary] ──────────────────────────────────────")
            print("[Sync Summary]   Expected batches : \(expectedStr) (from 0xfc ACK)")
            print("[Sync Summary]   Received batches : \(syncedBatchCount)")
            if idSpan > 0 {
                print("[Sync Summary]   BatchID range    : \(minBatchID) → \(maxBatchID) (span=\(idSpan))")
                print("[Sync Summary]   Contiguous       : \(contiguous ? "YES" : "NO — expected \(idSpan) got \(syncedBatchCount)")")
            }
            print("[Sync Summary]   BatchID gaps     : \(batchIDGapCount)")
            if !receivedBatchIDs.isEmpty {
                let first10 = receivedBatchIDs.prefix(10).map { String($0) }.joined(separator: ", ")
                print("[Sync Summary]   First IDs        : [\(first10)]")
                if receivedBatchIDs.count > 10 {
                    let last10 = receivedBatchIDs.suffix(10).map { String($0) }.joined(separator: ", ")
                    print("[Sync Summary]   Last IDs         : [\(last10)]")
                }
            }
        }

        // Collect affected dates before clearing (always include today)
        var dateKeys: Set<String> = [isoDateKey(Date())]
        for s in accumulatedSamples { dateKeys.insert(isoDateKey(s.timestamp)) }

        if !accumulatedSamples.isEmpty {
            let sorted = accumulatedSamples.sorted { $0.timestamp < $1.timestamp }

            // ── Timestamp continuity analysis (same sorted array reused for sleep detection) ──
            var tsGapCount = 0
            var largestGapSec = 0.0
            var largestGapAt: Date? = nil
            for i in 1..<sorted.count {
                let delta = sorted[i].timestamp.timeIntervalSince(sorted[i-1].timestamp)
                if delta > 120 {
                    tsGapCount += 1
                    if delta > largestGapSec { largestGapSec = delta; largestGapAt = sorted[i-1].timestamp }
                    if SyncManager.debugLogging {
                        print("[Sync] Time gap: Δ=\(Int(delta))s at \(sorted[i-1].timestamp)")
                    }
                }
            }

            // ── Coverage + averages summary ────────────────────────────────────
            if SyncManager.debugLogging, let first = sorted.first?.timestamp, let last = sorted.last?.timestamp {
                let coverageHours = last.timeIntervalSince(first) / 3600
                let avgPerBatch   = syncedBatchCount > 0 ? Double(totalSamplesReceived) / Double(syncedBatchCount) : 0
                let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                print("[Sync Summary]   Time range       : \(fmt.string(from: first)) → \(fmt.string(from: last))")
                print("[Sync Summary]   Coverage         : \(String(format: "%.1f", coverageHours)) hours")
                print("[Sync Summary]   Total samples    : \(totalSamplesReceived)")
                print("[Sync Summary]   Avg samples/batch: \(String(format: "%.1f", avgPerBatch))")
                if let gapAt = largestGapAt {
                    print("[Sync Summary]   TS gaps >120s    : \(tsGapCount) (largest Δ=\(Int(largestGapSec))s at \(fmt.string(from: gapAt)))")
                } else {
                    print("[Sync Summary]   TS gaps >120s    : 0")
                }
                print("[Sync Summary] ──────────────────────────────────────")
            }

            let newSessions = SleepDetector().process(sorted)
            let uniqueNew = newSessions.filter { n in
                guard n.end.timeIntervalSince(n.start) >= 1800 else { return false }
                return !sleepSessions.contains { abs($0.start.timeIntervalSince(n.start)) < 3600 }
            }
            if !uniqueNew.isEmpty {
                bleManager?.healthKit.writeSleep(uniqueNew)
                sleepSessions.append(contentsOf: uniqueNew)
                sleepSessions.sort { $0.start < $1.start }
                saveSleepSessions()
                print("[SyncManager] sleep detection: \(uniqueNew.count) session(s) from \(sorted.count) samples")
            } else {
                print("[SyncManager] sleep detection: no new sessions from \(sorted.count) samples")
            }
            accumulatedSamples = []
        } else if SyncManager.debugLogging {
            print("[Sync Summary]   Total samples    : 0 (no accumulated samples)")
            print("[Sync Summary] ──────────────────────────────────────")
        }

        // Flush pendingBatchHR to RawDataStore atomically before enqueue — prevents race where
        // recomputeDay starts before appendHRBatch completes if they were separate Tasks.
        if let ble = bleManager {
            let dates = dateKeys.compactMap { parseISODateString($0) }
            let batchHR = pendingBatchHR
            pendingBatchHR = []
            Task {
                if !batchHR.isEmpty { await ble.rawDataStore.appendHRBatch(batchHR) }
                await ble.recomputeQueue.enqueue(dates: dates, rawStore: ble.rawDataStore, dailyStore: ble.dailyMetrics)
            }
            print("[Recompute] sync done — queued \(dates.count) date(s), batch HR samples=\(batchHR.count)")
        }
    }

    private func isoDateKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
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

    // MARK: - Byte helpers

    private func readU32LE(_ bytes: [UInt8], at i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24
    }


}
