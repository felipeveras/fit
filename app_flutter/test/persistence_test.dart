import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/core/persistence/workout_schema.dart';
import 'package:app_fit/core/persistence/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'single versioned database migrates habits and survives reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('app-fit-test');
      final databasePath = '${directory.path}/app_fit.db';
      final store = AppDatabase(factory: databaseFactoryFfi);
      try {
        final db = await store.open(databasePath: databasePath);
        expect(await db.getVersion(), 5);
        final metadata = await db.query('app_metadata');
        expect(metadata.single['key'], 'created_at');
        await store.close();
        final reopened = await store.open(databasePath: databasePath);
        expect(await reopened.query('app_metadata'), metadata);
        final tables = await reopened.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        expect(
          tables.map((t) => t['name']),
          isNot(contains('health_snapshots')),
        );
        expect(
          tables.map((t) => t['name']),
          containsAll([
            'exercise_definitions',
            'workout_routines',
            'routine_exercises',
            'workout_sessions',
            'workout_exercises',
            'workout_sets',
            'personal_records',
            'body_measurements',
            'progress_photos',
            'workout_rest_timers',
            'workout_domain_events',
            'workout_preferences',
            'personal_record_achievements',
          ]),
        );
        expect(tables.map((t) => t['name']), contains('habits'));
        expect(tables.map((t) => t['name']), contains('habit_completions'));
        expect(
          tables.map((t) => t['name']),
          isNot(contains('health_snapshots')),
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'upgrades an existing version 1 database without losing metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'app-fit-upgrade',
      );
      final databasePath = '${directory.path}/app_fit.db';
      try {
        final oldDatabase = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
              );
              await db.insert('app_metadata', {
                'key': 'created_at',
                'value': '2026-01-02T03:04:05.000Z',
              });
            },
          ),
        );
        await oldDatabase.close();

        final store = AppDatabase(factory: databaseFactoryFfi);
        try {
          final upgraded = await store.open(databasePath: databasePath);
          expect(await upgraded.getVersion(), 5);
          expect(await upgraded.query('app_metadata'), [
            {'key': 'created_at', 'value': '2026-01-02T03:04:05.000Z'},
          ]);
          expect(await upgraded.query('exercise_definitions'), isNotEmpty);
        } finally {
          await store.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('upgrades an existing workout schema without losing routines', () async {
    final directory = await Directory.systemTemp.createTemp(
      'app-fit-v2-upgrade',
    );
    final databasePath = '${directory.path}/app_fit.db';
    try {
      final oldDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.insert('app_metadata', {
              'key': 'created_at',
              'value': '2026-01-02T03:04:05.000Z',
            });
            await createWorkoutSchema(db);
            await db.insert('workout_routines', {
              'id': 1,
              'name': 'Treino preservado',
              'created_at': '2026-01-02T03:04:05.000Z',
              'updated_at': '2026-01-02T03:04:05.000Z',
            });
          },
        ),
      );
      await oldDatabase.close();

      final store = AppDatabase(factory: databaseFactoryFfi);
      try {
        final upgraded = await store.open(databasePath: databasePath);
        expect(await upgraded.getVersion(), 5);
        expect(
          (await upgraded.query('workout_routines')).single['name'],
          'Treino preservado',
        );
        expect(await upgraded.query('workout_preferences'), [
          {'id': 1, 'weekly_goal': 3},
        ]);
        final setColumns = await upgraded.rawQuery(
          'PRAGMA table_info(workout_sets)',
        );
        expect(
          setColumns.map((column) => column['name']),
          containsAll(['duration_seconds', 'distance_meters']),
        );
        final exerciseColumns = await upgraded.rawQuery(
          'PRAGMA table_info(workout_exercises)',
        );
        expect(
          exerciseColumns.map((column) => column['name']),
          containsAll(['planned_sets', 'min_reps', 'max_reps']),
        );
        final eventColumns = await upgraded.rawQuery(
          'PRAGMA table_info(workout_domain_events)',
        );
        expect(
          eventColumns.map((column) => column['name']),
          containsAll(['delivery_attempts', 'last_attempt_at', 'last_error']),
        );
      } finally {
        await store.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'v3 migration preserves the current PR as a historical achievement',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'app-fit-v3-upgrade',
      );
      final databasePath = '${directory.path}/app_fit.db';
      try {
        final oldDatabase = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
              );
              await createWorkoutSchema(db);
              await upgradeWorkoutSchema(db);
              await db.insert('workout_sessions', {
                'id': 1,
                'status': 'completed',
                'started_at': '2026-01-02T03:00:00.000Z',
                'completed_at': '2026-01-02T03:30:00.000Z',
              });
              await db.insert('workout_sessions', {
                'id': 2,
                'status': 'completed',
                'started_at': '2026-01-02T03:40:00.000Z',
                'completed_at': '2026-01-02T04:00:00.000Z',
              });
              await db.insert('workout_exercises', {
                'id': 1,
                'session_id': 1,
                'exercise_id': 1,
                'exercise_name': 'Supino reto com barra',
                'position': 0,
                'muscle_group': 'chest',
                'rest_seconds': 90,
              });
              await db.insert('workout_exercises', {
                'id': 2,
                'session_id': 2,
                'exercise_id': 1,
                'exercise_name': 'Supino reto com barra',
                'position': 0,
                'muscle_group': 'chest',
                'rest_seconds': 90,
              });
              await db.insert('workout_sets', {
                'id': 1,
                'workout_exercise_id': 1,
                'position': 0,
                'reps': 5,
                'weight_kg': 60.0,
                'set_type': 'working',
                'completed_at': '2026-01-02T03:25:00.000Z',
              });
              await db.insert('workout_sets', {
                'id': 2,
                'workout_exercise_id': 2,
                'position': 0,
                'reps': 5,
                'weight_kg': 80.0,
                'set_type': 'working',
                'completed_at': '2026-01-02T03:55:00.000Z',
              });
              await db.insert('personal_records', {
                'exercise_id': 1,
                'record_type': 'top_load',
                'value': 80.0,
                'achieved_at': '2026-01-02T03:55:00.000Z',
                'workout_set_id': 2,
              });
            },
          ),
        );
        await oldDatabase.close();

        final store = AppDatabase(factory: databaseFactoryFfi);
        try {
          final upgraded = await store.open(databasePath: databasePath);
          expect(await upgraded.getVersion(), 5);
          final history = await upgraded.query(
            'personal_record_achievements',
            where: "record_type = 'top_load'",
            orderBy: 'achieved_at',
          );
          expect(history, hasLength(2));
          expect(history.map((row) => row['session_id']), [1, 2]);
          expect(history.map((row) => row['value']), [60.0, 80.0]);
        } finally {
          await store.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'v3 migration tolerates deleted exercises in completed sessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'app-fit-v3-deleted-exercise',
      );
      final databasePath = '${directory.path}/app_fit.db';
      try {
        final oldDatabase = await databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(
            version: 3,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, _) async {
              await db.execute(
                'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
              );
              await createWorkoutSchema(db);
              await upgradeWorkoutSchema(db);
              final exerciseId = await db.insert('exercise_definitions', {
                'name': 'Exercício personalizado removido',
                'muscle_group': 'chest',
                'is_custom': 1,
              });
              final sessionId = await db.insert('workout_sessions', {
                'status': 'completed',
                'started_at': '2026-01-02T03:00:00.000Z',
                'completed_at': '2026-01-02T03:30:00.000Z',
              });
              final workoutExerciseId = await db.insert('workout_exercises', {
                'session_id': sessionId,
                'exercise_id': exerciseId,
                'exercise_name': 'Exercício personalizado removido',
                'position': 0,
                'muscle_group': 'chest',
              });
              await db.insert('workout_sets', {
                'workout_exercise_id': workoutExerciseId,
                'position': 0,
                'reps': 8,
                'weight_kg': 40.0,
                'set_type': 'working',
                'completed_at': '2026-01-02T03:25:00.000Z',
              });
              await db.delete(
                'exercise_definitions',
                where: 'id = ?',
                whereArgs: [exerciseId],
              );
            },
          ),
        );
        await oldDatabase.close();

        final store = AppDatabase(factory: databaseFactoryFfi);
        try {
          final upgraded = await store.open(databasePath: databasePath);
          expect(await upgraded.getVersion(), 5);
          expect(
            (await upgraded.query('workout_exercises')).single['exercise_id'],
            isNull,
          );
          expect(await upgraded.query('personal_record_achievements'), isEmpty);
        } finally {
          await store.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'preferences recover Telegram destination and last send after reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppPreferences(await SharedPreferences.getInstance());
      await prefs.saveTelegram(
        const TelegramSettings(
          token: 'test-token',
          chatId: '-123',
          threadId: '9',
        ),
      );
      await prefs.markSent(DateTime.utc(2026, 10, 6, 12));
      final restored = AppPreferences(await SharedPreferences.getInstance());
      expect(restored.telegram.configured, isTrue);
      expect(restored.telegram.threadId, '9');
      expect(restored.lastSentAt, DateTime.utc(2026, 10, 6, 12));
      await restored.saveTelegram(const TelegramSettings());
      expect(restored.telegram.configured, isFalse);
    },
  );
}
