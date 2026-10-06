import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'workout_models.dart';
import 'workout_history_page.dart';
import 'workout_services.dart';
import 'workout_session_repository.dart';

class WorkoutProgressPage extends StatefulWidget {
  const WorkoutProgressPage({super.key, required this.services});
  final WorkoutServices services;

  @override
  State<WorkoutProgressPage> createState() => _WorkoutProgressPageState();
}

class _WorkoutProgressPageState extends State<WorkoutProgressPage> {
  WorkoutHistorySummary? _overview;
  Map<DateTime, int> _heatmap = {};
  List<PersonalRecord> _records = [];
  List<ExerciseDefinition> _exercises = [];
  List<BodyMeasurement> _measurements = [];
  List<ProgressPhoto> _photos = [];
  int? _selectedExerciseId;
  List<ExerciseHistoryPoint> _exerciseHistory = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        widget.services.progress.getOverview(),
        widget.services.progress.getHeatmap(days: 365),
        widget.services.sessions.listPersonalRecords(),
        widget.services.library.listExercises(),
        widget.services.progress.listBodyMeasurements(),
        widget.services.progress.listProgressPhotos(),
      ]);
      final exercises = values[3] as List<ExerciseDefinition>;
      final selected =
          _selectedExerciseId ??
          (exercises.isEmpty ? null : exercises.first.id);
      final history = selected == null
          ? <ExerciseHistoryPoint>[]
          : await widget.services.progress.getExerciseHistory(selected);
      if (!mounted) return;
      setState(() {
        _overview = values[0] as WorkoutHistorySummary;
        _heatmap = values[1] as Map<DateTime, int>;
        _records = values[2] as List<PersonalRecord>;
        _exercises = exercises;
        _measurements = values[4] as List<BodyMeasurement>;
        _photos = values[5] as List<ProgressPhoto>;
        _selectedExerciseId = selected;
        _exerciseHistory = history;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectExercise(int? id) async {
    if (id == null) return;
    final history = await widget.services.progress.getExerciseHistory(id);
    if (mounted) {
      setState(() {
        _selectedExerciseId = id;
        _exerciseHistory = history;
      });
    }
  }

  Future<void> _setGoal() async {
    final controller = TextEditingController(
      text: '${_overview?.weeklyGoal ?? 3}',
    );
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Meta semanal'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Treinos por semana (1–14)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final result = int.tryParse(controller.text);
              if (result != null && result >= 1 && result <= 14) {
                Navigator.pop(context, result);
              }
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      await widget.services.progress.setWeeklyGoal(value);
      _load();
    }
  }

  Future<void> _addMeasurement() async {
    final weight = TextEditingController();
    final fat = TextEditingController();
    final waist = TextEditingController();
    final hip = TextEditingController();
    final chest = TextEditingController();
    final arm = TextEditingController();
    final leg = TextEditingController();
    final notes = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Medidas corporais'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _decimalField(weight, 'Peso (kg)'),
              _decimalField(fat, 'Gordura corporal (%)'),
              _decimalField(waist, 'Cintura (cm)'),
              _decimalField(hip, 'Quadril (cm)'),
              _decimalField(chest, 'Peito (cm)'),
              _decimalField(arm, 'Braço (cm)'),
              _decimalField(leg, 'Coxa (cm)'),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Nota (opcional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (saved == true) {
      double? parse(TextEditingController controller) =>
          controller.text.trim().isEmpty
          ? null
          : double.tryParse(controller.text.replaceAll(',', '.'));
      final measures = <String, double>{
        if (parse(waist) != null) 'waist': parse(waist)!,
        if (parse(hip) != null) 'hip': parse(hip)!,
        if (parse(chest) != null) 'chest': parse(chest)!,
        if (parse(arm) != null) 'arm': parse(arm)!,
        if (parse(leg) != null) 'leg': parse(leg)!,
      };
      try {
        await widget.services.progress.saveBodyMeasurement(
          BodyMeasurement(
            measuredAt: DateTime.now(),
            weightKg: parse(weight),
            bodyFatPercent: parse(fat),
            measurementsCm: measures,
            notes: notes.text,
          ),
        );
        _load();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }
    for (final controller in [
      weight,
      fat,
      waist,
      hip,
      chest,
      arm,
      leg,
      notes,
    ]) {
      controller.dispose();
    }
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final image = await ImagePicker().pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 1800,
      );
      if (image == null) return;
      if (!mounted) return;
      final notes = TextEditingController();
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Foto de progresso'),
          content: TextField(
            controller: notes,
            decoration: const InputDecoration(labelText: 'Nota (opcional)'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Salvar foto'),
            ),
          ],
        ),
      );
      if (save == true) {
        await widget.services.progress.importProgressPhoto(
          image.path,
          notes: notes.text,
        );
      }
      notes.dispose();
      _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível abrir ou salvar a foto.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final overview = _overview;
    if (overview == null) {
      return const Center(
        child: Text('Não foi possível carregar o progresso.'),
      );
    }
    final selected = _exercises
        .where((e) => e.id == _selectedExerciseId)
        .firstOrNull;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Progresso',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WorkoutHistoryPage(services: widget.services),
                  ),
                ),
                child: const Text('Histórico'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ProgressMetric(
                  value: '${overview.sessions}',
                  label: 'treinos',
                ),
              ),
              Expanded(
                child: _ProgressMetric(
                  value: '${overview.completedSets}',
                  label: 'séries',
                ),
              ),
              Expanded(
                child: _ProgressMetric(
                  value: '${overview.volumeKg.round()}',
                  label: 'kg volume',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Meta semanal',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Editar meta',
                        onPressed: _setGoal,
                        icon: const Icon(Icons.tune),
                      ),
                    ],
                  ),
                  Text(
                    '${overview.frequency} de ${overview.weeklyGoal} treinos',
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: (overview.frequency / overview.weeklyGoal).clamp(
                      0.0,
                      1.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${overview.currentStreak} dias de sequência · ${overview.trainedDays} dias treinados no total',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Heatmap(heatmap: _heatmap),
          if (_records.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'Recordes pessoais',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final record in _records)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.emoji_events_outlined),
                title: Text(
                  '${_exerciseName(record.exerciseId)} · ${record.recordType == 'top_load' ? 'maior carga' : '1RM estimado'}',
                ),
                subtitle: Text(
                  '${record.value.toStringAsFixed(1)} kg · ${DateFormat('dd/MM/yyyy').format(record.achievedAt)}',
                ),
                onTap: () => _selectExercise(record.exerciseId),
              ),
          ],
          const SizedBox(height: 18),
          Text(
            'Evolução por exercício',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (_exercises.isEmpty)
            const Text('Conclua treinos para ver sua curva de força.')
          else ...[
            DropdownButtonFormField<int>(
              initialValue: _selectedExerciseId,
              decoration: const InputDecoration(labelText: 'Exercício'),
              items: _exercises
                  .map(
                    (e) => DropdownMenuItem(
                      value: e.id,
                      child: Text(e.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: _selectExercise,
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _exerciseHistory.isEmpty
                    ? const SizedBox(
                        height: 90,
                        child: Center(
                          child: Text(
                            'Ainda faltam treinos concluídos para desenhar a curva.',
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_exerciseHistory.length} sessões · ${selected?.name ?? ''}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 150,
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: _StrengthChartPainter(
                                _exerciseHistory,
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Linha: 1RM estimado · a carga usa séries concluídas, sem aquecimento.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Medidas corporais',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Adicionar medida',
                onPressed: _addMeasurement,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          if (_measurements.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Registre peso, percentual de gordura ou medidas para acompanhar tendências.',
                ),
              ),
            )
          else ...[
            _BodyWeightChart(measurements: _measurements),
            for (final measurement in _measurements.take(8))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.monitor_weight_outlined),
                title: Text(
                  DateFormat('dd/MM/yyyy').format(measurement.measuredAt),
                ),
                subtitle: Text(
                  [
                    if (measurement.weightKg != null)
                      '${measurement.weightKg} kg',
                    if (measurement.bodyFatPercent != null)
                      '${measurement.bodyFatPercent}% gordura',
                    for (final entry in measurement.measurementsCm.entries)
                      '${_measureName(entry.key)} ${entry.value} cm',
                  ].join(' · '),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Fotos de progresso',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              PopupMenuButton<ImageSource>(
                tooltip: 'Adicionar foto',
                onSelected: _addPhoto,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: ImageSource.camera,
                    child: Text('Tirar foto'),
                  ),
                  PopupMenuItem(
                    value: ImageSource.gallery,
                    child: Text('Escolher da galeria'),
                  ),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.add_a_photo_outlined),
                ),
              ),
            ],
          ),
          if (_photos.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Fotos opcionais são guardadas somente neste aparelho.',
                ),
              ),
            )
          else
            SizedBox(
              height: 170,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final photo in _photos)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(photo.localPath),
                              width: 130,
                              height: 170,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 130,
                                height: 170,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: const Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 6,
                            right: 6,
                            bottom: 6,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Text(
                                  DateFormat('dd/MM/yy')
                                      .format(photo.capturedAt),
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: IconButton.filledTonal(
                              onPressed: () async {
                                await widget.services.progress
                                    .deleteProgressPhoto(photo.id!);
                                _load();
                              },
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text(
            'Volume por grupo muscular',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (overview.muscleVolumes.isEmpty)
            const Text('O volume aparece depois do primeiro treino concluído.')
          else
            for (final entry
                in overview.muscleVolumes.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value)))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(_muscleName(entry.key))),
                    SizedBox(
                      width: 130,
                      child: LinearProgressIndicator(
                        value:
                            entry.value /
                            overview.muscleVolumes.values.reduce(
                              (a, b) => a > b ? a : b,
                            ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${entry.value.round()} kg'),
                  ],
                ),
              ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  String _exerciseName(int id) =>
      _exercises.where((e) => e.id == id).firstOrNull?.name ?? 'Exercício';
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.heatmap});
  final Map<DateTime, int> heatmap;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final start = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 364));
    final monday = start.subtract(Duration(days: start.weekday - 1));
    const cellSize = 9.0;
    final colors = Theme.of(context).colorScheme;
    Color color(int count) => count == 0
        ? colors.surfaceContainerHighest
        : Color.lerp(
            colors.surfaceContainerHighest,
            colors.primary,
            (count / 3).clamp(0.35, 1.0),
          )!;
    final weeks = <Widget>[];
    for (var week = 0; week < 53; week++) {
      weeks.add(
        Column(
          children: [
            for (var day = 0; day < 7; day++)
              Builder(
                builder: (context) {
                  final date = monday.add(Duration(days: week * 7 + day));
                  final count =
                      heatmap[DateTime(date.year, date.month, date.day)] ?? 0;
                  final inPeriod =
                      !date.isBefore(start) && !date.isAfter(today);
                  return Padding(
                    padding: const EdgeInsets.all(1.2),
                    child: Tooltip(
                      message:
                          '$count treino(s) · ${DateFormat('dd/MM/yyyy').format(date)}',
                      child: Semantics(
                        label:
                            '$count treinos em ${DateFormat('dd/MM/yyyy').format(date)}',
                        child: Container(
                          width: cellSize,
                          height: cellSize,
                          decoration: BoxDecoration(
                            color: inPeriod ? color(count) : Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calendário de atividade',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: weeks),
            ),
            const SizedBox(height: 6),
            const Text(
              'Cada quadrado representa um dia nos últimos 12 meses.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrengthChartPainter extends CustomPainter {
  _StrengthChartPainter(this.points, this.color);
  final List<ExerciseHistoryPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final values = points.map((p) => p.estimatedOneRepMaxKg).toList();
    final minValue = values.reduce((a, b) => a < b ? a : b);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final range = maxValue - minValue;
    final padding = const EdgeInsets.fromLTRB(8, 10, 8, 20);
    final width = size.width - padding.horizontal;
    final height = size.height - padding.vertical;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x =
          padding.left +
          (points.length == 1 ? width / 2 : width * i / (points.length - 1));
      final norm = range == 0 ? 0.5 : (values[i] - minValue) / range;
      final y = padding.top + height * (1 - norm);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < points.length; i++) {
      final x =
          padding.left +
          (points.length == 1 ? width / 2 : width * i / (points.length - 1));
      final norm = range == 0 ? 0.5 : (values[i] - minValue) / range;
      final y = padding.top + height * (1 - norm);
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = color);
    }
    final text = TextPainter(
      text: TextSpan(
        text:
            '${minValue.toStringAsFixed(0)}–${maxValue.toStringAsFixed(0)} kg',
        style: TextStyle(color: color, fontSize: 11),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(4, size.height - text.height));
  }

  @override
  bool shouldRepaint(covariant _StrengthChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _BodyWeightChart extends StatelessWidget {
  const _BodyWeightChart({required this.measurements});
  final List<BodyMeasurement> measurements;
  @override
  Widget build(BuildContext context) {
    final points = measurements
        .where((m) => m.weightKg != null)
        .toList()
        .reversed
        .toList();
    if (points.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Peso corporal',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: CustomPaint(
                size: Size.infinite,
                painter: _SimpleValuePainter(
                  points.map((e) => e.weightKg!).toList(),
                  Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
            Text(
              '${points.first.weightKg} kg → ${points.last.weightKg} kg',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SimpleValuePainter extends CustomPainter {
  _SimpleValuePainter(this.values, this.color);
  final List<double> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final range = max - min;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : size.width * i / (values.length - 1);
      final y =
          8 +
          (size.height - 16) *
              (range == 0 ? 0.5 : 1 - (values[i] - min) / range);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _SimpleValuePainter oldDelegate) =>
      oldDelegate.values != values;
}

class WorkoutToolsPage extends StatefulWidget {
  const WorkoutToolsPage({super.key, required this.services});
  final WorkoutServices services;
  @override
  State<WorkoutToolsPage> createState() => _WorkoutToolsPageState();
}

class _WorkoutToolsPageState extends State<WorkoutToolsPage> {
  final _weight = TextEditingController();
  final _reps = TextEditingController(text: '5');
  final _target = TextEditingController();
  final _bar = TextEditingController(text: '20');
  final _height = TextEditingController();
  double? _oneRepMax;
  double? _bmi;
  List<double> _plates = [];
  static const _availablePlates = [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25];

  @override
  void dispose() {
    _weight.dispose();
    _reps.dispose();
    _target.dispose();
    _bar.dispose();
    _height.dispose();
    super.dispose();
  }

  void _calculateOneRepMax() {
    final weight = double.tryParse(_weight.text.replaceAll(',', '.'));
    final reps = int.tryParse(_reps.text);
    if (weight == null ||
        weight <= 0 ||
        reps == null ||
        reps < 1 ||
        reps > 12) {
      return;
    }
    setState(
      () =>
          _oneRepMax = WorkoutSessionRepository.estimateOneRepMax(weight, reps),
    );
  }

  void _calculatePlates() {
    final target = double.tryParse(_target.text.replaceAll(',', '.'));
    final bar = double.tryParse(_bar.text.replaceAll(',', '.'));
    if (target == null || bar == null || target < bar || bar <= 0) {
      setState(() => _plates = []);
      return;
    }
    var remaining = (target - bar) / 2;
    final result = <double>[];
    for (final plate in _availablePlates) {
      while (remaining + 0.0001 >= plate) {
        result.add(plate);
        remaining -= plate;
      }
    }
    setState(() => _plates = result);
  }

  void _calculateBmi() {
    final height = double.tryParse(_height.text.replaceAll(',', '.'));
    widget.services.progress.listBodyMeasurements().then((items) {
      final weight = items.firstOrNull?.weightKg;
      if (!mounted || height == null || height <= 0 || weight == null) return;
      setState(() => _bmi = weight / (height * height));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ferramentas de treino')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Cálculos rápidos',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1RM estimado',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Estimativa de Epley; use séries de até 12 repetições.',
                ),
                Row(
                  children: [
                    Expanded(child: _decimalField(_weight, 'Carga (kg)')),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _decimalField(_reps, 'Reps', integer: true),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _calculateOneRepMax,
                  child: const Text('Calcular 1RM'),
                ),
                if (_oneRepMax != null)
                  Text(
                    '1RM estimado: ${_oneRepMax!.toStringAsFixed(1)} kg',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Anilhas por lado',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _decimalField(_target, 'Carga total (kg)')),
                    const SizedBox(width: 12),
                    Expanded(child: _decimalField(_bar, 'Barra (kg)')),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _calculatePlates,
                  child: const Text('Calcular anilhas'),
                ),
                if (_plates.isNotEmpty)
                  Text('Cada lado: ${_plates.map((p) => '$p kg').join(' + ')}'),
                if (_target.text.isNotEmpty && _plates.isEmpty)
                  const Text(
                    'Confira se a carga é compatível com a barra e as anilhas disponíveis.',
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IMC corporal',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Usa a medida de peso mais recente salva no progresso.',
                ),
                _decimalField(_height, 'Altura (m)'),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _calculateBmi,
                  child: const Text('Calcular IMC'),
                ),
                if (_bmi != null) Text('IMC: ${_bmi!.toStringAsFixed(1)}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'As estimativas são referências de treino, não avaliações clínicas.',
        ),
      ],
    ),
  );
}

Widget _decimalField(
  TextEditingController controller,
  String label, {
  bool integer = false,
}) => TextField(
  controller: controller,
  keyboardType: integer
      ? TextInputType.number
      : const TextInputType.numberWithOptions(decimal: true),
  decoration: InputDecoration(labelText: label),
);

class _ProgressMetric extends StatelessWidget {
  const _ProgressMetric({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(value, style: Theme.of(context).textTheme.titleLarge),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

String _muscleName(String value) =>
    const {
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
    }[value] ??
    value;
String _measureName(String value) =>
    const {
      'waist': 'Cintura',
      'hip': 'Quadril',
      'chest': 'Peito',
      'arm': 'Braço',
      'leg': 'Coxa',
    }[value] ??
    value;
