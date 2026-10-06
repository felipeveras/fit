import 'dart:math' as math;

enum HabitType { positive, avoid, quantitative }

enum HabitCadence { daily, weeklyTarget, monthlyTarget, specificDays, everyNDays }

enum HabitAutomation { manual, workout, healthConnectExercise, healthConnectRun, healthConnectSteps }

DateTime habitDay(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

int _civilDayNumber(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day).millisecondsSinceEpoch ~/ 86400000;

String habitDateKey(DateTime value) {
  final day = habitDay(value);
  return '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
}

DateTime parseHabitDay(String value) {
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

class HabitSchedule {
  HabitSchedule({
    this.cadence = HabitCadence.daily,
    this.targetCount = 1,
    this.weekdays = const {},
    this.intervalDays = 1,
    required DateTime startDate,
  }) : startDate = habitDay(startDate) {
    if (targetCount < 1 || intervalDays < 1) throw ArgumentError('Meta e intervalo devem ser positivos.');
    if (cadence == HabitCadence.specificDays && weekdays.isEmpty) {
      throw ArgumentError('Selecione ao menos um dia da semana.');
    }
  }

  final HabitCadence cadence;
  final int targetCount;
  final Set<int> weekdays; // DateTime weekday: Monday=1 … Sunday=7.
  final int intervalDays;
  final DateTime startDate;

  bool isScheduled(DateTime value) {
    final day = habitDay(value);
    if (day.isBefore(startDate)) return false;
    return switch (cadence) {
      HabitCadence.daily || HabitCadence.weeklyTarget || HabitCadence.monthlyTarget => true,
      HabitCadence.specificDays => weekdays.contains(day.weekday),
      HabitCadence.everyNDays => (_civilDayNumber(day) - _civilDayNumber(startDate)) % intervalDays == 0,
    };
  }

  Map<String, Object?> toColumns() => {
    'cadence': cadence.name,
    'target_count': targetCount,
    'weekdays': weekdays.toList()..sort(),
    'interval_days': intervalDays,
    'start_date': habitDateKey(startDate),
  };

  factory HabitSchedule.fromRow(Map<String, Object?> row) => HabitSchedule(
    cadence: HabitCadence.values.byName(row['cadence']! as String),
    targetCount: row['target_count']! as int,
    weekdays: ((row['weekdays'] as String?) ?? '').split(',').where((v) => v.isNotEmpty).map(int.parse).toSet(),
    intervalDays: row['interval_days']! as int,
    startDate: parseHabitDay(row['start_date']! as String),
  );
}

class Habit {
  Habit({
    required this.id,
    required this.name,
    required this.type,
    required this.schedule,
    this.quantityTarget,
    this.quantityUnit,
    this.dailyTargetCount = 1,
    this.archivedAt,
    this.category = 'Geral',
    this.emoji = '✦',
    this.color = 0xFF22618B,
    this.position = 0,
    this.automation = HabitAutomation.manual,
    this.exerciseTypes = const {},
    this.reminderEnabled = false,
    this.reminderHour,
    this.reminderMinute,
    this.createdAt,
  }) {
    if (name.trim().isEmpty) throw ArgumentError('Dê um nome ao hábito.');
    if (dailyTargetCount < 1) throw ArgumentError('A meta diária deve ser positiva.');
    if (type == HabitType.quantitative &&
        (!(quantityTarget ?? 0).isFinite || quantityTarget! <= 0 || (quantityUnit?.trim().isEmpty ?? true))) {
      throw ArgumentError('Informe uma meta e uma unidade válidas.');
    }
    if (reminderEnabled && (reminderHour == null || reminderMinute == null)) {
      throw ArgumentError('Informe o horário do lembrete.');
    }
    if ((automation == HabitAutomation.workout || automation == HabitAutomation.healthConnectExercise || automation == HabitAutomation.healthConnectRun) && type != HabitType.positive) {
      throw ArgumentError('Automação de treino só pode concluir hábitos positivos.');
    }
    if (automation == HabitAutomation.healthConnectSteps &&
        (type != HabitType.quantitative || quantityUnit?.toLowerCase() != 'passos')) {
      throw ArgumentError('Automação de passos exige um hábito quantitativo em passos.');
    }
  }

  final String id, name, category, emoji;
  final HabitType type;
  final HabitSchedule schedule;
  final double? quantityTarget;
  final String? quantityUnit;
  final int dailyTargetCount, color, position;
  final DateTime? archivedAt, createdAt;
  final HabitAutomation automation;
  final Set<int> exerciseTypes;
  final bool reminderEnabled;
  final int? reminderHour, reminderMinute;

  Map<String, Object?> toRow() => {
    'id': id, 'name': name.trim(), 'type': type.name, ...schedule.toColumns(),
    'quantity_target': quantityTarget, 'quantity_unit': quantityUnit,
    'daily_target_count': dailyTargetCount,
    'archived_at': archivedAt == null ? null : habitDateKey(archivedAt!),
    'category': category, 'emoji': emoji, 'color': color, 'position': position,
    'automation': automation.name,
    'exercise_types': exerciseTypes.toList()..sort(),
    'reminder_enabled': reminderEnabled ? 1 : 0,
    'reminder_hour': reminderHour, 'reminder_minute': reminderMinute,
    'created_at': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
  };

  factory Habit.fromRow(Map<String, Object?> row) => Habit(
    id: row['id']! as String, name: row['name']! as String,
    type: HabitType.values.byName(row['type']! as String),
    schedule: HabitSchedule.fromRow(row),
    quantityTarget: (row['quantity_target'] as num?)?.toDouble(),
    quantityUnit: row['quantity_unit'] as String?,
    dailyTargetCount: (row['daily_target_count'] as int?) ?? 1,
    archivedAt: row['archived_at'] == null ? null : parseHabitDay(row['archived_at']! as String),
    category: row['category']! as String, emoji: row['emoji']! as String,
    color: row['color']! as int, position: row['position']! as int,
    automation: HabitAutomation.values.byName(row['automation']! as String),
    exerciseTypes: ((row['exercise_types'] as String?) ?? '').split(',').where((v) => v.isNotEmpty).map(int.parse).toSet(),
    reminderEnabled: (row['reminder_enabled'] as int? ?? 0) == 1,
    reminderHour: row['reminder_hour'] as int?, reminderMinute: row['reminder_minute'] as int?,
    createdAt: DateTime.tryParse(row['created_at']! as String),
  );
}

class HabitCompletion {
  const HabitCompletion({required this.id, required this.habitId, required this.date, required this.occurredAt, this.note, this.sourceEventId, this.behavioralMomentId, this.source = 'MANUAL'});
  final String id, habitId, source;
  final DateTime date, occurredAt;
  final String? note, sourceEventId, behavioralMomentId;
}

class HabitNote {
  const HabitNote({required this.id, required this.habitId, required this.date, required this.text, this.photoUri, required this.createdAt});
  final String id, habitId, text;
  final DateTime date, createdAt;
  final String? photoUri;
}

class HabitVacation {
  const HabitVacation({required this.id, required this.habitId, required this.startDate, required this.endDate, this.label = 'Pausa'});
  final String id, habitId, label;
  final DateTime startDate, endDate;
  bool contains(DateTime date) => !habitDay(date).isBefore(startDate) && !habitDay(date).isAfter(endDate);
}

class HabitDayRecord {
  const HabitDayRecord({this.completions = 0, this.quantity = 0, this.quantityEntries = 0, this.restDay = false, this.vacation = false, this.covered = true});
  final int completions, quantityEntries;
  final double quantity;
  final bool restDay, vacation, covered;
}

class HabitStats {
  const HabitStats({required this.completedOpportunities, required this.scheduledOpportunities, required this.adherence, required this.totalCompletions, required this.currentStreak, required this.bestStreak, required this.monthlyCompletionCounts, required this.yearlyCompletionCounts, required this.timeBuckets});
  final int completedOpportunities, scheduledOpportunities, totalCompletions, currentStreak, bestStreak;
  final double adherence;
  final Map<String, int> monthlyCompletionCounts, yearlyCompletionCounts, timeBuckets;
  String get summary => '$completedOpportunities/$scheduledOpportunities oportunidades • ${(adherence * 100).round()}% de aderência • sequência atual $currentStreak, melhor $bestStreak';
}

HabitStats calculateHabitStats({required Habit habit, required Map<DateTime, HabitDayRecord> history, required DateTime from, required DateTime through, required Set<DateTime> vacationDays, required Set<DateTime> restDays, required Map<DateTime, List<int>> completionMinutes}) {
  final start = habitDay(from).isBefore(habit.schedule.startDate) ? habit.schedule.startDate : habitDay(from);
  final end = habit.archivedAt != null && habit.archivedAt!.isBefore(habitDay(through)) ? habitDay(habit.archivedAt!) : habitDay(through);
  if (end.isBefore(start)) return const HabitStats(completedOpportunities: 0, scheduledOpportunities: 0, adherence: 0, totalCompletions: 0, currentStreak: 0, bestStreak: 0, monthlyCompletionCounts: {}, yearlyCompletionCounts: {}, timeBuckets: {});
  HabitDayRecord recordFor(DateTime day) => history[day] ?? HabitDayRecord(covered: habit.automation != HabitAutomation.healthConnectSteps);
  final byDate = <DateTime, int>{};
  final byDateQuantity = <DateTime, double>{};
  var total = 0;
  for (var day = start; !day.isAfter(end); day = day.add(const Duration(days: 1))) {
    final record = recordFor(day);
    total += habit.type == HabitType.quantitative ? record.quantityEntries : record.completions;
    if (!record.covered) continue; // Missing Health Connect coverage is never a zero.
    final blocked = vacationDays.contains(day) || restDays.contains(day);
    if (blocked || !habit.schedule.isScheduled(day)) continue;
    byDate[day] = record.completions;
    byDateQuantity[day] = record.quantity;
  }
  var completed = 0;
  var scheduled = 0;
  var currentStreak = 0;
  var bestStreak = 0;
  var running = 0;
  if (habit.schedule.cadence == HabitCadence.weeklyTarget || habit.schedule.cadence == HabitCadence.monthlyTarget) {
    DateTime periodStart(DateTime d) => habit.schedule.cadence == HabitCadence.weeklyTarget
      ? habitDay(d).subtract(Duration(days: d.weekday - DateTime.monday))
      : DateTime(d.year, d.month);
    DateTime periodEnd(DateTime d) => habit.schedule.cadence == HabitCadence.weeklyTarget
      ? periodStart(d).add(const Duration(days: 6))
      : DateTime(d.year, d.month + 1, 0);
    var cursor = periodStart(start);
    final lastPeriod = periodStart(end);
    final periods = <({DateTime start, DateTime end, int count, int target})>[];
    while (!cursor.isAfter(lastPeriod)) {
      final pEnd = periodEnd(cursor);
      final effectiveStart = cursor.isBefore(start) ? start : cursor;
      final effectiveEnd = pEnd.isAfter(end) ? end : pEnd;
      final coveredDays = <DateTime>[];
      for (var day = effectiveStart; !day.isAfter(effectiveEnd); day = day.add(const Duration(days: 1))) {
        final record = recordFor(day);
        if (record.covered && !vacationDays.contains(day) && !restDays.contains(day)) coveredDays.add(day);
      }
      if (coveredDays.isNotEmpty) {
        final fullDays = _civilDayNumber(pEnd) - _civilDayNumber(cursor) + 1;
        var plannedActiveDays = 0;
        final plannedStart = cursor.isBefore(habit.schedule.startDate) ? habit.schedule.startDate : cursor;
        for (var day = plannedStart; !day.isAfter(pEnd); day = day.add(const Duration(days: 1))) {
          if (!vacationDays.contains(day) && !restDays.contains(day)) plannedActiveDays++;
        }
        final measurableDays = habit.automation == HabitAutomation.healthConnectSteps ? coveredDays.length : plannedActiveDays;
        final target = measurableDays == 0 ? 0 : math.max(1, math.min(habit.schedule.targetCount, (habit.schedule.targetCount * measurableDays / fullDays).ceil()));
        final count = coveredDays.fold<int>(0, (sum, d) => sum + (habit.type == HabitType.quantitative ? ((byDateQuantity[d] ?? 0) >= (habit.quantityTarget ?? double.infinity) ? 1 : 0) : (habit.type == HabitType.avoid ? ((byDate[d] ?? 0) == 0 ? 1 : 0) : (byDate[d] ?? 0))));
        final effectiveTarget = target.toInt();
        periods.add((start: cursor, end: pEnd, count: count.clamp(0, effectiveTarget).toInt(), target: effectiveTarget));
        scheduled += effectiveTarget;
        completed += count.clamp(0, effectiveTarget).toInt();
      }
      cursor = pEnd.add(const Duration(days: 1));
    }
    for (final period in periods) {
      final ok = period.count >= period.target;
      // An unfinished current week/month does not erase the prior streak until its
      // target period closes. If it already meets the target, it extends the streak.
      if (ok) {
        running++;
      } else if (!period.end.isAfter(end)) {
        running = 0;
      }
      bestStreak = math.max(bestStreak, running).toInt();
    }
    currentStreak = running;
  } else {
    final days = byDate.keys.toList()..sort();
    for (final day in days) {
      final record = recordFor(day);
      final count = switch (habit.type) {
        HabitType.positive => math.min(record.completions, habit.dailyTargetCount).toInt(),
        HabitType.avoid => record.completions == 0 ? 1 : 0,
        HabitType.quantitative => record.quantity >= (habit.quantityTarget ?? double.infinity) ? 1 : 0,
      };
      final target = habit.type == HabitType.positive ? habit.dailyTargetCount : 1;
      scheduled += target;
      completed += count;
      final ok = count >= target;
      running = ok ? running + 1 : 0;
      bestStreak = math.max(bestStreak, running).toInt();
    }
    currentStreak = running;
  }
  final months = <String, int>{};
  final years = <String, int>{};
  final times = {'Manhã': 0, 'Tarde': 0, 'Noite': 0};
  for (final entry in history.entries) {
    if (entry.key.isBefore(start) || entry.key.isAfter(end)) continue;
    final records = habit.type == HabitType.quantitative ? entry.value.quantityEntries : entry.value.completions;
    months['${entry.key.year}-${entry.key.month.toString().padLeft(2, '0')}'] = (months['${entry.key.year}-${entry.key.month.toString().padLeft(2, '0')}'] ?? 0) + records;
    years['${entry.key.year}'] = (years['${entry.key.year}'] ?? 0) + records;
    for (final minute in completionMinutes[entry.key] ?? const <int>[]) {
      final bucket = minute < 12 * 60 ? 'Manhã' : minute < 18 * 60 ? 'Tarde' : 'Noite';
      times[bucket] = (times[bucket] ?? 0) + 1;
    }
  }
  return HabitStats(completedOpportunities: completed, scheduledOpportunities: scheduled, adherence: scheduled == 0 ? 0 : completed / scheduled, totalCompletions: total, currentStreak: currentStreak, bestStreak: bestStreak, monthlyCompletionCounts: months, yearlyCompletionCounts: years, timeBuckets: times);
}

class HabitSummaryItem {
  const HabitSummaryItem({required this.habitId, required this.name, required this.type, required this.adherence, required this.currentStreak, required this.completedOpportunities, required this.scheduledOpportunities, required this.recentChange});
  final String habitId, name;
  final HabitType type;
  final double adherence;
  final int currentStreak, completedOpportunities, scheduledOpportunities;
  final int recentChange;
  Map<String, Object?> toPublicMap() => {'habitId': habitId, 'name': name, 'type': type.name, 'adherence': adherence, 'currentStreak': currentStreak, 'completedOpportunities': completedOpportunities, 'scheduledOpportunities': scheduledOpportunities, 'recentChange': recentChange};
}

class WorkoutCompletionEvent {
  const WorkoutCompletionEvent({required this.eventId, required this.sessionId, required this.occurredAt, this.exerciseType, this.label, this.source = 'workout', this.isRunning = false});
  final String eventId, sessionId;
  final DateTime occurredAt;
  final int? exerciseType;
  final String? label;
  final String source; // 'workout' or 'health_connect_exercise'.
  final bool isRunning;
}

abstract interface class ExerciseHabitEventSource {
  Stream<WorkoutCompletionEvent> get completedSessions;
}
