import 'package:app_fit/core/health/health_exercise_repository.dart';
import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/core/health/method_channel_health_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> period({String availability = 'no_data'}) => {
  'version': 1,
  'days': 1,
  'timezone': 'America/Sao_Paulo',
  'readAt': '2026-10-06T15:00:00Z',
  'sourcePolicy': 'all_origins',
  'originPackage': null,
  'coverage': [
    {
      'date': '2026-10-06',
      'availability': availability,
      'readComplete': availability == 'no_data' || availability == 'available',
      'provisional': true,
      'origins': <String>[],
      'errorCode': availability == 'no_data' ? null : 'exercise_permission_denied',
    },
  ],
  'sessions': <Object?>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.homefelipev.healthcoach/health');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('exercise permission uses its own call without data permission kind', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'requestExercisePermission');
      expect(call.arguments, {'version': 1});
      return {
        'version': 1,
        'provider': 'available',
        'granted': true,
        'history': 'not_granted',
      };
    });
    final HealthExerciseRepository repository = MethodChannelHealthRepository();
    final state = await repository.requestExercisePermission();
    expect(state.granted, isTrue);
    expect(state.history, ExerciseHistoryAccess.notGranted);
  });

  test('absence and denied coverage remain distinct', () async {
    for (final availability in ['no_data', 'permission_denied']) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getExerciseSessions');
        expect(call.arguments, {'version': 1, 'days': 1, 'originPackage': null});
        return period(availability: availability);
      });
      final result = await MethodChannelHealthRepository().getExerciseSessions(1);
      expect(result.sessions, isEmpty);
      expect(result.coverage.single.readComplete, availability == 'no_data');
      expect(result.coverage.single.availability,
          wireEnum(MetricAvailability.values, availability));
    }
  });

  test('invalid coverage is a typed bridge failure', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      ...period(),
      'coverage': <Object?>[],
    });
    await expectLater(
      MethodChannelHealthRepository().getExerciseSessions(1),
      throwsA(isA<HealthFailure>().having((e) => e.code, 'code', 'invalid_response')),
    );
  });

  test('composite identity preserves same ID in different sources', () {
    final dto = {
      'id': 'shared',
      'origin': 'producer',
      'date': '2026-10-06',
      'startAt': '2026-10-06T10:00:00Z',
      'endAt': '2026-10-06T11:00:00Z',
      'lastModifiedAt': '2026-10-06T12:00:00Z',
      'exerciseType': 56,
      'isRunning': true,
    };
    final first = HealthExerciseSession.fromMap(dto);
    final second = HealthExerciseSession.fromMap({...dto, 'origin': 'other'});
    expect(first.identity, isNot(second.identity));
    expect(first.duration, const Duration(hours: 1));
    expect(() => HealthExerciseSession.fromMap({...dto, 'id': ''}),
        throwsFormatException);
  });
}
