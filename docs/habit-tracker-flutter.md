# Habit Tracker Flutter

The feature lives under `app_flutter/lib/features/habits` and uses the shared
`AppDatabase` at `app_fit.db`. `AppDatabase` is version 2 on this branch; the
habit migration is isolated in `habit_schema.dart` so the coordinator can merge
it with the Workout v4 migration without introducing another database.

## Integration surface

- `HabitRepository.publicSummaries()` returns active-habit aggregates for the
  last N days. It excludes notes, photo URIs, behavioral-moment descriptions,
  and source event payloads.
- `HabitRepository.morningBrief()` returns a short aggregate list used by the
  dashboard. It does not create notifications or nag the user.
- `HabitRepository.baseline()` compares recent and previous aggregate windows.
- `HabitRepository.coachSummary()` is the safe aggregate contract for Coach.
  Consumers must continue treating notes, photos, and event descriptions as
  private and must not add them implicitly.
- A completion and its optional `BehavioralMoment` are written in one database
  transaction. Quantitative logs use the same linked-moment path.

## Workout and Health Connect event contract

`HabitWorkoutSink.ingestWorkoutCompletion(...)` completes only after the
SQLite transaction commits and returns the count of new habit records. The
consumer deduplicates by `(habit_id, source_event_id)` across app restarts.

The #20 adapter should provide finalized events with:

- stable `eventId`, unchanged when a pending event is replayed;
- stable `sessionId`;
- `occurredAt` as a Dart `DateTime` representing the event instant;
- optional exercise type and display label;
- `source: 'workout'`.

The #19 Health Connect exercise adapter should use the same sink with
`source: 'health_connect_exercise'` and set `isRunning` from the bridge's
normalized exercise type. `eventId` must be stable across reads (prefer the
provider record ID; otherwise derive a deterministic key from source package,
start, end, and normalized exercise type). The producer must await the sink
before acknowledging delivery. This worktree defines the consumer but does not
import or edit the #19/#20 worktrees.

Step automation consumes the existing 7/30/90-day daily snapshots. It records
the availability, completeness, and provisional state for each date. Only an
available, complete daily value becomes a quantity log; no-data, missing,
permission-denied, or history-restricted dates are excluded from the metric
denominator rather than written as zero. Re-reading the same timezone/date
replaces the prior automated sample, which supports backfill and deduplication.
Step reads are not gated by exercise-session permissions.

## Platform bridges and privacy

Android opens the system document picker for a local image URI and schedules
daily habit reminders through AlarmManager. Reminder times, snooze timestamps,
and action-created logs use the same `app_fit.db`; boot/resume scheduling reads
the persisted snooze before creating the next alarm. Notification actions log
one positive completion, one avoid occurrence, or one quarter of a quantitative
target. Notification permission remains user-controlled.

The database is local-first. There is no remote sync or competitor importer.
No Streak source files or GPL-licensed implementation were copied into this
feature.

## Remaining integration and validation

- The #20 finalized-session producer and #19 exercise-event bridge are not in
  this branch yet; the contract above is ready for their adapters.
- The foundation has no Coach, Baseline, experiment, or contextual-intervention
  feature to call the aggregate APIs from. Morning Brief is integrated in the
  dashboard; the other methods are public integration points.
- Photo selection, alarms, permissions, and notification actions require
  Android device/emulator validation.
- Central validation is pending by request: `flutter analyze`, `flutter test`,
  and the Android bridge lint/checks must run after coordinated migrations are
  combined. No checks were run while implementing this feature.
