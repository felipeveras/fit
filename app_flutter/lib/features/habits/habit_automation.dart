import '../../core/health/health_exercise_repository.dart';
import '../workout/workout_models.dart';
import 'habit_repository.dart';
import 'habit_reminder_bridge.dart';

/// The outbox acknowledges this future only after the habit transaction commits.
/// Stable SQLite event IDs make a retry after process death idempotent.
class WorkoutHabitConsumer {
  WorkoutHabitConsumer(this.repository);
  final HabitRepository repository;
  Future<void> consume(WorkoutDomainEvent event) async {
    await repository.ingestWorkoutCompletion(
      eventId: '${event.id}',
      sessionId: '${event.sessionId}',
      occurredAt: event.occurredAt.toLocal(),
      label: 'Treino concluído',
    );
    await rearmHabitReminders(repository);
  }
}

/// Applies only complete daily reads; failed dates retain their last known logs.
Future<void> consumeHealthExercises(
  HabitRepository repository,
  HealthExercisePeriod period,
) async {
  await repository.consumeHealthConnectExercises(period);
}

/// Native alarms read the same persisted rows. Reconcile after automatic logs,
/// so a completed goal or a changed measurable target does not keep an old alarm.
Future<void> rearmHabitReminders(HabitRepository repository) async {
  final habits = await repository.list();
  for (final habit in habits.where((habit) => habit.reminderEnabled)) {
    try {
      await HabitReminderBridge.sync(habit.id, enabled: true);
    } catch (_) {
      // Android scheduling is best effort; durable data acknowledges delivery.
    }
  }
}
