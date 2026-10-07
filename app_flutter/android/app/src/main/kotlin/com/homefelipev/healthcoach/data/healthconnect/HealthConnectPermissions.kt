package com.homefelipev.healthcoach.data.healthconnect

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import kotlin.reflect.KClass

object HealthConnectPermissions {
    val dataRead: Set<String> = HealthMetric.entries.map { HealthPermission.getReadPermission(recordType(it)) }.toSet()
    const val historyRead = HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY
    const val backgroundRead = HealthPermission.PERMISSION_READ_HEALTH_DATA_IN_BACKGROUND

    fun recordType(metric: HealthMetric): KClass<out Record> = when (metric) {
        HealthMetric.STEPS -> StepsRecord::class
        HealthMetric.SLEEP_DURATION -> SleepSessionRecord::class
        HealthMetric.RESTING_HEART_RATE -> RestingHeartRateRecord::class
        HealthMetric.ACTIVE_ENERGY -> ActiveCaloriesBurnedRecord::class
        HealthMetric.TOTAL_ENERGY -> TotalCaloriesBurnedRecord::class
        HealthMetric.DISTANCE -> DistanceRecord::class
        HealthMetric.WEIGHT -> WeightRecord::class
    }
}
