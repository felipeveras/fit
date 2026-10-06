package com.homefelipev.healthcoach.data.telegram

import com.homefelipev.healthcoach.data.healthconnect.HealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricSourcePolicy
import java.time.LocalDate
import java.time.ZoneId

/** Single collection path shared by the manual send and the daily automation. */
object DailyHealthSummary {
    suspend fun collect(
        repository: HealthConnectRepository,
        date: LocalDate,
        zone: ZoneId,
    ): List<HealthMetricSnapshot> = HealthMetric.entries.flatMap { metric ->
        val policy = if (metric.isPlatformAggregated) MetricSourcePolicy.PlatformAggregate
        else MetricSourcePolicy.SingleOrigin(null)
        repository.readSnapshot(metric, listOf(date), zone, policy)
    }
}
