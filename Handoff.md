  Session Handoff

  What's done and working

  recomputeDay pipeline — fully wired end to end:
  - RawDataStore → DailyMetricsStore → DayRecomputer → RecomputeQueue
  - Live HR/RR feed into raw store from acceptMetrics()
  - Batch HR accumulated in pendingBatchHR, flushed atomically before recompute enqueue
  (race fixed)
  - checkVersionMismatch() on launch backfills stale rows when AlgoVersions constants
  bumped
  - Logs: [Raw], [Recompute] throughout

  Bugs fixed:
  - Strain 30× overcounting on batch data → timestamp-based duration, 120s gap cap
  - RMSSD across reconnection gaps → skip pairs where timestamp gap > 10s
  - appendHRBatch race vs recomputeDay → atomic sequential await

  TrendsView:
  - Today tab: calendar-day filter, midnight-anchored x-axis, live CMPedometer steps (never
   batch-inflated), day-rollover timer ✅
  - 7 Days: consistent 7-day domain all charts, noon-anchored axis marks, today's step bar
  = live pedometer ✅

  ---
  Still broken — start here next session

  Daily Avg Heart Rate bars in 7-day view — label alignment still wrong on device.
  Noon-based marks were applied but may not be sufficient when only 2 bars exist in a 7-day
   domain. Suggested fix to try first:

  Switch from date-based to categorical x-axis — avoids all domain/spacing issues:

  // In weekView, change BarMark:
  BarMark(x: .value("Day", dayAbbrev(s.id)), y: .value("HR", s.avgHR))

  // Add helper:
  private func dayAbbrev(_ date: Date) -> String {
      date.formatted(.dateTime.weekday(.abbreviated))
  }

  Categorical x means Charts auto-centers each label under its bar, no domain math needed.
  Trade-off: empty days have no space (bars stretch to fill width). For 2-3 bars this looks
   clean; for 7 it matches perfectly.