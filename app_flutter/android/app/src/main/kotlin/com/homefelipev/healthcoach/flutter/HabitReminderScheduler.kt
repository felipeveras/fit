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
        if (readHabit(context, habitId) == null) return cancel(context, habitId)
        val row = readReminder(context, habitId) ?: return cancel(context, habitId)
        if (row.enabled != 1 || row.hour == null || row.minute == null) return cancel(context, habitId)
        val now = System.currentTimeMillis()
        val fireAt = row.snoozedUntil?.takeIf { it > now } ?: nextLocalTime(row.hour, row.minute, now)
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
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, habitId.hashCode(), Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val action = PendingIntent.getBroadcast(
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
        val actionLabel = when (habit.type) {
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

    private fun nextLocalTime(hour: Int, minute: Int, nowMillis: Long): Long {
        val zone = ZoneId.systemDefault()
        val now = Instant.ofEpochMilli(nowMillis).atZone(zone)
        var next = now.toLocalDate().atTime(hour, minute).atZone(zone)
        if (!next.isAfter(now)) next = next.plusDays(1)
        return next.toInstant().toEpochMilli()
    }

    private data class Reminder(val enabled: Int, val hour: Int?, val minute: Int?, val snoozedUntil: Long?)
    private data class HabitInfo(val name: String, val type: String, val target: Double?)

    private fun readReminder(context: Context, id: String): Reminder? = withDatabase(context) { db ->
        db.rawQuery("SELECT enabled,local_hour,local_minute,snoozed_until FROM habit_reminders WHERE habit_id=?", arrayOf(id)).use { c ->
            if (!c.moveToFirst()) null else Reminder(c.getInt(0), if (c.isNull(1)) null else c.getInt(1), if (c.isNull(2)) null else c.getInt(2), if (c.isNull(3)) null else runCatching { Instant.parse(c.getString(3)).toEpochMilli() }.getOrNull())
        }
    }

    private fun readHabit(context: Context, id: String): HabitInfo? = withDatabase(context) { db -> readHabit(db, id) }
    private fun readHabit(db: SQLiteDatabase, id: String): HabitInfo? = db.rawQuery("SELECT name,type,quantity_target FROM habits WHERE id=? AND archived_at IS NULL", arrayOf(id)).use { c ->
        if (!c.moveToFirst()) null else HabitInfo(c.getString(0), c.getString(1), if (c.isNull(2)) null else c.getDouble(2))
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
