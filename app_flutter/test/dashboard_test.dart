import 'dart:async';

import 'package:app_fit/app/app.dart';
import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/core/persistence/app_preferences.dart';
import 'package:app_fit/features/dashboard/dashboard_controller.dart';
import 'package:app_fit/features/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'health_fixture.dart';

class FakeHealth implements HealthRepository {
  bool granted = true;
  int todayCalls = 0;
  @override
  Future<HealthAvailability> getAvailability() async =>
      HealthAvailability.available;
  @override
  Future<PermissionState> getPermissions() async => PermissionState(
    granted: granted ? {'steps'} : {},
    required: {'steps'},
    history: 'not_granted',
    background: 'feature_unavailable',
  );
  @override
  Future<HealthPeriodSummary> getToday() async {
    todayCalls++;
    return granted
        ? todaySummary()
        : HealthPeriodSummary(
            days: 1,
            timezone: 'America/Sao_Paulo',
            snapshots: [
              HealthSnapshot.fromMap(
                snapshotDto(availability: 'permission_denied', value: null),
              ),
            ],
          );
  }

  @override
  Future<HealthPeriodSummary> getPeriod(int days) async => HealthPeriodSummary(
    days: days,
    timezone: 'America/Sao_Paulo',
    snapshots: todaySummary().snapshots,
  );
  @override
  Future<void> openHealthSettings() async {}
  @override
  Future<PermissionState> requestPermissions({bool history = false}) =>
      getPermissions();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppPreferences prefs;
  late FakeHealth health;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = AppPreferences(await SharedPreferences.getInstance());
    health = FakeHealth();
  });
  test(
    'revoked permissions remove previously visible values on refresh',
    () async {
      final client = MockClient((_) async => http.Response('{"ok":true}', 200));
      final c = DashboardController(health, prefs, TelegramService(client));
      await c.refresh();
      expect(c.summary!.snapshots.single.value, 1234);
      health.granted = false;
      await c.refresh();
      expect(c.summary!.snapshots.single.value, isNull);
      expect(c.permissions!.hasAllData, isFalse);
      c.dispose();
      client.close();
    },
  );
  test(
    'double tap sends once; selected historical period never gets sent',
    () async {
      await prefs.saveTelegram(
        const TelegramSettings(token: 'test', chatId: '-123'),
      );
      final gate = Completer<http.Response>();
      var sends = 0;
      final client = MockClient((_) {
        sends++;
        return gate.future;
      });
      final c = DashboardController(health, prefs, TelegramService(client));
      await c.refresh(period: 90);
      final pending = c.send();
      await c.send();
      await Future<void>.delayed(Duration.zero);
      expect(sends, 1);
      expect(health.todayCalls, 1);
      gate.complete(http.Response('{"ok":true}', 200));
      await pending;
      expect(prefs.lastSentAt, isNotNull);
      expect(c.sending, isFalse);
      c.dispose();
      client.close();
    },
  );
  testWidgets('startup dashboard works without AI and navigates to settings', (
    tester,
  ) async {
    final client = MockClient((_) async => http.Response('{"ok":true}', 200));
    final c = DashboardController(health, prefs, TelegramService(client));
    await tester.pumpWidget(AppFit(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Seu ritmo, hoje'), findsOneWidget);
    expect(find.text('Passos'), findsOneWidget);
    expect(find.text('1.234'), findsOneWidget);
    expect(health.todayCalls, 1);
    await tester.tap(find.byTooltip('Configurações'));
    await tester.pumpAndSettle();
    expect(find.text('Token do bot'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    client.close();
  });
}
