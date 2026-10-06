import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/core/health/method_channel_health_repository.dart';

import 'health_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.homefelipev.healthcoach/health');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'channel requests version and parses all daily snapshot metadata',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getToday');
        expect(call.arguments, {'version': 1});
        return {
          'version': 1,
          'days': 1,
          'timezone': 'America/Sao_Paulo',
          'snapshots': [snapshotDto()],
        };
      });
      final summary = await MethodChannelHealthRepository().getToday();
      final snapshot = summary.snapshots.single;
      expect(snapshot.value, 1234);
      expect(snapshot.origins, ['producer']);
      expect(snapshot.periodStart.isUtc, isTrue);
      expect(snapshot.timezone, 'America/Sao_Paulo');
      expect(snapshot.readComplete, isTrue);
      expect(snapshot.provisional, isTrue);
      expect(snapshot.mappingVersion, 1);
    },
  );
  test('every unavailable state preserves null', () {
    for (final state in MetricAvailability.values.where(
      (s) => s != MetricAvailability.available,
    )) {
      final snapshot = HealthSnapshot.fromMap(
        snapshotDto(availability: wireName(state), value: null),
      );
      expect(snapshot.value, isNull);
      expect(snapshot.availability, state);
    }
  });
  test('available zero is valid; absent/invalid values are rejected', () {
    expect(HealthSnapshot.fromMap(snapshotDto(value: 0)).value, 0);
    for (final dto in [
      snapshotDto(value: null),
      snapshotDto(availability: 'no_data'),
      snapshotDto(value: double.nan),
      snapshotDto(value: -1),
      snapshotDto(value: 1.5),
      snapshotDto(unit: 'kg'),
      snapshotDto(metric: 'weight', unit: 'kg', value: 0),
    ]) {
      expect(() => HealthSnapshot.fromMap(dto), throwsFormatException);
    }
  });
  test('period supports only 7/30/90 and carries requested range', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPeriod');
      expect(call.arguments, {'version': 1, 'days': 90});
      return {
        'version': 1,
        'days': 90,
        'timezone': 'America/Sao_Paulo',
        'snapshots': [
          snapshotDto(availability: 'history_restricted', value: null),
        ],
      };
    });
    final repository = MethodChannelHealthRepository();
    expect(
      (await repository.getPeriod(90)).snapshots.single.readComplete,
      isFalse,
    );
    expect(() => repository.getPeriod(8), throwsArgumentError);
  });
  test(
    'typed platform errors, unknown version and malformed response',
    () async {
      final repository = MethodChannelHealthRepository();
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'provider_unavailable'),
      );
      await expectLater(
        repository.getToday(),
        throwsA(
          isA<HealthFailure>().having(
            (e) => e.code,
            'code',
            'provider_unavailable',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => {'version': 2});
      await expectLater(
        repository.getToday(),
        throwsA(
          isA<HealthFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_version',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'version': 1, 'days': 'bad'},
      );
      await expectLater(
        repository.getToday(),
        throwsA(
          isA<HealthFailure>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    },
  );
  test('permissions are independent from historical capability', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments, {'version': 1, 'kind': 'history'});
      return {
        'version': 1,
        'granted': ['steps'],
        'required': ['steps', 'weight'],
        'history': 'not_granted',
        'background': 'feature_unavailable',
      };
    });
    final state = await MethodChannelHealthRepository().requestPermissions(
      history: true,
    );
    expect(state.hasAllData, isFalse);
    expect(state.history, 'not_granted');
  });
}
