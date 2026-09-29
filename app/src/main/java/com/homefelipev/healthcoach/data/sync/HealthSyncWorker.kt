package com.homefelipev.healthcoach.data.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class HealthSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        return try {
            val report = HealthSync(applicationContext).run(background = true) ?: return Result.success()
            when (report.outcome) {
                SyncOutcome.RETRY, SyncOutcome.BUSY -> Result.retry()
                SyncOutcome.FAILED -> Result.failure()
                SyncOutcome.PARTIAL ->
                    if (runAttemptCount < 3 && report.incompleteMetrics.values.any { "read_error" in it })
                        Result.retry() else Result.success()
                else -> Result.success()
            }
        } catch (_: RetryableSyncException) {
            Result.retry()
        } catch (_: SyncAuthException) {
            Result.success()
        }
    }
}

object HealthSyncScheduler {
    private const val PERIODIC_NAME = "health_reconciliation_v1"

    fun schedule(context: Context) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
        val work = PeriodicWorkRequestBuilder<HealthSyncWorker>(6, TimeUnit.HOURS)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PERIODIC_NAME, ExistingPeriodicWorkPolicy.KEEP, work)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_NAME)
    }
}
