# WHOOP BLE iOS App — Handoff V7

**Project root:** `/Users/nikolaskollias/WhoopBLE/`
**Build:** `xcodegen generate` → open `WhoopBLE.xcodeproj` → Cmd+R
**Bundle ID:** `com.personal.WhoopBLE` | **Team:** `2Z848WW3KQ`
**Swift:** 6.0 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
**Deployment target:** iOS 16.0

---

## What Works Right Now ✅

| Feature | Status | Notes |
|---|---|---|
| BLE connect to WHOOP 4.0 | ✅ | Auto-scans on launch, auto-reconnects on drop |
| Heart rate (live) | ✅ | From standard BLE HR service (0x2A37) — confirmed accurate |
| Battery level | ✅ | From BLE Battery Service (0x2A19) |
| Apple HealthKit HR writes | ✅ | Every 5 s, throttled |
| Apple HealthKit HRV writes | ✅ | RMSSD when RR intervals present |
| Background BLE | ✅ | `bluetooth-central` keeps stream alive when backgrounded |
| State restoration | ✅ | `CBCentralManagerOptionRestoreIdentifierKey` |
| Auto-reconnect | ✅ | `startScanning()` on disconnect; silence watchdog after 25 s |
| HRV (RMSSD) | ⚠️ | From RR intervals in 0x2A37; appears intermittently |
| Zone-colored HR ring | ✅ | Blue/green/yellow/orange/red by zone |
| HR history sparkline | ✅ | 60-sample Swift Charts line + area fill |
| Session stats bar | ✅ | Min/avg/max HR since connect |
| Sleep tab | ✅ | UI built; populated from historical sync |
| Steps counter (iOS) | ✅ | CMPedometer live step count in BLEManager.dailySteps |
| Historical batch sync | ⚠️ | Protocol confirmed; batch chunks received; data extraction WIP (see below) |
| HealthKit: steps, sleep | ✅ | Auth added; written when historical sync yields data |
| Clear sleep + re-sync | ✅ | Settings button — clears UserDefaults + HealthKit entries |

---

## Directory Structure

```
Sources/
  WhoopBLEApp.swift
  BLE/
    BLEManager.swift       — CBCentral + delegate, @MainActor ObservableObject
    CRCCalculator.swift    — CRC-32 + command builder
    PacketDecoder.swift    — decodes EVENTS_FROM_STRAP → WhoopMetrics
    SyncManager.swift      — historical batch sync state machine
  Health/
    HealthKitWriter.swift  — HR, HRV, steps, sleep HealthKit writes + deleteSleepSamples()
  Models/
    WhoopMetrics.swift     — WhoopMetrics + AccelerometerSample + HistoricalSample + SleepSession
  Processing/
    StepDetector.swift     — IIR filter + peak detection from AccelerometerSample
    SleepDetector.swift    — rolling-window HR → SleepSession[] (HR-only when no accel)
    LiveSleepMonitor.swift — real-time sleep onset/wake detection from live HR
  Views/
    ContentView.swift      — TabView: Live + Sleep tabs
    DashboardView.swift    — zone ring, sparkline, stats bar, sync status
    SleepView.swift        — sleep session list
    SettingsView.swift     — BLE debug + "Clear Sleep Data & Re-sync" action
Resources/Assets.xcassets/
project.yml                — xcodegen spec (source of truth)
```

---

## WHOOP 4.0 BLE Protocol — CONFIRMED on Device

### Services & Characteristics
| Short UUID | Role |
|---|---|
| 61080002 | CMD_TO_STRAP — write commands |
| 61080003 | CMD_FROM_STRAP — command ACKs (0xfc type) |
| 61080004 | EVENTS_FROM_STRAP — live HR packets (0x57, 0xab, 0x52) |
| 61080005 | DATA_FROM_STRAP — historical batch chunks + live 0xff packets |
| 0x180D/0x2A37 | Standard BLE HR — live HR + RR intervals (primary source) |
| 0x180F/0x2A19 | Battery Service |

### Enable Commands (sent to CMD_TO_STRAP after EVENTS subscription)
```
enableHealth:      [0xaa, 0x08, 0x00, 0xa8, 0x23, 0x70, 0x03, 0x01] + CRC
enableHRBroadcast: [0xaa, 0x08, 0x00, 0xa8, 0x23, 0x70, 0x0E, 0x01] + CRC
(0x03, 0x02):      [0xaa, 0x08, 0x00, 0xa8, 0x23, 0x70, 0x03, 0x02] + CRC — required at +5s
```

### Sync Protocol (CONFIRMED: batches arrive, chunks received)

**Trigger command** (two formats — old 8-byte format confirmed working):
```
old: aa 08 00 a8 23 70 16 00 [CRC-xorOut=0x6971BE68]  ← confirmed works
new: aa 10 00 57 23 70 16 00 00 00 00 00 00 00 00 00 [CRC-xorOut=0xF43F44AC]  ← per repo, unverified
```

**Batch ACK** — arrives on DATA_FROM_STRAP (bytes[3]=0xab):
```
aa 1c 00 ab 31 [counter] [02] [unix_ts 4B LE @7] [6B ??] [batch_id 4B LE @17] ...
```
Offsets `ts=7`, `batchID=17` — consistent with chunk IDs arriving (batch 289 confirmed).

**Batch Request** — sent to CMD_TO_STRAP:
```
aa 10 00 57 23 70 17 01 [batch_id 4B LE] 00 00 00 00 [CRC-xorOut=0xF43F44AC]
```

**Chunk packets** — arrive on DATA_FROM_STRAP:

| Type | Size | Routing |
|---|---|---|
| **0xa1** | **104 bytes** | **Confirmed batch history chunks** |
| 0xf0 | 96 bytes | Documented by repo (not seen on this device yet) |
| 0xff | 28 bytes | Live HR packet (also routes to sync during backfill) |

### 0xa1 Chunk Layout (104 bytes) — CONFIRMED

```
[0-3]   aa 64 00 a1          — header / type
[4-5]   2f 18                — subtype constant
[6]     ??                   — constant (0x05 seen)
[7]     packet counter       — increments per chunk (aa, ab, ac …)
[8-10]  ??                   — unknown 3 bytes (same across chunks in batch)
[11]    chunk sequence       — absolute position in batch (e.g. 0x24=36, 0x25=37)
[12-20] ??                   — unknown (may include timestamp — unresolved)
[21]    HR BPM               — confirmed incrementing 75→76 between consecutive chunks
[22]    RR count             — (01→02 observed)
[23-26] RR intervals         — 2 bytes LE each (0x02f7=759ms — valid RR)
[27+]   sensor/PPG payload   — unknown
[100-103] CRC-32             — last 4 bytes
```

**Timestamp in 0xa1**: NOT YET DETERMINED. No 4-byte LE sequence in observed packets
resolves to a valid recent Unix timestamp. Current approach: use batch ACK unix ts as
anchor + chunkSeq offset.

### EVENTS_FROM_STRAP Live Packets (0x57, dominant)
```
[0]     0xaa
[1]     payload length
[2]     0x00
[3]     type (0x57)
[4-7]   WHOOP internal timestamp (LE UInt32, device epoch — NOT Unix)
[8-9]   metric1 (UInt16 LE) — purpose unknown; TODO: test if it's WHOOP step count
[10]    HR BPM
[11]    RR count (capped at 4)
[12+]   RR intervals (2 bytes each, ms)
```

---

## CRC Parameters
```
Poly: 0x4C11DB7  (right-shift form: 0xEDB88320)
Init: 0x0
Reflect input + output: true
Three xorOut variants by header:
  aa 08 00 a8 23  →  0x6971BE68   (8-byte commands)
  aa 10 00 57 23  →  0xF43F44AC   (16-byte commands, batch requests)
  aa 18 00 ff 28  →  0xE02CCD0E   (28-byte DATA packets)
```

---

## Sync State Machine (SyncManager.swift)

```
onConnected() +5s → send syncTrigger
    ↓
0xab batch ACK arrives:
    parseBatchAck → activeBatchTimestamp = batchAckUnixTs
                  → skip if in processedBatches
                  → queue batchID → downloadNextBatchIfIdle()

downloadNextBatchIfIdle → send buildBatchRequest(batchID)
    ↓
0xa1 chunks arrive:
    receiveChunk → append to activeChunks
    [3s idle timer] → finalizeBatch()
        → parseChunk(0xa1): hr=bytes[21], ts=batchTs+chunkSeq
        → SleepDetector → HealthKit sleep write
        → markProcessed(batchID) → UserDefaults persist
        → syncedBatchCount += 1
```

**CRITICAL: `markProcessed` is called even when samples are empty** (empty guard path).
After any sync attempt (even broken), batches are persisted. To re-run:
use Settings → "Clear Sleep Data & Re-sync" which calls `clearAllSleepData()`.

---

## Known Issues / Open Questions

| Issue | Status |
|---|---|
| 0xa1 timestamp field unknown | Using batchACK ts + chunkSeq offset (approximate) |
| syncedBatchCount shows 0 if samples empty | Fixed: now logs exactly which guard failed |
| Sleep detection needs multiple hours of data | Single batch = ~minutes; need full night batch |
| metric1 at bytes[8-9] of 0x57 events unknown | TODO: walk test to check if it's step counter |
| 0xf0 (96B) chunks not seen on device | May not exist on this firmware; 0xa1 is actual format |
| RR from 0xa1 available but not used yet | bytes[22]=count, bytes[23+]=intervals |

---

## Next Steps (Priority Order)

1. **Verify sleep detection works** — after clear+resync with 0xa1 fix, check sleep sessions
2. **Resolve 0xa1 timestamp** — add debug print of full packet + compare to batch ACK ts
3. **metric1 investigation** — walk test, see if bytes[8-9] of EVENTS increments with steps
4. **Extract RR intervals from 0xa1** — add to HistoricalSample for HRV history
5. **SpO2 / resp rate** — probe DATA_FROM_STRAP with additional commands

---

## Build Notes

- **Never edit `.xcodeproj`** — edit `project.yml` → `xcodegen generate`
- Swift 6 strict concurrency: BLE callbacks `nonisolated`, UI via `Task { @MainActor }`
- `nonisolated(unsafe)` for CBCharacteristic refs (BLE queue — safe by convention)
- Charts framework is system on iOS 16+ — no extra dependency
