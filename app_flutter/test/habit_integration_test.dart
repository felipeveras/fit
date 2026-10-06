import 'dart:convert';
import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/core/persistence/workout_schema.dart';
import 'package:app_fit/core/health/health_exercise_repository.dart';
import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/features/habits/habit_automation.dart';
import 'package:app_fit/features/habits/habit_controller.dart';
import 'package:app_fit/features/habits/habit_models.dart';
import 'package:app_fit/features/habits/habit_repository.dart';
import 'package:app_fit/features/workout/workout_services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'health_fixture.dart';

Habit automatic(String id, HabitAutomation automation) => Habit(
  id: id,
  name: id,
  type: automation == HabitAutomation.healthConnectSteps
      ? HabitType.quantitative
      : HabitType.positive,
  quantityTarget: automation == HabitAutomation.healthConnectSteps
      ? 8000
      : null,
  quantityUnit: automation == HabitAutomation.healthConnectSteps
      ? 'passos'
      : null,
  schedule: HabitSchedule(
    cadence: HabitCadence.daily,
    startDate: DateTime(2026, 10, 5),
  ),
  automation: automation,
);

HealthExercisePeriod exercisePeriod({
  String origin = 'garmin',
  String availability = 'available',
  bool session = true,
  bool provisional = false,
}) => HealthExercisePeriod.fromMap({
  'days': 1,
  'timezone': 'America/Sao_Paulo',
  'readAt': '2026-10-06T15:00:00Z',
  'sourcePolicy': 'single_origin',
  'originPackage': origin,
  'coverage': [
    {
      'date': '2026-10-05',
      'availability': availability,
      'readComplete': ['available', 'no_data'].contains(availability),
      'provisional': provisional,
      'origins': session ? [origin] : <String>[],
      'errorCode': null,
    },
  ],
  'sessions': session
      ? [
          {
            'id': 'same-id',
            'origin': origin,
            'date': '2026-10-05',
            'startAt': '2026-10-05T10:00:00Z',
            'endAt': '2026-10-05T11:00:00Z',
            'lastModifiedAt': '2026-10-05T11:00:00Z',
            'exerciseType': 56,
            'isRunning': true,
          },
        ]
      : <Object?>[],
});

class StepsOnly implements HealthRepository {
  @override
  Future<HealthAvailability> getAvailability() async =>
      HealthAvailability.available;
  @override
  Future<HealthPeriodSummary> getPeriod(int days) async => HealthPeriodSummary(
    days: days,
    timezone: 'America/Sao_Paulo',
    snapshots: [
      HealthSnapshot.fromMap(snapshotDto(date: '2026-10-05', value: 9000)),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ExerciseOnly implements HealthRepository, HealthExerciseRepository {
  @override
  Future<ExercisePermissionState> getExercisePermissions() async =>
      const ExercisePermissionState(
        HealthAvailability.available,
        true,
        ExerciseHistoryAccess.availableAndGranted,
      );
  @override
  Future<HealthExercisePeriod> getExerciseSessions(
    int days, {
    String? originPackage,
  }) async => exercisePeriod(origin: originPackage ?? 'garmin');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late AppDatabase store;
  late HabitRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fit-integration');
    store = AppDatabase(factory: databaseFactoryFfi);
    await store.open(databasePath: '${directory.path}/app_fit.db');
    repository = HabitRepository(store);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('v4 upgrade adds habits while preserving workout rows', () async {
    await store.close();
    final oldPath = '${directory.path}/old.db';
    final old = await databaseFactoryFfi.openDatabase(
      oldPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await createWorkoutSchema(db);
          await upgradeWorkoutSchema(db);
          await upgradeWorkoutSchemaV4(db);
          await db.insert('workout_sessions', {
            'id': 1,
            'status': 'completed',
            'started_at': '2026-10-05T10:00:00Z',
            'completed_at': '2026-10-05T11:00:00Z',
          });
        },
      ),
    );
    await old.close();
    store = AppDatabase(factory: databaseFactoryFfi);
    final db = await store.open(databasePath: oldPath);
    expect(await db.getVersion(), 5);
    expect(await db.query('workout_sessions'), hasLength(1));
    expect(await db.query('habits'), isEmpty);
  });

  test(
    'durable workout consumer retries after commit and restart exactly once',
    () async {
      await repository.saveHabit(automatic('workout', HabitAutomation.workout));
      final db = await store.open();
      await db.insert('workout_sessions', {
        'id': 1,
        'status': 'completed',
        'started_at': '2026-10-05T10:00:00Z',
        'completed_at': '2026-10-05T11:00:00Z',
      });
      await db.insert('workout_domain_events', {
        'event_type': 'workout_completed',
        'session_id': 1,
        'occurred_at': '2026-10-05T11:00:00Z',
        'payload_json': jsonEncode({
          'exercise_count': 1,
          'completed_sets': 1,
          'volume_kg': 200,
          'duration_seconds': 3600,
        }),
      });
      var services = WorkoutServices(store);
      await services.replayPendingEvents();
      final consumer = WorkoutHabitConsumer(repository);
      await expectLater(
        services.connectEventConsumer((event) async {
          await consumer.consume(event);
          throw StateError('crash after commit');
        }),
        throwsStateError,
      );
      expect(await db.query('habit_completions'), hasLength(1));
      expect(
        (await db.query('workout_domain_events')).single['delivered_at'],
        isNull,
      );
      await services.dispose();
      await store.close();
      store = AppDatabase(factory: databaseFactoryFfi);
      await store.open(databasePath: '${directory.path}/app_fit.db');
      repository = HabitRepository(store);
      services = WorkoutServices(store);
      await services.connectEventConsumer(
        WorkoutHabitConsumer(repository).consume,
      );
      await services.replayPendingEvents(propagateErrors: true);
      final reopened = await store.open();
      expect(await reopened.query('habit_completions'), hasLength(1));
      expect(
        (await reopened.query('workout_domain_events')).single['delivered_at'],
        isNotNull,
      );
      await services.dispose();
    },
  );

  test('exercise origin/id identity survives repeated reads; failed coverage is not a miss', () async {
    await repository.saveHabit(
      automatic('run', HabitAutomation.healthConnectRun),
    );
    await repository.consumeHealthConnectExercises(exercisePeriod());
    await repository.consumeHealthConnectExercises(exercisePeriod());
    expect(await (await store.open()).query('habit_completions'), hasLength(1));
    await repository.consumeHealthConnectExercises(
      exercisePeriod(origin: 'healthsync'),
    );
    expect(await (await store.open()).query('habit_completions'), hasLength(2));
    await repository.consumeHealthConnectExercises(
      exercisePeriod(availability: 'read_error', session: false),
    );
    final failed = (await repository.loadProgress(
      through: DateTime(2026, 10, 5),
    )).single;
    expect(failed.stats.scheduledOpportunities, 0);
    expect(await (await store.open()).query('habit_completions'), hasLength(2));
  });

  test(
    'steps-only and exercise-only capabilities remain independent',
    () async {
      await repository.saveHabit(
        automatic('steps', HabitAutomation.healthConnectSteps),
      );
      var controller = HabitController(repository, health: StepsOnly());
      await controller.refresh();
      await controller.syncHealthHistory();
      expect(
        await (await store.open()).query('habit_quantity_logs'),
        hasLength(1),
      );
      controller.dispose();
      await repository.archive('steps');
      await repository.saveHabit(
        automatic('exercise', HabitAutomation.healthConnectExercise),
      );
      controller = HabitController(repository, health: ExerciseOnly());
      await controller.refresh();
      await controller.syncHealthHistory();
      expect(
        await (await store.open()).query('habit_completions'),
        hasLength(1),
      );
      expect(controller.error, isNull);
      controller.dispose();
    },
  );

  test('provisional empty and denied exercise days never become missed opportunities', () async {
    await repository.saveHabit(
      automatic('run', HabitAutomation.healthConnectRun),
    );
    for (final period in [
      exercisePeriod(
        availability: 'no_data',
        session: false,
        provisional: true,
      ),
      exercisePeriod(availability: 'permission_denied', session: false),
      exercisePeriod(availability: 'history_restricted', session: false),
    ]) {
      await repository.consumeHealthConnectExercises(period);
      expect(
        (await repository.loadProgress(through: DateTime(2026, 10, 5)))
            .single
            .stats
            .scheduledOpportunities,
        0,
      );
    }
  });
}
