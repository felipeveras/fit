package com.homefelipev.healthcoach.data.healthconnect

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.aggregate.AggregationResult
import androidx.health.connect.client.records.*
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.response.ReadRecordsResponse
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Mass
import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.*

class AndroidHealthConnectDataSourceTest {
    private val start = Instant.parse("2026-09-25T00:00:00Z")
    private val end = Instant.parse("2026-09-26T00:00:00Z")
    private val grantedAt = Instant.parse("2026-09-01T00:00:00Z")
    private val clock = Clock.fixed(end.plusSeconds(12 * 3600), ZoneOffset.UTC)
    private val client = mock(HealthConnectClient::class.java)
    private val permissions = mock(PermissionController::class.java)
    private val features = mock(HealthConnectFeatures::class.java)
    private var provider = ProviderState.AVAILABLE
    private val gateway = AndroidHealthConnectGateway({ client }, { provider })
    private val tracker = FirstGrantTracker(object : FirstGrantStore {
        private var value: FirstGrantWindow? = FirstGrantWindow(grantedAt, grantedAt)
        override fun load() = value
        override fun save(window: FirstGrantWindow) { value = window }
    }, grantedAt, clock)
    private val source = AndroidHealthConnectDataSource(gateway, tracker)

    @Before fun setup() = runBlocking {
        `when`(client.permissionController).thenReturn(permissions)
        `when`(client.features).thenReturn(features)
        `when`(permissions.getGrantedPermissions()).thenReturn(HealthConnectPermissions.dataRead)
        `when`(features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY)).thenReturn(HealthConnectFeatures.FEATURE_STATUS_AVAILABLE)
        `when`(features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND)).thenReturn(HealthConnectFeatures.FEATURE_STATUS_AVAILABLE)
        Unit
    }

    @Test fun overnightAndLongSleepUseOpenStartAndConsumeAllPagesUntilEmptyToken() = runBlocking {
        val overnight = sleep("night", "2026-09-24T23:00:00Z", "2026-09-25T07:00:00Z")
        val long = sleep("long", "2026-09-19T12:00:00Z", "2026-09-25T08:00:00Z")
        val outside = sleep("outside", "2026-09-23T23:00:00Z", "2026-09-24T07:00:00Z")
        val first = sleepRequest(null)
        val next = sleepRequest("page.2")
        `when`(client.readRecords(first)).thenReturn(ReadRecordsResponse(listOf(overnight, outside), "page.2"))
        `when`(client.readRecords(next)).thenReturn(ReadRecordsResponse(listOf(long), ""))
        val records = source.readRecords(HealthMetric.SLEEP_DURATION, start, end)
        assertEquals(listOf("night", "long"), records.map { it.id })
        assertEquals(Instant.parse("2026-09-19T12:00:00Z"), records[1].start)
        verify(client).readRecords(first)
        verify(client).readRecords(next)
        Unit
    }

    @Test fun overnightAdapterReadFeedsTheRepositoryWithoutClippingAtMidnight() = runBlocking {
        val night = sleep("night", "2026-09-24T23:00:00Z", "2026-09-25T07:00:00Z")
        `when`(client.readRecords(sleepRequest(null))).thenReturn(ReadRecordsResponse(listOf(night), null))
        val snapshot = DefaultHealthConnectRepository(source, clock).readSnapshot(
            HealthMetric.SLEEP_DURATION, listOf(LocalDate.parse("2026-09-25")), ZoneOffset.UTC, MetricSourcePolicy.SingleOrigin("writer"),
        ).single()
        assertEquals(8 * 3600.0, snapshot.value!!, 0.0)
        assertEquals(1, snapshot.sampleCount)
        assertEquals(setOf("session_duration_proxy"), snapshot.qualityFlags)
    }

    @Test fun failedSecondPageProducesNoCompleteSnapshotFromTheFirstPage() = runBlocking {
        val night = sleep("night", "2026-09-24T23:00:00Z", "2026-09-25T07:00:00Z")
        `when`(client.readRecords(sleepRequest(null))).thenReturn(ReadRecordsResponse(listOf(night), "page.2"))
        doAnswer { throw IOException("interrupted") }.`when`(client).readRecords(sleepRequest("page.2"))
        val snapshot = DefaultHealthConnectRepository(source, clock).readSnapshot(
            HealthMetric.SLEEP_DURATION, listOf(LocalDate.parse("2026-09-25")), ZoneOffset.UTC, MetricSourcePolicy.SingleOrigin("writer"),
        ).single()
        assertEquals(MetricAvailability.READ_ERROR, snapshot.availability)
        assertFalse(snapshot.readComplete)
        assertNull(snapshot.value)
    }

    @Test(expected = CancellationException::class) fun cancelledSdkPagePropagates() = runBlocking {
        `when`(client.readRecords(sleepRequest(null))).thenThrow(CancellationException())
        source.readRecords(HealthMetric.SLEEP_DURATION, start, end)
        Unit
    }

    @Test fun repeatedPageTokenFailsRatherThanLoopingOrReturningPartialData() = runBlocking {
        `when`(client.readRecords(sleepRequest(null))).thenReturn(ReadRecordsResponse(emptyList(), "page.2"))
        `when`(client.readRecords(sleepRequest("page.2"))).thenReturn(ReadRecordsResponse(emptyList(), "page.2"))
        try { source.readRecords(HealthMetric.SLEEP_DURATION, start, end); fail("Repeated token must fail") }
        catch (_: IllegalStateException) { }
    }

    @Test fun weightAdapterPreservesObservationModificationAndCanonicalKilograms() = runBlocking {
        val modified = end.plusSeconds(1)
        val weight = WeightRecord(start.plusSeconds(3600), null, Mass.pounds(150.0), metadata("weight", modified))
        val request = ReadRecordsRequest(WeightRecord::class, TimeRangeFilter.between(start, end))
        `when`(client.readRecords(request)).thenReturn(ReadRecordsResponse(listOf(weight), null))
        val record = source.readRecords(HealthMetric.WEIGHT, start, end).single()
        assertEquals(weight.weight.inKilograms, record.value!!, 0.0)
        assertEquals(modified, record.lastModifiedAt)
        assertEquals(weight.time, record.start)
        assertEquals("writer", record.origin)
    }

    @Test fun sdkWeightTiesSelectTheLatestModifiedObservationEndToEnd() = runBlocking {
        val old = WeightRecord(start.plusSeconds(3600), null, Mass.kilograms(72.0), metadata("z", start.plusSeconds(7200)))
        val newer = WeightRecord(start.plusSeconds(3600), null, Mass.kilograms(73.0), metadata("a", start.plusSeconds(10800)))
        val request = ReadRecordsRequest(WeightRecord::class, TimeRangeFilter.between(start, end))
        `when`(client.readRecords(request)).thenReturn(ReadRecordsResponse(listOf(old, newer), null))
        val snapshot = DefaultHealthConnectRepository(source, clock).readSnapshot(
            HealthMetric.WEIGHT, listOf(LocalDate.parse("2026-09-25")), ZoneOffset.UTC, MetricSourcePolicy.SingleOrigin("writer"),
        ).single()
        assertEquals(73.0, snapshot.value!!, 0.0)
        assertEquals(start.plusSeconds(3600), snapshot.observedAt)
    }

    @Test fun aggregateRequestsUseCorrectMetricsUnitsAndSelectedOriginFilters() = runBlocking {
        val cases = listOf(
            Triple(HealthMetric.STEPS, StepsRecord.COUNT_TOTAL, 123.0),
            Triple(HealthMetric.ACTIVE_ENERGY, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL, 250.0),
            Triple(HealthMetric.TOTAL_ENERGY, TotalCaloriesBurnedRecord.ENERGY_TOTAL, 1800.0),
            Triple(HealthMetric.DISTANCE, DistanceRecord.DISTANCE_TOTAL, 1200.0),
        )
        for ((metric, aggregateMetric, canonical) in cases) {
            val request = AggregateRequest(setOf(aggregateMetric), TimeRangeFilter.between(start, end), setOf(DataOrigin("writer")))
            // SDK 1.1.0 maps energy aggregate doubles with Energy::kilocalories.
            val raw = canonical
            val response = AggregationResult(
                if (metric == HealthMetric.STEPS) mapOf(aggregateMetric.metricKey to raw.toLong()) else emptyMap(),
                if (metric != HealthMetric.STEPS) mapOf(aggregateMetric.metricKey to raw) else emptyMap(),
                setOf(DataOrigin("writer")),
            )
            `when`(client.aggregate(request)).thenReturn(response)
            val actual = source.aggregate(metric, start, end, "writer")
            assertEquals(canonical, actual.value!!, 0.000001)
            assertEquals(setOf("writer"), actual.origins)
            verify(client).aggregate(request)
        }
    }

    @Test fun nullAndObservedZeroAggregatesRemainDifferent() = runBlocking {
        val request = AggregateRequest(setOf(StepsRecord.COUNT_TOTAL), TimeRangeFilter.between(start, end))
        `when`(client.aggregate(request)).thenReturn(AggregationResult(emptyMap(), emptyMap(), emptySet()))
        assertNull(source.aggregate(HealthMetric.STEPS, start, end).value)
        `when`(client.aggregate(request)).thenReturn(AggregationResult(mapOf(StepsRecord.COUNT_TOTAL.metricKey to 0L), emptyMap(), setOf(DataOrigin("writer"))))
        assertEquals(0.0, source.aggregate(HealthMetric.STEPS, start, end).value!!, 0.0)
    }

    @Test fun featuresAndGrantsAreIndependentAndProviderStateIsNotCached() = runBlocking {
        val all = HealthConnectPermissions.dataRead + HealthConnectPermissions.historyRead + HealthConnectPermissions.backgroundRead
        `when`(permissions.getGrantedPermissions()).thenReturn(all)
        assertTrue(source.readAccess(HealthMetric.WEIGHT).historyGranted)
        assertEquals(CapabilityState.AVAILABLE_AND_GRANTED, gateway.capabilities(all).background)
        `when`(features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY)).thenReturn(HealthConnectFeatures.FEATURE_STATUS_UNAVAILABLE)
        assertFalse(source.readAccess(HealthMetric.WEIGHT).historyGranted)
        assertEquals(CapabilityState.FEATURE_UNAVAILABLE, gateway.capabilities(all).history)
        assertEquals(CapabilityState.NOT_GRANTED, gateway.capabilities(HealthConnectPermissions.dataRead).background)
        provider = ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED
        assertFalse(source.supports(HealthMetric.WEIGHT))
        provider = ProviderState.AVAILABLE
        assertTrue(source.supports(HealthMetric.WEIGHT))
    }

    private fun sleepRequest(token: String?) = ReadRecordsRequest(SleepSessionRecord::class, TimeRangeFilter.before(end), pageToken = token)
    private fun sleep(id: String, start: String, end: String) = SleepSessionRecord(
        Instant.parse(start), null, Instant.parse(end), null, metadata = metadata(id),
    )
    private fun metadata(id: String, modified: Instant = end): Metadata {
        val metadata = mock(Metadata::class.java)
        `when`(metadata.id).thenReturn(id)
        `when`(metadata.dataOrigin).thenReturn(DataOrigin("writer"))
        `when`(metadata.lastModifiedTime).thenReturn(modified)
        return metadata
    }
}
