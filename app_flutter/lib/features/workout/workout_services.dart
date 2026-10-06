import '../../core/persistence/app_database.dart';
import 'workout_progress_repository.dart';
import 'workout_repository.dart';
import 'workout_session_repository.dart';
import 'workout_models.dart';

typedef WorkoutEventConsumer = Future<void> Function(WorkoutDomainEvent event);

/// Explicit async sink; completion acknowledges durable, idempotent persistence.
class WorkoutEventBus implements WorkoutEventSink {
  WorkoutEventConsumer? _consumer;

  @override
  bool get hasConsumer => _consumer != null;

  void connectConsumer(WorkoutEventConsumer consumer) {
    _consumer = consumer;
  }

  void disconnectConsumer() {
    _consumer = null;
  }

  @override
  Future<void> onWorkoutCompleted(WorkoutDomainEvent event) async {
    final consumer = _consumer;
    if (consumer == null) {
      throw StateError('Nenhum consumidor de eventos de treino conectado.');
    }
    await consumer(event);
  }
}

class WorkoutServices {
  WorkoutServices(AppDatabase database)
    : library = WorkoutRepository(database),
      sessions = WorkoutSessionRepository(database),
      progress = WorkoutProgressRepository(
        database,
        WorkoutSessionRepository(database),
      );

  final WorkoutRepository library;
  final WorkoutSessionRepository sessions;
  final WorkoutProgressRepository progress;
  final events = WorkoutEventBus();

  Future<void> connectEventConsumer(WorkoutEventConsumer consumer) async {
    events.connectConsumer(consumer);
    await replayPendingEvents(propagateErrors: true);
  }

  Future<void> replayPendingEvents({bool propagateErrors = false}) async {
    if (!events.hasConsumer) return;
    try {
      await sessions.dispatchPendingEvents(events);
    } catch (_) {
      if (propagateErrors) rethrow;
    }
  }

  Future<void> dispose() async {
    events.disconnectConsumer();
  }
}
