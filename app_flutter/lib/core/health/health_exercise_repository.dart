import 'health_repository.dart';

/// Optional capability: implementers of the seven-metric repository stay intact.
abstract interface class HealthExerciseRepository {
  Future<ExercisePermissionState> getExercisePermissions();
  Future<ExercisePermissionState> requestExercisePermission();
  Future<HealthExercisePeriod> getExerciseSessions(
    int days, {
    String? originPackage,
  });
}

enum ExerciseHistoryAccess {
  availableAndGranted,
  notGranted,
  featureUnavailable,
  osDeferred,
}

class ExercisePermissionState {
  const ExercisePermissionState(this.provider, this.granted, this.history);
  final HealthAvailability provider;
  final bool granted;
  final ExerciseHistoryAccess history;

  factory ExercisePermissionState.fromMap(Map<Object?, Object?> map) =>
      ExercisePermissionState(
        wireEnum(HealthAvailability.values, map['provider']),
        map['granted'] as bool,
        wireEnum(ExerciseHistoryAccess.values, map['history']),
      );
}

class HealthExerciseSession {
  HealthExerciseSession.fromMap(Map<Object?, Object?> map)
    : id = map['id'] as String,
      origin = map['origin'] as String,
      date = map['date'] as String,
      startAt = DateTime.parse(map['startAt'] as String),
      endAt = DateTime.parse(map['endAt'] as String),
      lastModifiedAt = DateTime.parse(map['lastModifiedAt'] as String),
      exerciseType = map['exerciseType'] as int,
      isRunning = map['isRunning'] as bool {
    if (id.trim().isEmpty || origin.trim().isEmpty || !endAt.isAfter(startAt)) {
      throw const FormatException('Invalid exercise session');
    }
    _checkDate(date);
  }
  final String id, origin, date;
  final DateTime startAt, endAt, lastModifiedAt;
  final int exerciseType;
  final bool isRunning;
  Duration get duration => endAt.difference(startAt);

  /// Keep these two fields as a composite key; IDs alone are insufficient.
  (String, String) get identity => (origin, id);
}

class ExerciseDayCoverage {
  ExerciseDayCoverage.fromMap(Map<Object?, Object?> map)
    : date = map['date'] as String,
      availability = wireEnum(MetricAvailability.values, map['availability']),
      readComplete = map['readComplete'] as bool,
      provisional = map['provisional'] as bool,
      origins = Set.unmodifiable((map['origins'] as List).cast<String>()),
      errorCode = map['errorCode'] as String? {
    _checkDate(date);
    if (readComplete !=
        (availability == MetricAvailability.available ||
            availability == MetricAvailability.noData)) {
      throw const FormatException('Inconsistent exercise coverage');
    }
  }
  final String date;
  final MetricAvailability availability;
  final bool readComplete, provisional;
  final Set<String> origins;
  final String? errorCode;
}

class HealthExercisePeriod {
  HealthExercisePeriod.fromMap(Map<Object?, Object?> map)
    : days = map['days'] as int,
      timeZone = map['timezone'] as String,
      readAt = DateTime.parse(map['readAt'] as String),
      sourcePolicy = map['sourcePolicy'] as String,
      originPackage = map['originPackage'] as String?,
      coverage = List.unmodifiable(
        (map['coverage'] as List).map(
          (entry) =>
              ExerciseDayCoverage.fromMap(entry as Map<Object?, Object?>),
        ),
      ),
      sessions = List.unmodifiable(
        (map['sessions'] as List).map(
          (entry) =>
              HealthExerciseSession.fromMap(entry as Map<Object?, Object?>),
        ),
      ) {
    if (![1, 7, 30, 90].contains(days) ||
        timeZone.isEmpty ||
        coverage.length != days ||
        coverage.map((day) => day.date).toSet().length != days ||
        !['all_origins', 'single_origin'].contains(sourcePolicy) ||
        (sourcePolicy == 'single_origin') != (originPackage != null) ||
        (originPackage != null && originPackage!.trim().isEmpty) ||
        sessions.map((session) => session.identity).toSet().length !=
            sessions.length) {
      throw const FormatException('Invalid exercise period');
    }
    for (final session in sessions) {
      final matching = coverage.where((day) => day.date == session.date);
      if (matching.length != 1 ||
          !matching.single.readComplete ||
          !matching.single.origins.contains(session.origin) ||
          session.endAt.isAfter(readAt) ||
          (originPackage != null && session.origin != originPackage)) {
        throw const FormatException('Exercise outside declared coverage');
      }
    }
  }
  final int days;
  final String timeZone, sourcePolicy;
  final String? originPackage;
  final DateTime readAt;
  final List<ExerciseDayCoverage> coverage;
  final List<HealthExerciseSession> sessions;
}

void _checkDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      DateTime.parse(value).toIso8601String().substring(0, 10) != value) {
    throw const FormatException('Invalid local date');
  }
}
