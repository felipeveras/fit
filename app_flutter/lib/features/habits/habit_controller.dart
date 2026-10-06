import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/health/health_repository.dart';
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
  Map<String, int> focusConfig = const {'dailyGoalMinutes': 60, 'workMinutes': 25, 'breakMinutes': 5};
  DateTime selectedDate = habitDay(DateTime.now());
  bool loading = false, syncingSteps = false;
  String? error;
  bool _disposed = false;
  StreamSubscription<WorkoutCompletionEvent>? _workoutSubscription;

  void _notify() { if (!_disposed) notifyListeners(); }

  Future<void> refresh({DateTime? now}) async {
    if (loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      habits = await repository.loadProgress(now: now);
      archived = await repository.loadProgress(now: now, archived: true);
      focusConfig = await repository.focusSettings();
      focusHistory = await repository.focusSessions(since: habitDay(now ?? DateTime.now()).subtract(const Duration(days: 365)));
    } catch (_) {
      error = 'Não foi possível abrir seus hábitos. Tente atualizar.';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> syncStepHistory() async {
    if (syncingSteps || health == null || !habits.any((p) => p.habit.automation == HabitAutomation.healthConnectSteps)) return;
    syncingSteps = true;
    _notify();
    try {
      // The platform returns per-date availability and coverage for each daily snapshot.
      // We intentionally do not gate step reads on the exercise-session permission.
      if (await health!.getAvailability() == HealthAvailability.available) {
        await repository.consumeHealthConnectSteps(await health!.getPeriod(90));
        habits = await repository.loadProgress(now: selectedDate);
      }
    } catch (_) {
      error = 'A leitura de passos não foi atualizada. Os registros manuais continuam disponíveis.';
    } finally {
      syncingSteps = false;
      _notify();
    }
  }

  /// Connect the #20 producer through this narrow, testable stream contract.
  /// Producers must publish only finalized sessions with stable eventId and sessionId.
  void connectWorkoutSource(ExerciseHabitEventSource source) {
    _workoutSubscription?.cancel();
    _workoutSubscription = source.completedSessions.listen((event) async {
      try {
        await repository.ingestWorkoutCompletion(eventId: event.eventId, sessionId: event.sessionId, occurredAt: event.occurredAt, exerciseType: event.exerciseType, label: event.label, source: event.source, isRunning: event.isRunning);
        await refresh(now: selectedDate);
      } catch (_) {
        error = 'A conclusão automática do treino não foi salva.';
        _notify();
      }
    }, onError: (_) { error = 'Não foi possível receber os eventos de treino.'; _notify(); });
  }

  void selectDate(DateTime date) { selectedDate = habitDay(date); _notify(); }

  Future<void> save(Habit habit, {List<String> substeps = const []}) async => _run(() async {
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
      try { await HabitReminderBridge.sync(habit.id, enabled: false); } catch (_) {}
    }
    await refresh(now: selectedDate);
    if (reminderPermissionDenied) {
      error = 'O horário foi salvo. Permita notificações do App Fit para receber lembretes.';
      _notify();
    }
  });
  DateTime get selectedOccurrenceTime {
    final day = habitDay(selectedDate), now = DateTime.now();
    return day == habitDay(now) ? now : DateTime(day.year, day.month, day.day, 12);
  }
  Future<void> complete(String id, {String? note, String? behavioralMoment}) async => _run(() async { await repository.addCompletion(id, selectedOccurrenceTime, note: note, behavioralMoment: behavioralMoment); await repository.clearSnooze(id); try { await HabitReminderBridge.sync(id, enabled: true); } catch (_) {} await refresh(now: selectedDate); });
  Future<void> addQuantity(String id, double amount, {String? note, String? behavioralMoment}) async => _run(() async { await repository.addQuantity(id, amount, selectedOccurrenceTime, note: note, behavioralMoment: behavioralMoment); await repository.clearSnooze(id); try { await HabitReminderBridge.sync(id, enabled: true); } catch (_) {} await refresh(now: selectedDate); });
  Future<void> removeLog(Map<String, Object?> log) async => _run(() async { if (log['log_kind'] == 'completion') { await repository.removeCompletion(log['id']! as String); } else { await repository.removeQuantity(log['id']! as String); } await refresh(now: selectedDate); });
  Future<void> adjustLogTime(Map<String, Object?> log, int hour, int minute) async => _run(() async { final day = habitDay(selectedDate); await repository.adjustLogTime(log['id']! as String, completion: log['log_kind'] == 'completion', occurredAt: DateTime(day.year, day.month, day.day, hour, minute)); await refresh(now: selectedDate); });
  Future<List<Map<String, Object?>>> logsFor(String id) => repository.logsForDay(id, selectedDate);
  Future<void> toggleSubstep(String id, bool checked) async => _run(() async { await repository.toggleSubstep(id, selectedDate, checked); await refresh(now: selectedDate); });
  Future<void> note(String id, String body, {String? photoUri}) async => _run(() async { await repository.saveNote(id, selectedDate, body, photoUri: photoUri); await refresh(now: selectedDate); });
  Future<void> restDay(String id, bool enabled) async => _run(() async { await repository.setRestDay(id, selectedDate, enabled); await refresh(now: selectedDate); });
  Future<void> vacation(String id, DateTime start, DateTime end, {String label = 'Férias'}) async => _run(() async { await repository.saveVacation(id, start, end, label: label); await refresh(now: selectedDate); });
  Future<void> removeVacation(String id) async => _run(() async { await repository.removeVacation(id); await refresh(now: selectedDate); });
  Future<void> archiveHabit(String id) async => _run(() async { await repository.archive(id, at: selectedDate); try { await HabitReminderBridge.sync(id, enabled: false); } catch (_) {} await refresh(now: selectedDate); });
  Future<void> restoreHabit(String id) async => _run(() async { await repository.restore(id); final habit = await repository.getHabit(id); if (habit?.reminderEnabled == true) { try { await HabitReminderBridge.sync(id, enabled: true); } catch (_) {} } await refresh(now: selectedDate); });
  Future<void> reorder(List<String> ids) async => _run(() async { await repository.reorder(ids); await refresh(now: selectedDate); });
  Future<void> snooze(String id) async => _run(() async { await repository.snoozeReminder(id); try { await HabitReminderBridge.sync(id, enabled: true); } catch (_) {} await refresh(now: selectedDate); });
  Future<void> saveFocus({required int goal, required int work, required int pause}) async => _run(() async { await repository.saveFocusSettings(dailyGoalMinutes: goal, workMinutes: work, breakMinutes: pause); await refresh(now: selectedDate); });
  Future<void> finishFocus({required DateTime start, required DateTime end, required int minutes, required bool completed}) async => _run(() async { await repository.addFocusSession(startedAt: start, endedAt: end, plannedMinutes: minutes, completed: completed); await refresh(now: selectedDate); });

  Future<void> _run(Future<void> Function() action) async {
    try { error = null; await action(); }
    catch (_) { error = 'Não foi possível salvar essa alteração. Confira os dados e tente novamente.'; _notify(); }
  }

  @override
  void dispose() {
    _disposed = true;
    _workoutSubscription?.cancel();
    super.dispose();
  }
}
