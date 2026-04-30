# WhoopBLE — Analytical Report
**Generated:** 2026-04-28  
**Purpose:** Study reference — architecture, data flow, protocol, algorithms, open problems.

---

## 1. Project Summary

WhoopBLE is a personal iOS app that reads raw biometric data directly from a WHOOP 4.0 fitness strap over Bluetooth Low Energy (BLE), without needing a WHOOP subscription. The subscription gate is entirely server/app-side — the strap itself streams data to any authorized BLE client unconditionally.

**Stack:** SwiftUI + CoreBluetooth + CoreMotion + HealthKit  
**Language:** Swift 6.0 (strict concurrency, `@MainActor` throughout)  
**Target:** iOS 16.0+

---

## 2. System Architecture

### 2.1 Layer Diagram
```
┌──────────────────────────────────────────────────────┐
│                      WHOOP 4.0 Strap                 │
│  BLE GATT: 3 notify chars + 1 write char             │
└──────────┬───────────────────────────────────────────┘
           │ CoreBluetooth
┌──────────▼───────────────────────────────────────────┐
│                     BLEManager                       │
│  • CBCentralManager + CBPeripheralDelegate           │
│  • State machine: scanning→connecting→streaming      │
│  • Dispatches all BLE callbacks → MainActor          │
│  • Owns: SyncManager, MetricsStore, HealthKitWriter  │
│          LiveSleepMonitor, CMPedometer               │
└──┬──────────┬──────────┬────────────┬────────────────┘
   │          │          │            │
   ▼          ▼          ▼            ▼
SyncManager  MetricsStore  HealthKit  LiveSleepMonitor
(batches)    (disk store)  Writer     (real-time sleep)
   │
   ▼
SleepDetector (post-sync, full corpus)
```

### 2.2 Concurrency Model
All logic runs on `@MainActor`. BLE delegate callbacks from CoreBluetooth arrive on the `bleQueue` (a private `DispatchQueue`) and are hopped to MainActor via `Task { @MainActor in }`. File I/O in MetricsStore uses `Task.detached(priority: .background)` to avoid blocking the main thread. Swift 6 strict concurrency is enforced — `nonisolated` where needed on BLE ivars accessed from the queue.

### 2.3 Object Graph
```
WhoopBLEApp
└── BLEManager (@StateObject)
    ├── SyncManager
    │   └── (weak) bleManager → BLEManager
    ├── MetricsStore
    ├── HealthKitWriter
    ├── LiveSleepMonitor
    └── CMPedometer

ContentView (@EnvironmentObject BLEManager)
├── DashboardView    — reads BLEManager directly
├── SleepView        — @ObservedObject SyncManager
└── TrendsView       — @ObservedObject MetricsStore
```

---

## 3. BLE Protocol (Reverse Engineered)

### 3.1 GATT Services & Characteristics
| UUID prefix | Name | Direction | Purpose |
|---|---|---|---|
| `61080002` | CMD_TO_STRAP | Write (no-resp) | Send enable/sync commands |
| `61080003` | CMD_FROM_STRAP | Notify | Per-command ACK (0xfc packets) |
| `61080004` | EVENTS_FROM_STRAP | Notify | Live HR stream (0x57 ~1 Hz) |
| `61080005` | DATA_FROM_STRAP | Notify | Historical batch chunks |
| `61080007` | MEMFAULT | Notify | Crash dumps (ignored) |
| `180D/2A37` | Std HR Service | Notify | Standard BLE HR (preferred) |
| `180F/2A19` | Std Battery | Read+Notify | Battery % |

### 3.2 CRC Algorithm
Reflected CRC-32 (Ethernet polynomial). Right-shift form:
- Polynomial: `0xEDB88320` (bit-reversal of `0x04C11DB7`)
- Init: `0x00000000`
- XOR-out: varies by header prefix:
  - `[aa 08 00 a8 23]` → `0x6971BE68` (8-byte commands)
  - `[aa 10 00 57 23]` → `0xF43F44AC` (16-byte batch request)
  - `[aa 18 00 ff 28]` → `0xE02CCD0E` (DATA_FROM_STRAP packets)

### 3.3 Command Catalogue
| Command | Bytes | Notes |
|---|---|---|
| `enableHealth` | `aa 08 00 a8 23 70 03 01 [CRC]` | Starts live HR stream |
| `disableHealth` | `aa 08 00 a8 23 70 03 00 [CRC]` | Stops stream on disconnect |
| `enableHRBroadcast` | `aa 08 00 a8 23 70 0e 01 [CRC]` | Activates 0x180D/0x2A37 |
| `buildCommand(0x03, 0x02)` | `aa 08 00 a8 23 70 03 02 [CRC]` | Required keepalive — silence without it |
| `syncTrigger` | `aa 08 00 a8 23 70 16 00 [CRC]` | Initiates batch enumeration |
| `buildBatchRequest(id)` | `aa 10 00 57 23 70 17 01 [id 4B LE] [pad 4B] [CRC]` | Request specific batch |

### 3.4 Packet Formats

#### EVENTS_FROM_STRAP (live HR)
```
Offset  Field
[0]     0xaa  sync
[1]     length
[2]     0x00  constant
[3]     type: 0x57 (dominant), 0xab, 0x52
[4-7]   WHOOP internal clock LE UInt32 (NOT Unix epoch)
[8-9]   metric1  — unknown; 16-bit LE; possibly step counter
[10]    Heart Rate BPM  ← primary field (guarded 30–220)
[11]    RR interval count (capped at 4)
[12+]   RR intervals, UInt16 LE, milliseconds
```
Note: On current firmware, byte[10] observed as 0xe4 (228) — rejected. Real HR sourced from 0x2A37.

#### CMD_FROM_STRAP ACK (0xfc)
```
Offset  Field
[0-2]   aa 0c 00
[3]     0xfc  type
[4]     0x24  constant
[5]     sequence counter (increments per ack)
[6]     cmd_echo (mirrors category of sent command)
[7]     0x70  constant
[8]     status (0x02 = success, 0x01 = ?)
[9]     data byte (for 0x16 sync: = batch count available)
[10-11] 0x00 0x00
[12-15] CRC
```

#### DATA_FROM_STRAP Batch Chunk (0xa1, 104 bytes)
```
Offset  Field
[0-3]   aa 64 00 a1
[7]     packet counter
[11]    chunk sequence index within batch
[21]    Heart Rate BPM (CONFIRMED via live observation)
[22]    RR count
[23-26] RR intervals (UInt16 LE, ms)
[100-103] CRC-32
```
No accelerometer data in 0xa1. Steps from historical batches = always 0.

#### Batch ACK (0xab on DATA_FROM_STRAP)
```
Offset  Field
[0-3]   aa 1c 00 ab
[4]     0x31 constant
[5]     counter
[6]     0x02
[7-10]  unix timestamp LE UInt32 (= batch end time)
[11-16] unknown 6 bytes
[17-20] batch_id LE UInt32
```

---

## 4. Data Pipeline

### 4.1 Live HR Path
```
0x2A37 notify → BLEManager.didUpdateValue
  → flags byte parsed (HR is UInt8 or UInt16 per flags)
  → RR intervals extracted (unit: 1/1024 s → ms)
  → jump filter: reject if |hr - lastHR| > 25 BPM
  → acceptMetrics(WhoopMetrics)
      → hrHistory ring buffer (60 samples)
      → smoothedHR = 15-sample rolling avg
      → rrBuffer appended (valid 300–2000 ms)
      → RMSSD computed when rrBuffer.count >= 4
      → smoothedHRV = 5-sample rolling avg of RMSSD
      → MetricsStore.record() every 30 s
      → HealthKitWriter.write() every 5 s
      → LiveSleepMonitor.observe()
```

### 4.2 Historical Batch Sync Path
```
onConnected() → syncTrigger sent
  → 0xfc ACK received (batch count in byte[9])
  → buildBatchRequest(batchID: 0) probe sent
  → 0xab batch ACKs → parseBatchAck()
      → batchQueue.append(batchID)
      → downloadNextBatchIfIdle() → buildBatchRequest(id)
  → 0xa1 chunks arrive → receiveChunk()
      → chunkIdleTask resets 3s timer
      → finalizeBatch() when chunks stop
          → parseChunk(): timestamp anchored to batchTs - offset
          → samples filtered: timestamp >= 2023-01-01
          → hk.writeHistoricalSamples()
          → metricsStore.addHistoricalSteps() (always 0 — no accel)
          → accumulatedSamples.append()
  → all batches done → runSleepDetectionIfDone()
      → SleepDetector.process(sorted accumulatedSamples)
      → deduplicate: min 30 min, 1-hour start tolerance
      → hk.writeSleep(), SyncManager.sleepSessions updated
```

### 4.3 Steps Path
```
CMPedometer (today midnight → now)
  → queryPedometerData + startUpdates callbacks
  → BLEManager.dailySteps (published, shown in Dashboard)
  → MetricsStore.setTodaySteps() (max semantics → disk)

SyncManager.finalizeBatch
  → StepDetector.process(accel samples) — always 0 for WHOOP batches
  → MetricsStore.addHistoricalSteps() (additive per day)
```

---

## 5. Algorithms

### 5.1 HRV (RMSSD)
Computed from rolling 60-sample RR buffer (~60 seconds at 1 Hz):
```
diffs[i] = (rr[i+1] - rr[i]) * 1000   [ms²]
RMSSD = sqrt(mean(diffs²))
```
Valid RR range: 300–2000 ms. Result smoothed with 5-sample rolling avg. Shows `— ms` when fewer than 4 valid RR intervals accumulated.

**Current limitation:** EVENTS packets (0x57) frequently have invalid RR data. Standard 0x2A37 packets carry valid RR when HR broadcast is active.

### 5.2 Live Sleep Detection (LiveSleepMonitor)
Three-state machine: `awake → candidate → sleeping`

**Sleep signal:**
- Rolling 4-minute (240-sample) HR buffer
- `sleepLike = avg(HR) < min(HR) + 5 BPM AND device stationary`
- Stationarity from CMMotionActivityManager; defaults to `true` if unavailable

**Onset:** 10 min continuous `sleepLike` between 21:00–11:00, else 20 min  
**Wake:** 5 min continuous non-sleep conditions  
**Output:** `SleepSession(start: onset, end: wakeCandidate)` via `onSessionEnd` callback → `SyncManager.addSleepSession()`

### 5.3 Historical Sleep Detection (SleepDetector)
Runs once after full sync completes on all accumulated samples.

**Window building:** 10-minute non-overlapping windows from first to last sample  
**Window classification:**
- HR-only (no accel): `sleepLike = avg(HR) < min(HR) + 5 BPM`
- With accel: both HR and motion variance < 0.05 g² required

**Session extraction:**
- Sleep onset: 20 min consecutive sleep-classified windows
- Wake: 10 min consecutive awake-classified windows
- Dedup: min 30-min session duration; 1-hour start-time tolerance against existing sessions

### 5.4 Step Detection (StepDetector)
Two-stage IIR filter on accelerometer magnitude:
```
high-pass:  hp[n] = α * (hp[n-1] + mag[n] - mag[n-1])    α = 0.94
low-pass:   lp[n] = β * lp[n-1] + (1-β) * hp[n]          β = 0.80
step:       rising edge of lp crossing 0.15 g, min 300 ms between steps
```
Dead letter in current WHOOP data — no accelerometer in 0xa1 chunks.

---

## 6. Persistence Layer

### 6.1 MetricsStore
| Property | Type | File | Strategy |
|---|---|---|---|
| `entries` | `[Entry]` | `metrics_history_v1.json` | 30s throttle, 7-day prune |
| `dailySteps` | `[DailySteps]` | `steps_history_v1.json` | upsert per day, permanent |

Entry struct: `{id: UUID, timestamp: Date, heartRate: Int, hrv: Double?}`  
DailySteps struct: `{id: Date (startOfDay), steps: Int}`

Writes via `Task.detached(priority: .background)` → `Data.write(to:options:.atomic)` to avoid write-tear.

### 6.2 SyncManager (UserDefaults)
| Key | Type | Purpose |
|---|---|---|
| `whoopSyncedBatches` | `[Int]` | Set of processed batch IDs |
| `whoopSleepSessions_v1` | `Data` (JSON) | `[SleepSession]` array |

`clearAllSleepData()` removes both keys, resets `processedBatches`, clears `accumulatedSamples` and `sleepSessions`.

---

## 7. UI Layer

### 7.1 Tab: Live (DashboardView)
- Connection state banner with colour-coded dot (green=live, yellow=connecting, red=off)
- HR ring: `Circle().trim` animated 0–1 progress, colour by zone, opacity dims when stale
- Zones: Rest (<60) blue, Easy (<100) green, Cardio (<140) yellow, Hard (<170) orange, Max red
- Session stats: min/avg/max from `hrHistory` ring (60 samples)
- HR sparkline: last 60 samples as AreaMark + LineMark Chart
- Steps tile: `max(ble.dailySteps, syncManager.totalSteps)` — prefers pedometer
- HRV display: `smoothedHRV ?? lastHRV` — sticky, dims when stale
- Sync banner: shown while `syncBannerVisible` (during sync + 8 s after)
- Stale threshold: 60 s since last packet → dims ring + HRV

### 7.2 Tab: Sleep (SleepView)
- Empty state with moon icon when no sessions
- Session list (newest first): date, time range, duration
- Quality colour: green ≥7h, yellow ≥5h, orange <5h
- Shows sync progress indicator when `isSyncing`

### 7.3 Tab: Trends (TrendsView)
- Segmented picker: Today / 7 Days
- Today: Steps tile → HR area chart (24h) → HRV line chart (24h)
- Week: Daily avg HR bars (zone-coloured) → Daily avg HRV area → Daily steps bars → Stats row
- All charts: `.chartBackground { _ in Color.clear }` + `.chartPlotStyle { $0.background(Color.clear) }` for correct dark rendering
- Data source: `MetricsStore` via `@ObservedObject` — live updates as new entries record

---

## 8. HealthKit Writes

| Data Type | Frequency | Notes |
|---|---|---|
| `heartRate` (live) | Every 5 s | From 0x2A37 or EVENTS |
| `heartRateVariabilitySDNN` | Every 5 s when RMSSD valid | Written as seconds (ms/1000) |
| `heartRate` (historical) | Per batch | All 0xa1 HR samples as batch |
| `stepCount` | Per batch | Always 0 (no accel in batches) |
| `sleepAnalysis` | Post-sync | `asleepUnspecified` category |

Authorization requested on app launch: share HR, HRV, steps, sleep; read HR, sleep.

---

## 9. Known Limitations & Open Problems

### 9.1 Batch Delivery Cursor (Critical)
The strap tracks which batch IDs it has pushed to each client. Once delivered, they won't be re-sent even if the client clears its own processed-batch cache. This means:
- First connect after wearing strap = gets historical data
- Subsequent reconnects = no new batches until new history accumulates
- The `buildBatchRequest(batchID: 0)` probe sometimes helps but is undocumented

### 9.2 Live HR from EVENTS 0x57
Byte[10] = 0xe4 = 228 BPM observed — physically impossible, consistently rejected by 30–220 guard. Real HR successfully read from 0x2A37. Root cause unknown — possibly firmware-specific encoding or field moved.

### 9.3 0xa1 Timestamps
No Unix timestamp found in 0xa1 packets. Current approach (batchTs − offset seconds per chunk) gives plausible ordering but accuracy degrades for batches where `maxSeq` is miscounted. Sleep session times may be off by minutes.

### 9.4 Historical Steps Always Zero
0xa1 batch chunks carry no accelerometer data. `StepDetector` always returns 0. Live steps from CMPedometer work correctly. WHOOP's internal step count may be in `metric1` (bytes[8-9] of EVENTS 0x57) — untested.

### 9.5 metric1 Field
16-bit LE at EVENTS bytes[8-9]. Observed value ~6945. Hypothesis: WHOOP internal step counter. Test: walk a known distance and observe delta.

### 9.6 SpO2 / Respiration Rate
WHOOP 4.0 hardware supports SpO2. No characteristic discovered yet. May require a specific enable command or dedicated service UUID.

---

## 10. What Works Reliably (On-Device Confirmed)

| Feature | Confidence |
|---|---|
| Live HR from 0x2A37 | ✅ High |
| Battery level from 0x2A19 | ✅ High |
| HRV RMSSD when RR valid | ✅ High |
| HealthKit HR + HRV writes | ✅ High |
| Daily step count (CMPedometer) | ✅ High |
| Auto-reconnect on disconnect | ✅ High |
| MetricsStore 7-day persistence | ✅ High |
| Trends charts (Today/Week) | ✅ High |
| 0xa1 batch chunks received | ✅ Medium (strap-side cursor limits re-delivery) |
| Sleep session detection | ⚠️ Medium (needs full night corpus; timestamp accuracy TBD) |
| 0xab batch ACKs | ⚠️ Low (delivered once per strap; probe is speculative) |
| SpO2 | ❌ Not implemented |
| Historical steps | ❌ No accel in batches |
