import 'dart:io';

import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/features/habits/habit_controller.dart';
import 'package:app_fit/features/habits/habit_models.dart';
import 'package:app_fit/features/habits/habit_repository.dart';
import 'package:app_fit/features/habits/habit_tracker_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'health_fixture.dart';

Future<void> settleDatabaseUi(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('SQLite UI did not finish loading');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final monday = DateTime(2026, 10, 5);

  Habit habit({
    HabitType type = HabitType.positive,
    HabitCadence cadence = HabitCadence.daily,
    int target = 1,
    int dailyTarget = 1,
    double? quantityTarget,
    String? unit,
    HabitAutomation automation = HabitAutomation.manual,
  }) => Habit(
    id: 'habit-test',
    name: 'Hábito de teste',
    type: type,
    schedule: HabitSchedule(
      cadence: cadence,
      targetCount: target,
      startDate: monday,
    ),
    dailyTargetCount: dailyTarget,
    quantityTarget: quantityTarget,
    quantityUnit: unit,
    automation: automation,
  );

  HabitStats calculate(
    Habit item,
    Map<DateTime, HabitDayRecord> history,
    DateTime through, {
    Set<DateTime> vacations = const {},
    Set<DateTime> rests = const {},
    Map<DateTime, List<int>> minutes = const {},
  }) => calculateHabitStats(
    habit: item,
    history: history,
    from: item.schedule.startDate,
    through: through,
    vacationDays: vacations,
    restDays: rests,
    completionMinutes: minutes,
  );

  test('quantitative habits require a positive target and non-empty unit', () {
    expect(() => habit(type: HabitType.quantitative), throwsArgumentError);
    expect(
      () => habit(type: HabitType.quantitative, quantityTarget: 0, unit: 'ml'),
      throwsArgumentError,
    );
    expect(
      habit(
        type: HabitType.quantitative,
        quantityTarget: 2500,
        unit: 'ml',
      ).quantityTarget,
      2500,
    );
  });

  test('three consecutive workout completions satisfy one weekly target', () {
    final item = habit(cadence: HabitCadence.weeklyTarget, target: 3);
    final result = calculate(item, {
      monday: const HabitDayRecord(completions: 1),
      monday.add(const Duration(days: 1)): const HabitDayRecord(completions: 1),
      monday.add(const Duration(days: 2)): const HabitDayRecord(completions: 1),
    }, monday.add(const Duration(days: 2)));
    expect(result.completedOpportunities, 3);
    expect(result.scheduledOpportunities, 3);
    expect(result.adherence, 1);
    expect(result.currentStreak, 1);
  });

  test('monthly target counts occurrences across the whole month', () {
    final item = habit(cadence: HabitCadence.monthlyTarget, target: 3);
    final result = calculate(item, {
      for (var i = 0; i < 3; i++)
        monday.add(Duration(days: i)): const HabitDayRecord(completions: 1),
    }, monday.add(const Duration(days: 2)));
    expect(result.completedOpportunities, 3);
    expect(result.scheduledOpportunities, 3);
    expect(result.adherence, 1);
  });

  test('daily positive goals support multiple occurrences and separate streak from adherence', () {
    final item = habit(dailyTarget: 2);
    final result = calculate(item, {
      monday: const HabitDayRecord(completions: 2),
      monday.add(const Duration(days: 1)): const HabitDayRecord(completions: 1),
    }, monday.add(const Duration(days: 1)));
    expect(result.completedOpportunities, 3);
    expect(result.scheduledOpportunities, 4);
    expect(result.adherence, .75);
    expect(result.currentStreak, 0);
    expect(result.bestStreak, 1);
  });

  test('avoid and quantitative habits retain adherence without guilt-based outcomes', () {
    final avoid = calculate(habit(type: HabitType.avoid), {
      monday: const HabitDayRecord(),
      monday.add(const Duration(days: 1)): const HabitDayRecord(completions: 1),
      monday.add(const Duration(days: 2)): const HabitDayRecord(),
    }, monday.add(const Duration(days: 2)));
    expect(avoid.completedOpportunities, 2);
    expect(avoid.scheduledOpportunities, 3);
    expect(avoid.adherence, closeTo(2 / 3, .001));
    expect(avoid.totalCompletions, 1);

    final quantity = calculate(
      habit(type: HabitType.quantitative, quantityTarget: 100, unit: 'ml'),
      {
        monday: const HabitDayRecord(quantity: 65, quantityEntries: 2),
        monday.add(const Duration(days: 1)): const HabitDayRecord(
          quantity: 110,
          quantityEntries: 1,
        ),
      },
      monday.add(const Duration(days: 1)),
    );
    expect(quantity.completedOpportunities, 1);
    expect(quantity.totalCompletions, 3);
  });

  test('specific weekdays, every-N schedule, vacation and rest days preserve eligible streaks', () {
    final weekdays = HabitSchedule(
      cadence: HabitCadence.specificDays,
      weekdays: {DateTime.monday, DateTime.wednesday},
      startDate: monday,
    );
    expect(weekdays.isScheduled(monday), isTrue);
    expect(weekdays.isScheduled(monday.add(const Duration(days: 1))), isFalse);
    final everyTwoDays = HabitSchedule(
      cadence: HabitCadence.everyNDays,
      intervalDays: 2,
      startDate: monday,
    );
    expect(
      everyTwoDays.isScheduled(monday.add(const Duration(days: 2))),
      isTrue,
    );
    expect(
      everyTwoDays.isScheduled(monday.add(const Duration(days: 1))),
      isFalse,
    );

    final thursday = monday.add(const Duration(days: 3));
    final result = calculate(
      habit(),
      {
        monday: const HabitDayRecord(completions: 1),
        thursday: const HabitDayRecord(completions: 1),
      },
      thursday,
      vacations: {monday.add(const Duration(days: 1))},
      rests: {monday.add(const Duration(days: 2))},
    );
    expect(result.scheduledOpportunities, 2);
    expect(result.completedOpportunities, 2);
    expect(result.currentStreak, 2);
  });

  test('local date keys remain stable within the same local day and roll over at midnight', () {
    expect(habitDateKey(DateTime(2026, 10, 6, 23, 59)), '2026-10-06');
    expect(habitDateKey(DateTime(2026, 10, 7)), '2026-10-07');
    final instant = DateTime.utc(2026, 10, 7);
    final local = instant.toLocal();
    expect(
      habitDateKey(instant),
      habitDateKey(DateTime(local.year, local.month, local.day, local.hour)),
    );
  });

  test('workout event is committed once and remains deduplicated after database reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'habit-restart-test',
    );
    final path = '${directory.path}/app_fit.db';
    var store = AppDatabase(factory: databaseFactoryFfi);
    try {
      var repository = HabitRepository(store);
      await store.open(databasePath: path);
      await repository.saveHabit(habit(automation: HabitAutomation.workout));
      const eventId = 'event-001', sessionId = 'session-001';
      final occurredAt = DateTime(2026, 10, 6, 7, 30);
      expect(
        await repository.ingestWorkoutCompletion(
          eventId: eventId,
          sessionId: sessionId,
          occurredAt: occurredAt,
        ),
        1,
      );
      expect(
        await repository.ingestWorkoutCompletion(
          eventId: eventId,
          sessionId: sessionId,
          occurredAt: occurredAt,
        ),
        0,
      );
      await store.close();
      store = AppDatabase(factory: databaseFactoryFfi);
      repository = HabitRepository(store);
      await store.open(databasePath: path);
      expect(
        await repository.ingestWorkoutCompletion(
          eventId: eventId,
          sessionId: sessionId,
          occurredAt: occurredAt,
        ),
        0,
      );
      var rows = await (await store.open()).query('habit_completions');
      expect(rows, hasLength(1));
      await repository.removeCompletion(rows.single['id']! as String);
      expect(
        await repository.ingestWorkoutCompletion(
          eventId: eventId,
          sessionId: sessionId,
          occurredAt: occurredAt,
        ),
        0,
      );
      rows = await (await store.open()).query('habit_completions');
      expect(rows, isEmpty);
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  test('a past completion time can be corrected and the log removed', () async {
    final directory = await Directory.systemTemp.createTemp('habit-edit-test');
    final store = AppDatabase(factory: databaseFactoryFfi);
    try {
      final repository = HabitRepository(store);
      await store.open(databasePath: '${directory.path}/app_fit.db');
      await repository.saveHabit(habit());
      await repository.addCompletion(
        'habit-test',
        DateTime(2026, 10, 5, 8, 15),
      );
      final original = (await repository.logsForDay(
        'habit-test',
        monday,
      )).single;
      await repository.adjustLogTime(
        original['id']! as String,
        completion: true,
        occurredAt: DateTime(2026, 10, 5, 19, 40),
      );
      final changed = (await repository.logsForDay(
        'habit-test',
        monday,
      )).single;
      expect(
        DateTime.parse(changed['occurred_at']! as String).toLocal().hour,
        19,
      );
      expect(
        DateTime.parse(changed['occurred_at']! as String).toLocal().minute,
        40,
      );
      await repository.removeCompletion(changed['id']! as String);
      expect(await repository.logsForDay('habit-test', monday), isEmpty);
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  test('Health Connect zero snapshots retain coverage and delete an older automatic sample', () async {
    final directory = await Directory.systemTemp.createTemp('habit-steps-test');
    final store = AppDatabase(factory: databaseFactoryFfi);
    try {
      final repository = HabitRepository(store);
      await store.open(databasePath: '${directory.path}/app_fit.db');
      await repository.saveHabit(
        habit(
          type: HabitType.quantitative,
          quantityTarget: 8000,
          unit: 'passos',
          automation: HabitAutomation.healthConnectSteps,
        ),
      );
      final available = HealthSnapshot.fromMap(
        snapshotDto(date: '2026-10-05', value: 9000),
      );
      final zero = HealthSnapshot.fromMap(
        snapshotDto(date: '2026-10-05', value: 0),
      );
      final noData = HealthSnapshot.fromMap(
        snapshotDto(date: '2026-10-06', availability: 'no_data', value: null),
      );
      final denied = HealthSnapshot.fromMap(
        snapshotDto(
          date: '2026-10-07',
          availability: 'permission_denied',
          value: null,
        ),
      );
      await repository.consumeHealthConnectSteps(
        HealthPeriodSummary(
          days: 7,
          timezone: 'America/Sao_Paulo',
          snapshots: [available],
        ),
      );
      expect(
        await (await store.open()).query('habit_quantity_logs'),
        hasLength(1),
      );
      await repository.consumeHealthConnectSteps(
        HealthPeriodSummary(
          days: 7,
          timezone: 'America/Sao_Paulo',
          snapshots: [zero, noData, denied],
        ),
      );
      final rows = await repository.loadProgress(
        through: DateTime(2026, 10, 7),
      );
      final result = rows.single.stats;
      expect(result.completedOpportunities, 0);
      expect(result.scheduledOpportunities, 1);
      expect(result.totalCompletions, 0);
      expect(await (await store.open()).query('habit_quantity_logs'), isEmpty);
      final coverage = await (await store.open()).query(
        'habit_health_coverage',
      );
      expect(
        coverage.map((r) => r['availability']),
        containsAll(['available', 'noData', 'permissionDenied']),
      );
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  test('selected historical checklist reload keeps metrics through the current cutoff', () async {
    final directory = await Directory.systemTemp.createTemp(
      'habit-selected-day-test',
    );
    final store = AppDatabase(factory: databaseFactoryFfi);
    final controller = HabitController(HabitRepository(store));
    try {
      await store.open(databasePath: '${directory.path}/app_fit.db');
      final repository = controller.repository;
      await repository.saveHabit(habit(), substeps: ['Etapa A', 'Etapa B']);
      final steps = await (await store.open()).query(
        'habit_substeps',
        orderBy: 'position',
      );
      final tuesday = monday.add(const Duration(days: 1));
      for (final day in [monday, tuesday]) {
        for (final step in steps) {
          await repository.toggleSubstep(step['id']! as String, day, true);
        }
        await repository.addCompletion(
          'habit-test',
          DateTime(day.year, day.month, day.day, 12),
        );
      }

      await controller.selectDate(monday, metricThrough: tuesday);
      final progress = controller.habits.single;
      expect(
        progress.checkedSubsteps,
        steps.map((step) => step['id']! as String).toSet(),
      );
      expect(progress.history[tuesday]?.completions, 1);
      expect(progress.stats.totalCompletions, 2);
    } finally {
      controller.dispose();
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('Pomodoro starts and counts down the configured break', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('habit-pomodoro-test'),
    ))!;
    final store = AppDatabase(factory: databaseFactoryFfi);
    final controller = HabitController(HabitRepository(store));
    try {
      await tester.runAsync(
        () => store.open(databasePath: '${directory.path}/app_fit.db'),
      );
      await tester.runAsync(() => controller.refresh());
      await tester.runAsync(
        () => controller.saveFocus(goal: 60, work: 1, pause: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FocusPanel(controller: controller)),
        ),
      );

      await tester.tap(find.text('Iniciar 1 min'));
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
      expect(find.textContaining('Sessão concluída'), findsOneWidget);

      await tester.tap(find.text('Iniciar pausa (1 min)'));
      await tester.pump();
      expect(find.text('01:00'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
      expect(find.text('Iniciar 1 min'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() => store.close());
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets(
    'quantitative editor validates and saves a comma decimal identically',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('habit-quantity-editor-test'),
      ))!;
      final store = AppDatabase(factory: databaseFactoryFfi);
      try {
        await tester.runAsync(
          () => store.open(databasePath: '${directory.path}/app_fit.db'),
        );
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(home: HabitTrackerPage(database: store)),
          );
        });
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await settleDatabaseUi(tester);
        await tester.tap(find.byTooltip('Criar hábito'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await settleDatabaseUi(tester);
        await tester.tap(find.text('Quantidade'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await settleDatabaseUi(tester);
        await tester.enterText(find.byType(TextFormField).at(0), 'Agua');
        await tester.enterText(find.byType(TextFormField).at(1), '2,5');
        await tester.enterText(find.byType(TextFormField).at(2), 'ml');
        await tester.tap(find.text('Salvar'));
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump();
          final saved = await tester.runAsync(
            () async => (await store.open()).query('habits'),
          );
          if (saved!.isNotEmpty) break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await settleDatabaseUi(tester);

        final habits = (await tester.runAsync(
          () async => (await store.open()).query('habits'),
        ))!;
        expect(habits, hasLength(1));
        expect(habits.single['quantity_target'], 2.5);
        expect(habits.single['quantity_unit'], 'ml');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => store.close());
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  test('snoozed reminder survives reload and private notes are excluded from public summaries', () async {
    final directory = await Directory.systemTemp.createTemp(
      'habit-reminder-test',
    );
    final path = '${directory.path}/app_fit.db';
    var store = AppDatabase(factory: databaseFactoryFfi);
    try {
      var repository = HabitRepository(store);
      await store.open(databasePath: path);
      await repository.saveHabit(habit());
      await repository.snoozeReminder('habit-test');
      await repository.addCompletion(
        'habit-test',
        monday,
        note: 'nota privada',
        behavioralMoment: 'momento privado',
      );
      final before = await repository.coachSummary(through: monday);
      expect('$before', isNot(contains('nota privada')));
      expect('$before', isNot(contains('momento privado')));
      await store.close();
      store = AppDatabase(factory: databaseFactoryFfi);
      repository = HabitRepository(store);
      await store.open(databasePath: path);
      await repository.saveHabit(
        habit(),
      ); // A refresh/save must not reset persisted snooze state.
      final reminder = (await (await store.open()).query('habit_reminders'))
          .single;
      expect(
        DateTime.parse(reminder['snoozed_until']! as String)
            .isAfter(DateTime.now().toUtc()),
        isTrue,
      );
      expect(
        (await repository.loadProgress(through: monday))
            .single
            .stats
            .totalCompletions,
        1,
      );
      expect(
        await (await store.open()).query('behavioral_moments'),
        hasLength(1),
      );
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });
}
