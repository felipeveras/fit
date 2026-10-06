import '../../core/health/health_exercise_repository.dart';
import '../workout/workout_models.dart';
import 'habit_repository.dart';

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
  }
}

/// Applies only complete daily reads; failed dates retain their last known logs.
Future<void> consumeHealthExercises(
  HabitRepository repository,
  HealthExercisePeriod period,
) async {
  await repository.consumeHealthConnectExercises(period);
}
