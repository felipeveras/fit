import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../../core/health/health_repository.dart';
import '../../core/persistence/app_preferences.dart';

String metricValue(HealthSnapshot snapshot) {
  final value = snapshot.value;
  if (value == null) return snapshot.availability.label;
  return switch (snapshot.metric) {
    HealthMetric.sleepDuration =>
      '${(value / 60).round() ~/ 60}h${((value / 60).round() % 60).toString().padLeft(2, '0')}',
    HealthMetric.weight => '${NumberFormat('0.0', 'pt_BR').format(value)} kg',
    HealthMetric.distance =>
      '${NumberFormat('0.0', 'pt_BR').format(value / 1000)} km',
    HealthMetric.steps => NumberFormat.decimalPattern(
      'pt_BR',
    ).format(value.round()),
    _ =>
      '${NumberFormat.decimalPattern('pt_BR').format(value.round())} ${snapshot.unit}',
  };
}

String formatHealthSummary(HealthPeriodSummary summary) {
  if (summary.days != 1) {
    throw ArgumentError('Only daily summaries can be sent');
  }
  final dates = summary.snapshots.map((s) => s.date).toSet();
  if (dates.length != 1) {
    throw ArgumentError('Daily summary must have one local date');
  }
  final date = DateFormat('dd/MM/yyyy').format(DateTime.parse(dates.single));
  final lines = ['📊 App Fit — $date'];
  for (final metric in [
    HealthMetric.weight,
    HealthMetric.steps,
    HealthMetric.sleepDuration,
    HealthMetric.restingHeartRate,
    HealthMetric.activeEnergy,
    HealthMetric.totalEnergy,
    HealthMetric.distance,
  ]) {
    final available = summary.snapshots.where(
      (s) => s.metric == metric && s.value != null,
    );
    if (available.isNotEmpty) {
      lines.add('${metric.label}: ${metricValue(available.first)}');
    }
  }
  if (lines.length == 1) lines.add('Nenhuma métrica disponível.');
  return lines.join('\n');
}

class TelegramFailure implements Exception {
  const TelegramFailure(this.code);
  final String code;
}

class TelegramService {
  TelegramService(this._client);
  final http.Client _client;
  Future<void> send(
    TelegramSettings settings,
    HealthPeriodSummary summary,
  ) async {
    if (!settings.configured || !settings.validThread) {
      throw const TelegramFailure('configuration');
    }
    final body = <String, Object>{
      'chat_id': settings.chatId,
      'text': formatHealthSummary(summary),
    };
    if (settings.threadId.isNotEmpty) {
      body['message_thread_id'] = int.parse(settings.threadId);
    }
    try {
      final response = await _client
          .post(
            Uri.https('api.telegram.org', '/bot${settings.token}/sendMessage'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final result = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          result is! Map ||
          result['ok'] != true) {
        throw const TelegramFailure('api');
      }
    } on TelegramFailure {
      rethrow;
    } catch (_) {
      throw const TelegramFailure('network');
    }
  }
}
