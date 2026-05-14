# WhoopBLE

A native SwiftUI iOS app that connects directly to a **WHOOP 4.0** strap over Bluetooth Low Energy and streams live biometrics — heart rate, HRV, RR intervals, SpO₂, respiratory rate, battery, wrist-on state — without going through the official WHOOP app or subscription service.

The strap itself broadcasts all of this data unconditionally to any authorized BLE client. The subscription gate lives entirely on WHOOP's app/server side. This project demonstrates that by talking to the device directly.

---

## ⚠️ Educational / Research Disclaimer

**This project is published strictly for educational and personal research purposes.**

It exists to document the BLE behavior of a device the author legally owns, to learn about reverse engineering of consumer wearables, signal processing, and physiological modeling, and to share that knowledge with the security/quantified-self community.

- Do **not** use this project to redistribute WHOOP's services, resell data, circumvent paid features for commercial gain, or infringe on any trademarks/IP.
- WHOOP is a trademark of WHOOP, Inc. This project is **not affiliated with, endorsed by, or sponsored by WHOOP, Inc.** in any way.
- All protocol details below were obtained by passively observing BLE traffic from a strap the author owns. No firmware was extracted, modified, or redistributed. No accounts or servers were attacked.
- The app is provided **as-is, with no warranty**. Biometric numbers it produces are **not medical-grade** and must not be used for diagnosis or treatment.
- If you are a WHOOP rights-holder and want something changed or removed, open an issue.

By cloning, building, or running this code, you agree to use it responsibly and at your own risk.

---

## What It Does

- Connects to a WHOOP 4.0 strap over CoreBluetooth as a BLE central
- Decodes the proprietary event stream to surface live HR, HRV (RMSSD), RR intervals, SpO₂, respiratory rate, wrist-on state, and battery
- Downloads historical batch data accumulated on the strap while it was off-body or offline
- Detects sleep sessions (both live, via a state machine + CoreMotion, and batch, via HR-signal windowing)
- Computes derived metrics — recovery score, day strain, sleep need, ATL/CTL load, circadian phase, physiological capacity
- Writes HR, HRV, SpO₂, steps, sleep stages, and workouts to **HealthKit**
- Presents everything in a dark SwiftUI dashboard with a 3-ring (Sleep / Strain / Recovery) summary, live tiles, and 7-day trend charts

---

## Build

```bash
git clone <this repo>
cd WhoopBLE
xcodegen generate           # regenerates WhoopBLE.xcodeproj from project.yml
open WhoopBLE.xcodeproj     # Cmd+R in Xcode to deploy to your iPhone
```

Requirements:

- Xcode 16+
- iOS 16.0+ deployment target
- Swift 6.0 with strict concurrency
- An Apple developer signing identity (update `Team` in `project.yml`)
- A WHOOP 4.0 strap you own and have already paired/registered once

> Never edit `.xcodeproj` directly — always edit `project.yml` and re-run `xcodegen generate`.

---

## Architecture

```
Sources/
  WhoopBLEApp.swift          @main, owns BLEManager as @StateObject
  BLE/
    BLEManager.swift         CoreBluetooth central, @MainActor, command pipeline + heartbeat
    CRCCalculator.swift      Reflected CRC-32 + all command builders
    PacketDecoder.swift      EVENTS_FROM_STRAP packet parsing → WhoopMetrics
    SyncManager.swift        Historical batch download orchestrator
    MetricsStore.swift       7-day HR/HRV/steps persistence
  Models/
    WhoopMetrics.swift       Live + historical sample structs
  Processing/
    SleepDetector.swift          Batch sleep detection (HR-window state machine)
    LiveSleepMonitor.swift       Real-time sleep state machine + CoreMotion
    StepDetector.swift           IIR filter + peak detection
    BiologicalDay.swift          Wake-anchored day boundaries
    CircadianEngine.swift        Light/HR-driven phase estimator
    EnhancedRecoveryScore.swift  Recovery score from HRV / RHR / sleep
    SleepNeedCalculator.swift    Sleep debt + need projection
    RespiratoryAggregator.swift  Respiratory rate via RSA from RR series
    PhysiologicalDynamics.swift  ATL/CTL load + capacity modeling
    DayRecomputer.swift          End-of-day rollup pipeline
    RecomputeQueue.swift         Serialized recompute jobs
    FeatureCache.swift           Cached derived features per bio-day
    DailyMetricsStore.swift      Per-bio-day snapshot persistence
  Health/
    HealthKitWriter.swift    HR, HRV, SpO₂, steps, sleep, workouts
  Views/
    ContentView.swift        3-tab root (Live / Sleep / Trends)
    DashboardView.swift      3-ring summary, live tiles, sparkline
    SleepView.swift          Sleep session list + stage breakdown
    TrendsView.swift         7-day charts
    SettingsView.swift       Clear/resync, HealthKit audit
project.yml                  xcodegen spec (source of truth)
```

---

## Reverse Engineering Notes

Everything below was obtained by sniffing live BLE traffic from a strap the author owns (LightBlue, Xcode CoreBluetooth logs, packet diffing across known physiological states) and confirming each field against ground truth — the official WHOOP app and a chest-strap reference HR monitor.

### Services & Characteristics

| Short UUID | Role |
|---|---|
| `61080001` | Main WHOOP service |
| `61080002` CMD_TO_STRAP | Write (no-response) — send enable / sync commands |
| `61080003` CMD_FROM_STRAP | Notify — `0xfc` ACK / NACK per command |
| `61080004` EVENTS_FROM_STRAP | Notify — live event stream (`0x57` HR ~1 Hz dominant) |
| `61080005` DATA_FROM_STRAP | Notify — historical batch chunks (`0xa1`, `0xff`, `0xf0`) |
| `61080007` MEMFAULT | Notify — crash reports, ignored |
| `180D` / `2A37` | Standard BLE HR Service — activated by `enableHRBroadcast` |
| `180F` / `2A19` | Standard BLE Battery Service |

### Enable Sequence

Triggered once the central confirms subscription to EVENTS_FROM_STRAP:

```
1. enableHealth        aa 08 00 a8 23 70 03 01 [CRC]   starts HR stream
2. enableHRBroadcast   aa 08 00 a8 23 70 0e 01 [CRC]   activates 180D/2A37
3. +5s buildCommand(0x03, 0x02)                         required; stream stays silent otherwise
4. +5s syncTrigger     aa 08 00 a8 23 70 16 00 [CRC]   enumerates historical batches
```

Heartbeat: `enableHealth` is re-sent every 10 s to keep the stream alive.

### CRC-32

Reflected CRC-32, polynomial `0xEDB88320`, init `0x0`. **xorOut varies by header prefix** — this was the single biggest gotcha during reversing; V1 of the code used the wrong polynomial entirely and broke sync silently.

| Header prefix | xorOut |
|---|---|
| `aa 08 00 a8 23` | `0x6971BE68` |
| `aa 10 00 57 23` | `0xF43F44AC` |
| `aa 18 00 ff 28` | `0xE02CCD0E` |

### Command ACK (`0xfc` on CMD_FROM_STRAP)

```
aa 0c 00 fc 24 [seq] [cmd_echo] 70 [status] [data] ...
```

- `cmd_echo` mirrors the category byte of the command sent
- For the sync trigger (`cmd_echo = 0x16`): `data` byte = batch count available on strap
- `status = 0x02` → success

### EVENTS_FROM_STRAP Packet Layout (`0x57` / `0xab` / `0x52`)

| Offset | Field |
|---|---|
| `[0]` | `0xaa` sync byte |
| `[1]` | payload length |
| `[3]` | type (`0x57` / `0xab` / `0x52`) |
| `[4..7]` | WHOOP internal clock (**not** Unix epoch) |
| `[8..9]` | `metric1` — purpose still unknown; previously misidentified as HR |
| `[10]` | **Heart rate (BPM)** — frequently out-of-range on `0x57`; prefer standard `0x2A37` when both are available |
| `[11]` | RR-interval count (capped at 4) |
| `[12+]` | RR intervals, UInt16 LE, milliseconds |

Other event subtypes decoded along the way:

- `0x35` — wrist-on / off-body state (specific bit layout still being verified; wrist gate was removed from the sleep state machine because false negatives blocked overnight onset)
- `0x69` — IMU / accelerometer block during historical playback
- `0x0f` — present but not yet decoded
- SpO₂ and respiratory rate are derived in software — SpO₂ from a dedicated event field, respiratory rate from the RSA component of the RR-interval time series

### Historical Batch Sync (DATA_FROM_STRAP)

The strap stores blocks of data when it cannot stream live. Each block ("batch") has an integer ID and must be requested explicitly.

Sync flow:

1. Send `syncTrigger` → strap ACKs with `0xfc`, where `byte[9]` is the number of batches available.
2. Send `buildBatchRequest(batchID: 0)` as a probe → strap typically responds by pushing `0xab` batch-ACK announcements.
3. Each `0xab` ACK contains a `batch_id`. The client requests each one via `buildBatchRequest(id)`.
4. The strap streams `0xa1` chunks (104 bytes each) for the requested batch until it is complete.

**Batch request command (16 bytes):**

```
aa 10 00 57 23 70 17 01 [batch_id 4B LE] [00 00 00 00] [CRC]
```

**Batch ACK (`0xab`) layout on DATA_FROM_STRAP:**

```
aa 1c 00 ab 31 [counter] 02 [unix_ts 4B LE @7] [6B ??] [batch_id 4B LE @17]
```

The Unix timestamp in the ACK marks the batch's **end** time, not its start.

**`0xa1` chunk layout (104 bytes):**

| Offset | Field |
|---|---|
| `[0..3]` | `aa 64 00 a1` header |
| `[11]` | Chunk sequence index within batch (absolute) |
| `[21]` | HR (BPM) — confirmed against live values |
| `[22]` | RR-interval count |
| `[23..26]` | RR intervals, UInt16 LE, milliseconds |
| `[100..103]` | CRC-32 |

Per-chunk timestamps are reconstructed as `batch_end_ts − (maxSeq − chunkSeq)` seconds. The chunk's own embedded timestamp field has not been resolved.

### Known Protocol Limitations

- **Delivery cursor is strap-side.** The strap tracks per-client batch delivery and will not resend a batch once it considers it delivered, even if the client crashed before persisting it. Clearing local `processedBatches` does **not** reset the strap-side cursor.
- **No accelerometer in `0xa1` chunks.** Historical step counts are therefore always zero; live step counts come from `CMPedometer`.
- **RR intervals in live EVENTS packets are sparse and frequently invalid (<300 ms)**, so live HRV is much noisier than overnight HRV computed from batch data.
- **Live HR on `0x57` events is unreliable** in this firmware version (often pinned to 228), so the standard `0x2A37` characteristic is preferred whenever it is advertised.
- **`metric1` (`bytes[8..9]`) on `0x57`** still has no confirmed meaning.

---

## Data Flow

```
WHOOP Strap
  ├── BLE notify 0x2A37         → BLEManager.acceptMetrics → DashboardView
  ├── BLE notify EVENTS 0x57    → PacketDecoder → BLEManager.acceptMetrics
  ├── BLE notify DATA 0xa1      → SyncManager.finalizeBatch → SleepDetector
  └── BLE notify CMD  0xfc      → SyncManager.parseCommandAck

BLEManager.acceptMetrics
  → hrHistory (60-sample ring)
  → rrBuffer → RMSSD / HRV
  → MetricsStore.record()                 → Documents/metrics_history_v1.json
  → HealthKitWriter.write()               → HealthKit HR + HRV
  → LiveSleepMonitor.observe()            → real-time sleep state machine

CMPedometer
  → BLEManager.dailySteps
  → MetricsStore.setTodaySteps()          → Documents/steps_history_v1.json

SyncManager (per batch)
  → HealthKitWriter.writeHistoricalSamples()
  → MetricsStore.addHistoricalSteps()
  → accumulatedSamples buffer

SyncManager (sync complete)
  → SleepDetector.process(allSamples)
  → HealthKitWriter.writeSleep()
  → SyncManager.sleepSessions → SleepView
```

---

## Persistence

| Location | Contents | Retention |
|---|---|---|
| `UserDefaults whoopSyncedBatches` | Processed batch IDs (`Set<UInt32>`) | permanent |
| `UserDefaults whoopSleepSessions_v1` | `SleepSession` JSON array | permanent |
| `Documents/metrics_history_v1.json` | HR / HRV entries | 7 days rolling |
| `Documents/steps_history_v1.json` | Daily step counts | permanent |
| `Documents/daily_snapshots/*.json` | Per-bio-day derived metrics | permanent |

---

## Status

- **Phase 1 — Live telemetry** ✅ HR, HRV, battery, HealthKit, dark dashboard, auto-reconnect
- **Phase 2 — Historical sync** ✅ Batch download, sleep detection, HealthKit sleep writes, Trends
- **Phase 3 — Physiological modeling** ✅ Recovery, strain, sleep need, ATL/CTL, circadian phase, respiratory rate, SpO₂
- **Open** 🔬 Batch delivery cursor reset (strap-side), `0xa1` chunk timestamp resolution, `0x0f` packet decode, `0x35` wrist-bit layout confirmation

---

## Contributing

Pull requests welcome, especially for:

- Additional EVENTS subtypes you have decoded against ground truth
- Better signal-processing primitives (HRV artifact rejection, respiratory rate, accel-based stage detection)
- Improvements to the sleep / recovery / strain models
- Bug reports with packet captures attached

Please keep the educational, non-commercial spirit of the project intact.

---

## License

MIT, with the explicit understanding that this is a personal-use educational project. See `LICENSE`.
