import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/features/workout/workout_models.dart';
import 'package:app_fit/features/workout/workout_pages.dart';
import 'package:app_fit/features/workout/workout_repository.dart';
import 'package:app_fit/features/workout/workout_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late AppDatabase database;
  late WorkoutServices services;
  late int sessionId;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-fit-workout-ui');
    database = AppDatabase(factory: databaseFactoryFfi);
    await database.open(databasePath: '${directory.path}/app_fit.db');
    services = WorkoutServices(database);
    final library = WorkoutRepository(database);
    final exercise = (await library.listExercises(muscleGroup: 'chest')).first;
    final routineId = await library.createRoutine(
      WorkoutRoutine(
        name: 'Rotina UI',
        exercises: [
          RoutineExercise(
            exerciseId: exercise.id!,
            position: 0,
            plannedSets: 3,
            minReps: 6,
            maxReps: 10,
            restSeconds: 60,
          ),
        ],
      ),
    );
    sessionId = await services.sessions.startSession(routineId: routineId);
    await services.sessions.startRestTimer(
      sessionId,
      const Duration(seconds: 60),
    );
  });

  tearDown(() async {
    await services.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpWorkoutPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ActiveWorkoutPage(services: services, sessionId: sessionId),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmountWorkoutPage(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('−15 s subtracts time through the active workout UI', (
    tester,
  ) async {
    await pumpWorkoutPage(tester);
    try {
      expect(find.text('−15 s'), findsOneWidget);
      expect(find.byTooltip('Pular descanso'), findsOneWidget);
      final before = await tester.runAsync(
        () => services.sessions.getRestTimer(sessionId),
      );

      await tester.tap(find.text('−15 s'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();

      final timer = await tester.runAsync(
        () => services.sessions.getRestTimer(sessionId),
      );
      expect(timer, isNotNull);
      expect(timer!.isPaused, isFalse);
      expect(
        timer.endsAt,
        before!.endsAt!.subtract(const Duration(seconds: 15)),
      );
    } finally {
      await unmountWorkoutPage(tester);
    }
  });

  testWidgets('−15 s preserves a paused timer and skip is separate', (
    tester,
  ) async {
    await tester.runAsync(() => services.sessions.pauseRestTimer(sessionId));
    await pumpWorkoutPage(tester);
    try {
      await tester.tap(find.text('−15 s'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
      var timer = await tester.runAsync(
        () => services.sessions.getRestTimer(sessionId),
      );
      expect(timer!.isPaused, isTrue);
      expect(timer.remaining.inSeconds, inInclusiveRange(44, 45));

      await tester.tap(find.byTooltip('Pular descanso'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      timer = await tester.runAsync(
        () => services.sessions.getRestTimer(sessionId),
      );
      expect(timer!.isPaused, isTrue);
      expect(timer.remaining, Duration.zero);
    } finally {
      await unmountWorkoutPage(tester);
    }
  });

  testWidgets(
    'set entry shows the routine target and pre-fills its rep floor',
    (tester) async {
      await pumpWorkoutPage(tester);
      try {
        await tester.tap(find.text('+ Série'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Meta: 1/3 séries · 6–10 reps'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is TextField && widget.controller?.text == '6',
          ),
          findsOneWidget,
        );
      } finally {
        await unmountWorkoutPage(tester);
      }
    },
  );
}
