import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/core/persistence/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'single versioned database migrates habits and survives reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('app-fit-test');
      final databasePath = '${directory.path}/app_fit.db';
      final store = AppDatabase(factory: databaseFactoryFfi);
      try {
        final db = await store.open(databasePath: databasePath);
        expect(await db.getVersion(), 2);
        final metadata = await db.query('app_metadata');
        expect(metadata.single['key'], 'created_at');
        await store.close();
        final reopened = await store.open(databasePath: databasePath);
        expect(await reopened.query('app_metadata'), metadata);
        final tables = await reopened.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        expect(tables.map((t) => t['name']), contains('habits'));
        expect(tables.map((t) => t['name']), contains('habit_completions'));
        expect(tables.map((t) => t['name']), isNot(contains('health_snapshots')));
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'preferences recover Telegram destination and last send after reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = AppPreferences(await SharedPreferences.getInstance());
      await prefs.saveTelegram(
        const TelegramSettings(
          token: 'test-token',
          chatId: '-123',
          threadId: '9',
        ),
      );
      await prefs.markSent(DateTime.utc(2026, 10, 6, 12));
      final restored = AppPreferences(await SharedPreferences.getInstance());
      expect(restored.telegram.configured, isTrue);
      expect(restored.telegram.threadId, '9');
      expect(restored.lastSentAt, DateTime.utc(2026, 10, 6, 12));
      await restored.saveTelegram(const TelegramSettings());
      expect(restored.telegram.configured, isFalse);
    },
  );
}
