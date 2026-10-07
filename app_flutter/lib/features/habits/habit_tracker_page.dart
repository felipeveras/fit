import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/health/health_repository.dart';
import '../../core/persistence/app_database.dart';
import 'habit_controller.dart';
import 'habit_models.dart';
import 'habit_photo_picker.dart';
import 'habit_reminder_bridge.dart';
import 'habit_repository.dart';

class HabitTrackerPage extends StatefulWidget {
  const HabitTrackerPage({super.key, required this.database, this.health});
  final AppDatabase database;
  final HealthRepository? health;

  @override
  State<HabitTrackerPage> createState() => _HabitTrackerPageState();
}

class _HabitTrackerPageState extends State<HabitTrackerPage> {
  late final HabitController c;
  bool showArchived = false, showFocus = false;

  @override
  void initState() {
    super.initState();
    c = HabitController(
      HabitRepository(widget.database),
      health: widget.health,
    );
    c.refresh().then((_) => c.syncHealthHistory());
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final rows = showArchived ? c.archived : c.habits;
      final today = habitDay(DateTime.now());
      final earned = c.habits.fold<int>(
        0,
        (sum, row) => sum + row.stats.completedOpportunities,
      );
      final possible = c.habits.fold<int>(
        0,
        (sum, row) => sum + row.stats.scheduledOpportunities,
      );
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  showArchived ? 'Hábitos arquivados' : 'Seus hábitos',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Foco e Pomodoro',
                onPressed: () => setState(() => showFocus = !showFocus),
                icon: const Icon(Icons.timer_outlined),
              ),
              IconButton(
                tooltip: 'Copiar resumo agregado',
                onPressed: _copySummary,
                icon: const Icon(Icons.ios_share_outlined),
              ),
              if (!showArchived)
                IconButton(
                  tooltip: 'Criar hábito',
                  onPressed: _createHabit,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              PopupMenuButton<String>(
                tooltip: 'Mais opções',
                onSelected: (value) =>
                    setState(() => showArchived = value == 'archive'),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: showArchived ? 'active' : 'archive',
                    child: Text(showArchived ? 'Ver ativos' : 'Ver arquivados'),
                  ),
                  if (!showArchived)
                    const PopupMenuItem(
                      value: 'focus',
                      child: Text('Foco e Pomodoro'),
                    ),
                ],
              ),
            ],
          ),
          Text(
            'Acompanhe o que está funcionando, com espaço para ajustar o caminho.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _dateSelector(context),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: 'Aderência',
                      value: '$earned/$possible',
                      detail: possible == 0
                          ? 'sem oportunidades avaliadas'
                          : '${(100 * earned / possible).round()}% no período',
                      icon: Icons.insights_outlined,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Metric(
                      label: 'Hábitos ativos',
                      value: '${c.habits.length}',
                      detail: 'com registro local',
                      icon: Icons.checklist_rtl_outlined,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (c.exerciseOrigins.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: c.exerciseOrigin,
              decoration: const InputDecoration(
                labelText: 'Fonte dos exercícios',
              ),
              items: [
                for (final origin in c.exerciseOrigins)
                  DropdownMenuItem(value: origin, child: Text(origin)),
              ],
              onChanged: (origin) {
                if (origin != null) c.selectExerciseOrigin(origin);
              },
            ),
          TextButton.icon(
            onPressed: () async {
              await c.refresh();
              await c.syncHealthHistory();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Atualizar hábitos e leituras'),
          ),
          if (c.error != null) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              text: c.error!,
              onTap: () async {
                await c.refresh();
                await c.syncHealthHistory();
              },
            ),
          ],
          if (c.loading) const LinearProgressIndicator(),
          if (c.syncingSteps) const LinearProgressIndicator(),
          if (showFocus) ...[
            const SizedBox(height: 16),
            FocusPanel(controller: c),
          ],
          const SizedBox(height: 12),
          if (showArchived)
            for (final row in rows) _archivedCard(context, row)
          else if (rows.isEmpty)
            _emptyState(context)
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: rows.length,
              onReorderItem: (oldIndex, newIndex) async {
                final reordered = rows.map((e) => e.habit.id).toList();
                final moved = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, moved);
                await c.reorder(reordered);
              },
              itemBuilder: (context, index) => Padding(
                key: ValueKey(rows[index].habit.id),
                padding: const EdgeInsets.only(bottom: 12),
                child: _habitCard(context, rows[index], today),
              ),
            ),
          if (!showArchived && c.habits.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('Visão anual', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _YearOverview(rows: c.habits),
          ],
        ],
      );
    },
  );

  Widget _dateSelector(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Dia anterior',
            onPressed: () async =>
                c.selectDate(c.selectedDate.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Semantics(
              button: true,
              label: 'Selecionar data',
              child: TextButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: c.selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) await c.selectDate(picked);
                },
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  _dateLabel(c.selectedDate),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
          if (!habitDay(c.selectedDate)
              .isAtSameMomentAs(habitDay(DateTime.now())))
            IconButton(
              tooltip: 'Ir para hoje',
              onPressed: () async => c.selectDate(DateTime.now()),
              icon: const Icon(Icons.today_outlined),
            ),
          IconButton(
            tooltip: 'Dia seguinte',
            onPressed: c.selectedDate.isBefore(habitDay(DateTime.now()))
                ? () async =>
                      c.selectDate(c.selectedDate.add(const Duration(days: 1)))
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    ),
  );

  Widget _emptyState(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.spa_outlined, size: 36),
          const SizedBox(height: 12),
          Text(
            'Comece com um hábito pequeno',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Escolha algo que faça sentido para sua rotina. Você pode mudar o plano depois.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _createHabit,
            icon: const Icon(Icons.add),
            label: const Text('Criar hábito'),
          ),
        ],
      ),
    ),
  );

  Widget _habitCard(BuildContext context, HabitProgress row, DateTime today) {
    final habit = row.habit;
    final day = habitDay(c.selectedDate);
    final record = row.history[day] ?? const HabitDayRecord();
    final scheduled =
        habit.schedule.isScheduled(day) &&
        !record.restDay &&
        !record.vacation &&
        day.isBefore(today.add(const Duration(days: 1)));
    final snoozed =
        row.snoozedUntil != null &&
        row.snoozedUntil!.isAfter(DateTime.now().toUtc());
    final checklistComplete =
        row.substeps.isEmpty ||
        row.substeps.every((step) => row.checkedSubsteps.contains(step.id));
    final status = switch (habit.type) {
      HabitType.positive =>
        '${record.completions}/${habit.dailyTargetCount} conclusões',
      HabitType.avoid =>
        record.completions == 0
            ? 'Sem ocorrência registrada'
            : '${record.completions} ocorrência(s) registrada(s)',
      HabitType.quantitative =>
        '${_quantity(record.quantity)} / ${_quantity(habit.quantityTarget ?? 0)} ${habit.quantityUnit}',
    };
    final progress = switch (habit.type) {
      HabitType.positive => (record.completions / habit.dailyTargetCount).clamp(
        0.0,
        1.0,
      ),
      HabitType.avoid => record.completions == 0 ? 1.0 : 0.0,
      HabitType.quantitative =>
        (record.quantity / (habit.quantityTarget ?? 1)).clamp(0.0, 1.0),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Color(habit.color).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    habit.emoji,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        habit.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_typeLabel(habit.type)} • ${_scheduleLabel(habit.schedule)} • ${habit.category}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Ações de ${habit.name}',
                  onSelected: (v) => _habitAction(row, v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'context',
                      child: Text('Registrar com contexto'),
                    ),
                    const PopupMenuItem(
                      value: 'history',
                      child: Text('Histórico e métricas'),
                    ),
                    const PopupMenuItem(
                      value: 'share',
                      child: Text('Compartilhar card de progresso'),
                    ),
                    const PopupMenuItem(
                      value: 'note',
                      child: Text('Nota deste dia'),
                    ),
                    const PopupMenuItem(
                      value: 'rest',
                      child: Text('Marcar dia de descanso'),
                    ),
                    const PopupMenuItem(
                      value: 'vacation',
                      child: Text('Programar pausa ou férias'),
                    ),
                    if (habit.reminderEnabled)
                      const PopupMenuItem(
                        value: 'reminder',
                        child: Text('Adiar lembrete por 10 min'),
                      ),
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Editar hábito'),
                    ),
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('Arquivar mantendo histórico'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: scheduled ? progress : 0,
              semanticsLabel: 'Progresso do hábito',
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text(status)),
                if (!scheduled)
                  const Text('Dia sem meta', style: TextStyle(fontSize: 12)),
              ],
            ),
            if (record.restDay || record.vacation)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  record.vacation ? 'Pausa programada' : 'Dia de descanso',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (snoozed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Lembrete adiado até ${DateFormat('HH:mm').format(row.snoozedUntil!.toLocal())}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (row.substeps.isNotEmpty) ...[
              const Divider(height: 20),
              for (final step in row.substeps)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(step.title),
                  value: row.checkedSubsteps.contains(step.id),
                  onChanged: (v) => c.toggleSubstep(step.id, v ?? false),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                switch (habit.type) {
                  HabitType.positive => FilledButton.tonalIcon(
                    onPressed: scheduled && checklistComplete
                        ? () => c.complete(habit.id)
                        : null,
                    icon: const Icon(Icons.check),
                    label: const Text('Concluir'),
                  ),
                  HabitType.avoid => OutlinedButton.icon(
                    onPressed: scheduled
                        ? () => _recordAvoidOccurrence(habit)
                        : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Registrar ocorrência'),
                  ),
                  HabitType.quantitative => FilledButton.tonalIcon(
                    onPressed: scheduled ? () => _addAmount(habit) : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Adicionar progresso'),
                  ),
                },
                OutlinedButton.icon(
                  onPressed: () => _correctHistory(habit),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Corrigir dia'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${row.stats.summary} • ${row.stats.totalCompletions} registros • força ${(_habitStrength(row.stats) * 100).round()}/100',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _archivedCard(BuildContext context, HabitProgress row) => Card(
    child: ListTile(
      leading: Text(row.habit.emoji, style: const TextStyle(fontSize: 22)),
      title: Text(row.habit.name),
      subtitle: Text(
        '${row.stats.totalCompletions} registros • ${row.stats.summary}',
      ),
      trailing: IconButton(
        tooltip: 'Restaurar hábito',
        icon: const Icon(Icons.unarchive_outlined),
        onPressed: () => c.restoreHabit(row.habit.id),
      ),
    ),
  );

  Future<void> _habitAction(HabitProgress row, String action) async {
    final h = row.habit;
    switch (action) {
      case 'context':
        await _recordWithContext(h);
        break;
      case 'history':
        await _showHistory(row);
        break;
      case 'share':
        await _shareCard(row);
        break;
      case 'note':
        await _editNote(row);
        break;
      case 'rest':
        await c.restDay(h.id, !(row.history[c.selectedDate]?.restDay ?? false));
        break;
      case 'vacation':
        await _scheduleVacation(h);
        break;
      case 'reminder':
        await c.snooze(h.id);
        break;
      case 'edit':
        await _createHabit(existing: row);
        break;
      case 'archive':
        await c.archiveHabit(h.id);
        break;
    }
  }

  Future<void> _createHabit({HabitProgress? existing}) async {
    final initial = existing?.habit;
    final values = await showDialog<_HabitDraft>(
      context: context,
      builder: (_) => _HabitEditor(
        initial: initial,
        substeps: existing?.substeps.map((s) => s.title).toList() ?? const [],
      ),
    );
    if (values == null) return;
    try {
      await c.save(values.habit, substeps: values.substeps);
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Não foi possível salvar. Confira os campos obrigatórios.',
        );
      }
    }
  }

  Future<void> _addAmount(Habit habit) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(habit: habit),
    );
    if (amount != null) await c.addQuantity(habit.id, amount);
  }

  Future<void> _recordAvoidOccurrence(Habit habit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Registrar ocorrência'),
        content: Text(
          'O registro de hoje ajuda a entender o padrão de “${habit.name}”. Seu histórico de aderência permanece.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Registrar'),
          ),
        ],
      ),
    );
    if (confirmed == true) await c.complete(habit.id);
  }

  Future<void> _recordWithContext(Habit habit) async {
    final draft = await showDialog<_ContextDraft>(
      context: context,
      builder: (_) =>
          _ContextDialog(quantitative: habit.type == HabitType.quantitative),
    );
    if (draft == null) return;
    if (habit.type == HabitType.quantitative) {
      if (draft.amount != null) {
        await c.addQuantity(
          habit.id,
          draft.amount!,
          note: draft.note,
          behavioralMoment: draft.behavior,
        );
      }
    } else {
      await c.complete(
        habit.id,
        note: draft.note,
        behavioralMoment: draft.behavior.isEmpty ? null : draft.behavior,
      );
    }
  }

  Future<void> _editNote(HabitProgress row) async {
    final matching = row.notes.where((n) => habitDay(n.date) == c.selectedDate);
    final existing = matching.isEmpty ? null : matching.first;
    final note = await showDialog<_NoteDraft>(
      context: context,
      builder: (_) => _NoteDialog(note: existing),
    );
    if (note != null) {
      await c.note(row.habit.id, note.body, photoUri: note.photoUri);
    }
  }

  Future<void> _correctHistory(Habit habit) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: c.selectedDate,
      firstDate: habit.schedule.startDate,
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    await c.selectDate(picked);
    final logs = await c.logsFor(habit.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Registros de ${DateFormat('d MMM', 'pt_BR').format(picked)}',
        ),
        content: SizedBox(
          width: 420,
          child: logs.isEmpty
              ? const Text('Nenhum registro neste dia.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final log in logs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          log['log_kind'] == 'completion'
                              ? 'Conclusão'
                              : '+ ${_quantity((log['amount']! as num).toDouble())} ${habit.quantityUnit ?? ''}',
                        ),
                        subtitle: Text(
                          DateFormat('HH:mm').format(
                            DateTime.parse(log['occurred_at']! as String)
                                .toLocal(),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Alterar horário',
                              icon: const Icon(Icons.schedule),
                              onPressed: () =>
                                  _editLogTime(habit, log, dialogContext),
                            ),
                            IconButton(
                              tooltip: 'Remover registro',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await c.removeLog(log);
                                if (dialogContext.mounted) {
                                  Navigator.pop(dialogContext);
                                }
                                await _correctHistory(habit);
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Future<void> _editLogTime(
    Habit habit,
    Map<String, Object?> log,
    BuildContext dialogContext,
  ) async {
    final occurred = DateTime.parse(log['occurred_at']! as String).toLocal();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(occurred),
    );
    if (time == null) return;
    await c.adjustLogTime(log, time.hour, time.minute);
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    await _correctHistory(habit);
  }

  Future<void> _showHistory(HabitProgress row) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Histórico • ${row.habit.name}'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.stats.summary),
                const SizedBox(height: 10),
                Text('Total de conclusões: ${row.stats.totalCompletions}'),
                Text(
                  'Força do hábito: ${(_habitStrength(row.stats) * 100).round()}/100 • 45% aderência + 30% frequência (máx. 30) + 25% melhor sequência (máx. 21).',
                ),
                const SizedBox(height: 14),
                const Text('Últimos 12 meses'),
                _Heatmap(
                  progress: row,
                  onTap: (day) {
                    unawaited(c.selectDate(day));
                    Navigator.pop(dialogContext);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Evolução por horário: ${row.stats.timeBuckets.entries.map((e) => '${e.key} ${e.value}').join(' • ')}',
                ),
                const SizedBox(height: 8),
                Text(
                  'Evolução mensal: ${_mapSummary(row.stats.monthlyCompletionCounts)}',
                ),
                Text(
                  'Evolução anual: ${_mapSummary(row.stats.yearlyCompletionCounts)}',
                ),
                const SizedBox(height: 12),
                Text('Agendamento: ${_scheduleLabel(row.habit.schedule)}'),
                if (row.vacations.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Pausas e férias'),
                  for (final v in row.vacations)
                    ListTile(
                      dense: true,
                      title: Text(v.label),
                      subtitle: Text(
                        '${habitDateKey(v.startDate)} a ${habitDateKey(v.endDate)}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Remover pausa',
                        onPressed: () async {
                          await c.removeVacation(v.id);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Future<void> _scheduleVacation(Habit habit) async {
    final initial = DateTimeRange(
      start: c.selectedDate,
      end: c.selectedDate.add(const Duration(days: 6)),
    );
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      initialDateRange: initial,
    );
    if (range != null) await c.vacation(habit.id, range.start, range.end);
  }

  Future<void> _copySummary() async {
    final json = await c.repository.exportJson();
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      _showMessage('Resumo agregado copiado. Notas e fotos não são incluídas.');
    }
  }

  Future<void> _shareCard(HabitProgress row) async {
    final strength = (_habitStrength(row.stats) * 100).round();
    final text =
        '${row.habit.emoji} ${row.habit.name}\n${row.stats.summary}\n${row.stats.totalCompletions} registros • força do hábito $strength/100';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Card de progresso'),
        content: Card(
          color: Color(row.habit.color).withValues(alpha: .10),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${row.habit.emoji} ${row.habit.name}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(row.stats.summary),
                const SizedBox(height: 6),
                Text(
                  '${row.stats.totalCompletions} registros • força $strength/100',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                await HabitReminderBridge.share(row.habit.name, text);
              } catch (_) {
                await Clipboard.setData(ClipboardData(text: text));
                if (mounted) _showMessage('Resumo copiado para compartilhar.');
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.share_outlined),
            label: const Text('Compartilhar'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
  });
  final String label, value, detail;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label, $value, $detail',
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 24),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.info_outline),
      title: Text(text),
      trailing: IconButton(
        tooltip: 'Tentar novamente',
        onPressed: onTap,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );
}

class _YearOverview extends StatelessWidget {
  const _YearOverview({required this.rows});
  final List<HabitProgress> rows;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final current = rows.fold<int>(
      0,
      (s, r) => s + (r.stats.yearlyCompletionCounts['${now.year}'] ?? 0),
    );
    final previous = rows.fold<int>(
      0,
      (s, r) => s + (r.stats.yearlyCompletionCounts['${now.year - 1}'] ?? 0),
    );
    return Card(
      child: ListTile(
        leading: const Icon(Icons.calendar_month_outlined),
        title: Text('$current registros em ${now.year}'),
        subtitle: Text(
          '$previous no ano anterior • hábitos continuam contando durante pausas e férias.',
        ),
      ),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.progress, required this.onTap});
  final HabitProgress progress;
  final ValueChanged<DateTime> onTap;
  @override
  Widget build(BuildContext context) {
    final end = habitDay(DateTime.now());
    final start = end.subtract(const Duration(days: 363));
    final first = start.subtract(Duration(days: start.weekday - 1));
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (var i = 0; i < 364; i++)
          Builder(
            builder: (context) {
              final day = first.add(Duration(days: i));
              final record = progress.history[day] ?? const HabitDayRecord();
              final count = progress.habit.type == HabitType.quantitative
                  ? (record.quantity > 0 ? 1 : 0)
                  : record.completions;
              final color = !record.covered
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : count == 0
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : Color(progress.habit.color)
                        .withValues(alpha: count >= 2 ? .92 : .55);
              return Semantics(
                button: true,
                label: '${habitDateKey(day)}, $count registros',
                child: InkWell(
                  onTap: day.isAfter(end) ? null : () => onTap(day),
                  borderRadius: BorderRadius.circular(3),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _HabitDraft {
  const _HabitDraft(this.habit, this.substeps);
  final Habit habit;
  final List<String> substeps;
}

class _HabitEditor extends StatefulWidget {
  const _HabitEditor({this.initial, required this.substeps});
  final Habit? initial;
  final List<String> substeps;
  @override
  State<_HabitEditor> createState() => _HabitEditorState();
}

class _HabitEditorState extends State<_HabitEditor> {
  late final TextEditingController name, target, unit, category, emoji, steps;
  late HabitType type;
  late HabitCadence cadence;
  late Set<int> weekdays;
  late DateTime start;
  late int targetCount, dailyCount, interval, color;
  late HabitAutomation automation;
  late bool reminderEnabled;
  TimeOfDay? reminder;
  final formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final h = widget.initial;
    name = TextEditingController(text: h?.name ?? '');
    target = TextEditingController(text: (h?.quantityTarget ?? 2.5).toString());
    unit = TextEditingController(text: h?.quantityUnit ?? '');
    category = TextEditingController(text: h?.category ?? 'Geral');
    emoji = TextEditingController(text: h?.emoji ?? '✦');
    steps = TextEditingController(text: widget.substeps.join('\n'));
    type = h?.type ?? HabitType.positive;
    cadence = h?.schedule.cadence ?? HabitCadence.daily;
    weekdays =
        h?.schedule.weekdays.toSet() ??
        {DateTime.monday, DateTime.wednesday, DateTime.friday};
    start = h?.schedule.startDate ?? habitDay(DateTime.now());
    targetCount = h?.schedule.targetCount ?? 3;
    dailyCount = h?.dailyTargetCount ?? 1;
    interval = h?.schedule.intervalDays ?? 2;
    color = h?.color ?? 0xFF22618B;
    automation = h?.automation ?? HabitAutomation.manual;
    reminderEnabled = h?.reminderEnabled ?? false;
    if (h?.reminderHour != null && h?.reminderMinute != null) {
      reminder = TimeOfDay(hour: h!.reminderHour!, minute: h.reminderMinute!);
    }
  }

  @override
  void dispose() {
    name.dispose();
    target.dispose();
    unit.dispose();
    category.dispose();
    emoji.dispose();
    steps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Novo hábito' : 'Editar hábito'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nome do hábito'),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Informe um nome.' : null,
              ),
              const SizedBox(height: 12),
              SegmentedButton<HabitType>(
                segments: const [
                  ButtonSegment(
                    value: HabitType.positive,
                    label: Text('Positivo'),
                  ),
                  ButtonSegment(value: HabitType.avoid, label: Text('Evitar')),
                  ButtonSegment(
                    value: HabitType.quantitative,
                    label: Text('Quantidade'),
                  ),
                ],
                selected: {type},
                onSelectionChanged: (v) => setState(() {
                  type = v.first;
                  if (type != HabitType.positive &&
                      automation != HabitAutomation.manual &&
                      automation != HabitAutomation.healthConnectSteps) {
                    automation = HabitAutomation.manual;
                  }
                  if (type != HabitType.quantitative &&
                      automation == HabitAutomation.healthConnectSteps) {
                    automation = HabitAutomation.manual;
                  }
                }),
              ),
              if (type == HabitType.quantitative) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: target,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Meta'),
                        validator: (v) => _parseQuantityTarget(v) == null
                            ? 'Meta maior que zero.'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: unit,
                        decoration: const InputDecoration(
                          labelText: 'Unidade (ex.: ml, min, passos)',
                        ),
                        validator: (v) => v?.trim().isEmpty ?? true
                            ? 'Informe a unidade.'
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
              if (type == HabitType.positive) ...[
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: '$dailyCount',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Conclusões necessárias por dia',
                  ),
                  onChanged: (v) => dailyCount = int.tryParse(v) ?? 1,
                ),
                const SizedBox(height: 8),
                Text(
                  'Checklist opcional (uma etapa por linha)',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                TextField(
                  controller: steps,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText:
                        'Ex.: aquecer\nse exercitar\nanotar como me senti',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<HabitCadence>(
                initialValue: cadence,
                decoration: const InputDecoration(labelText: 'Frequência'),
                items: const [
                  DropdownMenuItem(
                    value: HabitCadence.daily,
                    child: Text('Todos os dias'),
                  ),
                  DropdownMenuItem(
                    value: HabitCadence.weeklyTarget,
                    child: Text('X vezes por semana'),
                  ),
                  DropdownMenuItem(
                    value: HabitCadence.monthlyTarget,
                    child: Text('X vezes por mês'),
                  ),
                  DropdownMenuItem(
                    value: HabitCadence.specificDays,
                    child: Text('Dias específicos'),
                  ),
                  DropdownMenuItem(
                    value: HabitCadence.everyNDays,
                    child: Text('A cada N dias'),
                  ),
                ],
                onChanged: (v) => setState(() => cadence = v ?? cadence),
              ),
              if (cadence == HabitCadence.weeklyTarget ||
                  cadence == HabitCadence.monthlyTarget)
                TextFormField(
                  initialValue: '$targetCount',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Ocorrências no período',
                  ),
                  onChanged: (v) => targetCount = int.tryParse(v) ?? 1,
                ),
              if (cadence == HabitCadence.everyNDays)
                TextFormField(
                  initialValue: '$interval',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Intervalo em dias',
                  ),
                  onChanged: (v) => interval = int.tryParse(v) ?? 1,
                ),
              if (cadence == HabitCadence.specificDays)
                Wrap(
                  spacing: 2,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(_weekdayName(d)),
                        selected: weekdays.contains(d),
                        onSelected: (v) => setState(() {
                          if (v) {
                            weekdays.add(d);
                          } else {
                            weekdays.remove(d);
                          }
                        }),
                      ),
                  ],
                ),
              TextButton.icon(
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: start,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (date != null) setState(() => start = habitDay(date));
                },
                icon: const Icon(Icons.event),
                label: Text(
                  'Início: ${DateFormat('dd/MM/yyyy').format(start)}',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: category,
                      decoration: const InputDecoration(labelText: 'Categoria'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextFormField(
                      controller: emoji,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(labelText: 'Símbolo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Cor do hábito',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final value in const [
                    0xFF22618B,
                    0xFF397C5B,
                    0xFFB65D41,
                    0xFF7256A5,
                    0xFFAD7B20,
                    0xFF386B78,
                  ])
                    ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: Color(value)),
                      label: Text(value == color ? 'Selecionada' : ' '),
                      selected: value == color,
                      onSelected: (_) => setState(() => color = value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<HabitAutomation>(
                initialValue: automation,
                decoration: const InputDecoration(labelText: 'Como registrar'),
                items: const [
                  DropdownMenuItem(
                    value: HabitAutomation.manual,
                    child: Text('Manual'),
                  ),
                  DropdownMenuItem(
                    value: HabitAutomation.workout,
                    child: Text('Treino concluído'),
                  ),
                  DropdownMenuItem(
                    value: HabitAutomation.healthConnectExercise,
                    child: Text('Exercício no Health Connect'),
                  ),
                  DropdownMenuItem(
                    value: HabitAutomation.healthConnectRun,
                    child: Text('Corrida no Health Connect'),
                  ),
                  DropdownMenuItem(
                    value: HabitAutomation.healthConnectSteps,
                    child: Text('Meta de passos'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      automation = v;
                      if (v == HabitAutomation.healthConnectSteps) {
                        type = HabitType.quantitative;
                        if (unit.text.isEmpty) unit.text = 'passos';
                      } else if (v != HabitAutomation.manual) {
                        type = HabitType.positive;
                      }
                    });
                  }
                },
              ),
              if (automation == HabitAutomation.healthConnectSteps &&
                  type == HabitType.quantitative)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Cada dia usa a cobertura da própria leitura; dias sem dados não viram zero.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lembrete neste horário'),
                value: reminderEnabled,
                onChanged: (v) async {
                  setState(() => reminderEnabled = v);
                  if (v && reminder == null) {
                    reminder = await showTimePicker(
                      context: context,
                      initialTime: const TimeOfDay(hour: 20, minute: 0),
                    );
                  }
                  setState(() {});
                },
              ),
              if (reminderEnabled)
                TextButton.icon(
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime:
                          reminder ?? const TimeOfDay(hour: 20, minute: 0),
                    );
                    if (picked != null) setState(() => reminder = picked);
                  },
                  icon: const Icon(Icons.alarm),
                  label: Text(reminder?.format(context) ?? 'Escolher horário'),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );

  void _save() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    if (cadence == HabitCadence.specificDays && weekdays.isEmpty) return;
    final h = widget.initial;
    try {
      final schedule = HabitSchedule(
        cadence: cadence,
        targetCount: targetCount,
        weekdays: weekdays,
        intervalDays: interval,
        startDate: start,
      );
      final quantityTarget = type == HabitType.quantitative
          ? _parseQuantityTarget(target.text)
          : null;
      if (type == HabitType.quantitative && quantityTarget == null) return;
      final habit = Habit(
        id: h?.id ?? 'habit:${DateTime.now().microsecondsSinceEpoch}',
        name: name.text,
        type: type,
        schedule: schedule,
        quantityTarget: quantityTarget,
        quantityUnit: type == HabitType.quantitative ? unit.text.trim() : null,
        dailyTargetCount: type == HabitType.positive ? dailyCount : 1,
        archivedAt: h?.archivedAt,
        category: category.text.trim().isEmpty ? 'Geral' : category.text.trim(),
        emoji: emoji.text.trim().isEmpty ? '✦' : emoji.text.trim(),
        color: color,
        position: h?.position ?? 0,
        automation: automation,
        exerciseTypes: h?.exerciseTypes ?? const {},
        reminderEnabled: reminderEnabled && reminder != null,
        reminderHour: reminder?.hour,
        reminderMinute: reminder?.minute,
        createdAt: h?.createdAt,
      );
      Navigator.pop(context, _HabitDraft(habit, steps.text.split('\n')));
    } on ArgumentError catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message.toString())));
    }
  }
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.habit});
  final Habit habit;
  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final TextEditingController amount;
  @override
  void initState() {
    super.initState();
    amount = TextEditingController(text: '');
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Adicionar progresso'),
    content: TextField(
      controller: amount,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Quantidade',
        suffixText: widget.habit.quantityUnit,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          final parsed = double.tryParse(amount.text.replaceAll(',', '.'));
          if (parsed != null && parsed > 0) Navigator.pop(context, parsed);
        },
        child: const Text('Adicionar'),
      ),
    ],
  );
}

class _ContextDraft {
  const _ContextDraft({this.note = '', this.behavior = '', this.amount});
  final String note, behavior;
  final double? amount;
}

class _ContextDialog extends StatefulWidget {
  const _ContextDialog({required this.quantitative});
  final bool quantitative;
  @override
  State<_ContextDialog> createState() => _ContextDialogState();
}

class _ContextDialogState extends State<_ContextDialog> {
  final note = TextEditingController(),
      behavior = TextEditingController(),
      amount = TextEditingController();
  @override
  void dispose() {
    note.dispose();
    behavior.dispose();
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Registro com contexto'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.quantitative)
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Quantidade',
                helperText: 'Informe a quantidade para salvar o registro.',
              ),
            ),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Nota opcional'),
          ),
          TextField(
            controller: behavior,
            decoration: const InputDecoration(
              labelText: 'Momento comportamental opcional',
              helperText: 'Pode ser registrado junto, sem abrir outra ficha.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          final parsed = widget.quantitative
              ? double.tryParse(amount.text.replaceAll(',', '.'))
              : null;
          if (widget.quantitative && (parsed == null || parsed <= 0)) return;
          Navigator.pop(
            context,
            _ContextDraft(
              note: note.text.trim(),
              behavior: behavior.text.trim(),
              amount: parsed,
            ),
          );
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}

class _NoteDraft {
  const _NoteDraft(this.body, this.photoUri);
  final String body, photoUri;
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({this.note});
  final HabitNote? note;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController body, photo;
  @override
  void initState() {
    super.initState();
    body = TextEditingController(text: widget.note?.text ?? '');
    photo = TextEditingController(text: widget.note?.photoUri ?? '');
  }

  @override
  void dispose() {
    body.dispose();
    photo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nota do dia'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: body,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Como foi?'),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  photo.text.isEmpty
                      ? 'Nenhuma foto escolhida'
                      : 'Foto anexada neste aparelho',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  try {
                    final uri = await HabitPhotoPicker.pickLocalImage();
                    if (mounted && uri != null) {
                      setState(() => photo.text = uri);
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Não foi possível abrir as fotos.'),
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Foto'),
              ),
            ],
          ),
          const Text(
            'A referência fica no aparelho e não entra nos resumos agregados.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, _NoteDraft(body.text, photo.text)),
        child: const Text('Salvar'),
      ),
    ],
  );
}

class FocusPanel extends StatefulWidget {
  const FocusPanel({super.key, required this.controller});
  final HabitController controller;
  @override
  State<FocusPanel> createState() => _FocusPanelState();
}

class _FocusPanelState extends State<FocusPanel> {
  Timer? timer;
  DateTime? started;
  int seconds = 0;
  int planned = 25;
  int sessionPlanned = 25;
  bool running = false;
  bool completed = false;
  bool onBreak = false;
  HabitController get c => widget.controller;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void _startFocus() {
    if (running) return;
    started ??= DateTime.now();
    if (seconds == 0) sessionPlanned = planned;
    _startTimer(sessionPlanned, isBreak: false);
  }

  void _startBreak(int minutes) {
    if (running) return;
    _startTimer(minutes, isBreak: true);
  }

  void _startTimer(int minutes, {required bool isBreak}) {
    setState(() {
      running = true;
      onBreak = isBreak;
      if (!isBreak) completed = false;
      if (seconds == 0) seconds = minutes * 60;
    });
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !running) return;
      setState(() {
        seconds--;
        if (seconds <= 0) {
          seconds = 0;
          running = false;
          timer?.cancel();
          if (isBreak) {
            onBreak = false;
            completed = false;
          } else {
            completed = true;
            unawaited(_finish(true));
          }
        }
      });
    });
  }

  Future<void> _finish(bool done) async {
    final begin = started;
    if (begin != null) {
      await c.finishFocus(
        start: begin,
        end: DateTime.now(),
        minutes: sessionPlanned,
        completed: done,
      );
    }
    started = null;
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.focusConfig;
    planned = cfg['workMinutes'] ?? 25;
    final now = DateTime.now();
    final today = c.focusHistory
        .where((row) {
          final startedAt = DateTime.parse(row['started_at']! as String)
              .toLocal();
          return startedAt.year == now.year &&
              startedAt.month == now.month &&
              startedAt.day == now.day;
        })
        .fold<int>(
          0,
          (sum, row) =>
              sum +
              (row['completed'] == 1 ? row['planned_minutes']! as int : 0),
        );
    final displaySeconds = seconds == 0 && !running
        ? (onBreak ? (cfg['breakMinutes'] ?? 5) : planned) * 60
        : seconds;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Foco e Pomodoro',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Configurar foco',
                  onPressed: _configure,
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            Text('Meta do dia: $today / ${cfg['dailyGoalMinutes']} min'),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '${(displaySeconds ~/ 60).toString().padLeft(2, '0')}:${(displaySeconds % 60).toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: running || onBreak ? null : _startFocus,
                  child: Text(
                    running
                        ? 'Em andamento'
                        : seconds > 0 && !onBreak
                        ? 'Retomar foco'
                        : 'Iniciar ${cfg['workMinutes']} min',
                  ),
                ),
                if (completed || onBreak)
                  OutlinedButton(
                    onPressed: running
                        ? null
                        : () => _startBreak(cfg['breakMinutes'] ?? 5),
                    child: Text(
                      running && onBreak
                          ? 'Pausa em andamento'
                          : seconds > 0 && onBreak
                          ? 'Retomar pausa'
                          : 'Iniciar pausa (${cfg['breakMinutes']} min)',
                    ),
                  ),
                if (running)
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        running = false;
                        timer?.cancel();
                      });
                    },
                    child: const Text('Pausar'),
                  ),
                if (started != null && !onBreak)
                  TextButton(
                    onPressed: () async {
                      timer?.cancel();
                      setState(() {
                        running = false;
                        seconds = 0;
                        completed = false;
                      });
                      await _finish(false);
                    },
                    child: const Text('Encerrar'),
                  ),
              ],
            ),
            if (completed)
              const Text('Sess\u00e3o conclu\u00edda. Bom trabalho.'),
            Text(
              'Pausa configurada: ${cfg['breakMinutes']} min • ${c.focusHistory.length} sess\u00f5es no hist\u00f3rico',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configure() async {
    final values = await showDialog<Map<String, int>>(
      context: context,
      builder: (_) => _FocusSettings(config: c.focusConfig),
    );
    if (values != null) {
      await c.saveFocus(
        goal: values['dailyGoalMinutes']!,
        work: values['workMinutes']!,
        pause: values['breakMinutes']!,
      );
    }
  }
}

class _FocusSettings extends StatefulWidget {
  const _FocusSettings({required this.config});
  final Map<String, int> config;
  @override
  State<_FocusSettings> createState() => _FocusSettingsState();
}

class _FocusSettingsState extends State<_FocusSettings> {
  late final TextEditingController goal = TextEditingController(
        text: '${widget.config['dailyGoalMinutes']}',
      ),
      work = TextEditingController(text: '${widget.config['workMinutes']}'),
      pause = TextEditingController(text: '${widget.config['breakMinutes']}');
  @override
  void dispose() {
    goal.dispose();
    work.dispose();
    pause.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Meta de foco'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in [
          ('Meta diária em minutos', goal),
          ('Foco por sessão', work),
          ('Pausa em minutos', pause),
        ])
          TextField(
            controller: item.$2,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: item.$1),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          final values = [
            goal,
            work,
            pause,
          ].map((e) => int.tryParse(e.text) ?? 0).toList();
          if (values.every((v) => v > 0)) {
            Navigator.pop(context, {
              'dailyGoalMinutes': values[0],
              'workMinutes': values[1],
              'breakMinutes': values[2],
            });
          }
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}

String _dateLabel(DateTime day) {
  final d = habitDay(day), now = habitDay(DateTime.now());
  if (d == now) return 'Hoje';
  if (d == now.subtract(const Duration(days: 1))) return 'Ontem';
  return DateFormat('EEEE, d MMMM', 'pt_BR').format(day);
}

String _typeLabel(HabitType type) => switch (type) {
  HabitType.positive => 'Positivo',
  HabitType.avoid => 'Evitar',
  HabitType.quantitative => 'Quantitativo',
};
String _scheduleLabel(HabitSchedule schedule) => switch (schedule.cadence) {
  HabitCadence.daily => 'diário',
  HabitCadence.weeklyTarget => '${schedule.targetCount}x por semana',
  HabitCadence.monthlyTarget => '${schedule.targetCount}x por mês',
  HabitCadence.specificDays => schedule.weekdays.map(_weekdayName).join(', '),
  HabitCadence.everyNDays => 'a cada ${schedule.intervalDays} dias',
};
String _weekdayName(int day) =>
    const {
      1: 'Seg',
      2: 'Ter',
      3: 'Qua',
      4: 'Qui',
      5: 'Sex',
      6: 'Sáb',
      7: 'Dom',
    }[day] ??
    '';
String _quantity(double value) =>
    NumberFormat.decimalPattern('pt_BR').format(value);
String _mapSummary(Map<String, int> values) {
  final entries = values.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => '${e.key}: ${e.value}').join(' • ');
}

double _habitStrength(HabitStats stats) =>
    (0.45 * stats.adherence +
            0.30 * (stats.totalCompletions / 30).clamp(0.0, 1.0) +
            0.25 * (stats.bestStreak / 21).clamp(0.0, 1.0))
        .clamp(0.0, 1.0);

double? _parseQuantityTarget(String? raw) {
  final value = double.tryParse((raw ?? '').replaceAll(',', '.'));
  return value != null && value.isFinite && value > 0 ? value : null;
}
