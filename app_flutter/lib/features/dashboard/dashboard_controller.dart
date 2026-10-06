import 'package:flutter/foundation.dart';

import '../../core/health/health_repository.dart';
import '../../core/persistence/app_preferences.dart';
import '../telegram/telegram_service.dart';

class DashboardController extends ChangeNotifier {
  DashboardController(this.health, this.preferences, this.telegram);
  final HealthRepository health;
  final AppPreferences preferences;
  final TelegramService telegram;
  HealthAvailability? availability;
  PermissionState? permissions;
  HealthPeriodSummary? summary;
  bool loading = false, sending = false;
  bool _disposed = false;
  int days = 1;
  String? error, sendMessage;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh({int? period}) async {
    if (loading) return;
    if (period != null) days = period;
    loading = true;
    error = null;
    // Never retain previously authorized health values after a refresh/revocation.
    summary = null;
    permissions = null;
    _notify();
    try {
      availability = await health.getAvailability();
      if (availability == HealthAvailability.available) {
        permissions = await health.getPermissions();
        summary = days == 1
            ? await health.getToday()
            : await health.getPeriod(days);
      }
    } catch (_) {
      error = 'Não foi possível ler os dados. Tente atualizar.';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> requestPermissions({bool history = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      await health.requestPermissions(history: history);
    } catch (_) {
      error = 'Não foi possível abrir as permissões. Tente novamente.';
    } finally {
      loading = false;
    }
    if (error == null) {
      await refresh();
    } else {
      _notify();
    }
  }

  Future<void> openHealthSettings() async {
    try {
      await health.openHealthSettings();
    } catch (_) {
      error = 'Não foi possível abrir o Health Connect.';
      _notify();
    }
  }

  Future<void> send() async {
    if (sending) return;
    sending = true;
    sendMessage = null;
    _notify();
    try {
      final today = await health.getToday();
      await telegram.send(preferences.telegram, today);
      sendMessage = 'Resumo enviado para Telegram.';
      try {
        await preferences.markSent(DateTime.now());
      } catch (_) {
        sendMessage = 'Resumo enviado. O horário não pôde ser salvo.';
      }
    } on TelegramFailure catch (failure) {
      sendMessage = failure.code == 'configuration'
          ? 'Configure o bot, chat e tópico em Configurações.'
          : 'Envio não confirmado. Confira a conexão e as configurações do bot.';
    } catch (_) {
      sendMessage = 'Não foi possível ler o resumo de hoje para enviar.';
    } finally {
      sending = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
