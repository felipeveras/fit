import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../core/persistence/app_database.dart';
import 'workout_models.dart';

/// Local SQLite repository for the exercise library and planned routines.
class WorkoutRepository {
  WorkoutRepository(this._database);

  final AppDatabase _database;

  Future<List<ExerciseDefinition>> listExercises({
    String query = '',
    String? muscleGroup,
  }) async {
    final db = await _database.open();
    final filters = <String>[];
    final args = <Object?>[];
    final normalizedQuery = query.trim();
    if (normalizedQuery.isNotEmpty) {
      filters.add('(name LIKE ? OR instructions LIKE ?)');
      args.addAll(['%$normalizedQuery%', '%$normalizedQuery%']);
    }
    if (muscleGroup != null && muscleGroup.isNotEmpty) {
      filters.add('muscle_group = ?');
      args.add(muscleGroup);
    }
    final rows = await db.query(
      'exercise_definitions',
      where: filters.isEmpty ? null : filters.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(_exerciseFromRow).toList(growable: false);
  }

  Future<int> saveCustomExercise(ExerciseDefinition exercise) async {
    _requireText(exercise.name, 'Nome do exercício');
    _requireText(exercise.muscleGroup, 'Grupo muscular');
    final db = await _database.open();
    final values = _exerciseValues(exercise);
    values['is_custom'] = 1;
    if (exercise.id == null) {
      return db.insert('exercise_definitions', values);
    }
    final updated = await db.update(
      'exercise_definitions',
      values,
      where: 'id = ? AND is_custom = 1',
      whereArgs: [exercise.id],
    );
    if (updated == 0) {
      throw StateError('Exercício personalizado não encontrado.');
    }
    return exercise.id!;
  }

  Future<String> copyExerciseMedia(String sourcePath) async {
    final db = await _database.open();
    final directory = Directory(
      path.join(path.dirname(db.path), 'exercise_media'),
    );
    await directory.create(recursive: true);
    final extension = path.extension(sourcePath);
    final filename =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}$extension';
    return (await File(sourcePath).copy(path.join(directory.path, filename)))
        .path;
  }

  Future<void> deleteCustomExercise(int id) async {
    final db = await _database.open();
    final deleted = await db.delete(
      'exercise_definitions',
      where: 'id = ? AND is_custom = 1',
      whereArgs: [id],
    );
    if (deleted == 0) {
      throw StateError('Exercício personalizado não encontrado.');
    }
  }

  Future<List<WorkoutRoutine>> listRoutines() async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_routines',
      orderBy: 'name COLLATE NOCASE',
    );
    final result = <WorkoutRoutine>[];
    for (final row in rows) {
      result.add(await _readRoutine(db, row));
    }
    return result;
  }

  Future<WorkoutRoutine?> getRoutine(int id) async {
    final db = await _database.open();
    final rows = await db.query(
      'workout_routines',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _readRoutine(db, rows.single);
  }

  Future<int> createRoutine(WorkoutRoutine routine) async {
    _validateRoutine(routine);
    final db = await _database.open();
    return db.transaction((txn) async {
      final now = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('workout_routines', {
        'name': routine.name.trim(),
        'notes': _optionalText(routine.notes),
        'created_at': now,
        'updated_at': now,
      });
      await _replaceRoutineChildren(txn, id, routine);
      return id;
    });
  }

  Future<void> updateRoutine(WorkoutRoutine routine) async {
    final id = routine.id;
    if (id == null) {
      throw ArgumentError('A rotina precisa de um id para edição.');
    }
    _validateRoutine(routine);
    final db = await _database.open();
    await db.transaction((txn) async {
      final updated = await txn.update(
        'workout_routines',
        {
          'name': routine.name.trim(),
          'notes': _optionalText(routine.notes),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated == 0) throw StateError('Rotina não encontrada.');
      await txn.delete(
        'routine_days',
        where: 'routine_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'routine_exercises',
        where: 'routine_id = ?',
        whereArgs: [id],
      );
      await _replaceRoutineChildren(txn, id, routine);
    });
  }

  Future<int> duplicateRoutine(int id, {String? name}) async {
    final original = await getRoutine(id);
    if (original == null) throw StateError('Rotina não encontrada.');
    return createRoutine(
      WorkoutRoutine(
        name: name ?? '${original.name} (cópia)',
        notes: original.notes,
        scheduledWeekdays: original.scheduledWeekdays,
        exercises: original.exercises
            .map(
              (exercise) => RoutineExercise(
                exerciseId: exercise.exerciseId,
                position: exercise.position,
                plannedSets: exercise.plannedSets,
                minReps: exercise.minReps,
                maxReps: exercise.maxReps,
                restSeconds: exercise.restSeconds,
                supersetGroup: exercise.supersetGroup,
                notes: exercise.notes,
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Future<void> deleteRoutine(int id) async {
    final db = await _database.open();
    final deleted = await db.delete(
      'workout_routines',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (deleted == 0) throw StateError('Rotina não encontrada.');
  }

  Future<void> _replaceRoutineChildren(
    Transaction txn,
    int routineId,
    WorkoutRoutine routine,
  ) async {
    for (final day in routine.scheduledWeekdays.toSet().toList()..sort()) {
      await txn.insert('routine_days', {
        'routine_id': routineId,
        'weekday': day,
      });
    }
    final exercises = [...routine.exercises]
      ..sort((a, b) => a.position.compareTo(b.position));
    for (var index = 0; index < exercises.length; index++) {
      final exercise = exercises[index];
      await txn.insert('routine_exercises', {
        'routine_id': routineId,
        'exercise_id': exercise.exerciseId,
        'position': index,
        'planned_sets': exercise.plannedSets,
        'min_reps': exercise.minReps,
        'max_reps': exercise.maxReps,
        'rest_seconds': exercise.restSeconds,
        'superset_group': _optionalText(exercise.supersetGroup),
        'notes': _optionalText(exercise.notes),
      });
    }
  }

  Future<WorkoutRoutine> _readRoutine(
    DatabaseExecutor db,
    Map<String, Object?> row,
  ) async {
    final id = row['id']! as int;
    final dayRows = await db.query(
      'routine_days',
      columns: ['weekday'],
      where: 'routine_id = ?',
      whereArgs: [id],
      orderBy: 'weekday',
    );
    final exerciseRows = await db.query(
      'routine_exercises',
      where: 'routine_id = ?',
      whereArgs: [id],
      orderBy: 'position',
    );
    return WorkoutRoutine(
      id: id,
      name: row['name']! as String,
      notes: row['notes'] as String?,
      scheduledWeekdays: dayRows.map((e) => e['weekday']! as int).toList(),
      exercises: exerciseRows.map(_routineExerciseFromRow).toList(),
    );
  }

  void _validateRoutine(WorkoutRoutine routine) {
    _requireText(routine.name, 'Nome da rotina');
    if (routine.scheduledWeekdays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError('Os dias da semana devem estar entre 1 e 7.');
    }
    if (routine.exercises.any(
      (e) =>
          e.plannedSets < 1 ||
          e.minReps < 1 ||
          e.maxReps < e.minReps ||
          e.restSeconds < 0,
    )) {
      throw ArgumentError('Confira séries, repetições e descanso da rotina.');
    }
  }

  void _requireText(String value, String field) {
    if (value.trim().isEmpty) throw ArgumentError('$field é obrigatório.');
  }

  String? _optionalText(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  Map<String, Object?> _exerciseValues(ExerciseDefinition exercise) => {
    'name': exercise.name.trim(),
    'muscle_group': exercise.muscleGroup.trim(),
    'instructions': _optionalText(exercise.instructions),
    'media_path': _optionalText(exercise.mediaPath),
  };

  ExerciseDefinition _exerciseFromRow(Map<String, Object?> row) =>
      ExerciseDefinition(
        id: row['id']! as int,
        name: row['name']! as String,
        muscleGroup: row['muscle_group']! as String,
        instructions: row['instructions'] as String?,
        isCustom: row['is_custom'] == 1,
        mediaPath: row['media_path'] as String?,
      );

  RoutineExercise _routineExerciseFromRow(Map<String, Object?> row) =>
      RoutineExercise(
        id: row['id']! as int,
        exerciseId: row['exercise_id']! as int,
        position: row['position']! as int,
        plannedSets: row['planned_sets']! as int,
        minReps: row['min_reps']! as int,
        maxReps: row['max_reps']! as int,
        restSeconds: row['rest_seconds']! as int,
        supersetGroup: row['superset_group'] as String?,
        notes: row['notes'] as String?,
      );
}
