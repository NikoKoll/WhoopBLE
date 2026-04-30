# WhoopBLE — Claude Project Guide

## What This Is
Native SwiftUI iOS app that reads live biometrics from a WHOOP 4.0 strap over CoreBluetooth, bypassing the subscription gate (100% app/server-side — strap streams data unconditionally to any authorized client).

## Build & Deploy
```bash
cd /Users/nikolaskollias/WhoopBLE
xcodegen generate          # regenerates WhoopBLE.xcodeproj from project.yml
open WhoopBLE.xcodeproj    # then Cmd+R in Xcode to deploy to iPhone
```
- Bundle ID: `com.personal.WhoopBLE`
- Team: `2Z848WW3KQ`
- Swift 6.0 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- Deployment target: iOS 16.0

**Never edit `.xcodeproj` directly — always edit `project.yml` and run `xcodegen generate`.**

## Directory Layout
```
Sources/
  WhoopBLEApp.swift                 — @main, creates BLEManager as @StateObject
  BLE/
    BLEManager.swift                — CoreBluetooth central + peripheral delegate, @MainActor
    CRCCalculator.swift             — reflected CRC-32 + all command builders
    PacketDecoder.swift             — decodes EVENTS_FROM_STRAP packets → WhoopMetrics
    SyncManager.swift               — historical batch download orchestrator, sleep detection
    MetricsStore.swift              — persistent HR/HRV/steps storage (7-day, JSON files)
  Models/
    WhoopMetrics.swift              — WhoopMetrics, HistoricalSample, SleepSession structs
  Processing/
    SleepDetector.swift             — batch sleep detection (10-min windows, HR signal)
    LiveSleepMonitor.swift          — real-time sleep detection (state machine + CoreMotion)
    StepDetector.swift              — IIR filter + peak detection for accel steps
  Health/
    HealthKitWriter.swift           — writes HR, HRV, steps, sleep to HealthKit
  Views/
    ContentView.swift               — 3-tab root (Live / Sleep / Trends)
    DashboardView.swift             — dark HR ring, HRV, sparkline, steps, sync banner
    SleepView.swift                 — sleep session list with quality colour coding
    TrendsView.swift                — 7-day HR/HRV/steps charts (MetricsStore-backed)
    SettingsView.swift              — clear/resync button
Resources/Assets.xcassets/
project.yml                         — xcodegen spec (source of truth)
```

## WHOOP 4.0 BLE Protocol (Reverse Engineered)

### Services & Characteristics
| Short UUID | Role |
|---|---|
| `61080001` | Main WHOOP service |
| `61080002` CMD_TO_STRAP | Write (no-response) — send enable/sync commands |
| `61080003` CMD_FROM_STRAP | Notify — 0xfc ACK/NACK per command sent |
| `61080004` EVENTS_FROM_STRAP | Notify — live HR stream (0x57 dominant at ~1 Hz) |
| `61080005` DATA_FROM_STRAP | Notify — historical batch chunks (0xa1, 0xff, 0xf0) |
| `61080007` MEMFAULT | Notify — crash reports, ignored |
| `180D` / `2A37` | Standard BLE HR Service — activated by enableHRBroadcast |
| `180F` / `2A19` | Standard BLE Battery Service |

### Command ACK format (0xfc on CMD_FROM_STRAP)
```
aa 0c 00 fc 24 [seq] [cmd_echo] 70 [status] [data] ...
```
- `cmd_echo` mirrors the category byte of the command we sent
- For sync trigger (cmd_echo=0x16): `data` byte = batch count available on strap
- status=0x02 = success

### Enable Sequence (triggered once EVENTS subscription confirms)
```
1. enableHealth      aa 08 00 a8 23 70 03 01 [CRC]   — starts HR stream
2. enableHRBroadcast aa 08 00 a8 23 70 0e 01 [CRC]   — activates 180D/2A37 if supported
3. +5s: buildCommand(0x03, 0x02)                      — required; silence without it
4. +5s: syncTrigger  aa 08 00 a8 23 70 16 00 [CRC]   — starts historical batch enumeration
```
CRC: reflected CRC-32, poly=0xEDB88320, init=0x0, xorOut depends on header prefix:
- `[aa 08 00 a8 23]` → 0x6971BE68
- `[aa 10 00 57 23]` → 0xF43F44AC
- `[aa 18 00 ff 28]` → 0xE02CCD0E

Heartbeat: `enableHealth` re-sent every 10 s to keep stream alive.

### EVENTS_FROM_STRAP Packet Layout (0x57 / 0xab / 0x52)
| Offset | Field |
|---|---|
| [0] | 0xaa sync |
| [1] | payload length |
| [3] | type (0x57 / 0xab / 0x52) |
| [4-7] | WHOOP internal clock (NOT Unix epoch) |
| [8-9] | metric1 — unknown; was misidentified as HR |
| **[10]** | **Heart Rate BPM** |
| [11] | RR count (capped at 4) |
| [12+] | RR intervals, UInt16 LE ms |

Note: byte[10] HR on 0x57 was observed as 0xe4=228 (rejected by 30–220 guard). Real HR comes from standard BLE 0x2A37 characteristic when present — that path is preferred.

### DATA_FROM_STRAP Batch Sync

**Sync flow:**
1. Send `syncTrigger` → strap ACKs with 0xfc; byte[9] = N batches available
2. Send `buildBatchRequest(batchID: 0)` probe → strap may push 0xab batch ACKs
3. Each 0xab ACK contains a batch_id; SyncManager requests each via `buildBatchRequest(id)`
4. Strap streams 0xa1 chunks (104 B each) for the requested batch

**0xa1 chunk layout (104 bytes):**
```
[0-3]   aa 64 00 a1   — header
[11]    chunk sequence within batch (absolute index)
[21]    HR BPM (CONFIRMED: observed live values)
[22]    RR count
[23-26] RR intervals (UInt16 LE, ms)
[100-103] CRC-32
```
Timestamp strategy: batch ACK unix ts (= batch end time) − (maxSeq − chunkSeq) seconds.

**Batch request command (16 bytes):**
```
aa 10 00 57 23 70 17 01 [batch_id 4B LE] [00 00 00 00] [CRC]
```

**Batch ACK (0xab) layout on DATA_FROM_STRAP:**
```
aa 1c 00 ab 31 [counter] 02 [unix_ts 4B LE @7] [6B ??] [batch_id 4B LE @17]
```

### Known Protocol Limitations
- Strap tracks delivery per client — once batches delivered, won't resend until new data accumulates. Our `processedBatches` clear does NOT reset strap-side cursor.
- 0xa1 chunks carry NO accelerometer data → StepDetector always returns 0 for historical.
- RR intervals in EVENTS packets often invalid (<300 ms) → live HRV sparse.
- 0xa1 timestamp field unresolved; batch-ACK-anchored approximation used.

## Data Flow Summary
```
WHOOP Strap
  → BLE notify (0x2A37)         → BLEManager.acceptMetrics → DashboardView
  → BLE notify (EVENTS 0x57)    → PacketDecoder → BLEManager.acceptMetrics
  → BLE notify (DATA 0xa1)      → SyncManager.finalizeBatch → SleepDetector
  → BLE notify (CMD 0xfc)       → SyncManager.parseCommandAck

BLEManager.acceptMetrics
  → hrHistory (60-sample ring)
  → rrBuffer → RMSSD/HRV
  → MetricsStore.record()       → Documents/metrics_history_v1.json
  → HealthKitWriter.write()     → HealthKit HR + HRV
  → LiveSleepMonitor.observe()  → real-time sleep detection

CMPedometer
  → BLEManager.dailySteps
  → MetricsStore.setTodaySteps() → Documents/steps_history_v1.json

SyncManager (per-batch)
  → HealthKitWriter.writeHistoricalSamples()
  → MetricsStore.addHistoricalSteps()
  → accumulatedSamples buffer

SyncManager (sync complete)
  → SleepDetector.process(all samples) → HealthKitWriter.writeSleep()
  → SyncManager.sleepSessions → SleepView
```

## Persistence
| File | Contents | Retention |
|---|---|---|
| `UserDefaults whoopSyncedBatches` | processed batch IDs (Set<UInt32>) | permanent |
| `UserDefaults whoopSleepSessions_v1` | SleepSession JSON array | permanent |
| `Documents/metrics_history_v1.json` | HR/HRV Entry array | 7 days rolling |
| `Documents/steps_history_v1.json` | DailySteps array | permanent |

## Current Status
- **Phase 1 COMPLETE**: Live HR, HRV, battery, HealthKit, dark dashboard, auto-reconnect
- **Phase 2 COMPLETE**: Historical batch sync, sleep detection, HealthKit sleep writes, Settings clear/resync, Trends dashboard (HR/HRV/steps charts, 7-day persistence)
- **Phase 3 OPEN**: Batch delivery cursor reset (strap-side), resolve 0xa1 timestamp, batch probe reliability

## Known Issues
- Batch sync often yields 0 batches if strap already delivered them in a prior session — user must wear strap and reconnect after new history accumulates
- `buildBatchRequest(batchID: 0)` probe is speculative — sometimes triggers batch stream, sometimes ignored
- Live HR from 0x57 EVENTS currently rejected (hr_raw=228 out of range); actual HR read from standard 0x2A37 only
- metric1 bytes[8-9] in 0x57 packets — purpose unknown

## Phase Gate Rule
Stop after each deliverable and wait for user to test on device before starting next.
