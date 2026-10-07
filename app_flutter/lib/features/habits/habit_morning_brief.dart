import 'package:flutter/material.dart';

import '../../core/persistence/app_database.dart';
import 'habit_models.dart';
import 'habit_repository.dart';

class HabitMorningBrief extends StatefulWidget {
  const HabitMorningBrief({super.key, required this.database});
  final AppDatabase database;
  @override
  State<HabitMorningBrief> createState() => _HabitMorningBriefState();
}

class _HabitMorningBriefState extends State<HabitMorningBrief> {
  late Future<List<HabitSummaryItem>> brief;
  @override
  void initState() {
    super.initState();
    brief = HabitRepository(widget.database).morningBrief();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HabitSummaryItem>>(
    future: brief,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Text(
          'O resumo de hábitos ficará disponível quando os dados locais puderem ser lidos.',
        );
      }
      if (!snapshot.hasData) return const LinearProgressIndicator();
      final items = snapshot.data!;
      if (items.isEmpty) {
        return const Text(
          'Sem hábitos ativos para acompanhar hoje. Você pode criar um hábito na aba Hábitos.',
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items.take(3))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    item.type == HabitType.avoid
                        ? Icons.self_improvement_outlined
                        : Icons.track_changes_outlined,
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    '${item.completedOpportunities}/${item.scheduledOpportunities} oportunidades • ${(item.adherence * 100).round()}% de aderência • sequência ${item.currentStreak}',
                  ),
                ),
              if (items.length > 3)
                Text(
                  '+ ${items.length - 3} hábitos no histórico recente',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      );
    },
  );
}
