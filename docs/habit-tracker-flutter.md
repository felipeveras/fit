# Habit Tracker Flutter

The feature lives under `app_flutter/lib/features/habits` and uses the shared
`AppDatabase` at `app_fit.db`, now at version 5. Upgrades preserve metadata
(v1), workouts (v2), session timers and outbox (v3), and prescriptions/PR
history/retry metadata (v4), then add the habit tables (v5). No habit-only
v2 schema was released; the historical v2 remains the workout schema.

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

`WorkoutHabitConsumer` connects the #20 durable outbox to `HabitRepository`
at application bootstrap. Each delivery awaits the SQLite habit transaction;
a failed delivery remains pending for replay. Stable workout event IDs prevent
duplicate completions even when the process exits after persistence but before
acknowledgement. The app can still open while a pending event needs another retry.

Exercise automation reads the optional #19 `HealthExerciseRepository`
capability independently of step permissions. Settings exposes its separate
permission request. The habit page stores one selected origin in app metadata;
if multiple producers exist it asks for a source before importing exercises.
Switching origins replaces only automated exercise logs. Provider origin and
record ID form a JSON composite key; replaying the same read is idempotent.
Per-day permission/history/read errors remain uncovered, retain prior records,
and never become zero or a missed opportunity. An empty provisional day is
also excluded until the daily read is complete. If no producer origin is known,
the import does not infer missed workouts from an empty read.

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
target. Incomplete checklists open the app instead of bypassing required steps.
Weekly/monthly reminder targets exclude rest, vacation and ineligible initial
period days; Health Connect targets use measured coverage. Automatic workout,
step and exercise imports reconcile enabled reminders after persistence.
Notification permission remains user-controlled.

The database is local-first. There is no remote sync or competitor importer.
No Streak source files or GPL-licensed implementation were copied into this
feature.

## Remaining consumers and validation

The #20 finalized-session outbox and #19 exercise bridge are implemented and
connected to the habit repository in the integrated Flutter application. They
share `app_fit.db`; no additional habit database or producer adapter is needed.

The Coach, experiment and contextual-intervention features do not yet consume
the public aggregate APIs. Morning Brief is already composed into the dashboard;
`baseline()` and `coachSummary()` are available integration points.

Combined analysis, Flutter tests, Android tests/lint and APK/emulator validation
must be recorded against the final integrated commit. This document describes
the implemented behavior and does not claim that all checks are complete.
Photo selection, permissions, alarms and notification actions need platform
validation. Real producer data and authorized Telegram delivery on a physical
device are still pending for #19; an emulator without producers cannot establish
Health Connect parity or authorize the release cutover.
