import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'workout_models.dart';
import 'workout_services.dart';

class WorkoutHistoryPage extends StatefulWidget {
  const WorkoutHistoryPage({super.key, required this.services});
  final WorkoutServices services;

  @override
  State<WorkoutHistoryPage> createState() => _WorkoutHistoryPageState();
}

class _WorkoutHistoryPageState extends State<WorkoutHistoryPage> {
  List<WorkoutSessionSummary> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await widget.services.sessions.listCompletedSessions(
        limit: 1000,
      );
      if (mounted) {
        setState(() {
          _sessions = values;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Histórico de treinos')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _sessions.isEmpty
        ? const Center(
            child: Text(
              'Conclua seu primeiro treino para iniciar o histórico.',
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _sessions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final summary = _sessions[index];
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.check)),
                    title: Text(
                      DateFormat(
                        'EEEE, d MMMM',
                        'pt_BR',
                      ).format(summary.session.startedAt),
                    ),
                    subtitle: Text(
                      '${DateFormat('HH:mm').format(summary.session.startedAt)} · ${summary.exerciseCount} exercícios · ${summary.setCount} séries · ${summary.volumeKg.round()} kg',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WorkoutPastSessionPage(
                          services: widget.services,
                          sessionId: summary.session.id!,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
  );
}

class WorkoutPastSessionPage extends StatefulWidget {
  const WorkoutPastSessionPage({
    super.key,
    required this.services,
    required this.sessionId,
  });
  final WorkoutServices services;
  final int sessionId;

  @override
  State<WorkoutPastSessionPage> createState() => _WorkoutPastSessionPageState();
}

class _WorkoutPastSessionPageState extends State<WorkoutPastSessionPage> {
  WorkoutSessionDetail? _detail;
  WorkoutSessionSummary? _summary;

  @override
  void initState() {
    super.initState();
    Future.wait([
      widget.services.sessions.getSession(widget.sessionId),
      widget.services.sessions.getSummary(widget.sessionId),
    ]).then((values) {
      if (mounted) {
        setState(() {
          _detail = values[0] as WorkoutSessionDetail?;
          _summary = values[1] as WorkoutSessionSummary;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final summary = _summary;
    if (detail == null || summary == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Detalhes do treino')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            DateFormat(
              'EEEE, d MMMM yyyy · HH:mm',
              'pt_BR',
            ).format(detail.session.startedAt),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '${summary.exerciseCount} exercícios · ${summary.setCount} séries · ${summary.volumeKg.round()} kg de volume',
          ),
          if (detail.session.notes?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Text(detail.session.notes!),
          ],
          const SizedBox(height: 18),
          for (final item in detail.exercises)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.exercise.exerciseName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (item.exercise.notes?.isNotEmpty == true)
                      Text(item.exercise.notes!),
                    const Divider(),
                    if (item.sets.isEmpty)
                      const Text('Nenhuma série registrada')
                    else
                      for (final set in item.sets)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${set.position + 1}. ${set.weightKg} kg × ${set.reps} reps',
                                ),
                              ),
                              if (set.completedAt == null)
                                const Text(
                                  'Incompleta',
                                  style: TextStyle(fontSize: 12),
                                ),
                              if (set.rpe != null) Text('RPE ${set.rpe}'),
                              if (set.rir != null) Text('RIR ${set.rir}'),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
