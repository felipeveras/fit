package com.homefelipev.healthcoach.flutter

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/** Android alarm/notification adapter; reminder configuration and snooze remain in app_fit.db. */
object HabitReminderScheduler {
    const val CHANNEL_ID = "habit_reminders"
    const val ACTION_FIRE = "com.homefelipev.healthcoach.flutter.HABIT_REMINDER_FIRE"
    const val ACTION_COMPLETE = "com.homefelipev.healthcoach.flutter.HABIT_REMINDER_COMPLETE"
    const val ACTION_SNOOZE = "com.homefelipev.healthcoach.flutter.HABIT_REMINDER_SNOOZE"
    const val EXTRA_HABIT_ID = "habit_id"

    fun refresh(context: Context, habitId: String) {
        val habit = readHabit(context, habitId) ?: return cancel(context, habitId)
        val row = readReminder(context, habitId) ?: return cancel(context, habitId)
        if (row.enabled != 1 || row.hour == null || row.minute == null) return cancel(context, habitId)
        val now = System.currentTimeMillis()
        val fireAt = row.snoozedUntil?.takeIf { it > now }
            ?: nextEligibleTime(context, habit, row.hour, row.minute, now)
            ?: return cancel(context, habitId)
        val intent = Intent(context, HabitReminderReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_HABIT_ID, habitId)
        val pending = PendingIntent.getBroadcast(context, habitId.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pending)
    }

    fun refreshAll(context: Context) {
        withDatabase(context) { db ->
            db.rawQuery("SELECT r.habit_id FROM habit_reminders r JOIN habits h ON h.id=r.habit_id WHERE r.enabled=1 AND h.archived_at IS NULL", null).use { cursor ->
                val ids = mutableListOf<String>()
                while (cursor.moveToNext()) ids += cursor.getString(0)
                ids.forEach { refresh(context, it) }
            }
        }
    }

    fun cancel(context: Context, habitId: String) {
        val intent = Intent(context, HabitReminderReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_HABIT_ID, habitId)
        val pending = PendingIntent.getBroadcast(context, habitId.hashCode(), intent, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
        pending.cancel()
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(habitId.hashCode())
    }

    fun fire(context: Context, habitId: String) {
        val reminder = readReminder(context, habitId) ?: return
        if (reminder.enabled != 1) return
        val snoozed = reminder.snoozedUntil
        if (snoozed != null && snoozed > System.currentTimeMillis()) {
            refresh(context, habitId)
            return
        }
        if (snoozed != null) {
            withDatabase(context) { db -> db.execSQL("UPDATE habit_reminders SET snoozed_until=NULL, snooze_count=0, updated_at=? WHERE habit_id=?", arrayOf(Instant.now().toString(), habitId)) }
        }
        val habit = readHabit(context, habitId) ?: return
        val date = LocalDate.now(ZoneId.systemDefault())
        val eligible = withDatabase(context) { db -> dateEligible(db, habit, date) } ?: false
        if (!eligible) {
            refresh(context, habitId)
            return
        }
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, habitId.hashCode(), Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val requiresChecklist = habit.type != "quantitative" &&
            (withDatabase(context) { db -> checklistIncomplete(db, habitId, date.toString()) } ?: true)
        val action = if (requiresChecklist) open else PendingIntent.getBroadcast(
            context, habitId.hashCode() xor 0x22, Intent(context, HabitReminderActionReceiver::class.java)
                .setAction(ACTION_COMPLETE).putExtra(EXTRA_HABIT_ID, habitId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snooze = PendingIntent.getBroadcast(
            context, habitId.hashCode() xor 0x55, Intent(context, HabitReminderActionReceiver::class.java)
                .setAction(ACTION_SNOOZE).putExtra(EXTRA_HABIT_ID, habitId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = habit.name
        val body = when (habit.type) {
            "avoid" -> "Se fizer sentido, registre uma ocorrência sem julgamento."
            "quantitative" -> "Adicione um pouco de progresso à meta de hoje."
            else -> "Um passo pequeno também conta."
        }
        val actionLabel = if (requiresChecklist) "Abrir etapas" else when (habit.type) {
            "avoid" -> "Registrar ocorrência"
            "quantitative" -> "Adicionar progresso"
            else -> "Concluir"
        }
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_my_calendar)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_send, actionLabel, action).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_lock_idle_alarm, "Adiar 10 min", snooze).build())
            .build()
        try {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(habitId.hashCode(), notification)
            withDatabase(context) { db ->
                db.execSQL("UPDATE habit_reminders SET last_fired_at=? WHERE habit_id=?", arrayOf(Instant.now().toString(), habitId))
            }
        } catch (_: SecurityException) {
            // The Flutter settings screen exposes notification permission state to the user.
        } finally {
            refresh(context, habitId)
        }
    }

    fun act(context: Context, habitId: String, action: String) {
        if (action == ACTION_COMPLETE) {
            val habit = readHabit(context, habitId) ?: return
            if (habit.type != "quantitative") {
                val day = LocalDate.now().toString()
                val incomplete = withDatabase(context) { db -> checklistIncomplete(db, habitId, day) } ?: true
                if (incomplete) return
            }
        }
        withDatabase(context) { db ->
            if (action == ACTION_SNOOZE) {
                db.execSQL("UPDATE habit_reminders SET snoozed_until=?, snooze_count=snooze_count+1, updated_at=? WHERE habit_id=?", arrayOf(Instant.ofEpochMilli(System.currentTimeMillis() + 10 * 60_000L).toString(), Instant.now().toString(), habitId))
            } else {
                val habit = readHabit(db, habitId) ?: return@withDatabase
                val date = LocalDate.now().toString()
                val occurred = LocalDateTime.now().atZone(ZoneId.systemDefault()).toInstant().toString()
                when (habit.type) {
                    "quantitative" -> {
                        val quarter = ((habit.target ?: 0.0) / 4.0).coerceAtLeast(0.01)
                        db.execSQL("INSERT INTO habit_quantity_logs(id,habit_id,local_date,amount,occurred_at,source, note) VALUES(?,?,?,?,?,'reminder',?)", arrayOf("reminder:${habitId}:${System.nanoTime()}", habitId, date, quarter, occurred, "Registro pela notificação"))
                    }
                    else -> db.execSQL("INSERT INTO habit_completions(id,habit_id,local_date,occurred_at,note,source,created_at) VALUES(?,?,?,?,?,'reminder',?)", arrayOf("reminder:${habitId}:${System.nanoTime()}", habitId, date, occurred, if (habit.type == "avoid") "Ocorrência registrada pela notificação" else null, Instant.now().toString()))
                }
                db.execSQL("UPDATE habit_reminders SET snoozed_until=NULL, snooze_count=0, updated_at=? WHERE habit_id=?", arrayOf(Instant.now().toString(), habitId))
            }
        }
        refresh(context, habitId)
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(habitId.hashCode())
    }

    private fun checklistIncomplete(db: SQLiteDatabase, habitId: String, day: String): Boolean =
        db.rawQuery(
            "SELECT 1 FROM habit_substeps s WHERE s.habit_id=? AND NOT EXISTS " +
                "(SELECT 1 FROM habit_substep_logs l WHERE l.substep_id=s.id AND l.local_date=?) LIMIT 1",
            arrayOf(habitId, day),
        ).use { it.moveToFirst() }

    private data class Reminder(val enabled: Int, val hour: Int?, val minute: Int?, val snoozedUntil: Long?)
    private data class HabitInfo(
        val id: String,
        val name: String,
        val type: String,
        val target: Double?,
        val cadence: String,
        val targetCount: Int,
        val weekdays: Set<Int>,
        val intervalDays: Int,
        val startDate: LocalDate,
        val automation: String,
    )

    private fun nextEligibleTime(context: Context, habit: HabitInfo, hour: Int, minute: Int, nowMillis: Long): Long? {
        val zone = ZoneId.systemDefault()
        val now = Instant.ofEpochMilli(nowMillis).atZone(zone)
        return withDatabase(context) { db ->
            for (offset in 0..366) {
                val date = now.toLocalDate().plusDays(offset.toLong())
                val fireAt = date.atTime(hour, minute).atZone(zone)
                if (!fireAt.isAfter(now)) continue
                if (!dateEligible(db, habit, date)) continue
                return@withDatabase fireAt.toInstant().toEpochMilli()
            }
            null
        }
    }

    private fun dateEligible(db: SQLiteDatabase, habit: HabitInfo, date: LocalDate): Boolean {
        if (!ReminderSchedulePolicy.isScheduled(
                cadence = habit.cadence,
                weekdays = habit.weekdays,
                intervalDays = habit.intervalDays,
                startDate = habit.startDate,
                date = date,
            ) || isExcludedDay(db, habit.id, date)) return false
        if (habit.cadence == "weeklyTarget" || habit.cadence == "monthlyTarget") {
            return ReminderSchedulePolicy.periodTargetStillDue(
                habit.cadence,
                periodTarget(db, habit, date),
                periodSuccessCount(db, habit, date),
            )
        }
        return true
    }

    private fun isExcludedDay(db: SQLiteDatabase, habitId: String, date: LocalDate): Boolean {
        val key = date.toString()
        db.rawQuery(
            "SELECT 1 FROM habit_rest_days WHERE habit_id=? AND local_date=? UNION ALL " +
                "SELECT 1 FROM habit_vacations WHERE habit_id=? AND start_date<=? AND end_date>=? LIMIT 1",
            arrayOf(habitId, key, habitId, key, key),
        ).use { return it.moveToFirst() }
    }

    private fun periodTarget(db: SQLiteDatabase, habit: HabitInfo, date: LocalDate): Int {
        val start = ReminderSchedulePolicy.periodStart(habit.cadence, date)
        val end = ReminderSchedulePolicy.periodEnd(habit.cadence, date)
        val excluded = mutableSetOf<LocalDate>()
        var measuredDays = 0
        var day = start
        while (!day.isAfter(end)) {
            if (isExcludedDay(db, habit.id, day)) excluded += day
            if (habit.automation == "healthConnectSteps" && !day.isBefore(habit.startDate) && !day.isAfter(date) && day !in excluded &&
                hasStepCoverage(db, habit.id, day)) measuredDays++
            day = day.plusDays(1)
        }
        return ReminderSchedulePolicy.adjustedPeriodTarget(
            habit.cadence, habit.targetCount, habit.startDate, date, excluded,
            if (habit.automation == "healthConnectSteps") measuredDays else null,
        )
    }

    private fun hasStepCoverage(db: SQLiteDatabase, habitId: String, day: LocalDate): Boolean =
        db.rawQuery(
            "SELECT 1 FROM habit_health_coverage WHERE habit_id=? AND local_date=? AND availability='available' AND read_complete=1 " +
                "UNION ALL SELECT 1 FROM habit_quantity_logs WHERE habit_id=? AND local_date=? AND source='manual' LIMIT 1",
            arrayOf(habitId, day.toString(), habitId, day.toString()),
        ).use { it.moveToFirst() }

    private fun periodSuccessCount(db: SQLiteDatabase, habit: HabitInfo, date: LocalDate): Int {
        val naturalStart = ReminderSchedulePolicy.periodStart(habit.cadence, date)
        val periodStart = if (naturalStart.isBefore(habit.startDate)) habit.startDate else naturalStart
        val start = periodStart.toString()
        val through = date.toString()
        val successes = when (habit.type) {
            // Match the tracker: completed logs on rest/vacation days do not count.
            "positive" -> db.rawQuery(
                "SELECT local_date FROM habit_completions WHERE habit_id=? AND local_date BETWEEN ? AND ?",
                arrayOf(habit.id, start, through),
            ).use { dates ->
                val occurrences = mutableListOf<LocalDate>()
                val excluded = mutableSetOf<LocalDate>()
                while (dates.moveToNext()) {
                    val day = LocalDate.parse(dates.getString(0))
                    occurrences += day
                    if (isExcludedDay(db, habit.id, day)) excluded += day
                }
                ReminderSchedulePolicy.successfulOccurrences(occurrences, excluded)
            }
            "quantitative" -> db.rawQuery(
                "SELECT local_date,SUM(amount) FROM habit_quantity_logs WHERE habit_id=? AND local_date BETWEEN ? AND ? GROUP BY local_date",
                arrayOf(habit.id, start, through),
            ).use { cursor ->
                var count = 0
                while (cursor.moveToNext()) {
                    val day = LocalDate.parse(cursor.getString(0))
                    if (cursor.getDouble(1) >= (habit.target ?: Double.POSITIVE_INFINITY) && !isExcludedDay(db, habit.id, day) &&
                        (habit.automation != "healthConnectSteps" || hasStepCoverage(db, habit.id, day))) count++
                }
                count
            }
            else -> {
                var count = 0
                var day = periodStart
                while (!day.isAfter(date)) {
                    if (day >= habit.startDate && !isExcludedDay(db, habit.id, day)) {
                        val hasOccurrence = db.rawQuery(
                            "SELECT 1 FROM habit_completions WHERE habit_id=? AND local_date=? LIMIT 1",
                            arrayOf(habit.id, day.toString()),
                        ).use { it.moveToFirst() }
                        if (!hasOccurrence) count++
                    }
                    day = day.plusDays(1)
                }
                count
            }
        }
        return successes
    }

    private fun readReminder(context: Context, id: String): Reminder? = withDatabase(context) { db ->
        db.rawQuery("SELECT enabled,local_hour,local_minute,snoozed_until FROM habit_reminders WHERE habit_id=?", arrayOf(id)).use { c ->
            if (!c.moveToFirst()) null else Reminder(c.getInt(0), if (c.isNull(1)) null else c.getInt(1), if (c.isNull(2)) null else c.getInt(2), if (c.isNull(3)) null else runCatching { Instant.parse(c.getString(3)).toEpochMilli() }.getOrNull())
        }
    }

    private fun readHabit(context: Context, id: String): HabitInfo? = withDatabase(context) { db -> readHabit(db, id) }
    private fun readHabit(db: SQLiteDatabase, id: String): HabitInfo? = db.rawQuery("SELECT id,name,type,quantity_target,cadence,target_count,weekdays,interval_days,start_date,automation FROM habits WHERE id=? AND archived_at IS NULL", arrayOf(id)).use { c ->
        if (!c.moveToFirst()) null else HabitInfo(
            id = c.getString(0), name = c.getString(1), type = c.getString(2),
            target = if (c.isNull(3)) null else c.getDouble(3), cadence = c.getString(4),
            targetCount = c.getInt(5), weekdays = c.getString(6).split(',').mapNotNull { it.toIntOrNull() }.toSet(),
            intervalDays = c.getInt(7), startDate = LocalDate.parse(c.getString(8)), automation = c.getString(9),
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Lembretes de hábitos", NotificationManager.IMPORTANCE_DEFAULT))
        }
    }

    private fun <T> withDatabase(context: Context, block: (SQLiteDatabase) -> T): T? {
        val file = context.getDatabasePath("app_fit.db")
        if (!file.exists()) return null
        return runCatching { SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(block) }.getOrNull()
    }
}

internal object ReminderSchedulePolicy {
    fun isScheduled(
        cadence: String,
        weekdays: Set<Int>,
        intervalDays: Int,
        startDate: LocalDate,
        date: LocalDate,
        restDay: Boolean = false,
        vacation: Boolean = false,
    ): Boolean {
        if (date.isBefore(startDate) || restDay || vacation) return false
        return when (cadence) {
            "daily", "weeklyTarget", "monthlyTarget" -> true
            "specificDays" -> date.dayOfWeek.value in weekdays
            "everyNDays" -> intervalDays > 0 && java.time.temporal.ChronoUnit.DAYS.between(startDate, date) % intervalDays == 0L
            else -> false
        }
    }

    fun periodStart(cadence: String, date: LocalDate): LocalDate =
        if (cadence == "weeklyTarget") date.minusDays((date.dayOfWeek.value - 1).toLong())
        else date.withDayOfMonth(1)

    fun periodEnd(cadence: String, date: LocalDate): LocalDate =
        if (cadence == "weeklyTarget") periodStart(cadence, date).plusDays(6)
        else date.withDayOfMonth(date.lengthOfMonth())

    fun adjustedPeriodTarget(
        cadence: String,
        targetCount: Int,
        startDate: LocalDate,
        date: LocalDate,
        excludedDays: Set<LocalDate> = emptySet(),
        measuredDays: Int? = null,
    ): Int {
        val start = periodStart(cadence, date)
        val end = periodEnd(cadence, date)
        val fullDays = java.time.temporal.ChronoUnit.DAYS.between(start, end) + 1
        var activeDays = 0
        var day = if (start.isBefore(startDate)) startDate else start
        while (!day.isAfter(end)) {
            if (day !in excludedDays) activeDays++
            day = day.plusDays(1)
        }
        val measurableDays = measuredDays ?: activeDays
        if (measurableDays == 0) return 0
        return kotlin.math.ceil(targetCount.toDouble() * measurableDays / fullDays).toInt()
            .coerceIn(1, targetCount)
    }

    fun successfulOccurrences(occurrences: List<LocalDate>, excludedDays: Set<LocalDate>): Int =
        occurrences.count { it !in excludedDays }

    fun periodTargetStillDue(cadence: String, targetCount: Int, successes: Int): Boolean =
        cadence !in setOf("weeklyTarget", "monthlyTarget") || successes < targetCount
}

class HabitReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(HabitReminderScheduler.EXTRA_HABIT_ID) ?: return
        HabitReminderScheduler.fire(context, id)
    }
}

class HabitReminderActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(HabitReminderScheduler.EXTRA_HABIT_ID) ?: return
        val action = intent.action ?: return
        HabitReminderScheduler.act(context, id, action)
    }
}

class HabitReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) HabitReminderScheduler.refreshAll(context)
    }
}
