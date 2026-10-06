import 'package:sqflite/sqflite.dart';

/// Creates only the habit feature's tables in the shared app_fit.db database.
/// Kept separate so the coordinator can compose this with other feature migrations.
Future<void> createHabitSchema(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE habits (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('positive','avoid','quantitative')),
    cadence TEXT NOT NULL,
    target_count INTEGER NOT NULL DEFAULT 1 CHECK(target_count > 0),
    weekdays TEXT NOT NULL DEFAULT '',
    interval_days INTEGER NOT NULL DEFAULT 1 CHECK(interval_days > 0),
    start_date TEXT NOT NULL,
    quantity_target REAL,
    quantity_unit TEXT,
    daily_target_count INTEGER NOT NULL DEFAULT 1 CHECK(daily_target_count > 0),
    archived_at TEXT,
    category TEXT NOT NULL DEFAULT 'Geral',
    emoji TEXT NOT NULL DEFAULT '✦',
    color INTEGER NOT NULL DEFAULT 0xFF22618B,
    position INTEGER NOT NULL DEFAULT 0,
    automation TEXT NOT NULL DEFAULT 'manual',
    exercise_types TEXT NOT NULL DEFAULT '',
    reminder_enabled INTEGER NOT NULL DEFAULT 0,
    reminder_hour INTEGER,
    reminder_minute INTEGER,
    created_at TEXT NOT NULL,
    CHECK(type != 'quantitative' OR (quantity_target > 0 AND quantity_unit IS NOT NULL AND length(trim(quantity_unit)) > 0)),
    CHECK(reminder_enabled = 0 OR (reminder_hour BETWEEN 0 AND 23 AND reminder_minute BETWEEN 0 AND 59))
  )''');
  await db.execute(
    'CREATE INDEX habits_active_position ON habits(archived_at, position, name)',
  );
  await db.execute('''CREATE TABLE habit_completions (
    id TEXT PRIMARY KEY NOT NULL,
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    note TEXT,
    source_event_id TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    behavioral_moment_id TEXT,
    created_at TEXT NOT NULL
  )''');
  await db.execute(
    'CREATE INDEX habit_completions_day ON habit_completions(habit_id, local_date, occurred_at)',
  );
  await db.execute(
    'CREATE UNIQUE INDEX habit_completions_event ON habit_completions(habit_id, source_event_id) WHERE source_event_id IS NOT NULL',
  );
  await db.execute('''CREATE TABLE habit_quantity_logs (
    id TEXT PRIMARY KEY NOT NULL,
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    amount REAL NOT NULL CHECK(amount > 0),
    occurred_at TEXT NOT NULL,
    source_event_id TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    note TEXT,
    behavioral_moment_id TEXT
  )''');
  await db.execute(
    'CREATE INDEX habit_quantity_day ON habit_quantity_logs(habit_id, local_date, occurred_at)',
  );
  await db.execute(
    'CREATE UNIQUE INDEX habit_quantity_event ON habit_quantity_logs(habit_id, source_event_id) WHERE source_event_id IS NOT NULL',
  );
  await db.execute('''CREATE TABLE habit_ignored_events (
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    source_event_id TEXT NOT NULL,
    ignored_at TEXT NOT NULL,
    PRIMARY KEY(habit_id, source_event_id)
  )''');
  await db.execute('''CREATE TABLE habit_substeps (
    id TEXT PRIMARY KEY NOT NULL,
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    UNIQUE(habit_id, title)
  )''');
  await db.execute('''CREATE TABLE habit_substep_logs (
    substep_id TEXT NOT NULL REFERENCES habit_substeps(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    completed_at TEXT NOT NULL,
    PRIMARY KEY(substep_id, local_date)
  )''');
  await db.execute('''CREATE TABLE habit_day_notes (
    id TEXT PRIMARY KEY NOT NULL,
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    photo_uri TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(habit_id, local_date)
  )''');
  await db.execute('''CREATE TABLE habit_rest_days (
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT 'Descanso',
    PRIMARY KEY(habit_id, local_date)
  )''');
  await db.execute('''CREATE TABLE habit_vacations (
    id TEXT PRIMARY KEY NOT NULL,
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT 'Pausa',
    CHECK(end_date >= start_date)
  )''');
  await db.execute(
    'CREATE INDEX habit_vacations_range ON habit_vacations(habit_id, start_date, end_date)',
  );
  await db.execute('''CREATE TABLE habit_health_coverage (
    habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    local_date TEXT NOT NULL,
    source TEXT NOT NULL,
    availability TEXT NOT NULL,
    read_complete INTEGER NOT NULL,
    provisional INTEGER NOT NULL,
    observed_at TEXT,
    PRIMARY KEY(habit_id, local_date, source)
  )''');
  await db.execute('''CREATE TABLE behavioral_moments (
    id TEXT PRIMARY KEY NOT NULL,
    local_date TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    description TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'contextual',
    created_at TEXT NOT NULL
  )''');
  await db.execute('''CREATE TABLE habit_reminders (
    habit_id TEXT PRIMARY KEY NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
    enabled INTEGER NOT NULL DEFAULT 0,
    local_hour INTEGER,
    local_minute INTEGER,
    snoozed_until TEXT,
    snooze_count INTEGER NOT NULL DEFAULT 0,
    last_fired_at TEXT,
    updated_at TEXT NOT NULL
  )''');
  await db.execute('''CREATE TABLE habit_focus_settings (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    daily_goal_minutes INTEGER NOT NULL DEFAULT 60 CHECK(daily_goal_minutes > 0),
    work_minutes INTEGER NOT NULL DEFAULT 25 CHECK(work_minutes > 0),
    break_minutes INTEGER NOT NULL DEFAULT 5 CHECK(break_minutes > 0)
  )''');
  await db.insert('habit_focus_settings', {'id': 1});
  await db.execute('''CREATE TABLE habit_focus_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    planned_minutes INTEGER NOT NULL CHECK(planned_minutes > 0),
    completed INTEGER NOT NULL,
    note TEXT
  )''');
  await db.execute(
    'CREATE INDEX habit_focus_sessions_start ON habit_focus_sessions(started_at)',
  );
}
