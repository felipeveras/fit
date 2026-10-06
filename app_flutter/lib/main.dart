import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/health/method_channel_health_repository.dart';
import 'core/persistence/app_database.dart';
import 'core/persistence/app_preferences.dart';
import 'features/dashboard/dashboard_controller.dart';
import 'features/telegram/telegram_service.dart';
import 'features/workout/workout_services.dart';
import 'features/habits/habit_repository.dart';
import 'features/habits/habit_automation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('pt_BR');
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final _database = AppDatabase();
  late final _workouts = WorkoutServices(_database);
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
      _workouts.events.connectConsumer(
        WorkoutHabitConsumer(HabitRepository(_database)).consume,
      );
      await _workouts.replayPendingEvents();
      await _recoverPickedPhoto();
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

  Future<void> _recoverPickedPhoto() async {
    try {
      final lost = await ImagePicker().retrieveLostData();
      final files = lost.files;
      if (files != null && files.isNotEmpty) {
        await _workouts.progress.importProgressPhoto(
          files.first.path,
          notes: 'Foto recuperada após interrupção do aplicativo',
        );
      }
    } catch (_) {
      // Photo recovery is best effort and must not block opening the dashboard.
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _workouts.dispose();
    _client.close();
    _database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller != null
      ? AppFit(
          controller: _controller!,
          database: _database,
          workouts: _workouts,
        )
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
