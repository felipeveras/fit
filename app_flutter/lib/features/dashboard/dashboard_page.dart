import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/health/health_repository.dart';
import '../../core/persistence/app_database.dart';
import '../habits/habit_morning_brief.dart';
import '../habits/habit_tracker_page.dart';
import '../settings/settings_page.dart';
import '../telegram/telegram_service.dart';
import 'dashboard_controller.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.controller, required this.database});
  final DashboardController controller;
  final AppDatabase database;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  DashboardController get c => widget.controller;
  int _selectedTab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) c.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(_selectedTab == 0 ? 'App Fit' : 'Hábitos'),
        actions: [
          IconButton(
            tooltip: 'Configurações',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(
                    preferences: c.preferences,
                    health: c.health,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: _selectedTab == 0 ? RefreshIndicator(
        onRefresh: c.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              DateFormat('EEEE, d MMMM', 'pt_BR').format(DateTime.now()),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Seu ritmo, hoje',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 8),
            const Text('Saúde e movimento em um só lugar.'),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Saúde',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Atualizar dados',
                  onPressed: c.loading ? null : c.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final days in [1, 7, 30, 90])
                  ChoiceChip(
                    label: Text(days == 1 ? 'Hoje' : '$days dias'),
                    selected: c.days == days,
                    onSelected: c.loading
                        ? null
                        : (_) => c.refresh(period: days),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (c.loading) const LinearProgressIndicator(),
            if (c.error != null)
              _notice(c.error!, action: 'Tentar novamente', onTap: c.refresh),
            if (!c.loading &&
                c.availability != null &&
                c.availability != HealthAvailability.available)
              _notice(
                'O Health Connect precisa estar disponível para consultar suas métricas.',
                action: 'Abrir Health Connect',
                onTap: c.openHealthSettings,
              ),
            if (c.permissions != null && !c.permissions!.hasAllData)
              _notice(
                'Autorize as métricas que deseja acompanhar. Os dados são lidos no aparelho.',
                action: 'Permitir leitura',
                onTap: c.loading ? null : () => c.requestPermissions(),
              ),
            if (c.days > 7 && c.permissions?.history == 'not_granted')
              _notice(
                'Parte do período pode estar fora do histórico autorizado.',
                action: 'Autorizar histórico',
                onTap: c.loading
                    ? null
                    : () => c.requestPermissions(history: true),
              ),
            if (c.summary != null) ...[
              if (c.days > 1)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Leituras por dia • dias sem dados permanecem sem valor',
                  ),
                ),
              ..._dailySections(context, c.summary!),
            ],
            const SizedBox(height: 24),
            Text(
              'Compartilhar o dia',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Envie apenas as métricas disponíveis de hoje para seu Telegram.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: c.sending || c.loading ? null : c.send,
              icon: Icon(c.sending ? Icons.hourglass_top : Icons.send_outlined),
              label: Text(c.sending ? 'Enviando…' : 'Enviar para Telegram'),
            ),
            if (c.sendMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(c.sendMessage!, semanticsLabel: c.sendMessage),
              ),
            if (c.preferences.lastSentAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Último envio: ${DateFormat('dd/MM HH:mm').format(c.preferences.lastSentAt!.toLocal())}',
                ),
              ),
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 12),
            Text('Hábitos em foco', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            HabitMorningBrief(database: widget.database),
            const SizedBox(height: 24),
          ],
        ),
      ) : HabitTrackerPage(database: widget.database, health: c.health),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Resumo'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist), label: 'Hábitos'),
        ],
      ),
    ),
  );

  Widget _notice(String text, {required String action, VoidCallback? onTap}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text),
              TextButton(onPressed: onTap, child: Text(action)),
            ],
          ),
        ),
      );

  List<Widget> _dailySections(
    BuildContext context,
    HealthPeriodSummary summary,
  ) {
    final dates = summary.snapshots.map((s) => s.date).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final date in dates) ...[
        if (summary.days > 1)
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(
              DateFormat('dd/MM/yyyy').format(DateTime.parse(date)),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 600
                ? 3
                : constraints.maxWidth >= 320
                ? 2
                : 1;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final s in summary.snapshots.where((s) => s.date == date))
                  SizedBox(
                    width:
                        (constraints.maxWidth - (columns - 1) * 12) / columns,
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.metric.label,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              s.value == null ? '—' : metricValue(s),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.availability == MetricAvailability.available
                                  ? (s.provisional
                                        ? 'Em andamento'
                                        : 'Leitura completa')
                                  : s.availability.label,
                            ),
                            if (s.metric == HealthMetric.sleepDuration &&
                                s.value != null)
                              const Text(
                                'Duração das sessões',
                                style: TextStyle(fontSize: 12),
                              ),
                            if (s.origins.isNotEmpty)
                              Text(
                                'Fonte: ${s.origins.join(', ')}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ];
  }
}
