import 'package:app_fit/core/health/health_repository.dart';

Map<String, Object?> snapshotDto({
  String metric = 'steps',
  String availability = 'available',
  num? value = 1234,
  String unit = 'count',
  String date = '2026-10-06',
}) => {
  'metric': metric,
  'availability': availability,
  'value': value,
  'unit': unit,
  'localDate': date,
  'timezone': 'America/Sao_Paulo',
  'periodStartAt': '${date}T03:00:00Z',
  'periodEndAt':
      '${DateTime.parse(date).add(const Duration(days: 1)).toIso8601String().substring(0, 10)}T03:00:00Z',
  'origins': value == null ? <String>[] : ['producer'],
  'sampleCount': value == null ? 0 : 1,
  'observedAt': null,
  'readAt': '2026-10-06T12:00:00Z',
  'readComplete': ['available', 'no_data'].contains(availability),
  'provisional': true,
  'aggregationMethod': 'hc_aggregate_total_v1',
  'qualityFlags': <String>[],
  'configVersion': 1,
  'mappingVersion': 1,
  'sourcePolicyVersion': 1,
};

HealthPeriodSummary todaySummary() => HealthPeriodSummary(
  days: 1,
  timezone: 'America/Sao_Paulo',
  snapshots: [HealthSnapshot.fromMap(snapshotDto())],
);
