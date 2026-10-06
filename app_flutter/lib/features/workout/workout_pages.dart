import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'workout_models.dart';
import 'workout_services.dart';
import 'workout_history_page.dart';
import 'workout_progress_page.dart';

class WorkoutsPage extends StatelessWidget {
  const WorkoutsPage({super.key, required this.services});
  final WorkoutServices services;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Treinos'),
        actions: [
          IconButton(
            tooltip: 'Ferramentas',
            icon: const Icon(Icons.calculate_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => WorkoutToolsPage(services: services),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Biblioteca de exercícios',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ExerciseLibraryPage(services: services),
              ),
            ),
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Hoje'),
            Tab(text: 'Rotinas'),
            Tab(text: 'Progresso'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          _TodayTab(services: services),
          _RoutinesTab(services: services),
          WorkoutProgressPage(services: services),
        ],
      ),
    ),
  );
}

class _TodayTab extends StatefulWidget {
  const _TodayTab({required this.services});
  final WorkoutServices services;

  @override
  State<_TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<_TodayTab> {
  WorkoutSessionDetail? active;
  WorkoutHistorySummary? overview;
  List<WorkoutRoutine> routines = [];
  List<WorkoutSessionSummary> recent = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.services.sessions.getActiveSession(),
        widget.services.progress.getOverview(),
        widget.services.library.listRoutines(),
        widget.services.sessions.listCompletedSessions(limit: 5),
      ]);
      if (!mounted) return;
      setState(() {
        active = results[0] as WorkoutSessionDetail?;
        overview = results[1] as WorkoutHistorySummary;
        routines = results[2] as List<WorkoutRoutine>;
        recent = results[3] as List<WorkoutSessionSummary>;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openSession({int? routineId}) async {
    final sessionId =
        active?.session.id ??
        await widget.services.sessions.startSession(routineId: routineId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ActiveWorkoutPage(services: widget.services, sessionId: sessionId),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            DateFormat('EEEE, d MMMM', 'pt_BR').format(DateTime.now()),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Text(
            'Movimento que conta',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 18),
          if (active != null)
            Card(
              color: c.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.radio_button_checked),
                        SizedBox(width: 8),
                        Text(
                          'TREINO EM ANDAMENTO',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      active!.session.notes?.trim().isNotEmpty == true
                          ? active!.session.notes!
                          : '${active!.exercises.length} exercícios · iniciado às ${DateFormat('HH:mm').format(active!.session.startedAt)}',
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () => _openSession(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Retomar treino'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _MetricStrip(
              first: '${overview?.frequency ?? 0}/${overview?.weeklyGoal ?? 3}',
              firstLabel: 'treinos nesta semana',
              second: '${overview?.currentStreak ?? 0}',
              secondLabel: 'dias de sequência',
            ),
            const SizedBox(height: 14),
            if (routines.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Comece com uma rotina ou treino livre.'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context)
                            .push(
                              MaterialPageRoute<void>(
                                builder: (_) => RoutineEditorPage(
                                  services: widget.services,
                                ),
                              ),
                            )
                            .then((_) => _load()),
                        icon: const Icon(Icons.add),
                        label: const Text('Criar rotina'),
                      ),
                      TextButton(
                        onPressed: () => _openSession(),
                        child: const Text('Iniciar treino livre'),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sua próxima sessão',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        DefaultTabController.of(context).animateTo(1),
                    child: const Text('Ver rotinas'),
                  ),
                ],
              ),
              for (final routine in routines.take(3))
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: c.secondaryContainer,
                      child: const Icon(Icons.fitness_center),
                    ),
                    title: Text(routine.name),
                    subtitle: Text(
                      '${routine.exercises.length} exercícios${routine.scheduledWeekdays.isEmpty ? '' : ' · ${routine.scheduledWeekdays.map(_weekdayName).join(', ')}'}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Iniciar ${routine.name}',
                      icon: const Icon(Icons.play_circle_fill),
                      onPressed: () => _openSession(routineId: routine.id),
                    ),
                    onTap: () => _openSession(routineId: routine.id),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Atividade recente',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WorkoutHistoryPage(services: widget.services),
                  ),
                ),
                child: const Text('Ver histórico'),
              ),
            ],
          ),
          if (!loading && recent.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text('Treinos concluídos aparecerão aqui.'),
              ),
            ),
          for (final summary in recent)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_outline),
              title: Text(
                DateFormat(
                  'EEE, d MMM · HH:mm',
                  'pt_BR',
                ).format(summary.session.startedAt),
              ),
              subtitle: Text(
                '${summary.setCount} séries · ${summary.volumeKg.round()} kg de volume',
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RoutinesTab extends StatefulWidget {
  const _RoutinesTab({required this.services});
  final WorkoutServices services;

  @override
  State<_RoutinesTab> createState() => _RoutinesTabState();
}

class _RoutinesTabState extends State<_RoutinesTab> {
  List<WorkoutRoutine> routines = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.services.library.listRoutines();
      if (mounted) {
        setState(() {
          routines = value;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _edit([WorkoutRoutine? routine]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoutineEditorPage(services: widget.services, routine: routine),
      ),
    );
    _load();
  }

  Future<void> _start(WorkoutRoutine routine) async {
    final id =
        await widget.services.sessions.getActiveSessionId() ??
        await widget.services.sessions.startSession(routineId: routine.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ActiveWorkoutPage(services: widget.services, sessionId: id),
      ),
    );
    _load();
  }

  Future<void> _remove(WorkoutRoutine routine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir rotina?'),
        content: Text(
          '“${routine.name}” será removida. Treinos concluídos serão preservados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.services.library.deleteRoutine(routine.id!);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : routines.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.view_list_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'Suas rotinas começam aqui',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Monte a ordem dos exercícios, as séries, as repetições e os dias da semana.',
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _edit,
                    icon: const Icon(Icons.add),
                    label: const Text('Criar rotina'),
                  ),
                ],
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  'Organize seus treinos',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ajuste a sequência e deixe os planos prontos para iniciar.',
                ),
                const SizedBox(height: 12),
                for (final routine in routines)
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(routine.name),
                          subtitle: Text(
                            '${routine.exercises.length} exercícios · ${routine.scheduledWeekdays.isEmpty ? 'sem dias agendados' : routine.scheduledWeekdays.map(_weekdayName).join(' · ')}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'edit') await _edit(routine);
                              if (value == 'copy') {
                                await widget.services.library.duplicateRoutine(
                                  routine.id!,
                                );
                                _load();
                              }
                              if (value == 'delete') await _remove(routine);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Editar'),
                              ),
                              PopupMenuItem(
                                value: 'copy',
                                child: Text('Duplicar'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Excluir'),
                              ),
                            ],
                          ),
                        ),
                        if (routine.exercises.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                routine.exercises
                                    .map(
                                      (e) =>
                                          '${e.plannedSets} × ${e.minReps}–${e.maxReps}',
                                    )
                                    .join('   ·   '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => _start(routine),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Iniciar treino'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
    floatingActionButton: routines.isEmpty
        ? null
        : FloatingActionButton.extended(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('Nova rotina'),
          ),
  );
}

class RoutineEditorPage extends StatefulWidget {
  const RoutineEditorPage({super.key, required this.services, this.routine});
  final WorkoutServices services;
  final WorkoutRoutine? routine;

  @override
  State<RoutineEditorPage> createState() => _RoutineEditorPageState();
}

class _RoutineEditorPageState extends State<RoutineEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late List<RoutineExercise> _exercises;
  late Set<int> _days;
  Map<int, ExerciseDefinition> _definitions = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.routine?.name ?? '');
    _notes = TextEditingController(text: widget.routine?.notes ?? '');
    _exercises = [...?widget.routine?.exercises];
    _days = {...?widget.routine?.scheduledWeekdays};
    widget.services.library.listExercises().then((items) {
      if (mounted) {
        setState(
          () => _definitions = {for (final item in items) item.id!: item},
        );
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _addExercise() async {
    final result = await Navigator.of(context).push<ExerciseDefinition>(
      MaterialPageRoute(
        builder: (_) =>
            ExerciseLibraryPage(services: widget.services, canSelect: true),
      ),
    );
    if (result == null || !mounted) return;
    if (_exercises.any((item) => item.exerciseId == result.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Esse exercício já está na rotina.')),
      );
      return;
    }
    setState(() {
      _definitions[result.id!] = result;
      _exercises.add(
        RoutineExercise(exerciseId: result.id!, position: _exercises.length),
      );
    });
  }

  Future<void> _plan(RoutineExercise item) async {
    final updated = await showDialog<RoutineExercise>(
      context: context,
      builder: (_) => _PlanExerciseDialog(exercise: item),
    );
    if (updated != null) {
      setState(() {
        final index = _exercises.indexOf(item);
        _exercises[index] = updated;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final routine = WorkoutRoutine(
      id: widget.routine?.id,
      name: _name.text,
      notes: _notes.text,
      scheduledWeekdays: _days.toList()..sort(),
      exercises: [
        for (var index = 0; index < _exercises.length; index++)
          RoutineExercise(
            id: _exercises[index].id,
            exerciseId: _exercises[index].exerciseId,
            position: index,
            plannedSets: _exercises[index].plannedSets,
            minReps: _exercises[index].minReps,
            maxReps: _exercises[index].maxReps,
            restSeconds: _exercises[index].restSeconds,
            supersetGroup: _exercises[index].supersetGroup,
            notes: _exercises[index].notes,
          ),
      ],
    );
    try {
      if (routine.id == null) {
        await widget.services.library.createRoutine(routine);
      } else {
        await widget.services.library.updateRoutine(routine);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível salvar a rotina: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.routine == null ? 'Nova rotina' : 'Editar rotina'),
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvando' : 'Salvar'),
        ),
      ],
    ),
    body: Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nome da rotina'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Informe um nome.'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notas (opcional)'),
          ),
          const SizedBox(height: 22),
          Text(
            'Dias da semana',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  label: Text(_weekdayName(day)),
                  selected: _days.contains(day),
                  onSelected: (selected) => setState(
                    () => selected ? _days.add(day) : _days.remove(day),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Exercícios',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _addExercise,
                icon: const Icon(Icons.add),
                label: const Text('Adicionar'),
              ),
            ],
          ),
          if (_exercises.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text(
                'Adicione exercícios e arraste para definir a ordem.',
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              onReorderItem: (oldIndex, newIndex) => setState(() {
                final exercise = _exercises.removeAt(oldIndex);
                _exercises.insert(newIndex, exercise);
              }),
              children: [
                for (final exercise in _exercises)
                  Card(
                    key: ValueKey(exercise.exerciseId),
                    child: ListTile(
                      leading: const Icon(Icons.drag_handle),
                      title: Text(
                        _definitions[exercise.exerciseId]?.name ?? 'Exercício',
                      ),
                      subtitle: Text(
                        '${exercise.plannedSets} × ${exercise.minReps}–${exercise.maxReps} · ${_durationLabel(exercise.restSeconds)} de descanso${exercise.supersetGroup == null ? '' : ' · Superset ${exercise.supersetGroup}'}',
                      ),
                      onTap: () => _plan(exercise),
                      trailing: IconButton(
                        tooltip: 'Remover exercício',
                        onPressed: () =>
                            setState(() => _exercises.remove(exercise)),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Salvar rotina'),
          ),
        ],
      ),
    ),
  );
}

class _PlanExerciseDialog extends StatefulWidget {
  const _PlanExerciseDialog({required this.exercise});
  final RoutineExercise exercise;

  @override
  State<_PlanExerciseDialog> createState() => _PlanExerciseDialogState();
}

class _PlanExerciseDialogState extends State<_PlanExerciseDialog> {
  late final TextEditingController sets, min, max, rest, superset, notes;

  @override
  void initState() {
    super.initState();
    final item = widget.exercise;
    sets = TextEditingController(text: '${item.plannedSets}');
    min = TextEditingController(text: '${item.minReps}');
    max = TextEditingController(text: '${item.maxReps}');
    rest = TextEditingController(text: '${item.restSeconds}');
    superset = TextEditingController(text: item.supersetGroup ?? '');
    notes = TextEditingController(text: item.notes ?? '');
  }

  @override
  void dispose() {
    for (final field in [sets, min, max, rest, superset, notes]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Plano do exercício'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: sets,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Séries'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: rest,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Descanso (s)'),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: min,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Reps mín.'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: max,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Reps máx.'),
                ),
              ),
            ],
          ),
          TextField(
            controller: superset,
            decoration: const InputDecoration(
              labelText: 'Superset (opcional, ex.: A)',
            ),
          ),
          TextField(
            controller: notes,
            decoration: const InputDecoration(labelText: 'Nota do exercício'),
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
          final next = RoutineExercise(
            id: widget.exercise.id,
            exerciseId: widget.exercise.exerciseId,
            position: widget.exercise.position,
            plannedSets: int.tryParse(sets.text) ?? 0,
            minReps: int.tryParse(min.text) ?? 0,
            maxReps: int.tryParse(max.text) ?? 0,
            restSeconds: int.tryParse(rest.text) ?? -1,
            supersetGroup: superset.text.trim().isEmpty
                ? null
                : superset.text.trim(),
            notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
          );
          if (next.plannedSets < 1 ||
              next.minReps < 1 ||
              next.maxReps < next.minReps ||
              next.restSeconds < 0) {
            return;
          }
          Navigator.pop(context, next);
        },
        child: const Text('Aplicar'),
      ),
    ],
  );
}

class ExerciseLibraryPage extends StatefulWidget {
  const ExerciseLibraryPage({
    super.key,
    required this.services,
    this.canSelect = false,
  });
  final WorkoutServices services;
  final bool canSelect;

  @override
  State<ExerciseLibraryPage> createState() => _ExerciseLibraryPageState();
}

class _ExerciseLibraryPageState extends State<ExerciseLibraryPage> {
  final _search = TextEditingController();
  String? _muscle;
  List<ExerciseDefinition> _items = [];
  bool _loading = true;

  static const _groups = <String, String>{
    'chest': 'Peito',
    'back': 'Costas',
    'quadriceps': 'Quadríceps',
    'hamstrings': 'Posteriores',
    'shoulders': 'Ombros',
    'biceps': 'Bíceps',
    'triceps': 'Tríceps',
    'calves': 'Panturrilhas',
    'core': 'Core',
    'other': 'Outros',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await widget.services.library.listExercises(
      query: _search.text,
      muscleGroup: _muscle,
    );
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _editExercise([ExerciseDefinition? exercise]) async {
    final value = await showDialog<ExerciseDefinition>(
      context: context,
      builder: (_) => _ExerciseDefinitionDialog(
        services: widget.services,
        exercise: exercise,
        groups: _groups,
      ),
    );
    if (value != null) {
      await widget.services.library.saveCustomExercise(value);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Biblioteca'),
      actions: [
        if (!widget.canSelect)
          IconButton(
            tooltip: 'Criar exercício',
            onPressed: _editExercise,
            icon: const Icon(Icons.add),
          ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => _load(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar exercícios',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        _load();
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: const Text('Todos'),
                  selected: _muscle == null,
                  onSelected: (_) {
                    setState(() => _muscle = null);
                    _load();
                  },
                ),
              ),
              for (final entry in _groups.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _muscle == entry.key,
                    onSelected: (_) {
                      setState(
                        () => _muscle = _muscle == entry.key ? null : entry.key,
                      );
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? const Center(child: Text('Nenhum exercício encontrado.'))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final exercise = _items[index];
                    return ListTile(
                      leading: exercise.mediaPath == null
                          ? const CircleAvatar(
                              child: Icon(Icons.fitness_center),
                            )
                          : CircleAvatar(
                              child: ClipOval(
                                child: Image.file(
                                  File(exercise.mediaPath!),
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.fitness_center),
                                ),
                              ),
                            ),
                      title: Text(exercise.name),
                      subtitle: Text(
                        '${_groups[exercise.muscleGroup] ?? exercise.muscleGroup}${exercise.instructions == null ? '' : ' · ${exercise.instructions}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: widget.canSelect
                          ? const Icon(Icons.add_circle_outline)
                          : exercise.isCustom
                          ? PopupMenuButton<String>(
                              onSelected: (value) async {
                                final messenger = ScaffoldMessenger.of(context);
                                if (value == 'edit') {
                                  await _editExercise(exercise);
                                }
                                if (value == 'delete') {
                                  try {
                                    await widget.services.library
                                        .deleteCustomExercise(exercise.id!);
                                    _load();
                                  } catch (_) {
                                    if (mounted) {
                                      messenger.showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'O exercício está em uso por uma rotina ou histórico.',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Editar'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Excluir'),
                                ),
                              ],
                            )
                          : null,
                      onTap: widget.canSelect
                          ? () => Navigator.of(context).pop(exercise)
                          : null,
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _ExerciseDefinitionDialog extends StatefulWidget {
  const _ExerciseDefinitionDialog({
    required this.services,
    required this.groups,
    this.exercise,
  });

  final WorkoutServices services;
  final Map<String, String> groups;
  final ExerciseDefinition? exercise;

  @override
  State<_ExerciseDefinitionDialog> createState() =>
      _ExerciseDefinitionDialogState();
}

class _ExerciseDefinitionDialogState extends State<_ExerciseDefinitionDialog> {
  late final TextEditingController _name;
  late final TextEditingController _instructions;
  late String _muscleGroup;
  String? _mediaPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.exercise?.name ?? '');
    _instructions = TextEditingController(
      text: widget.exercise?.instructions ?? '',
    );
    _muscleGroup = widget.exercise?.muscleGroup ?? 'chest';
    _mediaPath = widget.exercise?.mediaPath;
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _pickMedia(ImageSource source) async {
    try {
      final image = await ImagePicker().pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 1800,
      );
      if (image == null || !mounted) return;
      final path = await widget.services.library.copyExerciseMedia(image.path);
      if (mounted) {
        setState(() {
          _mediaPath = path;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Não foi possível guardar a imagem.');
      }
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Informe o nome do exercício.');
      return;
    }
    Navigator.of(context).pop(
      ExerciseDefinition(
        id: widget.exercise?.id,
        name: _name.text.trim(),
        muscleGroup: _muscleGroup,
        instructions: _instructions.text,
        mediaPath: _mediaPath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.exercise == null ? 'Exercício personalizado' : 'Editar exercício',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nome'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _muscleGroup,
            decoration: const InputDecoration(labelText: 'Grupo muscular'),
            items: widget.groups.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _muscleGroup = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instructions,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Instruções'),
          ),
          const SizedBox(height: 8),
          if (_mediaPath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(_mediaPath!),
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<ImageSource>(
              onSelected: _pickMedia,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: ImageSource.camera,
                  child: Text('Tirar foto'),
                ),
                PopupMenuItem(
                  value: ImageSource.gallery,
                  child: Text('Escolher foto'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined),
                    SizedBox(width: 8),
                    Text('Imagem própria (opcional)'),
                  ],
                ),
              ),
            ),
          ),
          if (_error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}

class ActiveWorkoutPage extends StatefulWidget {
  const ActiveWorkoutPage({
    super.key,
    required this.services,
    required this.sessionId,
  });
  final WorkoutServices services;
  final int sessionId;

  @override
  State<ActiveWorkoutPage> createState() => _ActiveWorkoutPageState();
}

class _ActiveWorkoutPageState extends State<ActiveWorkoutPage>
    with WidgetsBindingObserver {
  WorkoutSessionDetail? _detail;
  RestTimerState? _rest;
  Timer? _ticker;
  bool _busy = false;
  bool _alerting = false;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final detail = await widget.services.sessions.getSession(widget.sessionId);
    final rest = await widget.services.sessions.getRestTimer(widget.sessionId);
    if (mounted) {
      setState(() {
        _detail = detail;
        _rest = rest;
        _now = DateTime.now();
      });
    }
  }

  Future<void> _tick() async {
    if (_detail == null) return;
    final rest = await widget.services.sessions.getRestTimer(widget.sessionId);
    if (!mounted) return;
    final remaining = rest?.remainingAt(DateTime.now()) ?? Duration.zero;
    if (rest != null &&
        !rest.isPaused &&
        remaining == Duration.zero &&
        !_alerting) {
      _alerting = true;
      await widget.services.sessions.markRestTimerAlerted(widget.sessionId);
      await HapticFeedback.mediumImpact();
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
    }
    setState(() {
      _rest = rest;
      _now = DateTime.now();
    });
  }

  Future<void> _addSet(WorkoutExerciseDetail exercise) async {
    final result = await showDialog<_SetDraft>(
      context: context,
      builder: (_) => _SetEditorDialog(
        setNumber: exercise.sets.length + 1,
        plannedSets: exercise.exercise.plannedSets,
        minReps: exercise.exercise.minReps,
        maxReps: exercise.exercise.maxReps,
      ),
    );
    if (result == null) return;
    try {
      await widget.services.sessions.addSet(
        workoutExerciseId: exercise.exercise.id!,
        reps: result.reps,
        weightKg: result.weight,
        type: result.type,
        rpe: result.rpe,
        rir: result.rir,
        completed: result.completed,
      );
      if (result.completed &&
          exercise.exercise.restSeconds > 0 &&
          !_isSupersetTransition(exercise)) {
        await widget.services.sessions.startRestTimer(
          widget.sessionId,
          Duration(seconds: exercise.exercise.restSeconds),
        );
        _alerting = false;
      }
      _load();
    } catch (error) {
      _message('Não foi possível registrar a série: $error');
    }
  }

  bool _isSupersetTransition(WorkoutExerciseDetail exercise) {
    final items = _detail?.exercises ?? const <WorkoutExerciseDetail>[];
    final group = exercise.exercise.supersetGroup;
    if (group == null) return false;
    final index = items.indexOf(exercise);
    return index + 1 < items.length &&
        items[index + 1].exercise.supersetGroup == group;
  }

  Future<void> _editSet(WorkoutSet set) async {
    final result = await showDialog<_SetDraft>(
      context: context,
      builder: (_) => _SetEditorDialog(set: set),
    );
    if (result == null) return;
    await widget.services.sessions.updateSet(
      WorkoutSet(
        id: set.id,
        workoutExerciseId: set.workoutExerciseId,
        position: set.position,
        reps: result.reps,
        weightKg: result.weight,
        type: result.type,
        rpe: result.rpe,
        rir: result.rir,
        completedAt: result.completed
            ? (set.completedAt ?? DateTime.now())
            : null,
        durationSeconds: set.durationSeconds,
        distanceMeters: set.distanceMeters,
      ),
    );
    _load();
  }

  Future<void> _addExercise() async {
    final exercise = await Navigator.of(context).push<ExerciseDefinition>(
      MaterialPageRoute(
        builder: (_) =>
            ExerciseLibraryPage(services: widget.services, canSelect: true),
      ),
    );
    if (exercise == null) return;
    await widget.services.sessions.addExercise(widget.sessionId, exercise);
    _load();
  }

  Future<void> _note({int? exerciseId}) async {
    final initial = exerciseId == null
        ? _detail?.session.notes
        : _detail?.exercises
              .firstWhere((e) => e.exercise.id == exerciseId)
              .exercise
              .notes;
    final controller = TextEditingController(text: initial ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          exerciseId == null ? 'Nota do treino' : 'Nota do exercício',
        ),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    if (exerciseId == null) {
      await widget.services.sessions.updateSessionNote(widget.sessionId, value);
    } else {
      await widget.services.sessions.updateExerciseNote(exerciseId, value);
    }
    _load();
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await widget.services.sessions.completeSession(widget.sessionId);
      await widget.services.replayPendingEvents();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => WorkoutSummaryPage(
            services: widget.services,
            sessionId: widget.sessionId,
          ),
        ),
      );
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar treino?'),
        content: const Text(
          'As séries registradas serão mantidas no histórico como treino cancelado e não contarão nas métricas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar treino'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.services.sessions.cancelSession(widget.sessionId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    if (detail == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final duration = _now.difference(detail.session.startedAt);
    final restRemaining = _rest?.remainingAt(_now) ?? Duration.zero;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          detail.session.routineId == null ? 'Treino livre' : 'Treino',
        ),
        actions: [
          IconButton(
            tooltip: 'Nota do treino',
            onPressed: () => _note(),
            icon: const Icon(Icons.edit_note),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'cancel') _cancel();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cancel', child: Text('Cancelar treino')),
            ],
          ),
        ],
      ),
      body: detail.exercises.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fitness_center, size: 48),
                    const SizedBox(height: 12),
                    const Text('Adicione o primeiro exercício para começar.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _addExercise,
                      icon: const Icon(Icons.add),
                      label: const Text('Adicionar exercício'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _durationLabel(duration.inSeconds),
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const Text('Duração da sessão'),
                        if (_rest != null && restRemaining > Duration.zero) ...[
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              const Icon(Icons.timer_outlined),
                              const SizedBox(width: 8),
                              Text(
                                'Descanso ${_durationLabel(restRemaining.inSeconds)}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: _rest!.isPaused ? 'Retomar' : 'Pausar',
                                onPressed: _togglePause,
                                icon: Icon(
                                  _rest!.isPaused
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Pular descanso',
                                onPressed: _skipRest,
                                icon: const Icon(Icons.skip_next),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () =>
                                    _adjustRest(const Duration(seconds: -15)),
                                child: const Text('−15 s'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    _adjustRest(const Duration(seconds: 15)),
                                child: const Text('+15 s'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                for (final exercise in detail.exercises)
                  _ExerciseSessionCard(
                    detail: exercise,
                    onAddSet: () => _addSet(exercise),
                    onEditSet: _editSet,
                    onDeleteSet: (set) async {
                      await widget.services.sessions.deleteSet(set.id!);
                      _load();
                    },
                    onNote: () => _note(exerciseId: exercise.exercise.id),
                  ),
                OutlinedButton.icon(
                  onPressed: _addExercise,
                  icon: const Icon(Icons.add),
                  label: const Text('Adicionar exercício'),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _busy ? null : _finish,
          icon: Icon(_busy ? Icons.hourglass_top : Icons.check_circle_outline),
          label: Text(_busy ? 'Salvando treino…' : 'Concluir treino'),
        ),
      ),
    );
  }

  Future<void> _togglePause() async {
    if (_rest?.isPaused == true) {
      await widget.services.sessions.startRestTimer(
        widget.sessionId,
        _rest!.remaining,
      );
      _alerting = false;
    } else {
      await widget.services.sessions.pauseRestTimer(widget.sessionId);
    }
    _load();
  }

  Future<void> _adjustRest(Duration delta) async {
    await widget.services.sessions.adjustRestTimer(widget.sessionId, delta);
    _load();
  }

  Future<void> _skipRest() async {
    await widget.services.sessions.skipRestTimer(widget.sessionId);
    _load();
  }
}

class _ExerciseSessionCard extends StatelessWidget {
  const _ExerciseSessionCard({
    required this.detail,
    required this.onAddSet,
    required this.onEditSet,
    required this.onDeleteSet,
    required this.onNote,
  });
  final WorkoutExerciseDetail detail;
  final VoidCallback onAddSet;
  final ValueChanged<WorkoutSet> onEditSet;
  final ValueChanged<WorkoutSet> onDeleteSet;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  detail.exercise.exerciseName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Nota do exercício',
                onPressed: onNote,
                icon: const Icon(Icons.sticky_note_2_outlined),
              ),
              TextButton(onPressed: onAddSet, child: const Text('+ Série')),
            ],
          ),
          if (detail.exercise.supersetGroup != null)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text('Superset ${detail.exercise.supersetGroup}'),
            ),
          if (detail.exercise.plannedSets != null &&
              detail.exercise.minReps != null &&
              detail.exercise.maxReps != null)
            Text(
              'Meta: ${detail.exercise.plannedSets} séries · '
              '${detail.exercise.minReps}â€“${detail.exercise.maxReps} reps '
              'Â· ${detail.sets.length}/${detail.exercise.plannedSets} registradas',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (detail.exercise.notes?.isNotEmpty == true)
            Text(detail.exercise.notes!),
          if (detail.sets.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Nenhuma série registrada'),
            )
          else ...[
            const Divider(height: 20),
            for (final set in detail.sets)
              InkWell(
                onTap: () => onEditSet(set),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        set.completedAt == null
                            ? Icons.radio_button_unchecked
                            : Icons.check_circle,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${set.position + 1}.  ${set.weightKg} kg × ${set.reps} reps${set.type == WorkoutSetType.working ? '' : ' · ${_setTypeName(set.type)}'}${set.rpe != null ? ' · RPE ${set.rpe}' : ''}${set.rir != null ? ' · RIR ${set.rir}' : ''}',
                        ),
                      ),
                      IconButton(
                        tooltip: 'Excluir série',
                        onPressed: () => onDeleteSet(set),
                        icon: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    ),
  );
}

class _SetDraft {
  const _SetDraft({
    required this.reps,
    required this.weight,
    required this.type,
    required this.completed,
    this.rpe,
    this.rir,
  });
  final int reps;
  final double weight;
  final WorkoutSetType type;
  final bool completed;
  final double? rpe;
  final int? rir;
}

class _SetEditorDialog extends StatefulWidget {
  const _SetEditorDialog({
    this.set,
    this.setNumber,
    this.plannedSets,
    this.minReps,
    this.maxReps,
  });
  final WorkoutSet? set;
  final int? setNumber;
  final int? plannedSets;
  final int? minReps;
  final int? maxReps;
  @override
  State<_SetEditorDialog> createState() => _SetEditorDialogState();
}

class _SetEditorDialogState extends State<_SetEditorDialog> {
  late final TextEditingController _reps;
  late final TextEditingController _weight;
  late final TextEditingController _rpe;
  late final TextEditingController _rir;
  late WorkoutSetType _type;
  late bool _completed;

  @override
  void initState() {
    super.initState();
    _reps = TextEditingController(
      text: '${widget.set?.reps ?? widget.minReps ?? ''}',
    );
    _weight = TextEditingController(
      text: widget.set == null ? '' : '${widget.set!.weightKg}',
    );
    _rpe = TextEditingController(text: widget.set?.rpe?.toString() ?? '');
    _rir = TextEditingController(text: widget.set?.rir?.toString() ?? '');
    _type = widget.set?.type ?? WorkoutSetType.working;
    _completed = widget.set == null || widget.set!.completedAt != null;
  }

  @override
  void dispose() {
    _reps.dispose();
    _weight.dispose();
    _rpe.dispose();
    _rir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.set == null ? 'Registrar série' : 'Editar série'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.plannedSets != null &&
              widget.minReps != null &&
              widget.maxReps != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Meta: ${widget.setNumber ?? 1}/${widget.plannedSets} séries '
                  '· ${widget.minReps}–${widget.maxReps} reps',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _weight,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Carga (kg)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _reps,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Repetições'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<WorkoutSetType>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Tipo de série'),
            items: WorkoutSetType.values
                .map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Text(_setTypeName(type)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _rpe,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'RPE (opcional)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _rir,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'RIR (opcional)',
                  ),
                ),
              ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _completed,
            onChanged: (value) => setState(() => _completed = value ?? false),
            title: const Text('Série concluída'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Voltar'),
      ),
      FilledButton(
        onPressed: () {
          final reps = int.tryParse(_reps.text) ?? -1;
          final weight =
              double.tryParse(_weight.text.replaceAll(',', '.')) ?? -1;
          final rpe = _rpe.text.trim().isEmpty
              ? null
              : double.tryParse(_rpe.text.replaceAll(',', '.'));
          final rir = _rir.text.trim().isEmpty ? null : int.tryParse(_rir.text);
          if (reps < 0 ||
              weight < 0 ||
              (_rpe.text.isNotEmpty && rpe == null) ||
              (_rir.text.isNotEmpty && rir == null) ||
              (rpe != null && rir != null)) {
            return;
          }
          Navigator.pop(
            context,
            _SetDraft(
              reps: reps,
              weight: weight,
              type: _type,
              completed: _completed,
              rpe: rpe,
              rir: rir,
            ),
          );
        },
        child: const Text('Salvar série'),
      ),
    ],
  );
}

class WorkoutSummaryPage extends StatefulWidget {
  const WorkoutSummaryPage({
    super.key,
    required this.services,
    required this.sessionId,
  });
  final WorkoutServices services;
  final int sessionId;

  @override
  State<WorkoutSummaryPage> createState() => _WorkoutSummaryPageState();
}

class _WorkoutSummaryPageState extends State<WorkoutSummaryPage> {
  final _shareKey = GlobalKey();
  WorkoutSessionSummary? summary;
  Map<int, String> _exerciseNames = {};
  @override
  void initState() {
    super.initState();
    Future.wait([
      widget.services.sessions.getSummary(widget.sessionId),
      widget.services.library.listExercises(),
    ]).then((values) {
      if (mounted) {
        setState(() {
          summary = values[0] as WorkoutSessionSummary;
          _exerciseNames = {
            for (final exercise in values[1] as List<ExerciseDefinition>)
              exercise.id!: exercise.name,
          };
        });
      }
    });
  }

  Future<void> _shareSummary(WorkoutSessionSummary value) async {
    try {
      final boundary =
          _shareKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final directory = await Directory.systemTemp.createTemp('appfit-share-');
      final file = File('${directory.path}/treino-${value.session.id}.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      await SharePlus.instance.share(
        ShareParams(
          title: 'Treino App Fit',
          text:
              'Treino concluído no App Fit · ${value.volumeKg.round()} kg de volume',
          files: [XFile(file.path)],
        ),
      );
      if (await file.exists()) await file.delete();
      if (await directory.exists()) await directory.delete();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível compartilhar o card.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = summary;
    return Scaffold(
      appBar: AppBar(title: const Text('Treino concluído')),
      body: value == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                RepaintBoundary(
                  key: _shareKey,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Icon(Icons.check_circle, size: 56),
                          const SizedBox(height: 10),
                          Text(
                            'Bom trabalho.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 20),
                          _MetricStrip(
                            first: '${value.setCount}',
                            firstLabel: 'séries concluídas',
                            second: '${value.volumeKg.round()} kg',
                            secondLabel: 'volume de trabalho',
                          ),
                          const SizedBox(height: 10),
                          _MetricStrip(
                            first: '${value.topLoadKg} kg',
                            firstLabel: 'maior carga',
                            second: _durationLabel(
                              (value.session.completedAt ?? DateTime.now())
                                  .difference(value.session.startedAt)
                                  .inSeconds,
                            ),
                            secondLabel: 'duração',
                          ),
                          const SizedBox(height: 20),
                          if (value.personalRecords.isNotEmpty) ...[
                            Text(
                              'Recordes pessoais',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            for (final record in value.personalRecords)
                              ListTile(
                                leading: const Icon(
                                  Icons.emoji_events_outlined,
                                ),
                                title: Text(
                                  '${_exerciseNames[record.exerciseId] ?? 'Exercício'} · ${record.recordType == 'top_load' ? 'maior carga' : '1RM estimado'}',
                                ),
                                subtitle: Text(
                                  '${record.value.toStringAsFixed(1)} kg',
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _shareSummary(value),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Compartilhar card'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
                  child: const Text('Voltar aos treinos'),
                ),
              ],
            ),
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({
    required this.first,
    required this.firstLabel,
    required this.second,
    required this.secondLabel,
  });
  final String first, firstLabel, second, secondLabel;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _MetricCard(value: first, label: firstLabel),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _MetricCard(value: second, label: secondLabel),
      ),
    ],
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

String _weekdayName(int day) =>
    const ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'][day - 1];
String _durationLabel(int seconds) {
  final clamped = seconds < 0 ? 0 : seconds;
  final hours = clamped ~/ 3600;
  final minutes = (clamped % 3600) ~/ 60;
  final rest = clamped % 60;
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  return '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

String _setTypeName(WorkoutSetType type) => switch (type) {
  WorkoutSetType.working => 'Trabalho',
  WorkoutSetType.warmup => 'Aquecimento',
  WorkoutSetType.drop => 'Drop set',
  WorkoutSetType.failure => 'Falha',
  WorkoutSetType.restPause => 'Rest-pause',
};
