enum WorkoutSetType { working, warmup, drop, failure, restPause }

enum WorkoutSessionStatus { active, completed, cancelled }

/// App-owned exercise catalog item. [muscleGroup] uses a stable snake_case key.
class ExerciseDefinition {
  const ExerciseDefinition({
    this.id,
    required this.name,
    required this.muscleGroup,
    this.instructions,
    this.isCustom = false,
    this.mediaPath,
  });

  final int? id;
  final String name;
  final String muscleGroup;
  final String? instructions;
  final bool isCustom;
  final String? mediaPath;
}

class RoutineExercise {
  const RoutineExercise({
    this.id,
    required this.exerciseId,
    required this.position,
    this.plannedSets = 3,
    this.minReps = 8,
    this.maxReps = 12,
    this.restSeconds = 90,
    this.supersetGroup,
    this.notes,
  });

  final int? id;
  final int exerciseId;
  final int position;
  final int plannedSets;
  final int minReps;
  final int maxReps;
  final int restSeconds;
  final String? supersetGroup;
  final String? notes;
}

class WorkoutRoutine {
  const WorkoutRoutine({
    this.id,
    required this.name,
    this.notes,
    this.scheduledWeekdays = const [],
    this.exercises = const [],
  });

  final int? id;
  final String name;
  final String? notes;

  /// ISO weekday numbers, Monday = 1 through Sunday = 7.
  final List<int> scheduledWeekdays;
  final List<RoutineExercise> exercises;
}

class WorkoutSession {
  const WorkoutSession({
    this.id,
    this.routineId,
    required this.status,
    required this.startedAt,
    this.completedAt,
    this.notes,
  });

  final int? id;
  final int? routineId;
  final WorkoutSessionStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? notes;
}

class WorkoutSessionDetail {
  const WorkoutSessionDetail({required this.session, required this.exercises});

  final WorkoutSession session;
  final List<WorkoutExerciseDetail> exercises;
}

class WorkoutExerciseDetail {
  const WorkoutExerciseDetail({required this.exercise, required this.sets});

  final WorkoutExercise exercise;
  final List<WorkoutSet> sets;
}

class WorkoutExercise {
  const WorkoutExercise({
    this.id,
    required this.sessionId,
    this.exerciseId,
    required this.exerciseName,
    required this.position,
    this.muscleGroup = 'other',
    this.restSeconds = 90,
    this.plannedSets,
    this.minReps,
    this.maxReps,
    this.supersetGroup,
    this.notes,
  });

  final int? id;
  final int sessionId;
  final int? exerciseId;
  final String exerciseName;
  final int position;
  final String muscleGroup;
  final int restSeconds;
  final int? plannedSets;
  final int? minReps;
  final int? maxReps;
  final String? supersetGroup;
  final String? notes;
}

class WorkoutSet {
  const WorkoutSet({
    this.id,
    required this.workoutExerciseId,
    required this.position,
    required this.reps,
    required this.weightKg,
    this.type = WorkoutSetType.working,
    this.rpe,
    this.rir,
    this.completedAt,
    this.durationSeconds,
    this.distanceMeters,
  });

  final int? id;
  final int workoutExerciseId;
  final int position;
  final int reps;
  final double weightKg;
  final WorkoutSetType type;
  final double? rpe;
  final int? rir;
  final DateTime? completedAt;
  final int? durationSeconds;
  final double? distanceMeters;
}

class RestTimerState {
  const RestTimerState({
    required this.sessionId,
    required this.remaining,
    required this.isPaused,
    this.endsAt,
  });

  final int sessionId;
  final Duration remaining;
  final bool isPaused;
  final DateTime? endsAt;

  Duration remainingAt(DateTime now) {
    if (isPaused || endsAt == null) return remaining;
    final value = endsAt!.difference(now);
    return value.isNegative ? Duration.zero : value;
  }
}

class WorkoutDomainEvent {
  const WorkoutDomainEvent({
    required this.id,
    required this.sessionId,
    required this.occurredAt,
    required this.exerciseCount,
    required this.completedSets,
    required this.volumeKg,
    required this.durationSeconds,
  });

  final int id;
  final int sessionId;
  final DateTime occurredAt;
  final int exerciseCount;
  final int completedSets;
  final double volumeKg;
  final int durationSeconds;
}

abstract interface class WorkoutEventSink {
  /// True only while a durable asynchronous consumer is connected.
  bool get hasConsumer;

  /// Complete only after durable persistence. Consumers must deduplicate by [event.id].
  Future<void> onWorkoutCompleted(WorkoutDomainEvent event);
}

class WorkoutSessionSummary {
  const WorkoutSessionSummary({
    required this.session,
    required this.exerciseCount,
    required this.setCount,
    required this.volumeKg,
    required this.topLoadKg,
    required this.personalRecords,
  });

  final WorkoutSession session;
  final int exerciseCount;
  final int setCount;
  final double volumeKg;
  final double topLoadKg;
  final List<PersonalRecord> personalRecords;
}

class WorkoutHistorySummary {
  const WorkoutHistorySummary({
    required this.sessions,
    required this.trainedDays,
    required this.completedSets,
    required this.volumeKg,
    required this.frequency,
    required this.currentStreak,
    required this.weeklyGoal,
    required this.muscleVolumes,
  });

  final int sessions;
  final int trainedDays;
  final int completedSets;
  final double volumeKg;
  final int frequency;
  final int currentStreak;
  final int weeklyGoal;
  final Map<String, double> muscleVolumes;
}

class ExerciseHistoryPoint {
  const ExerciseHistoryPoint({
    required this.sessionDate,
    required this.topLoadKg,
    required this.estimatedOneRepMaxKg,
    required this.volumeKg,
  });

  final DateTime sessionDate;
  final double topLoadKg;
  final double estimatedOneRepMaxKg;
  final double volumeKg;
}

class CoachWorkoutSummary {
  const CoachWorkoutSummary({
    required this.sessions,
    required this.trainedDays,
    required this.volumeKg,
    required this.muscleGroups,
    required this.personalRecords,
    required this.averageDurationMinutes,
    required this.averageRpe,
  });

  final int sessions;
  final int trainedDays;
  final double volumeKg;
  final Map<String, double> muscleGroups;
  final List<String> personalRecords;
  final double? averageDurationMinutes;
  final double? averageRpe;
}

class PersonalRecord {
  const PersonalRecord({
    this.id,
    required this.exerciseId,
    required this.recordType,
    required this.value,
    required this.achievedAt,
    this.workoutSetId,
  });

  final int? id;
  final int exerciseId;
  final String recordType;
  final double value;
  final DateTime achievedAt;
  final int? workoutSetId;
}

class BodyMeasurement {
  const BodyMeasurement({
    this.id,
    required this.measuredAt,
    this.weightKg,
    this.bodyFatPercent,
    this.measurementsCm = const {},
    this.notes,
  });

  final int? id;
  final DateTime measuredAt;
  final double? weightKg;
  final double? bodyFatPercent;
  final Map<String, double> measurementsCm;
  final String? notes;
}

class ProgressPhoto {
  const ProgressPhoto({
    this.id,
    required this.capturedAt,
    required this.localPath,
    this.notes,
  });

  final int? id;
  final DateTime capturedAt;
  final String localPath;
  final String? notes;
}
