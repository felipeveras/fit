
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/health/health_repository.dart';
import '../../core/health/health_exercise_repository.dart';
import 'habit_reminder_bridge.dart';
import 'habit_models.dart';
import 'habit_repository.dart';

class HabitController extends ChangeNotifier {
  HabitController(this.repository, {this.health});
  final HabitRepository repository;
  final HealthRepository? health;

  List<HabitProgress> habits = const [];
  List<HabitProgress> archived = const [];
  List<Map<String, Object?>> focusHistory = const [];
  Map<String, int> focusConfig = const {
    'dailyGoalMinutes': 60,
    'workMinutes': 25,
    'breakMinutes': 5,
  };
  DateTime selectedDate = habitDay(DateTime.now());
  bool loading = false, syncingSteps = false;
  String? error;
  bool _disposed = false;
  int _refreshSequence = 0;
  StreamSubscription<WorkoutCompletionEvent>? _workoutSubscription;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh({DateTime? metricThrough}) async {
    final sequence = ++_refreshSequence;
    loading = true;
    error = null;
    _notify();
    try {
      final active = await repository.loadProgress(
        through: metricThrough,
        selectedDate: selectedDate,
      );
      final archivedRows = await repository.loadProgress(
        through: metricThrough,
        selectedDate: selectedDate,
        archived: true,
      );
      final config = await repository.focusSettings();
      final sessions = await repository.focusSessions(
        since: habitDay(metricThrough ?? DateTime.now())
            .subtract(const Duration(days: 365)),
      );
      if (sequence != _refreshSequence) return;
      habits = active;
      archived = archivedRows;
      focusConfig = config;
      focusHistory = sessions;
    } catch (_) {
      if (sequence != _refreshSequence) return;
      error = 'Não foi possível abrir seus hábitos. Tente atualizar.';
    } finally {
      if (sequence == _refreshSequence) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> syncStepHistory() async {
    if (syncingSteps ||
        health == null ||
        !habits.any(
          (p) => p.habit.automation == HabitAutomation.healthConnectSteps,
        ))
      return;
    syncingSteps = true;
    _notify();
    try {
      // The platform returns per-date availability and coverage for each daily snapshot.
      // We intentionally do not gate step reads on the exercise-session permission.
      if (await health!.getAvailability() == HealthAvailability.available) {
        await repository.consumeHealthConnectSteps(await health!.getPeriod(90));
        habits = await repository.loadProgress(selectedDate: selectedDate);
      }
    } catch (_) {
      error = 'A leitura de passos não foi atualizada. Os registros manuais continuam disponíveis.';
    } finally {
      syncingSteps = false;
      _notify();
    }
  }

  Future<void> syncExerciseHistory() async {

    final source = health;

    if (source is! HealthExerciseRepository || !habits.any((p) => p.habit.automation == HabitAutomation.healthConnectExercise || p.habit.automation == HabitAutomation.healthConnectRun)) return;

    try {

      final permissions = await source.getExercisePermissions();

      if (!permissions.granted) {

        error = 'Autorize a leitura de exerc?cios nas Configura??es para atualizar estes h?bitos.';

        _notify();

        return;

      }

      await repository.consumeHealthConnectExercises(await source.getExerciseSessions(90));

      await refresh();

    } catch (_) {

      error = 'A leitura de exerc?cios n?o foi atualizada. Os registros anteriores continuam dispon?veis.';

      _notify();

    }

  }



  Future<void> syncHealthHistory() async {

    await syncStepHistory();

    await syncExerciseHistory();

  }



  /// Connect the #20 producer through this narrow, testable stream contract.
  /// Producers must publish only finalized sessions with stable eventId and sessionId.
  void connectWorkoutSource(ExerciseHabitEventSource source) {
    _workoutSubscription?.cancel();
    _workoutSubscription = source.completedSessions.listen(
      (event) async {
        try {
          await repository.ingestWorkoutCompletion(
            eventId: event.eventId,
            sessionId: event.sessionId,
            occurredAt: event.occurredAt,
            exerciseType: event.exerciseType,
            label: event.label,
            source: event.source,
            isRunning: event.isRunning,
          );
          await refresh();
        } catch (_) {
          error = 'A conclusão automática do treino não foi salva.';
          _notify();
        }
      },
      onError: (_) {
        error = 'Não foi possível receber os eventos de treino.';
        _notify();
      },
    );
  }

  Future<void> selectDate(DateTime date, {DateTime? metricThrough}) async {
    selectedDate = habitDay(date);
    _notify();
    await refresh(metricThrough: metricThrough);
  }

  Future<void> save(
    Habit habit, {
    List<String> substeps = const [],
  }) async => _run(() async {
    await repository.saveHabit(habit, substeps: substeps);
    var reminderPermissionDenied = false;
    if (habit.reminderEnabled) {
      try {
        final granted = await HabitReminderBridge.requestPermission();
        await HabitReminderBridge.sync(habit.id, enabled: true);
        reminderPermissionDenied = !granted;
      } catch (_) {
        // Non-Android hosts still retain the reminder configuration in SQLite.
      }
    } else {
      try {
        await HabitReminderBridge.sync(habit.id, enabled: false);
      } catch (_) {}
    }
    await refresh();
    if (reminderPermissionDenied) {
      error = 'O horário foi salvo. Permita notificações do App Fit para receber lembretes.';
      _notify();
    }
  });
  DateTime get selectedOccurrenceTime {
    final day = habitDay(selectedDate), now = DateTime.now();
    return day == habitDay(now)
        ? now
        : DateTime(day.year, day.month, day.day, 12);
  }

  Future<void> complete(
    String id, {
    String? note,
    String? behavioralMoment,
  }) async => _run(() async {
    await repository.addCompletion(
      id,
      selectedOccurrenceTime,
      note: note,
      behavioralMoment: behavioralMoment,
    );
    await repository.clearSnooze(id);
    try {
      await HabitReminderBridge.sync(id, enabled: true);
    } catch (_) {}
    await refresh();
  });
  Future<void> addQuantity(
    String id,
    double amount, {
    String? note,
    String? behavioralMoment,
  }) async => _run(() async {
    await repository.addQuantity(
      id,
      amount,
      selectedOccurrenceTime,
      note: note,
      behavioralMoment: behavioralMoment,
    );
    await repository.clearSnooze(id);
    try {
      await HabitReminderBridge.sync(id, enabled: true);
    } catch (_) {}
    await refresh();
  });
  Future<void> removeLog(Map<String, Object?> log) async => _run(() async {
    if (log['log_kind'] == 'completion') {
      await repository.removeCompletion(log['id']! as String);
    } else {
      await repository.removeQuantity(log['id']! as String);
    }
    await _syncReminder(log['habit_id']! as String);
    await refresh();
  });
  Future<void> adjustLogTime(
    Map<String, Object?> log,
    int hour,
    int minute,
  ) async => _run(() async {
    final day = habitDay(selectedDate);
    await repository.adjustLogTime(
      log['id']! as String,
      completion: log['log_kind'] == 'completion',
      occurredAt: DateTime(day.year, day.month, day.day, hour, minute),
    );
    await refresh();
  });
  Future<List<Map<String, Object?>>> logsFor(String id) =>
      repository.logsForDay(id, selectedDate);
  Future<void> toggleSubstep(String id, bool checked) async => _run(() async {
    await repository.toggleSubstep(id, selectedDate, checked);
    await refresh();
  });
  Future<void> note(String id, String body, {String? photoUri}) async =>
      _run(() async {
        await repository.saveNote(id, selectedDate, body, photoUri: photoUri);
        await refresh();
      });
  Future<void> restDay(String id, bool enabled) async => _run(() async {
    await repository.setRestDay(id, selectedDate, enabled);
    await _syncReminder(id);
    await refresh();
  });
  Future<void> vacation(
    String id,
    DateTime start,
    DateTime end, {
    String label = 'Férias',
  }) async => _run(() async {
    await repository.saveVacation(id, start, end, label: label);
    await _syncReminder(id);
    await refresh();
  });
  Future<void> removeVacation(String id) async => _run(() async {
    final affected = habits.where((row) => row.vacations.any((v) => v.id == id))
        .map((row) => row.habit.id).toList();
    await repository.removeVacation(id);
    for (final habitId in affected) {
      await _syncReminder(habitId);
    }
    await refresh();
  });
  Future<void> archiveHabit(String id) async => _run(() async {
    await repository.archive(id, at: selectedDate);
    try {
      await HabitReminderBridge.sync(id, enabled: false);
    } catch (_) {}
    await refresh();
  });
  Future<void> restoreHabit(String id) async => _run(() async {
    await repository.restore(id);
    final habit = await repository.getHabit(id);
    if (habit?.reminderEnabled == true) {
      try {
        await HabitReminderBridge.sync(id, enabled: true);
      } catch (_) {}
    }
    await refresh();
  });
  Future<void> reorder(List<String> ids) async => _run(() async {
    await repository.reorder(ids);
    await refresh();
  });
  Future<void> snooze(String id) async => _run(() async {
    await repository.snoozeReminder(id);
    try {
      await HabitReminderBridge.sync(id, enabled: true);
    } catch (_) {}
    await refresh();
  });
  Future<void> saveFocus({
    required int goal,
    required int work,
    required int pause,
  }) async => _run(() async {
    await repository.saveFocusSettings(
      dailyGoalMinutes: goal,
      workMinutes: work,
      breakMinutes: pause,
    );
    await refresh();
  });
  Future<void> finishFocus({
    required DateTime start,
    required DateTime end,
    required int minutes,
    required bool completed,
  }) async => _run(() async {
    await repository.addFocusSession(
      startedAt: start,
      endedAt: end,
      plannedMinutes: minutes,
      completed: completed,
    );
    await refresh();
  });

  Future<void> _syncReminder(String id) async {
    try {
      final habit = await repository.getHabit(id);
      await HabitReminderBridge.sync(id,
          enabled: habit?.reminderEnabled == true && habit?.archivedAt == null);
    } catch (_) {
      // Non-Android hosts retain scheduling state in the shared database.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      error = null;
      await action();
    } catch (_) {
      error = 'Não foi possível salvar essa alteração. Confira os dados e tente novamente.';
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _workoutSubscription?.cancel();
    super.dispose();
  }
}
