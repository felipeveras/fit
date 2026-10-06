import 'package:flutter/services.dart';

import 'health_repository.dart';
import 'health_exercise_repository.dart';

const healthBridgeVersion = 1;

class MethodChannelHealthRepository
    implements HealthRepository, HealthExerciseRepository {
  MethodChannelHealthRepository({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.homefelipev.healthcoach/health');
  final MethodChannel _channel;

  Future<Map<Object?, Object?>> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      final response = await _channel.invokeMethod<Object?>(method, {
        'version': healthBridgeVersion,
        ...args,
      });
      if (response is! Map || response['version'] != healthBridgeVersion) {
        throw const HealthFailure('unsupported_version');
      }
      return response;
    } on PlatformException catch (error) {
      throw HealthFailure(error.code);
    } on MissingPluginException {
      throw const HealthFailure('bridge_unavailable');
    }
  }

  Future<T> _parse<T>(
    Future<Map<Object?, Object?>> response,
    T Function(Map<Object?, Object?>) parse,
  ) async {
    try {
      return parse(await response);
    } on FormatException {
      throw const HealthFailure('invalid_response');
    } on TypeError {
      throw const HealthFailure('invalid_response');
    }
  }

  @override
  Future<HealthAvailability> getAvailability() => _parse(
    _call('getAvailability'),
    (map) => wireEnum(HealthAvailability.values, map['provider']),
  );
  @override
  Future<ExercisePermissionState> getExercisePermissions() => _parse(
    _call('getExercisePermissions'),
    ExercisePermissionState.fromMap,
  );
  @override
  Future<ExercisePermissionState> requestExercisePermission() => _parse(
    _call('requestExercisePermission'),
    ExercisePermissionState.fromMap,
  );
  @override
  Future<HealthExercisePeriod> getExerciseSessions(
    int days, {
    String? originPackage,
  }) {
    if (![1, 7, 30, 90].contains(days)) {
      throw ArgumentError.value(days, 'days');
    }
    if (originPackage != null && originPackage.trim().isEmpty) {
      throw ArgumentError.value(originPackage, 'originPackage');
    }
    return _parse(
      _call('getExerciseSessions', {
        'days': days,
        'originPackage': originPackage,
      }),
      HealthExercisePeriod.fromMap,
    );
  }
  @override
  Future<PermissionState> getPermissions() =>
      _parse(_call('getPermissions'), PermissionState.fromMap);
  @override
  Future<PermissionState> requestPermissions({bool history = false}) => _parse(
    _call('requestPermissions', {'kind': history ? 'history' : 'data'}),
    PermissionState.fromMap,
  );
  @override
  Future<void> openHealthSettings() async {
    await _call('openHealthSettings');
  }

  @override
  Future<HealthPeriodSummary> getToday() =>
      _parse(_call('getToday'), HealthPeriodSummary.fromMap);
  @override
  Future<HealthPeriodSummary> getPeriod(int days) {
    if (![7, 30, 90].contains(days)) throw ArgumentError.value(days, 'days');
    return _parse(
      _call('getPeriod', {'days': days}),
      HealthPeriodSummary.fromMap,
    );
  }
}
