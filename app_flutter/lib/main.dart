import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/health/method_channel_health_repository.dart';
import 'core/persistence/app_database.dart';
import 'core/persistence/app_preferences.dart';
import 'features/dashboard/dashboard_controller.dart';
import 'features/telegram/telegram_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final _database = AppDatabase();
  final _client = http.Client();
  DashboardController? _controller;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _failed = false);
    try {
      await _database.open();
      final preferences = AppPreferences(await SharedPreferences.getInstance());
      if (!mounted) return;
      setState(
        () => _controller = DashboardController(
          MethodChannelHealthRepository(),
          preferences,
          TelegramService(_client),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _client.close();
    _database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller != null
      ? AppFit(controller: _controller!)
      : MaterialApp(
          home: Scaffold(
            body: Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Não foi possível abrir os dados locais.'),
                        TextButton(
                          onPressed: _initialize,
                          child: const Text('Tentar novamente'),
                        ),
                      ],
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        );
}
