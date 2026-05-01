# WhoopBLE — Next Steps

## Just shipped (validate first)
1. **Move ring fix** — continuous MET curve, weight setting, Watch suppression. Wear strap on a watch-off day; confirm Active Energy in Health from "WhoopBLE" accumulates during sedentary HR (70–95 BPM). Compare day total to ~400–800 kcal.
2. **Sleep rewrite (staged)** — DEEP/CORE/REM/AWAKE samples written per session. After a night, check Health → Sleep shows one staged session, not fragments.
3. **Exercise ring via HKWorkout** — brisk activity ≥1 min per 3-min window writes a `.other` workout. After a walk, confirm workout entry in Health and Exercise ring fills.

If any of those misbehave, fix before adding new features.

## P1 (next concrete tasks)

### Task 1 — Batch cursor reset (sync old data while disconnected)
File: `Sources/BLE/CRCCalculator.swift` + `SyncManager.swift`.
Symptom: after one successful sync, reconnects yield `0xfc data=0` even after wiping `whoopSyncedBatches`.
Hypotheses to test, **one at a time**, logging strap response each time:
  - Send `syncTrigger` with non-zero data byte (try 0x01..0x05) — possibly "resync from N".
  - Try `buildBatchRequest(batchID:)` for IDs below `minBatchID` ever seen.
  - Try category 0x16 with status byte alternates (0x01, 0x03).
  - Reverse-engineer: install Wireshark + nRF Connect, capture official WHOOP app re-fetching old data, diff packet headers.
If protocol resists: add a UI banner explaining the limitation; do not pretend it works.

### Task 2 — Daily HRV from history
File: `Sources/Processing/DayRecomputer.swift`.
`HistoricalSample.rrIntervals` is now populated (last session, via 0xa1 bytes 22-26). Wire `DayRecomputer.computeHRV` to consume it: collect all RR across the day, compute RMSSD on the lowest 10-min trailing window during sleep (per master plan §2.2). Persist to `DailyMetricsStore`.

### Task 3 — Recovery Score
New file: `Sources/Processing/RecoveryScore.swift`. Master plan §3.2.
Inputs: today's HRV, RHR, sleep duration, yesterday's strain. Baselines: 30-day rolling means + std from `DailyMetricsStore`.
Formula: `0.4 * HRV_z + 0.25 * RHR_z + 0.25 * Sleep_z - 0.1 * Strain_z`, mapped 0–100.
Show on `DashboardView` as a ring next to HR.

### Task 4 — 30-day baselines
File: `Sources/Processing/DailyMetricsStore.swift`.
Add: `func rollingBaseline(metric: String, days: Int) -> (mean: Double, std: Double)?`. Used by Recovery Score.

## P2 (after P1)
- **Stress indicator** (master plan §3.4): real-time HR elevation + HRV suppression on `DashboardView`.
- **Activity sessions** (master plan §9.4): start/stop on connection events, persist to disk, show in Trends. Mark `partial` on disconnect.
- **DATA stream watchdog** (§9.3): if DATA_FROM_STRAP silent > 30s after activity start, surface UI warning.
- **CRC retry + rate-limit** (§9.1–§9.2): FIFO command queue, 200ms throttle, retry across header variants on first failure.

## P3 (research, low priority)
- 0x57 byte[10] = 228 mystery: scope live to a known resting state, dump full 32 B packet, look for HR fields.
- Enable r19 / sigproc_* string commands to unlock extended data.
- 36 B / 12 B EVENTS alternate formats.

## Hard constraints (project rules)
- Never edit `.xcodeproj`. Edit `project.yml`, run `xcodegen generate`.
- Phase-gate: stop after each deliverable, wait for user device test.
- Don't bypass HealthKit auth — every new type needs `share` set update.
- `appleExerciseTime` is read-only on iOS. Use HKWorkout.
- iOS 16 deployment target, Swift 6 strict concurrency.

## Files most touched last session (2026-05-01)
- `Sources/Models/WhoopMetrics.swift` (SleepStage, segments, rr in HistoricalSample)
- `Sources/Processing/SleepDetector.swift` (full rewrite)
- `Sources/BLE/SyncManager.swift` (parseChunk RR, weight from defaults)
- `Sources/BLE/BLEManager.swift` (MET curve, weight, Watch suppression, Exercise sec, HKWorkout)
- `Sources/Health/HealthKitWriter.swift` (watchEnergyActiveRecently, writeWorkout, staged sleep)
- `Sources/Views/SettingsView.swift` (Profile/weight)
