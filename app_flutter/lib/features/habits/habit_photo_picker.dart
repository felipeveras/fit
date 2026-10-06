import 'package:flutter/services.dart';

class HabitPhotoPicker {
  static const MethodChannel _channel = MethodChannel('com.homefelipev.healthcoach/habits');

  static Future<String?> pickLocalImage() => _channel.invokeMethod<String>('pickHabitPhoto');
}
