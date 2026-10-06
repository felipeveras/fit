import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/health/health_repository.dart';
import '../../core/health/health_exercise_repository.dart';
import '../../core/persistence/app_database.dart';
import 'habit_models.dart';

class HabitProgress {
  const HabitProgress({required this.habit, required this.stats, required this.history, required this.substeps, required this.checkedSubsteps, required this.notes, required this.vacations, required this.restDays, required this.completionMinutes, this.snoozedUntil});
  final Habit habit;
  final HabitStats stats;
  final Map<DateTime, HabitDayRecord> history;
  final List<({String id, String title})> substeps;
  final Set<String> checkedSubsteps;
  final List<HabitNote> notes;
  final List<HabitVacation> vacations;
  final Set<DateTime> restDays;
  final Map<DateTime, List<int>> completionMinutes;
  final DateTime? snoozedUntil;
}

class HabitRepository {
  HabitRepository(this.database);
  final AppDatabase database;
  Future<Database> get _db => database.open();

  Future<List<Habit>> list({bool archived = false}) async {
    final rows = await (await _db).query('habits', where: archived ? 'archived_at IS NOT NULL' : 'archived_at IS NULL', orderBy: 'position, name COLLATE NOCASE');
    return rows.map(Habit.fromRow).toList(growable: false);
  }

  Future<void> saveHabit(Habit habit, {List<String> substeps = const []}) async {
    final db = await _db;
    final row = habit.toRow()
      ..['weekdays'] = (habit.schedule.weekdays.toList()..sort()).join(',')
      ..['exercise_types'] = (habit.exerciseTypes.toList()..sort()).join(',');
    await db.transaction((tx) async {
      final existingHabit = await tx.query('habits', columns: ['id'], where: 'id=?', whereArgs: [habit.id], limit: 1);
      if (existingHabit.isEmpty) {
        await tx.insert('habits', row);
      } else {
        await tx.update('habits', row, where: 'id=?', whereArgs: [habit.id]);
      }
      final oldSteps = await tx.query('habit_substeps', where: 'habit_id=?', whereArgs: [habit.id], orderBy: 'position');
      final titles = substeps.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      for (var i = 0; i < titles.length; i++) {
        if (i < oldSteps.length) {
          await tx.update('habit_substeps', {'title': titles[i], 'position': i}, where: 'id=?', whereArgs: [oldSteps[i]['id']]);
        } else {
          await tx.insert('habit_substeps', {'id': '${habit.id}:substep:${DateTime.now().microsecondsSinceEpoch}:$i', 'habit_id': habit.id, 'title': titles[i], 'position': i});
        }
      }
      for (final removed in oldSteps.skip(titles.length)) {
        await tx.delete('habit_substeps', where: 'id=?', whereArgs: [removed['id']]);
      }
      await tx.insert('habit_reminders', {
        'habit_id': habit.id,
        'enabled': habit.reminderEnabled ? 1 : 0,
        'local_hour': habit.reminderHour,
        'local_minute': habit.reminderMinute,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.rawUpdate('UPDATE habit_reminders SET enabled=?, local_hour=?, local_minute=?, updated_at=? WHERE habit_id=?', [habit.reminderEnabled ? 1 : 0, habit.reminderHour, habit.reminderMinute, DateTime.now().toUtc().toIso8601String(), habit.id]);
    });
  }

  Future<void> reorder(List<String> ids) async {
    final tx = await _db;
    await tx.transaction((db) async {
      for (var index = 0; index < ids.length; index++) {
        await db.update('habits', {'position': index}, where: 'id = ?', whereArgs: [ids[index]]);
      }
    });
  }

  Future<Habit?> getHabit(String id) async {
    final rows = await (await _db).query('habits', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Habit.fromRow(rows.first);
  }

  Future<void> archive(String id, {DateTime? at}) async => (await _db).update('habits', {'archived_at': habitDateKey(at ?? DateTime.now())}, where: 'id = ?', whereArgs: [id]);
  Future<void> restore(String id) async => (await _db).update('habits', {'archived_at': null}, where: 'id = ?', whereArgs: [id]);
  Future<void> deleteHabit(String id) async => (await _db).delete('habits', where: 'id = ?', whereArgs: [id]);

  Future<void> addCompletion(String habitId, DateTime occurredAt, {String? note, String? behavioralMoment, String source = 'manual', String? sourceEventId}) async {
    final db = await _db;
    await db.transaction((tx) async {
      final substeps = await tx.query('habit_substeps', columns: ['id'], where: 'habit_id=?', whereArgs: [habitId]);
      if (substeps.isNotEmpty) {
        final checked = await tx.query('habit_substep_logs', columns: ['substep_id'], where: 'substep_id IN (SELECT id FROM habit_substeps WHERE habit_id=?) AND local_date=?', whereArgs: [habitId, habitDateKey(occurredAt)]);
        if (checked.length < substeps.length) throw StateError('Conclua as etapas antes de registrar o hábito.');
      }
      var momentId = behavioralMoment?.trim().isNotEmpty == true ? 'moment:${DateTime.now().microsecondsSinceEpoch}' : null;
      if (momentId != null) {
        await tx.insert('behavioral_moments', {'id': momentId, 'local_date': habitDateKey(occurredAt), 'occurred_at': occurredAt.toUtc().toIso8601String(), 'description': behavioralMoment!.trim(), 'kind': 'contextual', 'created_at': DateTime.now().toUtc().toIso8601String()});
      }
      await tx.insert('habit_completions', {'id': 'completion:${DateTime.now().microsecondsSinceEpoch}:${sourceEventId ?? ''}', 'habit_id': habitId, 'local_date': habitDateKey(occurredAt), 'occurred_at': occurredAt.toUtc().toIso8601String(), 'note': note, 'source_event_id': sourceEventId, 'source': source, 'behavioral_moment_id': momentId, 'created_at': DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<void> addQuantity(String habitId, double amount, DateTime occurredAt, {String source = 'manual', String? sourceEventId, String? note, String? behavioralMoment}) async {
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Informe um valor maior que zero.');
    final db = await _db;
    await db.transaction((tx) async {
      String? momentId;
      if (behavioralMoment?.trim().isNotEmpty == true) {
        momentId = 'moment:${DateTime.now().microsecondsSinceEpoch}';
        await tx.insert('behavioral_moments', {'id': momentId, 'local_date': habitDateKey(occurredAt), 'occurred_at': occurredAt.toUtc().toIso8601String(), 'description': behavioralMoment!.trim(), 'kind': 'contextual', 'created_at': DateTime.now().toUtc().toIso8601String()});
      }
      await tx.insert('habit_quantity_logs', {'id': 'quantity:${DateTime.now().microsecondsSinceEpoch}:${sourceEventId ?? ''}', 'habit_id': habitId, 'local_date': habitDateKey(occurredAt), 'amount': amount, 'occurred_at': occurredAt.toUtc().toIso8601String(), 'source_event_id': sourceEventId, 'source': source, 'note': note, 'behavioral_moment_id': momentId}, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<void> removeCompletion(String id) async {
    final db = await _db;
    await db.transaction((tx) async {
      final rows = await tx.query('habit_completions', columns: ['habit_id', 'source_event_id'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      final eventId = rows.single['source_event_id'] as String?;
      if (eventId != null) await tx.insert('habit_ignored_events', {'habit_id': rows.single['habit_id'], 'source_event_id': eventId, 'ignored_at': DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.delete('habit_completions', where: 'id=?', whereArgs: [id]);
    });
  }

  Future<void> removeQuantity(String id) async {
    final db = await _db;
    await db.transaction((tx) async {
      final rows = await tx.query('habit_quantity_logs', columns: ['habit_id', 'source_event_id'], where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      final eventId = rows.single['source_event_id'] as String?;
      if (eventId != null) await tx.insert('habit_ignored_events', {'habit_id': rows.single['habit_id'], 'source_event_id': eventId, 'ignored_at': DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.delete('habit_quantity_logs', where: 'id=?', whereArgs: [id]);
    });
  }
  Future<void> adjustLogTime(String id, {required bool completion, required DateTime occurredAt}) async {
    final table = completion ? 'habit_completions' : 'habit_quantity_logs';
    await (await _db).update(table, {'local_date': habitDateKey(occurredAt), 'occurred_at': occurredAt.toUtc().toIso8601String()}, where: 'id=?', whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> logsForDay(String habitId, DateTime day) async {
    final db = await _db;
    final key = habitDateKey(day);
    final completions = await db.query('habit_completions', where: 'habit_id=? AND local_date=?', whereArgs: [habitId, key], orderBy: 'occurred_at');
    final quantities = await db.query('habit_quantity_logs', where: 'habit_id=? AND local_date=?', whereArgs: [habitId, key], orderBy: 'occurred_at');
    return [
      ...completions.map((row) => {...row, 'log_kind': 'completion'}),
      ...quantities.map((row) => {...row, 'log_kind': 'quantity'}),
    ]..sort((a, b) => (a['occurred_at']! as String).compareTo(b['occurred_at']! as String));
  }

  Future<List<Map<String, Object?>>> focusSessions({DateTime? since}) async => (await _db).query('habit_focus_sessions', where: since == null ? null : 'started_at >= ?', whereArgs: since == null ? null : [since.toUtc().toIso8601String()], orderBy: 'started_at DESC', limit: 100);

  Future<void> toggleSubstep(String substepId, DateTime day, bool checked) async {
    final db = await _db;
    if (checked) {
      await db.insert('habit_substep_logs', {'substep_id': substepId, 'local_date': habitDateKey(day), 'completed_at': DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete('habit_substep_logs', where: 'substep_id = ? AND local_date = ?', whereArgs: [substepId, habitDateKey(day)]);
    }
  }

  Future<void> saveNote(String habitId, DateTime day, String body, {String? photoUri}) async {
    final db = await _db;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('habit_day_notes', {'id': 'note:$habitId:${habitDateKey(day)}', 'habit_id': habitId, 'local_date': habitDateKey(day), 'body': body.trim(), 'photo_uri': photoUri?.trim().isEmpty == true ? null : photoUri?.trim(), 'created_at': now, 'updated_at': now}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setRestDay(String habitId, DateTime day, bool enabled) async {
    final db = await _db;
    if (enabled) {
      await db.insert('habit_rest_days', {'habit_id': habitId, 'local_date': habitDateKey(day)}, conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete('habit_rest_days', where: 'habit_id = ? AND local_date = ?', whereArgs: [habitId, habitDateKey(day)]);
    }
  }

  Future<void> saveVacation(String habitId, DateTime start, DateTime end, {String label = 'Férias'}) async {
    final from = habitDay(start), through = habitDay(end);
    if (through.isBefore(from)) throw ArgumentError('A data final deve ser posterior à inicial.');
    await (await _db).insert('habit_vacations', {'id': 'vacation:$habitId:${habitDateKey(from)}:${habitDateKey(through)}', 'habit_id': habitId, 'start_date': habitDateKey(from), 'end_date': habitDateKey(through), 'label': label.trim().isEmpty ? 'Férias' : label.trim()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeVacation(String id) async => (await _db).delete('habit_vacations', where: 'id = ?', whereArgs: [id]);

  Future<void> snoozeReminder(String habitId, {Duration duration = const Duration(minutes: 10)}) async {
    final db = await _db;
    await db.rawUpdate('UPDATE habit_reminders SET snoozed_until=?, snooze_count=snooze_count+1, updated_at=? WHERE habit_id=?', [DateTime.now().add(duration).toUtc().toIso8601String(), DateTime.now().toUtc().toIso8601String(), habitId]);
  }

  Future<void> clearSnooze(String habitId) async => (await _db).rawUpdate('UPDATE habit_reminders SET snoozed_until=NULL, snooze_count=0, updated_at=? WHERE habit_id=?', [DateTime.now().toUtc().toIso8601String(), habitId]);

  Future<void> saveFocusSettings({required int dailyGoalMinutes, required int workMinutes, required int breakMinutes}) async {
    await (await _db).insert('habit_focus_settings', {'id': 1, 'daily_goal_minutes': dailyGoalMinutes, 'work_minutes': workMinutes, 'break_minutes': breakMinutes}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, int>> focusSettings() async {
    final rows = await (await _db).query('habit_focus_settings', where: 'id=1');
    return rows.isEmpty ? {'dailyGoalMinutes': 60, 'workMinutes': 25, 'breakMinutes': 5} : {'dailyGoalMinutes': rows.first['daily_goal_minutes']! as int, 'workMinutes': rows.first['work_minutes']! as int, 'breakMinutes': rows.first['break_minutes']! as int};
  }

  Future<void> addFocusSession({required DateTime startedAt, required DateTime endedAt, required int plannedMinutes, required bool completed, String? note}) async {
    await (await _db).insert('habit_focus_sessions', {'id': 'focus:${startedAt.microsecondsSinceEpoch}', 'started_at': startedAt.toUtc().toIso8601String(), 'ended_at': endedAt.toUtc().toIso8601String(), 'planned_minutes': plannedMinutes, 'completed': completed ? 1 : 0, 'note': note});
  }

  Future<int> ingestWorkoutCompletion({required String eventId, required String sessionId, required DateTime occurredAt, int? exerciseType, String? label, String source = 'workout', bool isRunning = false}) async {
    if (eventId.trim().isEmpty || sessionId.trim().isEmpty) throw ArgumentError('Evento e sessão precisam de identificadores estáveis.');
    final db = await _db;
    var inserted = 0;
    await db.transaction((tx) async {
      final rows = await tx.query('habits', where: "archived_at IS NULL AND type='positive' AND automation IN ('workout','healthConnectExercise','healthConnectRun')");
      for (final row in rows) {
        final habit = Habit.fromRow(row);
        if (habit.automation == HabitAutomation.workout && source != 'workout') continue;
        if (habit.automation == HabitAutomation.healthConnectExercise && source != 'health_connect_exercise') continue;
        if (habit.automation == HabitAutomation.healthConnectRun && (source != 'health_connect_exercise' || !isRunning)) continue;
        if (habit.exerciseTypes.isNotEmpty && (exerciseType == null || !habit.exerciseTypes.contains(exerciseType))) continue;
        final eventKey = '$source:$eventId';
        final ignored = await tx.query('habit_ignored_events', columns: ['habit_id'], where: 'habit_id=? AND source_event_id=?', whereArgs: [habit.id, eventKey], limit: 1);
        if (ignored.isNotEmpty) continue;
        final result = await tx.insert('habit_completions', {'id': '$eventKey:${habit.id}', 'habit_id': habit.id, 'local_date': habitDateKey(occurredAt), 'occurred_at': occurredAt.toUtc().toIso8601String(), 'note': label ?? 'Treino $sessionId', 'source_event_id': eventKey, 'source': source, 'created_at': DateTime.now().toUtc().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (result != 0) inserted++;
      }
    });
    return inserted;
  }

  Future<void> consumeHealthConnectExercises(HealthExercisePeriod period) async {
    final automated = (await list()).where((h) => h.automation == HabitAutomation.healthConnectExercise || h.automation == HabitAutomation.healthConnectRun).toList();
    if (automated.isEmpty) return;
    final db = await _db;
    // Coverage failures are visible without deleting durable or manual completions.
    await db.transaction((tx) async {
      for (final habit in automated) {
        for (final day in period.coverage) {
          await tx.insert('habit_health_coverage', {
            'habit_id': habit.id, 'local_date': day.date, 'source': 'health_connect_exercise',
            'availability': day.availability.name, 'read_complete': day.readComplete ? 1 : 0,
            'provisional': day.provisional ? 1 : 0, 'observed_at': period.readAt.toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    for (final session in period.sessions) {
      // JSON preserves the origin/id tuple without delimiter collisions.
      await ingestWorkoutCompletion(eventId: jsonEncode([session.origin, session.id]),
        sessionId: session.id, occurredAt: parseHabitDay(session.date).add(Duration(hours: session.startAt.toLocal().hour, minutes: session.startAt.toLocal().minute)),
        exerciseType: session.exerciseType, label: 'Health Connect ? ${session.origin}',
        source: 'health_connect_exercise', isRunning: session.isRunning);
    }
  }

  Future<int> consumeHealthConnectSteps(HealthPeriodSummary summary) async {
    final habits = (await list()).where((h) => h.automation == HabitAutomation.healthConnectSteps).toList();
    if (habits.isEmpty) return 0;
    final db = await _db;
    var imported = 0;
    await db.transaction((tx) async {
      for (final habit in habits) {
        for (final snapshot in summary.snapshots.where((s) => s.metric == HealthMetric.steps)) {
          final day = snapshot.date;
          final date = parseHabitDay(day);
          await tx.insert('habit_health_coverage', {
            'habit_id': habit.id, 'local_date': day, 'source': 'health_connect_steps',
            'availability': snapshot.availability.name, 'read_complete': snapshot.readComplete ? 1 : 0,
            'provisional': snapshot.provisional ? 1 : 0, 'observed_at': snapshot.observedAt?.toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          final eventId = 'health-connect-steps:${snapshot.timezone}:$day';
          final ignored = await tx.query('habit_ignored_events', columns: ['habit_id'], where: 'habit_id=? AND source_event_id=?', whereArgs: [habit.id, eventId], limit: 1);
          if (ignored.isNotEmpty) continue;
          if (snapshot.availability != MetricAvailability.available || snapshot.value == null || !snapshot.readComplete) {
            await tx.delete('habit_quantity_logs', where: 'habit_id=? AND source_event_id=?', whereArgs: [habit.id, eventId]);
            continue;
          }
          if (snapshot.value! <= 0) {
            // Keep the zero-coverage snapshot, but never insert a non-positive
            // amount into habit_quantity_logs (whose CHECK requires amount > 0).
            await tx.delete('habit_quantity_logs', where: 'habit_id=? AND source_event_id=?', whereArgs: [habit.id, eventId]);
            continue;
          }
          await tx.insert('habit_quantity_logs', {
            'id': 'hc-steps:${habit.id}:$day', 'habit_id': habit.id, 'local_date': habitDateKey(date),
            'amount': snapshot.value, 'occurred_at': (snapshot.observedAt ?? snapshot.readAt).toUtc().toIso8601String(),
            'source_event_id': eventId, 'source': 'health_connect_steps',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          imported++;
        }
      }
    });
    return imported;
  }

  Future<List<HabitProgress>> loadProgress({DateTime? through, DateTime? selectedDate, bool archived = false}) async {
    // `through` is the metric cutoff. The selected day only controls day-specific
    // checklist/reminder/note state and may be earlier than that cutoff.
    final date = habitDay(through ?? DateTime.now());
    final selected = habitDay(selectedDate ?? date);
    final db = await _db;
    final habits = (await list(archived: archived)).toList();
    final progress = <HabitProgress>[];
    for (final habit in habits) {
      final from = habit.schedule.startDate;
      final completions = await db.query('habit_completions', where: 'habit_id=? AND local_date BETWEEN ? AND ?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)], orderBy: 'occurred_at');
      final quantities = await db.query('habit_quantity_logs', where: 'habit_id=? AND local_date BETWEEN ? AND ?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)]);
      final coverage = await db.query('habit_health_coverage', where: 'habit_id=? AND local_date BETWEEN ? AND ?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)]);
      final records = <DateTime, HabitDayRecord>{};
      final minutes = <DateTime, List<int>>{};
      final completeCount = <String, int>{};
      for (final row in completions) {
        final day = parseHabitDay(row['local_date']! as String);
        completeCount.update(habitDateKey(day), (n) => n + 1, ifAbsent: () => 1);
        final occurred = DateTime.parse(row['occurred_at']! as String).toLocal();
        minutes.putIfAbsent(day, () => []).add(occurred.hour * 60 + occurred.minute);
      }
      final amounts = <String, double>{};
      final amountEntries = <String, int>{};
      final manualQuantityDays = <String>{};
      for (final row in quantities) {
        final day = row['local_date']! as String;
        amounts.update(day, (v) => v + (row['amount']! as num).toDouble(), ifAbsent: () => (row['amount']! as num).toDouble());
        amountEntries.update(day, (v) => v + 1, ifAbsent: () => 1);
        if (row['source'] == 'manual') manualQuantityDays.add(day);
        final occurred = DateTime.parse(row['occurred_at']! as String).toLocal();
        minutes.putIfAbsent(parseHabitDay(day), () => []).add(occurred.hour * 60 + occurred.minute);
      }
      final covered = <String, bool>{};
      for (final row in coverage) {
        covered[row['local_date']! as String] = row['availability'] == MetricAvailability.available.name && row['read_complete'] == 1;
      }
      final keys = {...completeCount.keys, ...amounts.keys, ...covered.keys};
      for (final key in keys) {
        final day = parseHabitDay(key);
        records[day] = HabitDayRecord(completions: completeCount[key] ?? 0, quantity: amounts[key] ?? 0, quantityEntries: amountEntries[key] ?? 0, covered: habit.automation != HabitAutomation.healthConnectSteps || covered[key] == true || manualQuantityDays.contains(key));
      }
      final restRows = await db.query('habit_rest_days', where: 'habit_id=? AND local_date BETWEEN ? AND ?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)]);
      final rests = restRows.map((row) => parseHabitDay(row['local_date']! as String)).toSet();
      final vacations = (await db.query('habit_vacations', where: 'habit_id=? AND end_date>=? AND start_date<=?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)])).map((row) => HabitVacation(id: row['id']! as String, habitId: habit.id, startDate: parseHabitDay(row['start_date']! as String), endDate: parseHabitDay(row['end_date']! as String), label: row['label']! as String)).toList();
      final vacationDays = <DateTime>{};
      for (final vacation in vacations) {
        for (var day = vacation.startDate; !day.isAfter(vacation.endDate); day = day.add(const Duration(days: 1))) vacationDays.add(day);
      }
      for (var day = from; !day.isAfter(date); day = day.add(const Duration(days: 1))) {
        final prior = records[day] ?? const HabitDayRecord();
        final key = habitDateKey(day);
        records[day] = HabitDayRecord(completions: prior.completions, quantity: prior.quantity, quantityEntries: prior.quantityEntries, restDay: rests.contains(day), vacation: vacationDays.contains(day), covered: habit.automation != HabitAutomation.healthConnectSteps || covered[key] == true || manualQuantityDays.contains(key));
      }
      final stats = calculateHabitStats(habit: habit, history: records, from: from, through: date, vacationDays: vacationDays, restDays: rests, completionMinutes: minutes);
      final subs = await db.query('habit_substeps', where: 'habit_id=?', whereArgs: [habit.id], orderBy: 'position');
      final checked = await db.query('habit_substep_logs', where: 'substep_id IN (SELECT id FROM habit_substeps WHERE habit_id=?) AND local_date=?', whereArgs: [habit.id, habitDateKey(selected)]);
      final notesRows = await db.query('habit_day_notes', where: 'habit_id=? AND local_date BETWEEN ? AND ?', whereArgs: [habit.id, habitDateKey(from), habitDateKey(date)], orderBy: 'local_date DESC');
      final reminders = await db.query('habit_reminders', where: 'habit_id=?', whereArgs: [habit.id], limit: 1);
      progress.add(HabitProgress(
        habit: habit, stats: stats, history: records,
        substeps: subs.map((s) => (id: s['id']! as String, title: s['title']! as String)).toList(),
        checkedSubsteps: checked.map((r) => r['substep_id']! as String).toSet(),
        notes: notesRows.map((r) => HabitNote(id: r['id']! as String, habitId: habit.id, date: parseHabitDay(r['local_date']! as String), text: r['body']! as String, photoUri: r['photo_uri'] as String?, createdAt: DateTime.parse(r['created_at']! as String))).toList(),
        vacations: vacations, restDays: rests, completionMinutes: minutes,
        snoozedUntil: reminders.isEmpty || reminders.first['snoozed_until'] == null ? null : DateTime.tryParse(reminders.first['snoozed_until']! as String),
      ));
    }
    return progress;
  }

  Future<List<HabitSummaryItem>> publicSummaries({DateTime? through, int days = 30}) async {
    final end = habitDay(through ?? DateTime.now());
    final from = end.subtract(Duration(days: days - 1));
    final rows = await loadProgress(through: end);
    return rows.map((p) {
      final vacationDays = <DateTime>{};
      for (final vacation in p.vacations) {
        for (var day = vacation.startDate; !day.isAfter(vacation.endDate); day = day.add(const Duration(days: 1))) vacationDays.add(day);
      }
      final stats = calculateHabitStats(habit: p.habit, history: p.history, from: from, through: end, vacationDays: vacationDays, restDays: p.restDays, completionMinutes: p.completionMinutes);
      final prior = calculateHabitStats(habit: p.habit, history: p.history, from: from.subtract(Duration(days: days)), through: from.subtract(const Duration(days: 1)), vacationDays: vacationDays, restDays: p.restDays, completionMinutes: p.completionMinutes);
      return HabitSummaryItem(habitId: p.habit.id, name: p.habit.name, type: p.habit.type, adherence: stats.adherence, currentStreak: stats.currentStreak, completedOpportunities: stats.completedOpportunities, scheduledOpportunities: stats.scheduledOpportunities, recentChange: stats.completedOpportunities - prior.completedOpportunities);
    }).toList(growable: false);
  }

  /// Safe for Coach/Morning Brief/Baseline: aggregates only; never returns notes, photo URIs, or raw event payloads.
  Future<Map<String, Object?>> coachSummary({DateTime? through}) async => {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'habits': (await publicSummaries(through: through)).map((item) => item.toPublicMap()).toList(),
  };

  Future<List<HabitSummaryItem>> morningBrief({DateTime? today}) async {
    final items = await publicSummaries(through: today, days: 7);
    return items.where((item) => item.scheduledOpportunities > item.completedOpportunities || item.currentStreak > 0).toList(growable: false);
  }

  Future<Map<String, Object?>> baseline({DateTime? through, int days = 30}) async {
    final end = habitDay(through ?? DateTime.now());
    return {'recent': (await publicSummaries(through: end, days: days)).map((x) => x.toPublicMap()).toList(), 'previous': (await publicSummaries(through: end.subtract(Duration(days: days)), days: days)).map((x) => x.toPublicMap()).toList()};
  }

  Future<String> exportJson() async => jsonEncode(await coachSummary());
}

/// Boundary the #20 adapter can depend on. The future resolves after the SQLite transaction commits.
abstract interface class HabitWorkoutSink {
  Future<int> ingestWorkoutCompletion({required String eventId, required String sessionId, required DateTime occurredAt, int? exerciseType, String? label, String source = 'workout', bool isRunning = false});
}

class RepositoryHabitWorkoutSink implements HabitWorkoutSink {
  RepositoryHabitWorkoutSink(this.repository);
  final HabitRepository repository;
  @override
  Future<int> ingestWorkoutCompletion({required String eventId, required String sessionId, required DateTime occurredAt, int? exerciseType, String? label, String source = 'workout', bool isRunning = false}) => repository.ingestWorkoutCompletion(eventId: eventId, sessionId: sessionId, occurredAt: occurredAt, exerciseType: exerciseType, label: label, source: source, isRunning: isRunning);
}
