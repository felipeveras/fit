package com.homefelipev.healthcoach.data.autosend

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * Schedules a single periodic daily work with the daily-summary worker.
 * WorkManager only guarantees "about once a day", not an exact minute — acceptable for a personal app.
 */
object DailySummaryScheduler {
    const val WORK_NAME = "daily_health_summary"

    fun sync(context: Context, preferences: AutoSendPreferences = AutoSendPreferences(context)) {
        val workManager = WorkManager.getInstance(context)
        if (!preferences.enabled) {
            workManager.cancelUniqueWork(WORK_NAME)
            return
        }

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<DailySummaryWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(initialDelay(preferences.hour, LocalDateTime.now(), ZoneId.systemDefault()))
            .setConstraints(constraints)
            .build()

        // KEEP: re-toggling (e.g. hour change) must not reset an already-scheduled periodic work.
        workManager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** Delay until the next occurrence of [hour]:00 in [zone]; the next day when that time already passed. */
    fun initialDelay(hour: Int, now: LocalDateTime, zone: ZoneId): Duration {
        val today = now.toLocalDate().atTime(LocalTime.of(hour.coerceIn(0, 23), 0))
        val target = if (today.isAfter(now)) today else LocalDate.from(now).plusDays(1).atTime(LocalTime.of(hour.coerceIn(0, 23), 0))
        return Duration.between(now, target)
    }
}
