package com.homefelipev.healthcoach.data.autosend

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectDataSource
import com.homefelipev.healthcoach.data.healthconnect.DefaultHealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthConnectRepository
import com.homefelipev.healthcoach.data.telegram.DailyHealthSummary
import com.homefelipev.healthcoach.data.telegram.HealthSummarySender
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Sends the daily health summary to the configured Telegram group/topic without the app open.
 * Reuses the same collector, formatter and Telegram client as the manual send.
 */
class DailySummaryWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    private val preferences = AutoSendPreferences(context)

    override suspend fun doWork(): Result {
        if (!preferences.enabled) return Result.success()

        val zone = ZoneId.systemDefault()
        val date = LocalDate.now(zone)
        if (!preferences.shouldSend(date)) return Result.success()

        val sender = HealthSummarySender()
        if (!sender.configured) return Result.success()

        val repository: HealthConnectRepository =
            DefaultHealthConnectRepository(AndroidHealthConnectDataSource(applicationContext))

        return try {
            val snapshots = withContext(Dispatchers.IO) {
                DailyHealthSummary.collect(repository, date, zone)
            }
            sender.send(date, snapshots)
            preferences.markSent(date)
            Result.success()
        } catch (failure: Exception) {
            // A retry stays within the same day: the guard still prevents a duplicate once sent.
            Result.retry()
        }
    }
}
