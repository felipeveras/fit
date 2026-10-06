import 'package:shared_preferences/shared_preferences.dart';

class TelegramSettings {
  const TelegramSettings({
    this.token = '',
    this.chatId = '',
    this.threadId = '',
  });
  final String token, chatId, threadId;
  bool get configured => token.trim().isNotEmpty && chatId.trim().isNotEmpty;
  bool get validThread => threadId.isEmpty || (int.tryParse(threadId) ?? 0) > 0;
}

class AppPreferences {
  AppPreferences(this._prefs);
  final SharedPreferences _prefs;
  TelegramSettings get telegram => TelegramSettings(
    token: _prefs.getString('telegram_token') ?? '',
    chatId: _prefs.getString('telegram_chat') ?? '',
    threadId: _prefs.getString('telegram_thread') ?? '',
  );
  Future<void> saveTelegram(TelegramSettings value) async {
    if (!value.validThread) throw ArgumentError('Invalid Telegram thread');
    if (!await _prefs.setString('telegram_token', value.token) ||
        !await _prefs.setString('telegram_chat', value.chatId) ||
        !await _prefs.setString('telegram_thread', value.threadId)) {
      throw StateError('Preferences could not be saved');
    }
  }

  DateTime? get lastSentAt =>
      DateTime.tryParse(_prefs.getString('last_sent_at') ?? '');
  Future<void> markSent(DateTime at) async {
    if (!await _prefs.setString('last_sent_at', at.toUtc().toIso8601String())) {
      throw StateError('Send timestamp could not be saved');
    }
  }
}
