# WhoopBLE — Next Steps

## Session 2026-05-03 (continued) — HealthKit Audit + Workout Consolidation + New Reads

### Workout Fragmentation Fix (shipped)
- `WorkoutSessionAggregator.minWorkoutSec` raised 60s → 300s. Workouts under 5 min no longer written.
- Log format updated: `[Workout] session finalized writing single HKWorkout duration=42m energy=384kcal samples=128`
- One call site confirmed: only `WorkoutSessionAggregator.close()` → `HealthKitWriter.writeWorkoutSession()`. Historical batches use `writeActiveEnergy` (not HKWorkout).

### WorkoutMigrator (shipped)
- `Sources/Health/WorkoutMigrator.swift` (NEW) — actor that runs once on first launch (UserDefaults flag `hkWorkoutMigration_v1`).
- Groups this app's HKWorkouts by (local date, activityType). Merges consecutive workouts ≤30 min apart into single workout with summed energy + all linked HR samples.
- Log: `[Migration] consolidated N workout fragments into 1 session for date=... duration=42m energy=384kcal`
- Affected dates re-enqueued for DayRecomputer backfill.
- Called from `BLEManager.refreshCapabilities()` → `WhoopBLEApp.task` (after HK auth, before checkVersionMismatch).

### New HealthKit Reads (shipped)
- Added to `requestAuthorization` read set: `.heartRateVariabilitySDNN`, `.restingHeartRate`, `.respiratoryRate`, `.oxygenSaturation`, `.bodyTemperature`, `.workoutType`
- Auth logging per §10.8: `[HealthKit] authorization granted for: hrv,rhr,resp,spo2,sleep`
- `NSHealthShareUsageDescription` already in Info.plist (covers reads).

### Capability Map §9.11 (shipped)
- `BLEManager` gains `@Published var hkRespRateAvailable`, `hkSpO2Available`, `hkAppleWatchPaired`
- Refreshed via `BLEManager.refreshCapabilities()` on launch (after HK auth).
- New methods on `HealthKitWriter`: `hasRecentSamples(_:lookback:)`, `appleWatchPaired()`.

### Source Fusion — RHR/HRV Fallback (shipped)
- `DayRecomputer.recomputeDay` gains optional `healthKit: HealthKitWriter?` param.
- When Whoop RHR is nil: reads `HKQuantityType(.restingHeartRate)` from HealthKit (±1 day window).
- When Whoop HRV is nil: reads `HKQuantityType(.heartRateVariabilitySDNN)` from HealthKit (±1 day window, ms converted from s).
- Log: `[DayRecomputer] 2026-05-03 RHR from HealthKit fallback=52.0`
- Recompute log shows `[HK fallback]` suffix when fallback was used.
- `RecomputeQueue.configure(healthKit:)` wires HealthKit through to drain.

### Settings HealthKit Access Section (shipped)
- New section in SettingsView shows Resp. Rate / SpO₂ / Apple Watch capability status with ✓/✗ icons.
- "Manage in Health App" button opens `x-apple-health://`.

### Files touched this session (2026-05-03 continued)
- `Sources/Health/WorkoutSessionAggregator.swift` (minWorkoutSec 60→300, log format)
- `Sources/Health/WorkoutMigrator.swift` (NEW)
- `Sources/Health/HealthKitWriter.swift` (store exposed internal, new reads, auth logging, capability checks, fallback readers)
- `Sources/BLE/BLEManager.swift` (capability @Published flags, refreshCapabilities(), recomputeQueue.configure)
- `Sources/Processing/RecomputeQueue.swift` (configure(healthKit:), pass to recomputeDay)
- `Sources/Processing/DayRecomputer.swift` (healthKit param, source fusion for RHR+HRV)
- `Sources/Views/SettingsView.swift` (HealthKit Access section)
- `Sources/WhoopBLEApp.swift` (call refreshCapabilities after auth)

---

## Session 2026-05-03 — Sleep Need Calculator + Recovery Accuracy fixes

### Personalized Sleep Need (shipped)
- New: `Sources/Processing/SleepNeedCalculator.swift`
- Formula: `sleep_need = baseline + strain_adj + debt - nap_credit`
  - **baseline**: rolling 28-day median of `sleepMinutes` when ≥14 nights exist; else 480 min bootstrap. Clamped [360, 600].
  - **strain_adj**: `(yesterday_strain / 21) * 60`, capped 60 min
  - **debt**: sum of (need − actual) over last 7 days, each recovery day capped at -30 min, total capped [0, 120]
  - **nap_credit**: sessions starting 10:00–21:00 local, same day, capped 60 min
- `DailyMetrics` gains `sleepNeedMinutes: Int?` (backward-compatible decoder)
- `DayRecomputer.recomputeDay` calls calculator, stores result, passes personalized need as sleep baseline mean to `RecoveryScore` (so z-score = "vs your need" not population average)
- `AlgoVersions.sleep` bumped to 5, `AlgoVersions.recovery` to 8 → full backfill on next launch
- Log: `[SleepNeed] computed for date=... baseline=480 strain_adj=44 debt=120 napcredit=0 total=644`

### SleepView updated (shipped)
- Row badge: `"8h 14m / 8h 30m needed · 3 brief wakes"`
- Quality dot uses sufficiency ratio vs need (not raw hours)
- Tap row to expand: shows Slept / Need / Balance summary
- Data loaded async from `DailyMetricsStore` via `@EnvironmentObject var ble: BLEManager`

### Recovery score accuracy fixes (shipped)

**Bug 1 — RMSSD artifact (382 ms — physically impossible)**
- Root cause: stage 2 RR deviation filter (§9.5) was never implemented. Historical 0xa1 batches contain noisy RR pairs that pass the 300–2000 ms range filter but have huge inter-beat jumps.
- Fix: `DayRecomputer.computeHRV` now applies stage 2 filter before computing RMSSD/SDNN: rejects any RR value >20% from rolling 10-sample mean.
- `AlgoVersions.hrv` bumped 2→3

**Bug 2 — Z-scores unclamped (§9.8)**
- Root cause: `RecoveryScore.compute` had no ±3σ clamp. Corrupted HRV of 382 ms produced z ≈ +17 → recovery dominated at ~89 regardless of other inputs.
- Fix: z-score clamped to `max(-3.0, min(3.0, ...))` in `RecoveryScore.swift`

**Bug 3 — nil sleep treated as unknown, not penalized**
- Root cause: `RecoveryScore.compute` returned nil when `sleepMinutes` was nil → `refreshRecoveryFromStore` fell back to yesterday's high score.
- Fix: `sleepMinutes: nil` → `sleep = 0.0`. 0 min vs 480 min mean → z ≈ -8 (clamped to -3) → recovery ~13–25 (red zone).
- `AlgoVersions.recovery` bumped 7→8

**Bug 4 — today never recomputed when no prior row exists**
- Root cause: `checkVersionMismatch` only enqueues dates already in `DailyMetricsStore`. On first launch of day (no row yet), today was silently skipped → dashboard showed yesterday's score.
- Fix: `BLEManager.checkVersionMismatch` always adds today's UTC date key to the recompute set unconditionally.

### Current AlgoVersions
```
hrv      = 3   // stage 2 deviation filter
strain   = 1
sleep    = 5   // personalized need
recovery = 8   // z-clamp + nil-sleep penalty + personalized sleep baseline
```

---

## Outstanding / Next

- **Sleep accuracy still HR-only for historical data.** No accel data in 0xa1 batches. If Sleep minutes still drift vs Apple Health:
  - Option A: tighten `SleepDetector.maxWakeAbsorbWindows` 12→4 (60→20 min gap absorption)
  - Option B: read Apple Health sleep as source of truth for `sleepMinutes` in `DailyMetrics`
  - Option C: prefer `LiveSleepMonitor` sessions (accel-aware, in `whoopSleepSessions_v1`) when available for the night

- **Sleep need breakdown in SleepView** only shows totals (Slept / Need / Balance). Full component breakdown (baseline / strain_adj / debt / nap_credit) requires re-running `SleepNeedCalculator` inline on tap — deferred. Store full breakdown in `DailyMetrics` if needed.

- **Batch cursor reset (P1)** — strap won't resend already-delivered batches. `whoopSyncedBatches` clear does not reset strap-side cursor. See `HANDOFF_NEXT.md` prior session for hypotheses.

- **Move ring sedentary accrual** — confirm Active Energy from "WhoopBLE" accumulates on watch-off days.

## P2
- Stress indicator (§3.4)
- Activity sessions UI in Trends
- TrendsView: surface `recoveryScore` as 7-day sparkline
- DATA stream watchdog (§9.3)

## P3
- 0x57 byte[10]=228 mystery
- r19 / sigproc_* commands

## Hard constraints
- Never edit `.xcodeproj`. Edit `project.yml`, run `xcodegen generate`.
- Phase-gate: stop after each deliverable, wait for device test.
- iOS 16 target, Swift 6 strict concurrency.

## Files touched this session (2026-05-03)
- `Sources/Processing/SleepNeedCalculator.swift` (NEW)
- `Sources/Processing/DailyMetricsStore.swift` (sleepNeedMinutes field)
- `Sources/Processing/DayRecomputer.swift` (calculator call, stage 2 RR filter, version bumps)
- `Sources/Processing/RecoveryScore.swift` (z-clamp, nil sleep = 0)
- `Sources/BLE/BLEManager.swift` (always enqueue today)
- `Sources/Views/SleepView.swift` (need display, tap-expand)
