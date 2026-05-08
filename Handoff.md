# Session Handoff — 2026-05-08

## Recap
Big session focused on recovery + sleep correctness. ~12 distinct bugs/issues fixed across detector, classifier, recovery score, baselines, persistence, surfacing layer.

## Changes shipped

### Recovery score (EnhancedRecoveryScore + DayRecomputer)
| # | Change | Files |
|---|---|---|
| 1 | Quantity formula caps at 100 when need met (was 67 due to `/1.5` divisor) | EnhancedRecoveryScore.swift |
| 2 | Stage pct clamp to 0...1 with guard | EnhancedRecoveryScore.swift |
| 3 | Autonomic intent comment (HRV+, RHR-, strain-) | EnhancedRecoveryScore.swift |
| 4 | Confidence formula now includes strain availability (0.30/0.30/0.20/0.20) | EnhancedRecoveryScore.swift |
| 5 | `popStrain` constant added | EnhancedRecoveryScore.swift |
| 6 | Recovery score = nil when confidence < 0.5 (gate) | DayRecomputer.swift |
| 7 | Per-bio-day HRV from RR within session window (not calendar date) | DayRecomputer.swift |
| 8 | Per-bio-day RHR from HR over bio-day window | DayRecomputer.swift |
| 9 | HK SDNN fallback removed for HRV (unit mismatch with WHOOP RMSSD) | DayRecomputer.swift |
| 10 | HR-coverage gate uses minute-buckets ≥360min (was naive count/86400) | DayRecomputer.swift |
| 11 | RR outlier filter: `mean > 1.0` divide guard | DayRecomputer.swift |
| 12 | `computeHRV` requires ≥5 valid pair diffs | DayRecomputer.swift |
| 13 | `relevantKeys` filter restored: each calendar recompute writes only ±1 day bio rows | DayRecomputer.swift |

### Baselines (DailyMetricsStore + DayRecomputer)
| # | Change | Files |
|---|---|---|
| 14 | Sample variance n-1 (was n) | DailyMetricsStore.swift |
| 15 | UTC-consistent baseline cutoff (was Calendar.current) | DailyMetricsStore.swift |
| 16 | `rollingBaseline` returns count for shrinkage | DailyMetricsStore.swift |
| 17 | `blendBaseline` warmup=7 — personal blends toward population during ramp-up | DayRecomputer.swift |
| 18 | `deleteAll()` API added | DailyMetricsStore.swift |

### Sleep pipeline (SleepDetector + BiologicalDay + DayRecomputer)
| # | Change | Files |
|---|---|---|
| 19 | SleepDetector brace mismatch fix (build error) | SleepDetector.swift |
| 20 | Afternoon-nap blanket filter removed; classifier handles via `.nap` type | DayRecomputer.swift |
| 21 | Detected vs stored session dedup (overlap check) | DayRecomputer.swift |
| 22 | Bio day = wake calendar date (UTC) — dropped noon-shift convention | BiologicalDay.swift |
| 23 | `biologicalDayKey(for:)` exposed for SleepView | BiologicalDay.swift |

### Surfacing + edits (BLEManager + SyncManager + Settings)
| # | Change | Files |
|---|---|---|
| 24 | Stale recovery age cap: scores >3 days old not displayed as current | BLEManager.swift |
| 25 | `updateSleepSession` rebuilds `briefWakeCount` + seconds from clipped stages | SyncManager.swift |
| 26 | `clearAllSleepData` also wipes DailyMetrics + clears displayed recovery | SyncManager.swift |
| 27 | `forceRecomputeAll()` API + Settings button | BLEManager.swift, SettingsView.swift |
| 28 | `forceRecomputeAll` wipes DailyMetrics first (orphan-row migration) | BLEManager.swift |
| 29 | HealthKit sleep clock-skew tightened 1h → 5min | HealthKitWriter.swift |

### SleepView
| # | Change | Files |
|---|---|---|
| 30 | Stage bar pads detected stages with Core to fill edited duration | SleepView.swift |

## AlgoVersions
- `hrv` = 4 (HK SDNN fallback removed)
- `strain` = 3
- `sleep` = 11 (filter removed, dedup, bio-day rule change, briefWake recompute)
- `recovery` = 18 (formula, baseline, gating, per-bio-day, bio-day rule, relevantKeys)

`checkVersionMismatch()` will auto-backfill on launch. Or Settings → "Recompute Recovery / Strain / HRV".

## Known remaining issues (priorities for next session)

### P0
- **`Sleep=719min` (12h) on 5/7 logs** — unclear if real (multiple stored sessions for same night) or storage corruption. Inspect `whoopSleepSessions_v1` UserDefaults dump. If duplicates, dedup at storage layer not just at recompute.
- **`forceRecomputeAll` perf**: serial recompute over 60+ days has no progress UI, no batching, no cancel. Background task may be killed. Add `recomputeProgress` published + RecomputeQueue progress callback + Settings progress label "X/Y days".

### P1
- **`commitCreateSession` recompute coverage** (SleepView): doesn't call `affectedDateKeys`. Manual session creation may not trigger recompute for previous bio day. Switch to existing `affectedDateKeys` helper or route via `addSleepSession`.
- **Today date label**: with bio-day=wake-date now, scoreKey should match `todayKey` naturally. Verify on device. Edge case: if user hasn't slept yet today, fallback to yesterday's bio day — show "as of <date>" cleanly.
- **Live + batch dedup mismatch**: SyncManager:535 uses 5-min start-distance, DayRecomputer uses interval-overlap. Unify.
- **`clearAllSleepData` triggers Task** holding bleManager weakly — verify recoveryScore resets on main thread after async wipe.

### P2
- **Nap recovery caps at 50%** — design intent? Document in code or rebalance. User taking only naps maxes at 50% even with perfect HRV.
- **`computeHRVSleep` is dead code** post per-bio-day refactor. Remove for clarity.
- **Personalized sleep need uses full-window std** — mean=need, std=history std. Z-score interpretation drifts. Currently quantity uses ratio not z, so doesn't bite. Document.
- **Strain coverage 360 minutes**: edge case — strap worn only at night (480 min sleep + 0 day) just passes. May want stricter day-only coverage.

### P3 — Architectural debt
- **BLEManager 1021 LOC** + **SyncManager 935 LOC**: too many responsibilities. Split:
  - BLE transport (scan/connect/characteristic routing)
  - Live metrics aggregation (HR/HRV/steps/energy/exercise)
  - Sync orchestration (already mostly in SyncManager)
  - HealthKit write coordinator
- **CircadianEngine state retained across recomputes** in `RecomputeQueue.recomputer` singleton. Works but fragile — clearing recomputer mid-session would reset baseline. Document or persist circadian state to disk.
- **`whoopSleepSessions_v1` UserDefaults grows unbounded**. Add vacuum: drop sessions >90 days old or move to file storage.
- **No tests**. Recovery formula + sleep detector are testable pure functions. Wire up XCTest target with synthetic input fixtures.

### P4 — Protocol RE outstanding (per CLAUDE.md)
- 0xa1 chunk timestamp resolution
- Strap-side batch delivery cursor reset
- 0x57 EVENTS HR byte interpretation (currently rejected as out-of-range)
- 0xff metric1 bytes[8-9] purpose

## Plan: app improvements next session

### Theme A — Performance + UX of recompute
1. Publish `recomputeProgress: (done: Int, total: Int)?` from BLEManager.
2. RecomputeQueue gains `progressHandler: (Int, Int) -> Void`.
3. SettingsView progress label.
4. Optional cancel button (queue.clear()).
5. Batch enqueue: process 10 dates, yield, repeat — keeps UI responsive.

### Theme B — Sleep storage hygiene
1. Inspect 12h sleep total: dump `whoopSleepSessions_v1` to console on launch (debug-only).
2. Dedup-on-load: when SyncManager loads sessions, drop overlapping pairs (keep newest by id or longest by duration).
3. Vacuum sessions >90 days.
4. SleepView: list shows session.id + source — useful for finding stuck duplicates.

### Theme C — Dashboard polish
1. Show recovery confidence next to ring ("75% • conf 0.85").
2. Show sleep type tag ("Main 8h" / "Nap 0:30" / "Delayed 6h").
3. "as of" label hides when today; appears with reason when stale.
4. Manual create/edit session: visible undo + recompute progress.

### Theme D — Tests
1. XCTest target for `EnhancedRecoveryScore.compute` — fixed-input regressions.
2. Snapshot test for SleepDetector against canned HR samples.
3. BiologicalDay grouping tests for boundary cases (midnight/noon-UTC/timezones).

### Theme E — Code health
1. Split BLEManager into transport + aggregator.
2. Remove dead `computeHRVSleep`.
3. Persist CircadianEngine state to disk so it survives app relaunch deterministically.
4. Migrate `whoopSleepSessions_v1` UserDefaults → file in Documents.

## Verification done this session
- xcodebuild clean after every batch of changes.
- User pasted live logs showing recovery values + per-bio-day issues, fixed iteratively.

## Open questions for user
- **Confirm 12h sleep on 5/7 was real** (multiple sessions you actually had) **or storage corruption** (need clear+resync).
- **Per-stage Apple Health sleep writes** (deep/REM/core)? Currently single asleepUnspecified. Behind a settings toggle. Want it?
- **Bidirectional Apple Health sync** (read AH edits back into WhoopBLE)? Bigger work — needs HK observer + reconciliation. Not requested yet, flag as future feature.
