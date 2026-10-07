package com.homefelipev.healthcoach.data.healthconnect

import android.content.Context
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Instant
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

class AndroidHealthConnectDataSource(
    private val gateway: AndroidHealthConnectGateway,
    private val grants: FirstGrantTracker,
) : HealthConnectDataSource {
    constructor(context: Context) : this(AndroidHealthConnectGateway(context), androidFirstGrantTracker(context))
    private val client get() = gateway.client()

    override suspend fun hasReadPermission(metric: HealthMetric): Boolean =
        HealthPermission.getReadPermission(HealthConnectPermissions.recordType(metric)) in gateway.grantedPermissions()

    override suspend fun hasHistoryReadPermission(): Boolean =
        gateway.capabilities(gateway.grantedPermissions()).history == CapabilityState.AVAILABLE_AND_GRANTED

    override suspend fun supports(metric: HealthMetric): Boolean =
        gateway.providerState() == ProviderState.AVAILABLE

    override suspend fun readAccess(metric: HealthMetric): HealthReadAccess {
        val granted = gateway.grantedPermissions()
        val window = grants.observe(granted.any { it in HealthConnectPermissions.dataRead })
        return HealthReadAccess(
            HealthPermission.getReadPermission(HealthConnectPermissions.recordType(metric)) in granted,
            gateway.capabilities(granted).history == CapabilityState.AVAILABLE_AND_GRANTED,
            window,
        )
    }

    override suspend fun aggregate(metric: HealthMetric, start: Instant, end: Instant, originPackage: String?): AggregateSample {
        val response = client.aggregate(
            AggregateRequest(
                metrics = setOf(aggregateMetric(metric)),
                timeRangeFilter = TimeRangeFilter.between(start, end),
                dataOriginFilter = originPackage?.let { setOf(DataOrigin(it)) } ?: emptySet(),
            ),
        )
        val value = when (metric) {
            HealthMetric.STEPS -> response[StepsRecord.COUNT_TOTAL]?.toDouble()
            HealthMetric.ACTIVE_ENERGY -> response[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.inKilocalories
            HealthMetric.TOTAL_ENERGY -> response[TotalCaloriesBurnedRecord.ENERGY_TOTAL]?.inKilocalories
            HealthMetric.DISTANCE -> response[DistanceRecord.DISTANCE_TOTAL]?.inMeters
            else -> error("$metric does not use the Aggregate API")
        }
        return AggregateSample(value, response.dataOrigins.map { it.packageName }.toSet())
    }

    override suspend fun readRecords(metric: HealthMetric, start: Instant, end: Instant): List<HealthRecordSample> {
        val output = mutableListOf<HealthRecordSample>()
        var pageToken: String? = null
        val seenTokens = mutableSetOf<String>()
        do {
            currentCoroutineContext().ensureActive()
            val page = client.readRecords(
                ReadRecordsRequest(
                    recordType = HealthConnectPermissions.recordType(metric),
                    // A start-time filter can omit overnight/long sessions. Read all authorized
                    // history before the end, then attribute complete sessions by end time.
                    timeRangeFilter = if (metric == HealthMetric.SLEEP_DURATION) TimeRangeFilter.before(end)
                        else TimeRangeFilter.between(start, end),
                    pageSize = 1000,
                    pageToken = pageToken,
                ),
            )
            output += page.records.mapNotNull(::toSample)
            pageToken = page.pageToken?.takeIf(String::isNotEmpty)
            check(pageToken == null || seenTokens.add(pageToken)) { "Repeated Health Connect page token" }
        } while (pageToken != null)
        return output.filter { record ->
            val attributedAt = if (metric == HealthMetric.SLEEP_DURATION) record.end else record.start
            attributedAt >= start && attributedAt < end
        }
    }

    private fun aggregateMetric(metric: HealthMetric) = when (metric) {
        HealthMetric.STEPS -> StepsRecord.COUNT_TOTAL
        HealthMetric.ACTIVE_ENERGY -> ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL
        HealthMetric.TOTAL_ENERGY -> TotalCaloriesBurnedRecord.ENERGY_TOTAL
        HealthMetric.DISTANCE -> DistanceRecord.DISTANCE_TOTAL
        else -> error("$metric does not use the Aggregate API")
    }

    private fun toSample(record: Record): HealthRecordSample? {
        val metadata = record.metadata
        return when (record) {
            is SleepSessionRecord -> HealthRecordSample(
                id = metadata.id,
                origin = metadata.dataOrigin.packageName,
                start = record.startTime,
                end = record.endTime,
                lastModifiedAt = metadata.lastModifiedTime,
            )
            is RestingHeartRateRecord -> HealthRecordSample(
                id = metadata.id,
                origin = metadata.dataOrigin.packageName,
                start = record.time,
                end = record.time,
                value = record.beatsPerMinute.toDouble(),
                lastModifiedAt = metadata.lastModifiedTime,
            )
            is WeightRecord -> HealthRecordSample(
                id = metadata.id,
                origin = metadata.dataOrigin.packageName,
                start = record.time,
                end = record.time,
                value = record.weight.inKilograms,
                lastModifiedAt = metadata.lastModifiedTime,
            )
            else -> null
        }
    }
}
