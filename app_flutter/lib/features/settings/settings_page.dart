import 'package:flutter/material.dart';

import '../../core/health/health_repository.dart';
import '../../core/persistence/app_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.health,
  });
  final AppPreferences preferences;
  final HealthRepository health;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController token, chat, thread;
  bool saving = false;
  String? message;
  @override
  void initState() {
    super.initState();
    final settings = widget.preferences.telegram;
    token = TextEditingController(text: settings.token);
    chat = TextEditingController(text: settings.chatId);
    thread = TextEditingController(text: settings.threadId);
  }

  @override
  void dispose() {
    token.dispose();
    chat.dispose();
    thread.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await widget.preferences.saveTelegram(
        TelegramSettings(
          token: token.text.trim(),
          chatId: chat.text.trim(),
          threadId: thread.text.trim(),
        ),
      );
      if (mounted) setState(() => message = 'Configurações salvas.');
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Não foi possível salvar. Tente novamente.');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Configurações')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Telegram', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Seu bot, chat e tópico. As configurações ficam neste aparelho.',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Token do bot'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: chat,
            decoration: const InputDecoration(labelText: 'ID do chat'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: thread,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'ID do tópico (opcional)',
            ),
            validator: (value) =>
                value == null ||
                    value.trim().isEmpty ||
                    (int.tryParse(value.trim()) ?? 0) > 0
                ? null
                : 'Use um número inteiro positivo.',
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: saving ? null : save,
            child: Text(saving ? 'Salvando…' : 'Salvar'),
          ),
          TextButton(
            onPressed: saving
                ? null
                : () {
                    token.clear();
                    chat.clear();
                    thread.clear();
                    save();
                  },
            child: const Text('Remover configurações do bot'),
          ),
          if (message != null) Text(message!),
          const SizedBox(height: 28),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Permissões de saúde'),
            subtitle: const Text(
              'Gerencie acesso e revogue permissões no Health Connect.',
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: () async {
              try {
                await widget.health.openHealthSettings();
              } catch (_) {
                if (mounted) {
                  setState(
                    () => message = 'Não foi possível abrir o Health Connect.',
                  );
                }
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sobre e créditos'),
            trailing: const Icon(Icons.info_outline),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'App Fit',
              applicationVersion: '0.1.0 • Flutter',
              children: [
                const Text(
                  'Dados locais, sem conta. Health Connect é usado somente para leitura. '
                  'O envio manual ao Telegram inclui apenas métricas disponíveis. '
                  'Não fornece diagnóstico clínico.\n\nBridge adaptado do App Fit Kotlin. '
                  'Nenhum código ou asset do GymMane/Streak foi incorporado nesta fundação. '
                  'As licenças das dependências estão listadas abaixo.',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
