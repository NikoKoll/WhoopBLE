# WhoopBLE — Handoff V7
**Date:** 2026-04-28  
**Status:** Phase 2 complete. Phase 3 items identified below.

---

## What Was Built (Sessions Since V6)

### 1. Sleep Detection Fix — Accumulate Across All Batches
**Problem:** `SleepDetector` ran per-batch in `finalizeBatch`. Each batch has ~minutes of data; sleep detection needs 7+ hours. Result: zero sessions detected.  
**Fix:** `SyncManager` now accumulates `HistoricalSample` from every batch into `accumulatedSamples: [HistoricalSample]`. `runSleepDetectionIfDone()` called at all 5 `isSyncing = false` sites, runs `SleepDetector` once on the sorted full corpus.  
**Timestamp filter added:** Samples with timestamp < 2023-01-01 (Unix 1_672_531_200) dropped — guards against bogus pre-2023 timestamps from miscalculated WHOOP epoch offsets.

### 2. Batch Sync — 0xfc ACK Parsing + Probe
**Problem:** Sync trigger sent, strap responded with 0xfc ACK saying "11 batches available" but no 0xab batch ACKs followed. SyncManager timed out after 20 s.  
**Findings:**
- 0xfc packets on CMD_FROM_STRAP are per-command ACKs: `byte[6]` = echoed command category, `byte[9]` = data (batch count for category 0x16)
- Strap ACKs sync trigger (cmd_echo=0x16) with batch count in byte[9]
- No 0xab batch ACKs arrive because strap tracks delivery per connection — prior sessions consumed the batches
**Fix:** `SyncManager.parseCommandAck()` now handles 0xfc; when cmd_echo=0x16 and batch_count > 0, sends `buildBatchRequest(batchID: 0)` as a probe. Timeout extended 20 s → 60 s.  
**Status:** Speculative; may trigger batch stream in some firmware versions.

### 3. MetricsStore — Persistent HR/HRV/Steps
New `Sources/BLE/MetricsStore.swift`:
- `Entry`: timestamp, heartRate, hrv? — saved every 30 s, 7-day rolling retention
- `DailySteps`: steps per calendar day — permanent retention
- Two JSON files in Documents: `metrics_history_v1.json`, `steps_history_v1.json`
- Background `Task.detached` writes (never blocks MainActor)
- `record()` called from `BLEManager.acceptMetrics` with freshly computed RMSSD
- `setTodaySteps()` called from both CMPedometer callbacks in `startPedometer()`
- `addHistoricalSteps()` called from `SyncManager.finalizeBatch` (always 0 today — no accel in 0xa1)

### 4. TrendsView — 3rd Tab
New `Sources/Views/TrendsView.swift`:
- Today / 7 Days segmented picker
- Today: Steps tile, HR area+line chart, HRV line chart (all 24h from MetricsStore)
- Week: Daily avg HR bar chart, daily avg HRV area chart, daily steps bar chart, summary stats row
- Dark-correct: `.chartBackground { _ in Color.clear }` + `.chartPlotStyle { $0.background(Color.clear) }` on all charts
- `@ObservedObject` on MetricsStore directly — re-renders on new entries
- Passed from ContentView as `TrendsView(store: ble.metricsStore)`

---

## Architecture State (Current)

```
BLEManager (@MainActor ObservableObject)
├── syncManager: SyncManager          — batch download + sleep detection
├── metricsStore: MetricsStore        — 7-day persistence
├── healthKit: HealthKitWriter        — HealthKit writes
├── liveSleep: LiveSleepMonitor       — real-time sleep state machine
├── pedometer: CMPedometer            — live daily step count
└── hrHistory, rrBuffer, smoothedHR/HRV — session-lifetime in-memory

ContentView (TabView: 3 tabs)
├── DashboardView       — live metrics (@EnvironmentObject BLEManager)
├── SleepView           — sleep sessions (@ObservedObject SyncManager)
└── TrendsView          — charts (@ObservedObject MetricsStore)
```

---

## Open Issues / Phase 3 Work

### P1 — Batch Delivery Reset (Blocker for historical sleep)
The strap marks batches as delivered per client. Once delivered, won't resend.  
Our `clearAllSleepData()` clears our processed-batch set but NOT the strap's cursor.  
**Options to investigate:**
- Find a "reset delivery cursor" BLE command (undocumented)
- Try `buildBatchRequest(batchID: 0xFFFFFFFF)` or other sentinel IDs
- Reverse engineer strap firmware response to clear state
- Accept limitation: only capture new history going forward after first sync

### P2 — 0xa1 Timestamp Resolution
Current approach: `batchTs - (maxSeq - chunkSeq)` seconds. This gives relative ordering but absolute accuracy depends on batch ACK timestamp being reliable.  
To verify: compare 0xa1 HR values against known activity (walk, workout) and check if timestamps place that activity at the correct time of day.

### P3 — Live HR from EVENTS 0x57
EVENTS packets currently show hr_raw=228 (out of 30–220 guard, rejected).  
The standard 0x2A37 path works. If 0x2A37 ever becomes unavailable, need to understand why 0x57 byte[10] = 0xe4 on this firmware.

### P4 — metric1 at EVENTS bytes[8-9]
16-bit LE field, consistent value ~6945 observed. Hypothesis: WHOOP step counter.  
Test: walk 100 steps, observe if value changes by ~100.

### P5 — SpO2 / Resp Rate
WHOOP 4.0 has SpO2 sensor. No known characteristic for it yet. Could be in a yet-undiscovered service or requires a specific enable command.

---

## Deployment Checklist
```bash
xcodegen generate
xcodebuild -scheme WhoopBLE -destination 'generic/platform=iOS' build
# Verify: BUILD SUCCEEDED, zero errors
open WhoopBLE.xcodeproj  # Cmd+R to device
```

Test matrix after deploy:
1. Live: HR ring updates, HRV shows after 4+ valid RR intervals
2. Battery: % shows in top-right of dashboard
3. Trends Today: connect, wait 30 s, check HR chart has a point
4. Trends Week: check steps bar if pedometer data available
5. Sleep: connect, wait for sync banner, check Sleep tab
6. Settings → Clear: clears sleep sessions + forces re-sync on next connect
