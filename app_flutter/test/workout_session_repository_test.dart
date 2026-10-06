import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/features/workout/workout_models.dart';
import 'package:app_fit/features/workout/workout_progress_repository.dart';
import 'package:app_fit/features/workout/workout_repository.dart';
import 'package:app_fit/features/workout/workout_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingSink implements WorkoutEventSink {
  final events = <WorkoutDomainEvent>[];
  @override
  bool get hasConsumer => true;
  @override
  Future<void> onWorkoutCompleted(WorkoutDomainEvent event) async =>
      events.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late AppDatabase database;
  late WorkoutRepository library;
  late WorkoutSessionRepository sessions;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-fit-session-test');
    database = AppDatabase(factory: databaseFactoryFfi);
    await database.open(databasePath: '${directory.path}/app_fit.db');
    library = WorkoutRepository(database);
    sessions = WorkoutSessionRepository(database);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<int> makeRoutine() async {
    final exercise = (await library.listExercises(muscleGroup: 'chest')).first;
    return library.createRoutine(
      WorkoutRoutine(
        name: 'Peito',
        exercises: [
          RoutineExercise(
            exerciseId: exercise.id!,
            position: 0,
            plannedSets: 3,
            minReps: 6,
            maxReps: 10,
            restSeconds: 90,
            supersetGroup: 'A',
          ),
        ],
      ),
    );
  }

  test('estimated one-rep max uses Epley for supported rep ranges', () {
    expect(
      WorkoutSessionRepository.estimateOneRepMax(100, 1),
      closeTo(103.33, 0.01),
    );
    expect(
      WorkoutSessionRepository.estimateOneRepMax(100, 5),
      closeTo(116.67, 0.01),
    );
    expect(WorkoutSessionRepository.estimateOneRepMax(100, 13), 0);
  });

  test(
    'active session, sets and timer survive database close and reopen',
    () async {
      final routineId = await makeRoutine();
      final start = DateTime(2026, 10, 6, 8);
      final sessionId = await sessions.startSession(
        routineId: routineId,
        startedAt: start,
      );
      final active = (await sessions.getActiveSession())!;
      final exercise = active.exercises.single;
      expect(exercise.exercise.supersetGroup, 'A');
      expect(exercise.exercise.restSeconds, 90);
      expect(exercise.exercise.plannedSets, 3);
      expect(exercise.exercise.minReps, 6);
      expect(exercise.exercise.maxReps, 10);

      await sessions.addSet(
        workoutExerciseId: exercise.exercise.id!,
        reps: 8,
        weightKg: 52.5,
        rpe: 8,
      );
      await sessions.startRestTimer(
        sessionId,
        const Duration(seconds: 90),
        now: start,
      );
      expect(
        (await sessions.getRestTimer(
          sessionId,
          now: start.add(const Duration(seconds: 25)),
        ))!.remaining,
        const Duration(seconds: 65),
      );
      await sessions.pauseRestTimer(
        sessionId,
        now: start.add(const Duration(seconds: 25)),
      );
      await database.close();
      await database.open(databasePath: '${directory.path}/app_fit.db');

      final reopened = (await sessions.getActiveSession())!;
      expect(reopened.session.id, sessionId);
      expect(reopened.exercises.single.sets.single.weightKg, 52.5);
      final timer = await sessions.getRestTimer(
        sessionId,
        now: start.add(const Duration(minutes: 5)),
      );
      expect(timer!.isPaused, isTrue);
      expect(timer.remaining, const Duration(seconds: 65));
    },
  );

  test('valid completion publishes one domain event and creates correctly ordered PRs', () async {
    final routineId = await makeRoutine();
    final sessionId = await sessions.startSession(routineId: routineId);
    final exerciseId =
        (await sessions.getActiveSession())!.exercises.single.exercise.id!;
    final setId = await sessions.addSet(
      workoutExerciseId: exerciseId,
      reps: 5,
      weightKg: 50,
      rpe: 9,
    );
    await sessions.addSet(
      workoutExerciseId: exerciseId,
      reps: 12,
      weightKg: 10,
      type: WorkoutSetType.warmup,
    );
    await sessions.addSet(
      workoutExerciseId: exerciseId,
      reps: 100,
      weightKg: 500,
      completed: false,
    );

    final sink = _RecordingSink();
    await sessions.completeSession(sessionId, sink: sink);
    expect(sink.events, hasLength(1));
    expect(sink.events.single.completedSets, 2);
    expect(sink.events.single.volumeKg, 250);
    await expectLater(
      sessions.completeSession(sessionId, sink: sink),
      throwsStateError,
    );
    expect(sink.events, hasLength(1));

    final summary = await sessions.getSummary(sessionId);
    expect(summary.setCount, 2);
    expect(summary.volumeKg, 250);
    expect(summary.topLoadKg, 50);
    expect(
      summary.personalRecords.map((pr) => pr.recordType),
      containsAll(['top_load', 'estimated_1rm']),
    );
    expect(
      summary.personalRecords
          .firstWhere((pr) => pr.recordType == 'top_load')
          .workoutSetId,
      setId,
    );
    expect(sink.events.single.durationSeconds, greaterThanOrEqualTo(0));
  });

  test(
    'incomplete sets cannot complete a workout and never emit habit events',
    () async {
      final routineId = await makeRoutine();
      final sessionId = await sessions.startSession(routineId: routineId);
      final exerciseId =
          (await sessions.getActiveSession())!.exercises.single.exercise.id!;
      await sessions.addSet(
        workoutExerciseId: exerciseId,
        reps: 8,
        weightKg: 40,
        completed: false,
      );
      final sink = _RecordingSink();
      await expectLater(
        sessions.completeSession(sessionId, sink: sink),
        throwsStateError,
      );
      expect(sink.events, isEmpty);
      expect(await sessions.getCompletionEvent(sessionId), isNull);
      expect(await sessions.getActiveSessionId(), sessionId);
    },
  );

  test(
    'correcting or removing completed sets recalculates historical PRs',
    () async {
      final routineId = await makeRoutine();
      final firstSession = await sessions.startSession(routineId: routineId);
      var detail = (await sessions.getActiveSession())!;
      final firstExercise = detail.exercises.single.exercise.id!;
      final firstSet = await sessions.addSet(
        workoutExerciseId: firstExercise,
        reps: 5,
        weightKg: 50,
      );
      await sessions.completeSession(firstSession);

      final secondSession = await sessions.startSession(routineId: routineId);
      detail = (await sessions.getActiveSession())!;
      await sessions.addSet(
        workoutExerciseId: detail.exercises.single.exercise.id!,
        reps: 5,
        weightKg: 40,
      );
      await sessions.completeSession(secondSession);
      var prs = await sessions.listPersonalRecords();
      expect(prs.firstWhere((pr) => pr.recordType == 'top_load').value, 50);

      await sessions.deleteSet(firstSet);
      prs = await sessions.listPersonalRecords();
      expect(prs.firstWhere((pr) => pr.recordType == 'top_load').value, 40);
      final history = await sessions.listCompletedSessions();
      expect(
        history.firstWhere((s) => s.session.id == firstSession).setCount,
        0,
      );
    },
  );

  test(
    'timer adjustment decrements accurately and preserves paused state',
    () async {
      final id = await sessions.startSession();
      final now = DateTime(2026, 10, 6, 8);
      await sessions.startRestTimer(id, const Duration(seconds: 60), now: now);
      await sessions.adjustRestTimer(
        id,
        const Duration(seconds: -15),
        now: now,
      );
      var timer = await sessions.getRestTimer(id, now: now);
      expect(timer!.isPaused, isFalse);
      expect(timer.remaining, const Duration(seconds: 45));

      await sessions.pauseRestTimer(id, now: now);
      await sessions.adjustRestTimer(
        id,
        const Duration(seconds: -15),
        now: now,
      );
      timer = await sessions.getRestTimer(id, now: now);
      expect(timer!.isPaused, isTrue);
      expect(timer.remaining, const Duration(seconds: 30));
    },
  );

  test('skipping the rest timer is a separate idempotent action', () async {
    final id = await sessions.startSession();
    await sessions.startRestTimer(id, const Duration(seconds: 40));
    await sessions.skipRestTimer(id);
    await sessions.skipRestTimer(id);
    final timer = await sessions.getRestTimer(id);
    expect(timer!.isPaused, isTrue);
    expect(timer.remaining, Duration.zero);
  });

  test(
    'decrementing through zero leaves a running timer ready to alert',
    () async {
      final id = await sessions.startSession();
      final now = DateTime(2026, 10, 6, 8);
      await sessions.startRestTimer(id, const Duration(seconds: 10), now: now);
      await sessions.adjustRestTimer(
        id,
        const Duration(seconds: -15),
        now: now,
      );
      var timer = await sessions.getRestTimer(id, now: now);
      expect(timer!.isPaused, isFalse);
      expect(timer.remaining, Duration.zero);

      await sessions.markRestTimerAlerted(id);
      timer = await sessions.getRestTimer(id, now: now);
      expect(timer!.isPaused, isTrue);
      expect(timer.remaining, Duration.zero);
    },
  );

  test(
    'pending events survive no consumer, failure, retry and restart',
    () async {
      final routineId = await makeRoutine();
      final sessionId = await sessions.startSession(routineId: routineId);
      final exerciseId =
          (await sessions.getActiveSession())!.exercises.single.exercise.id!;
      await sessions.addSet(
        workoutExerciseId: exerciseId,
        reps: 8,
        weightKg: 40,
      );
      await sessions.completeSession(sessionId);

      final disconnected = WorkoutServices(database);
      await disconnected.replayPendingEvents();
      var db = await database.open();
      var outbox = (await db.query('workout_domain_events')).single;
      expect(outbox['delivered_at'], isNull);
      expect(outbox['delivery_attempts'], 0);

      await database.close();
      await database.open(databasePath: '${directory.path}/app_fit.db');
      final services = WorkoutServices(database);
      final persistedById = <int, WorkoutDomainEvent>{};
      var failAfterPersist = true;
      Future<void> consumer(WorkoutDomainEvent event) async {
        persistedById.putIfAbsent(event.id, () => event);
        if (failAfterPersist) {
          failAfterPersist = false;
          throw StateError('Falha simulada depois da persistência.');
        }
      }

      await expectLater(
        services.connectEventConsumer(consumer),
        throwsStateError,
      );
      db = await database.open();
      outbox = (await db.query('workout_domain_events')).single;
      expect(outbox['delivered_at'], isNull);
      expect(outbox['delivery_attempts'], 1);
      expect(outbox['last_error'], contains('Falha simulada'));

      await services.replayPendingEvents(propagateErrors: true);
      outbox = (await db.query('workout_domain_events')).single;
      expect(outbox['delivered_at'], isNotNull);
      expect(outbox['delivery_attempts'], 2);
      expect(outbox['last_error'], isNull);
      expect(persistedById, hasLength(1));
      expect(persistedById.values.single.sessionId, sessionId);
      await disconnected.dispose();
      await services.dispose();
    },
  );

  test(
    'session prescription remains a snapshot after routine changes',
    () async {
      final routineId = await makeRoutine();
      final sessionId = await sessions.startSession(routineId: routineId);
      final routine = (await library.getRoutine(routineId))!;
      await library.updateRoutine(
        WorkoutRoutine(
          id: routineId,
          name: routine.name,
          exercises: [
            RoutineExercise(
              exerciseId: routine.exercises.single.exerciseId,
              position: 0,
              plannedSets: 5,
              minReps: 10,
              maxReps: 15,
            ),
          ],
        ),
      );
      final snapshot = (await sessions.getSession(sessionId))!.exercises.single;
      expect(snapshot.exercise.plannedSets, 3);
      expect(snapshot.exercise.minReps, 6);
      expect(snapshot.exercise.maxReps, 10);
    },
  );

  test(
    'PR history is chronological and recalculates after edit and deletion',
    () async {
      final routineId = await makeRoutine();
      final base = DateTime.now().subtract(const Duration(hours: 1));

      Future<({int sessionId, int setId})> completeAt(
        DateTime start,
        DateTime finish,
        double weight,
      ) async {
        final sessionId = await sessions.startSession(
          routineId: routineId,
          startedAt: start,
        );
        final detail = (await sessions.getActiveSession())!;
        final setId = await sessions.addSet(
          workoutExerciseId: detail.exercises.single.exercise.id!,
          reps: 5,
          weightKg: weight,
        );
        await sessions.completeSession(sessionId, completedAt: finish);
        return (sessionId: sessionId, setId: setId);
      }

      final first = await completeAt(
        base,
        base.add(const Duration(minutes: 5)),
        50,
      );
      final second = await completeAt(
        base.add(const Duration(minutes: 10)),
        base.add(const Duration(minutes: 15)),
        60,
      );
      var firstSummary = await sessions.getSummary(first.sessionId);
      var secondSummary = await sessions.getSummary(second.sessionId);
      expect(
        firstSummary.personalRecords
            .firstWhere((pr) => pr.recordType == 'top_load')
            .value,
        50,
      );
      expect(
        secondSummary.personalRecords
            .firstWhere((pr) => pr.recordType == 'top_load')
            .value,
        60,
      );
      final coach = await WorkoutProgressRepository(database, sessions)
          .getCoachSummary(
            from: base.subtract(const Duration(days: 1)),
            to: base.add(const Duration(days: 1)),
          );
      expect(coach.personalRecords, hasLength(4));

      final secondDetail = (await sessions.getSession(second.sessionId))!;
      final secondSet = secondDetail.exercises.single.sets.single;
      await sessions.updateSet(
        WorkoutSet(
          id: second.setId,
          workoutExerciseId: secondSet.workoutExerciseId,
          position: secondSet.position,
          reps: 5,
          weightKg: 45,
          completedAt: secondSet.completedAt,
        ),
      );
      secondSummary = await sessions.getSummary(second.sessionId);
      expect(
        secondSummary.personalRecords.where(
          (pr) => pr.recordType == 'top_load',
        ),
        isEmpty,
      );

      final firstDetail = (await sessions.getSession(first.sessionId))!;
      final firstSet = firstDetail.exercises.single.sets.single;
      await sessions.updateSet(
        WorkoutSet(
          id: first.setId,
          workoutExerciseId: firstSet.workoutExerciseId,
          position: firstSet.position,
          reps: 5,
          weightKg: 70,
          completedAt: firstSet.completedAt,
        ),
      );
      secondSummary = await sessions.getSummary(second.sessionId);
      expect(secondSummary.personalRecords, isEmpty);
      expect(
        (await sessions.listPersonalRecords())
            .firstWhere((pr) => pr.recordType == 'top_load')
            .value,
        70,
      );

      await sessions.deleteSet(first.setId);
      firstSummary = await sessions.getSummary(first.sessionId);
      secondSummary = await sessions.getSummary(second.sessionId);
      expect(firstSummary.personalRecords, isEmpty);
      expect(
        secondSummary.personalRecords
            .firstWhere((pr) => pr.recordType == 'top_load')
            .value,
        45,
      );
      final updatedCoach = await WorkoutProgressRepository(database, sessions)
          .getCoachSummary(
            from: base.subtract(const Duration(days: 1)),
            to: base.add(const Duration(days: 1)),
          );
      final coachRecords = updatedCoach.personalRecords.join(' ');
      expect(updatedCoach.personalRecords, hasLength(2));
      expect(coachRecords, contains('(45.0)'));
      expect(coachRecords, isNot(contains('(70.0)')));
    },
  );

  test('coach summary contains aggregates only', () async {
    final progress = WorkoutProgressRepository(database, sessions);
    final routineId = await makeRoutine();
    final sessionId = await sessions.startSession(routineId: routineId);
    final exerciseId =
        (await sessions.getActiveSession())!.exercises.single.exercise.id!;
    await sessions.addSet(
      workoutExerciseId: exerciseId,
      reps: 8,
      weightKg: 35,
      rpe: 7,
    );
    await sessions.completeSession(sessionId);
    final summary = await progress.getCoachSummary(
      from: DateTime.now().subtract(const Duration(days: 1)),
      to: DateTime.now().add(const Duration(days: 1)),
    );
    expect(summary.sessions, 1);
    expect(summary.trainedDays, 1);
    expect(summary.volumeKg, 280);
    expect(summary.averageRpe, 7);
  });

  test('body measures and copied progress photos survive restart and delete locally', () async {
    final progress = WorkoutProgressRepository(database, sessions);
    final source = File('${directory.path}/source-photo.jpg');
    await source.writeAsBytes([1, 2, 3, 4]);
    await progress.saveBodyMeasurement(
      BodyMeasurement(
        measuredAt: DateTime(2026, 10, 6),
        weightKg: 72.4,
        bodyFatPercent: 18.5,
        measurementsCm: const {'waist': 82.0, 'arm': 34.5},
      ),
    );
    final photoId = await progress.importProgressPhoto(
      source.path,
      notes: 'Frente',
    );
    final measurement = (await progress.listBodyMeasurements()).single;
    expect(measurement.weightKg, 72.4);
    expect(measurement.measurementsCm['arm'], 34.5);
    final storedPath = (await progress.listProgressPhotos()).single.localPath;
    expect(storedPath, isNot(source.path));
    expect(await File(storedPath).readAsBytes(), [1, 2, 3, 4]);

    await database.close();
    await database.open(databasePath: '${directory.path}/app_fit.db');
    expect((await progress.listProgressPhotos()).single.notes, 'Frente');
    await progress.deleteProgressPhoto(photoId);
    expect(await File(storedPath).exists(), isFalse);
  });
}
