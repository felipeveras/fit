import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/persistence/app_database.dart';
import 'workout_models.dart';

class WorkoutSessionRepository {
  WorkoutSessionRepository(this._database);

  final AppDatabase _database;

  static double estimateOneRepMax(double weightKg, int reps) {
    if (weightKg < 0 || reps < 1 || reps > 12) return 0;
    return weightKg * (1 + reps / 30);
  }

  Future<int?> getActiveSessionId() async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_sessions',
      columns: ['id'],
      where: "status = 'active'",
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['id']! as int;
  }

  Future<int> startSession({int? routineId, DateTime? startedAt}) async {
    final db = await _database.open();
    return db.transaction((txn) async {
      final existing = await txn.query(
        'workout_sessions',
        columns: ['id'],
        where: "status = 'active'",
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError('Já existe um treino em andamento.');
      }
      final start = (startedAt ?? DateTime.now()).toUtc();
      final sessionId = await txn.insert('workout_sessions', {
        'routine_id': routineId,
        'status': 'active',
        'started_at': start.toIso8601String(),
      });
      if (routineId != null) {
        final routine = await txn.query(
          'workout_routines',
          where: 'id = ?',
          whereArgs: [routineId],
          limit: 1,
        );
        if (routine.isEmpty) throw StateError('Rotina não encontrada.');
        final exercises = await txn.rawQuery(
          '''SELECT re.*, ed.name, ed.muscle_group
             FROM routine_exercises re
             JOIN exercise_definitions ed ON ed.id = re.exercise_id
             WHERE re.routine_id = ? ORDER BY re.position''',
          [routineId],
        );
        for (var position = 0; position < exercises.length; position++) {
          final exercise = exercises[position];
          await txn.insert('workout_exercises', {
            'session_id': sessionId,
            'exercise_id': exercise['exercise_id'],
            'exercise_name': exercise['name'],
            'muscle_group': exercise['muscle_group'],
            'position': position,
            'planned_sets': exercise['planned_sets'],
            'min_reps': exercise['min_reps'],
            'max_reps': exercise['max_reps'],
            'rest_seconds': exercise['rest_seconds'],
            'superset_group': exercise['superset_group'],
            'notes': exercise['notes'],
          });
        }
      }
      await txn.insert('workout_rest_timers', {
        'session_id': sessionId,
        'remaining_ms': 0,
        'is_paused': 1,
        'updated_at': start.toIso8601String(),
      });
      return sessionId;
    });
  }

  Future<WorkoutSessionDetail?> getActiveSession() async {
    final id = await getActiveSessionId();
    return id == null ? null : getSession(id);
  }

  Future<WorkoutSessionDetail?> getSession(int id) async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final sessionRow = rows.single;
    final exerciseRows = await db.query(
      'workout_exercises',
      where: 'session_id = ?',
      whereArgs: [id],
      orderBy: 'position',
    );
    final details = <WorkoutExerciseDetail>[];
    for (final row in exerciseRows) {
      final exerciseId = row['id']! as int;
      final setRows = await db.query(
        'workout_sets',
        where: 'workout_exercise_id = ?',
        whereArgs: [exerciseId],
        orderBy: 'position',
      );
      details.add(
        WorkoutExerciseDetail(
          exercise: WorkoutExercise(
            id: exerciseId,
            sessionId: id,
            exerciseId: row['exercise_id'] as int?,
            exerciseName: row['exercise_name']! as String,
            position: row['position']! as int,
            muscleGroup: row['muscle_group'] as String? ?? 'other',
            restSeconds: row['rest_seconds'] as int? ?? 90,
            plannedSets: row['planned_sets'] as int?,
            minReps: row['min_reps'] as int?,
            maxReps: row['max_reps'] as int?,
            supersetGroup: row['superset_group'] as String?,
            notes: row['notes'] as String?,
          ),
          sets: setRows.map(_setFromRow).toList(growable: false),
        ),
      );
    }
    return WorkoutSessionDetail(
      session: _sessionFromRow(sessionRow),
      exercises: details,
    );
  }

  Future<int> addExercise(
    int sessionId,
    ExerciseDefinition exercise, {
    int restSeconds = 90,
  }) async {
    if (exercise.id == null) throw ArgumentError('Exercício sem id.');
    if (restSeconds < 0) throw ArgumentError('Descanso inválido.');
    final db = await _database.open();
    return db.transaction((txn) async {
      await _requireEditableSession(txn, sessionId, activeOnly: true);
      final exerciseRows = await txn.query(
        'exercise_definitions',
        where: 'id = ?',
        whereArgs: [exercise.id],
        limit: 1,
      );
      if (exerciseRows.isEmpty) throw StateError('Exercício não encontrado.');
      final current = await txn.rawQuery(
        'SELECT COALESCE(MAX(position), -1) + 1 AS next FROM workout_exercises WHERE session_id = ?',
        [sessionId],
      );
      return txn.insert('workout_exercises', {
        'session_id': sessionId,
        'exercise_id': exercise.id,
        'exercise_name': exercise.name,
        'muscle_group': exercise.muscleGroup,
        'position': current.single['next'],
        'rest_seconds': restSeconds,
      });
    });
  }

  Future<void> updateExerciseNote(int id, String? note) async {
    final db = await _database.open();
    await db.update(
      'workout_exercises',
      {'notes': _clean(note)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSessionNote(int id, String? note) async {
    final db = await _database.open();
    await db.update(
      'workout_sessions',
      {'notes': _clean(note)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> addSet({
    required int workoutExerciseId,
    required int reps,
    required double weightKg,
    WorkoutSetType type = WorkoutSetType.working,
    double? rpe,
    int? rir,
    bool completed = true,
    int? durationSeconds,
    double? distanceMeters,
  }) async {
    _validateSet(reps, weightKg, rpe, rir);
    final db = await _database.open();
    return db.transaction((txn) async {
      final parent = await _exerciseSession(txn, workoutExerciseId);
      await _requireEditableSession(txn, parent.sessionId, activeOnly: true);
      final position = await txn.rawQuery(
        'SELECT COALESCE(MAX(position), -1) + 1 AS next FROM workout_sets WHERE workout_exercise_id = ?',
        [workoutExerciseId],
      );
      final now = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('workout_sets', {
        'workout_exercise_id': workoutExerciseId,
        'position': position.single['next'],
        'reps': reps,
        'weight_kg': weightKg,
        'set_type': type.name,
        'rpe': rpe,
        'rir': rir,
        'completed_at': completed ? now : null,
        'duration_seconds': durationSeconds,
        'distance_meters': distanceMeters,
      });
      await _recalculatePrs(txn, parent.exerciseId);
      return id;
    });
  }

  Future<void> updateSet(WorkoutSet set) async {
    final id = set.id;
    if (id == null) throw ArgumentError('A série precisa de um id.');
    _validateSet(set.reps, set.weightKg, set.rpe, set.rir);
    final db = await _database.open();
    await db.transaction((txn) async {
      final oldRows = await txn.rawQuery(
        '''SELECT we.exercise_id, we.session_id
           FROM workout_sets ws JOIN workout_exercises we ON we.id = ws.workout_exercise_id
           WHERE ws.id = ?''',
        [id],
      );
      if (oldRows.isEmpty) throw StateError('Série não encontrada.');
      final parent = oldRows.single;
      final sessionId = parent['session_id']! as int;
      await _requireEditableSession(txn, sessionId);
      await txn.update(
        'workout_sets',
        {
          'reps': set.reps,
          'weight_kg': set.weightKg,
          'set_type': set.type.name,
          'rpe': set.rpe,
          'rir': set.rir,
          'completed_at': set.completedAt?.toUtc().toIso8601String(),
          'duration_seconds': set.durationSeconds,
          'distance_meters': set.distanceMeters,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await _recalculatePrs(txn, parent['exercise_id'] as int?);
    });
  }

  Future<void> deleteSet(int id) async {
    final db = await _database.open();
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''SELECT we.exercise_id, we.session_id
           FROM workout_sets ws JOIN workout_exercises we ON we.id = ws.workout_exercise_id
           WHERE ws.id = ?''',
        [id],
      );
      if (rows.isEmpty) return;
      final parent = rows.single;
      await _requireEditableSession(txn, parent['session_id']! as int);
      await txn.delete('workout_sets', where: 'id = ?', whereArgs: [id]);
      await _recalculatePrs(txn, parent['exercise_id'] as int?);
    });
  }

  Future<void> completeSession(
    int sessionId, {
    WorkoutEventSink? sink,
    DateTime? completedAt,
  }) async {
    final db = await _database.open();
    await db.transaction((txn) async {
      final rows = await txn.query(
        'workout_sessions',
        where: 'id = ? AND status = \'active\'',
        whereArgs: [sessionId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('O treino não está em andamento.');
      final data = await _sessionMetrics(txn, sessionId);
      if (data['completed_sets'] == 0) {
        throw StateError(
          'Registre ao menos uma série concluída antes de finalizar.',
        );
      }
      final finished = (completedAt ?? DateTime.now()).toUtc();
      await txn.update(
        'workout_sessions',
        {'status': 'completed', 'completed_at': finished.toIso8601String()},
        where: 'id = ?',
        whereArgs: [sessionId],
      );
      await txn.delete(
        'workout_rest_timers',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      final exerciseIds = await txn.rawQuery(
        'SELECT DISTINCT exercise_id FROM workout_exercises WHERE session_id = ?',
        [sessionId],
      );
      for (final row in exerciseIds) {
        await _recalculatePrs(txn, row['exercise_id'] as int?);
      }
      final payload = <String, Object?>{
        'exercise_count': data['exercise_count'],
        'completed_sets': data['completed_sets'],
        'volume_kg': data['volume_kg'],
        'duration_seconds': finished
            .difference(_date(rows.single['started_at']))
            .inSeconds,
      };
      await txn.insert('workout_domain_events', {
        'event_type': 'workout_completed',
        'session_id': sessionId,
        'occurred_at': finished.toIso8601String(),
        'payload_json': jsonEncode(payload),
      });
    });
    if (sink != null) await dispatchPendingEvents(sink);
  }

  Future<void> dispatchPendingEvents(WorkoutEventSink sink) async {
    if (!sink.hasConsumer) return;
    final db = await _database.open();
    final rows = await db.query(
      'workout_domain_events',
      where: 'delivered_at IS NULL',
      orderBy: 'id',
    );
    for (final row in rows) {
      final payload =
          jsonDecode(row['payload_json']! as String) as Map<String, dynamic>;
      final event = WorkoutDomainEvent(
        id: row['id']! as int,
        sessionId: row['session_id']! as int,
        occurredAt: _date(row['occurred_at']),
        exerciseCount: payload['exercise_count'] as int,
        completedSets: payload['completed_sets'] as int,
        volumeKg: (payload['volume_kg'] as num).toDouble(),
        durationSeconds: payload['duration_seconds'] as int,
      );
      await db.rawUpdate(
        '''UPDATE workout_domain_events
           SET delivery_attempts = delivery_attempts + 1,
               last_attempt_at = ?, last_error = NULL
           WHERE id = ? AND delivered_at IS NULL''',
        [DateTime.now().toUtc().toIso8601String(), event.id],
      );
      try {
        await sink.onWorkoutCompleted(event);
      } catch (error) {
        await db.update(
          'workout_domain_events',
          {'last_error': error.toString()},
          where: 'id = ? AND delivered_at IS NULL',
          whereArgs: [event.id],
        );
        rethrow;
      }
      await db.update(
        'workout_domain_events',
        {
          'delivered_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': null,
        },
        where: 'id = ? AND delivered_at IS NULL',
        whereArgs: [event.id],
      );
    }
  }

  Future<WorkoutDomainEvent?> getCompletionEvent(int sessionId) async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_domain_events',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final payload =
        jsonDecode(row['payload_json']! as String) as Map<String, dynamic>;
    return WorkoutDomainEvent(
      id: row['id']! as int,
      sessionId: sessionId,
      occurredAt: _date(row['occurred_at']),
      exerciseCount: payload['exercise_count'] as int,
      completedSets: payload['completed_sets'] as int,
      volumeKg: (payload['volume_kg'] as num).toDouble(),
      durationSeconds: payload['duration_seconds'] as int,
    );
  }

  Future<void> cancelSession(int sessionId) async {
    final db = await _database.open();
    await db.transaction((txn) async {
      final changed = await txn.update(
        'workout_sessions',
        {
          'status': 'cancelled',
          'completed_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: "id = ? AND status = 'active'",
        whereArgs: [sessionId],
      );
      if (changed == 0) throw StateError('O treino não está em andamento.');
      await txn.delete(
        'workout_rest_timers',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
    });
  }

  Future<RestTimerState?> getRestTimer(int sessionId, {DateTime? now}) async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_rest_timers',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final paused = row['is_paused'] == 1;
    final endsAt = row['ends_at'] == null ? null : _date(row['ends_at']);
    final remaining = paused || endsAt == null
        ? Duration(milliseconds: row['remaining_ms']! as int)
        : Duration(
            milliseconds: endsAt
                .difference(now ?? DateTime.now())
                .inMilliseconds,
          ).isNegative
        ? Duration.zero
        : endsAt.difference(now ?? DateTime.now());
    return RestTimerState(
      sessionId: sessionId,
      remaining: remaining,
      isPaused: paused,
      endsAt: endsAt,
    );
  }

  Future<void> startRestTimer(
    int sessionId,
    Duration duration, {
    DateTime? now,
  }) async {
    if (duration.isNegative) throw ArgumentError('Duração inválida.');
    final db = await _database.open();
    await _requireEditableSession(db, sessionId, activeOnly: true);
    final currentTime = (now ?? DateTime.now()).toUtc();
    final endsAt = currentTime.add(duration);
    await db.insert('workout_rest_timers', {
      'session_id': sessionId,
      'ends_at': endsAt.toIso8601String(),
      'remaining_ms': duration.inMilliseconds,
      'is_paused': duration == Duration.zero ? 1 : 0,
      'updated_at': currentTime.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> pauseRestTimer(int sessionId, {DateTime? now}) async {
    final current = await getRestTimer(sessionId, now: now);
    if (current == null) return;
    final db = await _database.open();
    await db.update(
      'workout_rest_timers',
      {
        'ends_at': null,
        'remaining_ms': current.remaining.inMilliseconds,
        'is_paused': 1,
        'updated_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> adjustRestTimer(
    int sessionId,
    Duration delta, {
    DateTime? now,
  }) async {
    final current = await getRestTimer(sessionId, now: now);
    if (current == null) return;
    final next = current.remaining + delta;
    final db = await _database.open();
    await _requireEditableSession(db, sessionId, activeOnly: true);
    final currentTime = (now ?? DateTime.now()).toUtc();
    if (next <= Duration.zero) {
      await db.update(
        'workout_rest_timers',
        {
          'ends_at': current.isPaused ? null : currentTime.toIso8601String(),
          'remaining_ms': 0,
          'is_paused': current.isPaused ? 1 : 0,
          'updated_at': currentTime.toIso8601String(),
        },
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
    } else if (current.isPaused) {
      await db.update(
        'workout_rest_timers',
        {
          'ends_at': null,
          'remaining_ms': next.inMilliseconds,
          'is_paused': 1,
          'updated_at': currentTime.toIso8601String(),
        },
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
    } else {
      await startRestTimer(sessionId, next, now: now);
    }
  }

  Future<void> skipRestTimer(int sessionId, {DateTime? now}) async {
    final db = await _database.open();
    await _requireEditableSession(db, sessionId, activeOnly: true);
    await db.update(
      'workout_rest_timers',
      {
        'ends_at': null,
        'remaining_ms': 0,
        'is_paused': 1,
        'updated_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> markRestTimerAlerted(int sessionId) async {
    final db = await _database.open();
    await db.update(
      'workout_rest_timers',
      {
        'ends_at': null,
        'remaining_ms': 0,
        'is_paused': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<WorkoutSessionSummary> getSummary(int sessionId) async {
    final detail = await getSession(sessionId);
    if (detail == null) throw StateError('Treino não encontrado.');
    var sets = 0;
    var exercisedCount = 0;
    var volume = 0.0;
    var topLoad = 0.0;
    for (final exercise in detail.exercises) {
      final completedSets = exercise.sets.where(_countsAsCompleted);
      if (completedSets.isNotEmpty) exercisedCount++;
      for (final set in completedSets) {
        sets++;
        if (set.type != WorkoutSetType.warmup) {
          volume += set.reps * set.weightKg;
          if (set.weightKg > topLoad) topLoad = set.weightKg;
        }
      }
    }
    final db = await _database.open();
    final prs = await db.rawQuery(
      '''SELECT * FROM personal_record_achievements
         WHERE session_id = ? ORDER BY achieved_at, record_type''',
      [sessionId],
    );
    return WorkoutSessionSummary(
      session: detail.session,
      exerciseCount: exercisedCount,
      setCount: sets,
      volumeKg: volume,
      topLoadKg: topLoad,
      personalRecords: prs.map(_prFromRow).toList(growable: false),
    );
  }

  Future<List<WorkoutSessionSummary>> listCompletedSessions({
    int limit = 200,
  }) async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_sessions',
      where: "status = 'completed'",
      orderBy: 'completed_at DESC',
      limit: limit,
    );
    final result = <WorkoutSessionSummary>[];
    for (final row in rows) {
      result.add(await getSummary(row['id']! as int));
    }
    return result;
  }

  Future<List<PersonalRecord>> listPersonalRecords() async {
    final db = await _database.open();
    final rows = await db.query(
      'personal_records',
      orderBy: 'achieved_at DESC',
    );
    return rows.map(_prFromRow).toList(growable: false);
  }

  Future<void> _recalculatePrs(DatabaseExecutor db, int? exerciseId) async {
    if (exerciseId == null) return;
    final rows = await db.rawQuery(
      '''SELECT ws.*, we.exercise_id, we.session_id
         FROM workout_sets ws
         JOIN workout_exercises we ON we.id = ws.workout_exercise_id
         JOIN workout_sessions s ON s.id = we.session_id
         WHERE we.exercise_id = ? AND s.status = 'completed'
           AND ws.completed_at IS NOT NULL AND ws.reps > 0 AND ws.set_type != 'warmup'
         ORDER BY s.completed_at, s.id, ws.completed_at, ws.id''',
      [exerciseId],
    );
    await db.delete(
      'personal_record_achievements',
      where: 'exercise_id = ?',
      whereArgs: [exerciseId],
    );
    await db.delete(
      'personal_records',
      where: 'exercise_id = ?',
      whereArgs: [exerciseId],
    );
    final rowsBySession = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      rowsBySession.putIfAbsent(row['session_id']! as int, () => []).add(row);
    }
    final bestByType = <String, ({double value, String time, int? setId})>{};
    for (final entry in rowsBySession.entries) {
      final candidates = <(String, ({double value, String time, int? setId})?)>[
        (
          'top_load',
          _maximum(entry.value, (row) => (row['weight_kg'] as num).toDouble()),
        ),
        (
          'estimated_1rm',
          _maximum(entry.value, (row) {
            final reps = row['reps']! as int;
            final weight = (row['weight_kg'] as num).toDouble();
            return estimateOneRepMax(weight, reps);
          }),
        ),
      ];
      for (final (recordType, candidate) in candidates) {
        if (candidate == null || candidate.value <= 0) continue;
        final previous = bestByType[recordType];
        if (previous != null && candidate.value <= previous.value) continue;
        await db.insert('personal_record_achievements', {
          'session_id': entry.key,
          'exercise_id': exerciseId,
          'record_type': recordType,
          'value': candidate.value,
          'achieved_at': candidate.time,
          'workout_set_id': candidate.setId,
        });
        bestByType[recordType] = candidate;
      }
    }
    for (final entry in bestByType.entries) {
      await db.insert('personal_records', {
        'exercise_id': exerciseId,
        'record_type': entry.key,
        'value': entry.value.value,
        'achieved_at': entry.value.time,
        'workout_set_id': entry.value.setId,
      });
    }
  }

  Future<Map<String, Object?>> _sessionMetrics(
    DatabaseExecutor db,
    int sessionId,
  ) async {
    final counts = await db.rawQuery(
      '''SELECT COUNT(DISTINCT CASE WHEN ws.id IS NOT NULL THEN we.id END) AS exercise_count,
           COUNT(ws.id) AS completed_sets,
           COALESCE(SUM(CASE WHEN ws.set_type != 'warmup' THEN ws.reps * ws.weight_kg ELSE 0 END), 0) AS volume_kg
         FROM workout_exercises we
         LEFT JOIN workout_sets ws ON ws.workout_exercise_id = we.id
           AND ws.completed_at IS NOT NULL AND ws.reps > 0
         WHERE we.session_id = ?''',
      [sessionId],
    );
    return {
      'exercise_count': counts.single['exercise_count']! as int,
      'completed_sets': counts.single['completed_sets']! as int,
      'volume_kg': (counts.single['volume_kg'] as num).toDouble(),
    };
  }

  Future<({int sessionId, int? exerciseId})> _exerciseSession(
    DatabaseExecutor db,
    int exerciseId,
  ) async {
    final rows = await db.query(
      'workout_exercises',
      columns: ['session_id', 'exercise_id'],
      where: 'id = ?',
      whereArgs: [exerciseId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Exercício do treino não encontrado.');
    return (
      sessionId: rows.single['session_id']! as int,
      exerciseId: rows.single['exercise_id'] as int?,
    );
  }

  Future<void> _requireEditableSession(
    DatabaseExecutor db,
    int sessionId, {
    bool activeOnly = false,
  }) async {
    final rows = await db.query(
      'workout_sessions',
      columns: ['status'],
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.single['status'] == 'cancelled' ||
        (activeOnly && rows.single['status'] != 'active')) {
      throw StateError('Este treino não pode mais ser alterado.');
    }
  }

  void _validateSet(int reps, double weight, double? rpe, int? rir) {
    if (reps < 0 || weight < 0 || !weight.isFinite) {
      throw ArgumentError('Repetições ou carga inválidas.');
    }
    if (rpe != null && (!rpe.isFinite || rpe < 0 || rpe > 10)) {
      throw ArgumentError('RPE deve estar entre 0 e 10.');
    }
    if (rir != null && (rir < 0 || rir > 10)) {
      throw ArgumentError('RIR deve estar entre 0 e 10.');
    }
    if (rpe != null && rir != null) {
      throw ArgumentError('Informe RPE ou RIR, não os dois.');
    }
  }

  bool _countsAsCompleted(WorkoutSet set) =>
      set.completedAt != null && set.reps > 0;

  ({double value, String time, int? setId})? _maximum(
    List<Map<String, Object?>> rows,
    double Function(Map<String, Object?>) select,
  ) {
    Map<String, Object?>? best;
    var value = double.negativeInfinity;
    for (final row in rows) {
      final candidate = select(row);
      if (candidate > value) {
        best = row;
        value = candidate;
      }
    }
    if (best == null) return null;
    return (
      value: value,
      time: best['completed_at']! as String,
      setId: best['id']! as int,
    );
  }

  WorkoutSet _setFromRow(Map<String, Object?> row) => WorkoutSet(
    id: row['id']! as int,
    workoutExerciseId: row['workout_exercise_id']! as int,
    position: row['position']! as int,
    reps: row['reps']! as int,
    weightKg: (row['weight_kg'] as num).toDouble(),
    type: WorkoutSetType.values.firstWhere(
      (value) => value.name == row['set_type'],
    ),
    rpe: (row['rpe'] as num?)?.toDouble(),
    rir: row['rir'] as int?,
    completedAt: row['completed_at'] == null
        ? null
        : _date(row['completed_at']),
    durationSeconds: row['duration_seconds'] as int?,
    distanceMeters: (row['distance_meters'] as num?)?.toDouble(),
  );

  WorkoutSession _sessionFromRow(Map<String, Object?> row) => WorkoutSession(
    id: row['id']! as int,
    routineId: row['routine_id'] as int?,
    status: WorkoutSessionStatus.values.firstWhere(
      (value) => value.name == row['status'],
    ),
    startedAt: _date(row['started_at']),
    completedAt: row['completed_at'] == null
        ? null
        : _date(row['completed_at']),
    notes: row['notes'] as String?,
  );

  PersonalRecord _prFromRow(Map<String, Object?> row) => PersonalRecord(
    id: row['id']! as int,
    exerciseId: row['exercise_id']! as int,
    recordType: row['record_type']! as String,
    value: (row['value'] as num).toDouble(),
    achievedAt: _date(row['achieved_at']),
    workoutSetId: row['workout_set_id'] as int?,
  );

  DateTime _date(Object? value) => DateTime.parse(value! as String).toLocal();

  String? _clean(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
