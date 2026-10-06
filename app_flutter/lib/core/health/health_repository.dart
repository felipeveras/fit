enum HealthAvailability {
  available,
  providerMissingOrUpdateRequired,
  unavailable,
}

enum MetricAvailability {
  available,
  noData,
  permissionDenied,
  historyRestricted,
  unsupported,
  readError,
  sourceAmbiguous;

  String get label => switch (this) {
    available => 'Disponível',
    noData => 'Sem dados',
    permissionDenied => 'Sem permissão',
    historyRestricted => 'Histórico limitado',
    unsupported => 'Indisponível',
    readError => 'Erro de leitura',
    sourceAmbiguous => 'Mais de uma fonte',
  };
}

enum HealthMetric {
  steps('Passos', 'count'),
  sleepDuration('Sono', 's'),
  restingHeartRate('FC de repouso', 'bpm'),
  activeEnergy('Calorias ativas', 'kcal'),
  totalEnergy('Calorias totais', 'kcal'),
  distance('Distância', 'm'),
  weight('Peso', 'kg');

  const HealthMetric(this.label, this.unit);
  final String label;
  final String unit;
}

String wireName(Enum value) => value.name.replaceAllMapped(
  RegExp(r'[A-Z]'),
  (match) => '_${match[0]!.toLowerCase()}',
);
T wireEnum<T extends Enum>(List<T> values, Object? name) => values.firstWhere(
  (value) => wireName(value) == name,
  orElse: () => throw const FormatException('Unknown bridge enum'),
);

class HealthFailure implements Exception {
  const HealthFailure(this.code);
  final String code;
}

class PermissionState {
  const PermissionState({
    required this.granted,
    required this.required,
    required this.history,
    required this.background,
  });
  final Set<String> granted;
  final Set<String> required;
  final String history;
  final String background;
  bool get hasAllData => required.isNotEmpty && granted.containsAll(required);
  factory PermissionState.fromMap(Map<Object?, Object?> map) => PermissionState(
    granted: Set.of((map['granted'] as List).cast<String>()),
    required: Set.of((map['required'] as List).cast<String>()),
    history: map['history'] as String,
    background: map['background'] as String,
  );
}

class HealthSnapshot {
  HealthSnapshot.fromMap(Map<Object?, Object?> map)
    : metric = wireEnum(HealthMetric.values, map['metric']),
      availability = wireEnum(MetricAvailability.values, map['availability']),
      value = (map['value'] as num?)?.toDouble(),
      date = map['localDate'] as String,
      timezone = map['timezone'] as String,
      unit = map['unit'] as String,
      periodStart = DateTime.parse(map['periodStartAt'] as String),
      periodEnd = DateTime.parse(map['periodEndAt'] as String),
      origins = List.unmodifiable((map['origins'] as List).cast<String>()),
      sampleCount = map['sampleCount'] as int?,
      observedAt = map['observedAt'] == null
          ? null
          : DateTime.parse(map['observedAt'] as String),
      readAt = DateTime.parse(map['readAt'] as String),
      readComplete = map['readComplete'] as bool,
      provisional = map['provisional'] as bool,
      aggregationMethod = map['aggregationMethod'] as String,
      qualityFlags = List.unmodifiable(
        (map['qualityFlags'] as List).cast<String>(),
      ),
      configVersion = map['configVersion'] as int,
      mappingVersion = map['mappingVersion'] as int,
      sourcePolicyVersion = map['sourcePolicyVersion'] as int {
    if ((availability == MetricAvailability.available) != (value != null) ||
        (value != null && (!value!.isFinite || value! < 0)) ||
        (metric == HealthMetric.weight && value != null && value! <= 0) ||
        (metric == HealthMetric.steps &&
            value != null &&
            (value! > 9007199254740991 || value != value!.floorToDouble())) ||
        unit != metric.unit ||
        !periodEnd.isAfter(periodStart) ||
        (sampleCount != null && sampleCount! < 0) ||
        configVersion < 1 ||
        mappingVersion < 1 ||
        sourcePolicyVersion < 1 ||
        readComplete !=
            (availability == MetricAvailability.available ||
                availability == MetricAvailability.noData)) {
      throw const FormatException('Invalid health snapshot');
    }
  }
  final HealthMetric metric;
  final MetricAvailability availability;
  final double? value;
  final String date, timezone, unit, aggregationMethod;
  final DateTime periodStart, periodEnd, readAt;
  final DateTime? observedAt;
  final List<String> origins, qualityFlags;
  final int? sampleCount;
  final bool readComplete, provisional;
  final int configVersion, mappingVersion, sourcePolicyVersion;
}

class HealthPeriodSummary {
  const HealthPeriodSummary({
    required this.days,
    required this.timezone,
    required this.snapshots,
  });
  final int days;
  final String timezone;
  final List<HealthSnapshot> snapshots;
  factory HealthPeriodSummary.fromMap(Map<Object?, Object?> map) =>
      HealthPeriodSummary(
        days: map['days'] as int,
        timezone: map['timezone'] as String,
        snapshots: List.unmodifiable(
          (map['snapshots'] as List).map(
            (item) => HealthSnapshot.fromMap(item as Map<Object?, Object?>),
          ),
        ),
      );
}

abstract interface class HealthRepository {
  Future<HealthAvailability> getAvailability();
  Future<PermissionState> getPermissions();
  Future<PermissionState> requestPermissions({bool history = false});
  Future<void> openHealthSettings();
  Future<HealthPeriodSummary> getToday();
  Future<HealthPeriodSummary> getPeriod(int days);
}
