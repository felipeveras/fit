import 'package:flutter/services.dart';

class HabitReminderBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.homefelipev.healthcoach/habits',
  );

  static Future<bool> requestPermission() async =>
      (await _channel.invokeMethod<bool>('requestHabitNotifications')) ?? false;

  static Future<void> sync(String habitId, {required bool enabled}) =>
      _channel.invokeMethod<void>('syncHabitReminder', {
        'habitId': habitId,
        'enabled': enabled,
      });

  static Future<void> share(String title, String text) => _channel
      .invokeMethod<void>('shareHabitSummary', {'title': title, 'text': text});
}
