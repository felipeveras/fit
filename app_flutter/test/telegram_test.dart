import 'dart:convert';

import 'package:app_fit/core/health/health_repository.dart';
import 'package:app_fit/core/persistence/app_preferences.dart';
import 'package:app_fit/features/telegram/telegram_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'health_fixture.dart';

void main() {
  test('formatter omits absent/error metrics while preserving actual zero', () {
    final summary = HealthPeriodSummary(
      days: 1,
      timezone: 'America/Sao_Paulo',
      snapshots: [
        HealthSnapshot.fromMap(snapshotDto(value: 0)),
        HealthSnapshot.fromMap(
          snapshotDto(
            metric: 'weight',
            unit: 'kg',
            availability: 'no_data',
            value: null,
          ),
        ),
      ],
    );
    expect(formatHealthSummary(summary), '📊 App Fit — 06/10/2026\nPassos: 0');
  });
  test('chat/thread and text are sent directly to Telegram', () async {
    for (final thread in ['', '5']) {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.telegram.org');
        final body = jsonDecode(request.body) as Map;
        expect(body['chat_id'], '-123');
        expect(body['text'], contains('Passos: 1.234'));
        expect(body.containsKey('message_thread_id'), thread.isNotEmpty);
        if (thread.isNotEmpty) expect(body['message_thread_id'], 5);
        return http.Response('{"ok":true}', 200);
      });
      await TelegramService(client).send(
        TelegramSettings(token: 'test-token', chatId: '-123', threadId: thread),
        todaySummary(),
      );
      client.close();
    }
  });
  test('API and network failures never expose token or raw response', () async {
    final settings = TelegramSettings(token: 'test-token', chatId: '-123');
    for (final client in [
      MockClient((_) async => http.Response('{"ok":false}', 401)),
      MockClient((_) async => throw http.ClientException('private url')),
    ]) {
      await expectLater(
        TelegramService(client).send(settings, todaySummary()),
        throwsA(isA<TelegramFailure>()),
      );
      client.close();
    }
  });
}
