import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../core/persistence/app_database.dart';
import 'workout_models.dart';
import 'workout_session_repository.dart';

class WorkoutProgressRepository {
  WorkoutProgressRepository(this._database, this._sessions);

  final AppDatabase _database;
  final WorkoutSessionRepository _sessions;

  Future<void> setWeeklyGoal(int sessions) async {
    if (sessions < 1 || sessions > 14) {
      throw ArgumentError('A meta deve estar entre 1 e 14 treinos.');
    }
    final db = await _database.open();
    await db.update('workout_preferences', {
      'weekly_goal': sessions,
    }, where: 'id = 1');
  }

  Future<int> getWeeklyGoal() async {
    final db = await _database.open();
    final rows = await db.query('workout_preferences', limit: 1);
    return rows.isEmpty ? 3 : rows.single['weekly_goal']! as int;
  }

  Future<void> saveBodyMeasurement(BodyMeasurement measurement) async {
    if (measurement.weightKg != null && measurement.weightKg! <= 0) {
      throw ArgumentError('O peso deve ser maior que zero.');
    }
    if (measurement.bodyFatPercent != null &&
        (measurement.bodyFatPercent! < 0 ||
            measurement.bodyFatPercent! > 100)) {
      throw ArgumentError('O percentual de gordura deve estar entre 0 e 100.');
    }
    if (measurement.measurementsCm.values.any(
      (value) => value <= 0 || !value.isFinite,
    )) {
      throw ArgumentError('As medidas devem ser maiores que zero.');
    }
    final db = await _database.open();
    final values = {
      'measured_at': measurement.measuredAt.toUtc().toIso8601String(),
      'weight_kg': measurement.weightKg,
      'body_fat_percent': measurement.bodyFatPercent,
      'measurements_cm_json': jsonEncode(measurement.measurementsCm),
      'notes': _clean(measurement.notes),
    };
    if (measurement.id == null) {
      await db.insert('body_measurements', values);
    } else {
      final count = await db.update(
        'body_measurements',
        values,
        where: 'id = ?',
        whereArgs: [measurement.id],
      );
      if (count == 0) throw StateError('Medida corporal não encontrada.');
    }
  }

  Future<List<BodyMeasurement>> listBodyMeasurements({int limit = 100}) async {
    final db = await _database.open();
    final rows = await db.query(
      'body_measurements',
      orderBy: 'measured_at DESC',
      limit: limit,
    );
    return rows
        .map((row) {
          final decoded = jsonDecode(row['measurements_cm_json']! as String);
          return BodyMeasurement(
            id: row['id']! as int,
            measuredAt: DateTime.parse(row['measured_at']! as String).toLocal(),
            weightKg: (row['weight_kg'] as num?)?.toDouble(),
            bodyFatPercent: (row['body_fat_percent'] as num?)?.toDouble(),
            measurementsCm: (decoded as Map<String, dynamic>).map(
              (key, value) => MapEntry(key, (value as num).toDouble()),
            ),
            notes: row['notes'] as String?,
          );
        })
        .toList(growable: false);
  }

  Future<int> saveProgressPhoto(ProgressPhoto photo) async {
    if (photo.localPath.trim().isEmpty) {
      throw ArgumentError('Selecione uma foto.');
    }
    final db = await _database.open();
    final values = {
      'captured_at': photo.capturedAt.toUtc().toIso8601String(),
      'local_path': photo.localPath,
      'notes': _clean(photo.notes),
    };
    if (photo.id == null) return db.insert('progress_photos', values);
    final count = await db.update(
      'progress_photos',
      values,
      where: 'id = ?',
      whereArgs: [photo.id],
    );
    if (count == 0) throw StateError('Foto de progresso não encontrada.');
    return photo.id!;
  }

  Future<int> importProgressPhoto(String sourcePath, {String? notes}) async {
    final db = await _database.open();
    final directory = Directory(
      path.join(path.dirname(db.path), 'progress_photos'),
    );
    await directory.create(recursive: true);
    final extension = path.extension(sourcePath);
    final filename =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}$extension';
    final copy = await File(sourcePath)
        .copy(path.join(directory.path, filename));
    return saveProgressPhoto(
      ProgressPhoto(
        capturedAt: DateTime.now(),
        localPath: copy.path,
        notes: notes,
      ),
    );
  }

  Future<List<ProgressPhoto>> listProgressPhotos({int limit = 100}) async {
    final db = await _database.open();
    final rows = await db.query(
      'progress_photos',
      orderBy: 'captured_at DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => ProgressPhoto(
            id: row['id']! as int,
            capturedAt: DateTime.parse(row['captured_at']! as String).toLocal(),
            localPath: row['local_path']! as String,
            notes: row['notes'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<void> deleteProgressPhoto(int id) async {
    final db = await _database.open();
    final rows = await db.query(
      'progress_photos',
      columns: ['local_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.delete('progress_photos', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final stored = path.normalize(rows.single['local_path']! as String);
    final photoRoot = path.normalize(
      path.join(path.dirname(db.path), 'progress_photos'),
    );
    if (path.isWithin(photoRoot, stored)) {
      final file = File(stored);
      if (await file.exists()) await file.delete();
    }
  }

  Future<WorkoutHistorySummary> getOverview({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final all = await _sessions.listCompletedSessions(limit: 2000);
    final today = DateTime(current.year, current.month, current.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 7));
    final trainedDates = <DateTime>{};
    var totalSets = 0;
    var totalVolume = 0.0;
    var weekFrequency = 0;
    final muscleVolumes = await _muscleVolumeByGroup();
    for (final summary in all) {
      final date = summary.session.completedAt ?? summary.session.startedAt;
      final localDate = DateTime(date.year, date.month, date.day);
      trainedDates.add(localDate);
      totalSets += summary.setCount;
      totalVolume += summary.volumeKg;
      if (!localDate.isBefore(weekStart) && localDate.isBefore(weekEnd)) {
        weekFrequency++;
      }
    }
    var streak = 0;
    var streakDate = trainedDates.contains(today)
        ? today
        : today.subtract(const Duration(days: 1));
    while (trainedDates.contains(streakDate)) {
      streak++;
      streakDate = streakDate.subtract(const Duration(days: 1));
    }
    return WorkoutHistorySummary(
      sessions: all.length,
      trainedDays: trainedDates.length,
      completedSets: totalSets,
      volumeKg: totalVolume,
      frequency: weekFrequency,
      currentStreak: streak,
      weeklyGoal: await getWeeklyGoal(),
      muscleVolumes: muscleVolumes,
    );
  }

  Future<Map<DateTime, int>> getHeatmap({int days = 365, DateTime? now}) async {
    if (days < 1 || days > 1095) throw ArgumentError('Período inválido.');
    final current = now ?? DateTime.now();
    final start = DateTime(
      current.year,
      current.month,
      current.day,
    ).subtract(Duration(days: days - 1));
    final db = await _database.open();
    final rows = await db.rawQuery(
      '''SELECT date(completed_at, 'localtime') AS day, COUNT(*) AS workouts
         FROM workout_sessions
         WHERE status = 'completed' AND completed_at >= ?
         GROUP BY date(completed_at, 'localtime')''',
      [start.toUtc().toIso8601String()],
    );
    return {
      for (final row in rows)
        DateTime.parse(row['day']! as String): row['workouts']! as int,
    };
  }

  Future<List<ExerciseHistoryPoint>> getExerciseHistory(int exerciseId) async {
    final db = await _database.open();
    final rows = await db.rawQuery(
      '''SELECT s.completed_at, ws.weight_kg, ws.reps, ws.set_type
         FROM workout_sets ws
         JOIN workout_exercises we ON we.id = ws.workout_exercise_id
         JOIN workout_sessions s ON s.id = we.session_id
         WHERE we.exercise_id = ? AND s.status = 'completed'
           AND ws.completed_at IS NOT NULL AND ws.reps > 0
         ORDER BY s.completed_at''',
      [exerciseId],
    );
    final byDate = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final date = DateTime.parse(row['completed_at']! as String).toLocal();
      final key = '${date.year}-${date.month}-${date.day}';
      byDate.putIfAbsent(key, () => []).add(row);
    }
    final points = <ExerciseHistoryPoint>[];
    for (final entry in byDate.entries) {
      var top = 0.0;
      var oneRepMax = 0.0;
      var volume = 0.0;
      for (final row in entry.value) {
        if (row['set_type'] == WorkoutSetType.warmup.name) continue;
        final weight = (row['weight_kg'] as num).toDouble();
        final reps = row['reps']! as int;
        if (weight > top) top = weight;
        final estimated = WorkoutSessionRepository.estimateOneRepMax(
          weight,
          reps,
        );
        if (estimated > oneRepMax) oneRepMax = estimated;
        volume += weight * reps;
      }
      final first = DateTime.parse(entry.value.first['completed_at']! as String)
          .toLocal();
      points.add(
        ExerciseHistoryPoint(
          sessionDate: DateTime(first.year, first.month, first.day),
          topLoadKg: top,
          estimatedOneRepMaxKg: oneRepMax,
          volumeKg: volume,
        ),
      );
    }
    points.sort((a, b) => a.sessionDate.compareTo(b.sessionDate));
    return points;
  }

  Future<CoachWorkoutSummary> getCoachSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    final db = await _database.open();
    final periods = await db.query(
      'workout_sessions',
      where: "status = 'completed' AND completed_at >= ? AND completed_at < ?",
      whereArgs: [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()],
      orderBy: 'completed_at',
    );
    final aggregates = await db.rawQuery(
      '''SELECT COUNT(*) AS set_count,
           COALESCE(SUM(CASE WHEN ws.set_type != 'warmup' THEN ws.weight_kg * ws.reps ELSE 0 END), 0) AS volume,
           AVG(ws.rpe) AS average_rpe
         FROM workout_sets ws
         JOIN workout_exercises we ON we.id = ws.workout_exercise_id
         JOIN workout_sessions s ON s.id = we.session_id
         WHERE s.status = 'completed' AND s.completed_at >= ? AND s.completed_at < ?
           AND ws.completed_at IS NOT NULL AND ws.reps > 0''',
      [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()],
    );
    final muscles = await db.rawQuery(
      '''SELECT we.muscle_group, SUM(ws.weight_kg * ws.reps) AS volume
         FROM workout_sets ws
         JOIN workout_exercises we ON we.id = ws.workout_exercise_id
         JOIN workout_sessions s ON s.id = we.session_id
         WHERE s.status = 'completed' AND s.completed_at >= ? AND s.completed_at < ?
           AND ws.completed_at IS NOT NULL AND ws.reps > 0 AND ws.set_type != 'warmup'
         GROUP BY we.muscle_group''',
      [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()],
    );
    final records = await db.rawQuery(
      '''SELECT ed.name, pra.record_type, pra.value
         FROM personal_record_achievements pra
         JOIN exercise_definitions ed ON ed.id = pra.exercise_id
         WHERE pra.achieved_at >= ? AND pra.achieved_at < ?
         ORDER BY pra.achieved_at DESC LIMIT 20''',
      [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()],
    );
    final trainedDays = periods
        .map((row) {
          final date = DateTime.parse(row['completed_at']! as String).toLocal();
          return DateTime(date.year, date.month, date.day);
        })
        .toSet()
        .length;
    final durations = periods.map((row) {
      final start = DateTime.parse(row['started_at']! as String);
      final end = DateTime.parse(row['completed_at']! as String);
      return end.difference(start).inSeconds / 60;
    }).toList();
    final avgRpe = aggregates.single['average_rpe'] as num?;
    return CoachWorkoutSummary(
      sessions: periods.length,
      trainedDays: trainedDays,
      volumeKg: (aggregates.single['volume'] as num).toDouble(),
      muscleGroups: {
        for (final row in muscles)
          row['muscle_group']! as String: (row['volume'] as num).toDouble(),
      },
      personalRecords: records
          .map(
            (row) => '${row['name']}: ${row['record_type']} (${row['value']})',
          )
          .toList(growable: false),
      averageDurationMinutes: durations.isEmpty
          ? null
          : durations.reduce((a, b) => a + b) / durations.length,
      averageRpe: avgRpe?.toDouble(),
    );
  }

  Future<Map<String, double>> _muscleVolumeByGroup() async {
    final db = await _database.open();
    final rows = await db.rawQuery(
      '''SELECT we.muscle_group, SUM(ws.weight_kg * ws.reps) AS volume
         FROM workout_sets ws
         JOIN workout_exercises we ON we.id = ws.workout_exercise_id
         JOIN workout_sessions s ON s.id = we.session_id
         WHERE s.status = 'completed' AND ws.completed_at IS NOT NULL
           AND ws.reps > 0 AND ws.set_type != 'warmup'
         GROUP BY we.muscle_group''',
    );
    return {
      for (final row in rows)
        row['muscle_group']! as String: (row['volume'] as num).toDouble(),
    };
  }

  String? _clean(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
