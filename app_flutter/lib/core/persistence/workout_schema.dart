import 'package:sqflite/sqflite.dart';

/// Adds the first workout schema to the shared, app-owned database.
Future<void> createWorkoutSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE exercise_definitions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL COLLATE NOCASE,
      muscle_group TEXT NOT NULL,
      instructions TEXT,
      is_custom INTEGER NOT NULL DEFAULT 0 CHECK (is_custom IN (0, 1)),
      media_path TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX exercise_name_idx ON exercise_definitions(name)',
  );
  await db.execute(
    'CREATE INDEX exercise_muscle_group_idx ON exercise_definitions(muscle_group)',
  );
  await db.execute('''
    CREATE TABLE workout_routines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      notes TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE routine_days (
      routine_id INTEGER NOT NULL REFERENCES workout_routines(id) ON DELETE CASCADE,
      weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
      PRIMARY KEY (routine_id, weekday)
    )
  ''');
  await db.execute('''
    CREATE TABLE routine_exercises (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      routine_id INTEGER NOT NULL REFERENCES workout_routines(id) ON DELETE CASCADE,
      exercise_id INTEGER NOT NULL REFERENCES exercise_definitions(id) ON DELETE RESTRICT,
      position INTEGER NOT NULL CHECK (position >= 0),
      planned_sets INTEGER NOT NULL DEFAULT 3 CHECK (planned_sets > 0),
      min_reps INTEGER NOT NULL DEFAULT 8 CHECK (min_reps > 0),
      max_reps INTEGER NOT NULL DEFAULT 12 CHECK (max_reps >= min_reps),
      rest_seconds INTEGER NOT NULL DEFAULT 90 CHECK (rest_seconds >= 0),
      superset_group TEXT,
      notes TEXT,
      UNIQUE (routine_id, position)
    )
  ''');
  await db.execute('''
    CREATE TABLE workout_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      routine_id INTEGER REFERENCES workout_routines(id) ON DELETE SET NULL,
      status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled')),
      started_at TEXT NOT NULL,
      completed_at TEXT,
      notes TEXT
    )
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX one_active_workout_idx ON workout_sessions(status)
    WHERE status = 'active'
  ''');
  await db.execute('''
    CREATE TABLE workout_exercises (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
      exercise_id INTEGER REFERENCES exercise_definitions(id) ON DELETE SET NULL,
      exercise_name TEXT NOT NULL,
      position INTEGER NOT NULL CHECK (position >= 0),
      notes TEXT,
      UNIQUE (session_id, position)
    )
  ''');
  await db.execute('''
    CREATE TABLE workout_sets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      workout_exercise_id INTEGER NOT NULL REFERENCES workout_exercises(id) ON DELETE CASCADE,
      position INTEGER NOT NULL CHECK (position >= 0),
      reps INTEGER NOT NULL CHECK (reps >= 0),
      weight_kg REAL NOT NULL CHECK (weight_kg >= 0),
      set_type TEXT NOT NULL CHECK (set_type IN ('working', 'warmup', 'drop', 'failure', 'restPause')),
      rpe REAL CHECK (rpe BETWEEN 0 AND 10),
      rir INTEGER CHECK (rir BETWEEN 0 AND 10),
      completed_at TEXT,
      UNIQUE (workout_exercise_id, position)
    )
  ''');
  await db.execute(
    'CREATE INDEX workout_sessions_started_idx ON workout_sessions(started_at)',
  );
  await db.execute('''
    CREATE TABLE personal_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      exercise_id INTEGER NOT NULL REFERENCES exercise_definitions(id) ON DELETE CASCADE,
      record_type TEXT NOT NULL,
      value REAL NOT NULL CHECK (value >= 0),
      achieved_at TEXT NOT NULL,
      workout_set_id INTEGER REFERENCES workout_sets(id) ON DELETE SET NULL,
      UNIQUE (exercise_id, record_type)
    )
  ''');
  await db.execute('''
    CREATE TABLE body_measurements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      measured_at TEXT NOT NULL,
      weight_kg REAL CHECK (weight_kg > 0),
      body_fat_percent REAL CHECK (body_fat_percent BETWEEN 0 AND 100),
      measurements_cm_json TEXT NOT NULL DEFAULT '{}',
      notes TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE progress_photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      captured_at TEXT NOT NULL,
      local_path TEXT NOT NULL,
      notes TEXT
    )
  ''');
  await _seedExerciseLibrary(db);
}

/// Extends the phase-one schema without rebuilding or losing user data.
Future<void> upgradeWorkoutSchema(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE workout_exercises ADD COLUMN muscle_group TEXT NOT NULL DEFAULT \'other\'',
  );
  await db.execute(
    'ALTER TABLE workout_exercises ADD COLUMN rest_seconds INTEGER NOT NULL DEFAULT 90',
  );
  await db.execute(
    'ALTER TABLE workout_exercises ADD COLUMN superset_group TEXT',
  );
  await db.execute(
    'ALTER TABLE workout_sets ADD COLUMN duration_seconds INTEGER',
  );
  await db.execute('ALTER TABLE workout_sets ADD COLUMN distance_meters REAL');
  await db.execute('''
    CREATE TABLE workout_rest_timers (
      session_id INTEGER PRIMARY KEY REFERENCES workout_sessions(id) ON DELETE CASCADE,
      ends_at TEXT,
      remaining_ms INTEGER NOT NULL DEFAULT 0 CHECK (remaining_ms >= 0),
      is_paused INTEGER NOT NULL DEFAULT 1 CHECK (is_paused IN (0, 1)),
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE workout_domain_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_type TEXT NOT NULL,
      session_id INTEGER NOT NULL UNIQUE REFERENCES workout_sessions(id) ON DELETE CASCADE,
      occurred_at TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      delivered_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE workout_preferences (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      weekly_goal INTEGER NOT NULL DEFAULT 3 CHECK (weekly_goal BETWEEN 1 AND 14)
    )
  ''');
  await db.insert('workout_preferences', {'id': 1, 'weekly_goal': 3});
}

/// Adds session prescription snapshots, durable event retry metadata and PR history.
Future<void> upgradeWorkoutSchemaV4(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE workout_exercises ADD COLUMN planned_sets INTEGER',
  );
  await db.execute('ALTER TABLE workout_exercises ADD COLUMN min_reps INTEGER');
  await db.execute('ALTER TABLE workout_exercises ADD COLUMN max_reps INTEGER');
  await db.execute(
    'ALTER TABLE workout_domain_events ADD COLUMN delivery_attempts INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute(
    'ALTER TABLE workout_domain_events ADD COLUMN last_attempt_at TEXT',
  );
  await db.execute(
    'ALTER TABLE workout_domain_events ADD COLUMN last_error TEXT',
  );
  await db.execute('''
    CREATE TABLE personal_record_achievements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
      exercise_id INTEGER NOT NULL REFERENCES exercise_definitions(id) ON DELETE CASCADE,
      record_type TEXT NOT NULL,
      value REAL NOT NULL CHECK (value > 0),
      achieved_at TEXT NOT NULL,
      workout_set_id INTEGER REFERENCES workout_sets(id) ON DELETE SET NULL,
      UNIQUE (session_id, exercise_id, record_type)
    )
  ''');
  final sets = await db.rawQuery('''
    SELECT ws.*, we.exercise_id, we.session_id
    FROM workout_sets ws
    JOIN workout_exercises we ON we.id = ws.workout_exercise_id
    JOIN workout_sessions s ON s.id = we.session_id
    WHERE s.status = 'completed' AND we.exercise_id IS NOT NULL
      AND ws.completed_at IS NOT NULL
      AND ws.reps > 0 AND ws.set_type != 'warmup'
    ORDER BY we.exercise_id, s.completed_at, s.id, ws.completed_at, ws.id
  ''');
  final byExercise = <int, Map<int, List<Map<String, Object?>>>>{};
  for (final row in sets) {
    byExercise
        .putIfAbsent(row['exercise_id']! as int, () => {})
        .putIfAbsent(row['session_id']! as int, () => [])
        .add(row);
  }
  for (final exerciseEntry in byExercise.entries) {
    final bestByType = <String, double>{};
    for (final sessionEntry in exerciseEntry.value.entries) {
      final sessionSets = sessionEntry.value;
      final candidates = <(String, Map<String, Object?>?)>[
        (
          'top_load',
          _migrationMaximum(
            sessionSets,
            (row) => (row['weight_kg'] as num).toDouble(),
          ),
        ),
        (
          'estimated_1rm',
          _migrationMaximum(sessionSets, (row) {
            final reps = row['reps']! as int;
            final weight = (row['weight_kg'] as num).toDouble();
            return reps > 12 ? 0 : weight * (1 + reps / 30);
          }),
        ),
      ];
      for (final (recordType, set) in candidates) {
        if (set == null) continue;
        if (recordType == 'estimated_1rm' && (set['reps']! as int) > 12) {
          continue;
        }
        final value = recordType == 'top_load'
            ? (set['weight_kg'] as num).toDouble()
            : (set['weight_kg'] as num).toDouble() *
                  (1 + (set['reps']! as int) / 30);
        if (value <= (bestByType[recordType] ?? 0)) continue;
        await db.insert('personal_record_achievements', {
          'session_id': sessionEntry.key,
          'exercise_id': exerciseEntry.key,
          'record_type': recordType,
          'value': value,
          'achieved_at': set['completed_at'],
          'workout_set_id': set['id'],
        });
        bestByType[recordType] = value;
      }
    }
  }
}

Map<String, Object?>? _migrationMaximum(
  List<Map<String, Object?>> rows,
  double Function(Map<String, Object?> row) select,
) {
  Map<String, Object?>? best;
  var bestValue = double.negativeInfinity;
  for (final row in rows) {
    final value = select(row);
    if (value > bestValue) {
      best = row;
      bestValue = value;
    }
  }
  return best;
}

Future<void> _seedExerciseLibrary(DatabaseExecutor db) async {
  const exercises = <(String, String, String)>[
    (
      'Supino reto com barra',
      'chest',
      'Desça a barra com controle até o peito e empurre para cima.',
    ),
    (
      'Supino inclinado com halteres',
      'chest',
      'Mantenha os punhos alinhados e controle a descida.',
    ),
    (
      'Crucifixo na máquina',
      'chest',
      'Aproxime os braços sem perder o controle do movimento.',
    ),
    (
      'Puxada frontal',
      'back',
      'Puxe a barra em direção ao alto do peito, sem balançar o tronco.',
    ),
    (
      'Remada curvada com barra',
      'back',
      'Incline o tronco e puxe a barra em direção ao abdômen.',
    ),
    (
      'Agachamento com barra',
      'quadriceps',
      'Desça mantendo os pés apoiados e os joelhos acompanhando os pés.',
    ),
    (
      'Leg press',
      'quadriceps',
      'Desça até uma amplitude confortável sem tirar o quadril do encosto.',
    ),
    (
      'Levantamento terra romeno',
      'hamstrings',
      'Leve o quadril para trás e mantenha a barra próxima às pernas.',
    ),
    (
      'Mesa flexora',
      'hamstrings',
      'Flexione os joelhos com controle e sem tirar o quadril do apoio.',
    ),
    (
      'Desenvolvimento com halteres',
      'shoulders',
      'Empurre os halteres acima da cabeça sem arquear a lombar.',
    ),
    ('Rosca direta', 'biceps', 'Flexione os cotovelos sem balançar o tronco.'),
    (
      'Tríceps na polia',
      'triceps',
      'Estenda os cotovelos mantendo-os próximos ao corpo.',
    ),
    (
      'Panturrilha em pé',
      'calves',
      'Eleve os calcanhares e faça uma pausa no alto.',
    ),
    (
      'Prancha',
      'core',
      'Mantenha o corpo alinhado e contraia o abdômen durante a sustentação.',
    ),
  ];
  for (final (name, muscle, instructions) in exercises) {
    await db.insert('exercise_definitions', {
      'name': name,
      'muscle_group': muscle,
      'instructions': instructions,
      'is_custom': 0,
    });
  }
}
