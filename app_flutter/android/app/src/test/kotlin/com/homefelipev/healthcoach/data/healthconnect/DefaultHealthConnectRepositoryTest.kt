package com.homefelipev.healthcoach.data.healthconnect

import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.runBlocking

class DefaultHealthConnectRepositoryTest {
    private val utc = ZoneOffset.UTC
    private val date = LocalDate.parse("2026-09-25")

    @Test
    fun aggregateDistinguishesObservedZeroFromNoData() = runBlocking {
        val source = FakeHealthConnectDataSource()
        val repository = repository(source)

        source.aggregateSample = AggregateSample(value = 0.0, origins = setOf("steps.writer"))
        val zero = repository.readSnapshot(HealthMetric.STEPS, listOf(date), utc, MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.AVAILABLE, zero.availability)
        assertEquals(0.0, zero.value!!, 0.0)
        assertTrue(zero.readComplete)

        source.aggregateSample = AggregateSample(value = null, origins = emptySet())
        val empty = repository.readSnapshot(HealthMetric.STEPS, listOf(date), utc, MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.NO_DATA, empty.availability)
        assertNull(empty.value)
        assertTrue(empty.readComplete)
    }

    @Test
    fun missingPermissionDoesNotReadAndIsNotAnEmptySnapshot() = runBlocking {
        val source = FakeHealthConnectDataSource().apply { permitted = false }
        val result = repository(source).readSnapshot(
            HealthMetric.STEPS,
            listOf(date),
            utc,
            MetricSourcePolicy.PlatformAggregate,
        ).single()

        assertEquals(MetricAvailability.PERMISSION_DENIED, result.availability)
        assertFalse(result.readComplete)
        assertEquals(0, source.aggregateCalls)
        assertNull(result.value)
    }

    @Test
    fun multipleSingleOriginsRequireASelectionAndSelectedOriginIsAveraged() = runBlocking {
        val source = FakeHealthConnectDataSource().apply {
            records = listOf(
                sample("a1", "watch.a", date, 60.0),
                sample("b1", "watch.b", date, 90.0),
                sample("a2", "watch.a", date, 70.0),
            )
        }
        val repository = repository(source)

        val ambiguous = repository.readSnapshot(
            HealthMetric.RESTING_HEART_RATE,
            listOf(date),
            utc,
            MetricSourcePolicy.SingleOrigin(null),
        ).single()
        assertEquals(MetricAvailability.SOURCE_AMBIGUOUS, ambiguous.availability)
        assertEquals(setOf("watch.a", "watch.b"), ambiguous.origins)
        assertFalse(ambiguous.readComplete)

        val selected = repository.readSnapshot(
            HealthMetric.RESTING_HEART_RATE,
            listOf(date),
            utc,
            MetricSourcePolicy.SingleOrigin("watch.a"),
        ).single()
        assertEquals(MetricAvailability.AVAILABLE, selected.availability)
        assertEquals(65.0, selected.value!!, 0.0)
        assertEquals(setOf("watch.a"), selected.origins)
        assertEquals(2, selected.sampleCount)
    }

    @Test
    fun sleepSessionsCrossingMidnightAreUnionedWithoutDoubleCounting() = runBlocking {
        val source = FakeHealthConnectDataSource().apply {
            records = listOf(
                HealthRecordSample("overnight", "sleep.writer", Instant.parse("2026-09-24T23:00:00Z"), Instant.parse("2026-09-25T02:00:00Z")),
                HealthRecordSample("overlap", "sleep.writer", Instant.parse("2026-09-25T01:00:00Z"), Instant.parse("2026-09-25T03:00:00Z")),
                HealthRecordSample("nap", "sleep.writer", Instant.parse("2026-09-25T12:00:00Z"), Instant.parse("2026-09-25T13:00:00Z")),
            )
        }
        val result = repository(source).readSnapshot(
            HealthMetric.SLEEP_DURATION,
            listOf(date),
            utc,
            MetricSourcePolicy.SingleOrigin("sleep.writer"),
        ).single()

        assertEquals(MetricAvailability.AVAILABLE, result.availability)
        assertEquals(5 * 60 * 60.0, result.value!!, 0.0)
        assertEquals(setOf("session_duration_proxy"), result.qualityFlags)
        assertEquals(Instant.parse("2026-09-25T00:00:00Z"), source.lastReadStart)
        assertEquals(Instant.parse("2026-09-26T00:00:00Z"), source.lastReadEnd)
    }

    @Test
    fun analysisDayUsesZoneRulesForDaylightSavingTransitions() = runBlocking {
        val source = FakeHealthConnectDataSource().apply { historyPermitted = true }
        val dstDate = LocalDate.parse("2018-11-04")
        repository(source).readSnapshot(
            HealthMetric.STEPS,
            listOf(dstDate),
            ZoneId.of("America/Sao_Paulo"),
            MetricSourcePolicy.PlatformAggregate,
        )

        assertEquals(23 * 60 * 60L, source.lastAggregateEnd!!.epochSecond - source.lastAggregateStart!!.epochSecond)
    }

    @Test
    fun interruptedReadIsAnIncompleteReadError() = runBlocking {
        val source = FakeHealthConnectDataSource().apply { failReads = true }
        val result = repository(source).readSnapshot(
            HealthMetric.WEIGHT,
            listOf(date),
            utc,
            MetricSourcePolicy.SingleOrigin("scale.writer"),
        ).single()

        assertEquals(MetricAvailability.READ_ERROR, result.availability)
        assertFalse(result.readComplete)
        assertNull(result.value)
    }

    @Test
    fun analysisDayCanHaveTwentyFiveHours() = runBlocking {
        val source = FakeHealthConnectDataSource().apply { historyPermitted = true }
        repository(source).readSnapshot(
            HealthMetric.STEPS, listOf(LocalDate.parse("2018-11-04")),
            ZoneId.of("America/New_York"), MetricSourcePolicy.PlatformAggregate,
        )
        assertEquals(25 * 60 * 60L, source.lastAggregateEnd!!.epochSecond - source.lastAggregateStart!!.epochSecond)
    }

    private fun repository(source: FakeHealthConnectDataSource) = DefaultHealthConnectRepository(
        source = source,
        clock = Clock.fixed(Instant.parse("2026-09-26T12:00:00Z"), utc),
    )

    private fun sample(id: String, origin: String, day: LocalDate, value: Double) = HealthRecordSample(
        id = id,
        origin = origin,
        start = day.atStartOfDay(utc).toInstant(),
        end = day.atStartOfDay(utc).toInstant(),
        value = value,
    )

    private class FakeHealthConnectDataSource : HealthConnectDataSource {
        var permitted = true
        var historyPermitted = false
        var aggregateSample = AggregateSample(value = null, origins = emptySet())
        var aggregateCalls = 0
        var records = emptyList<HealthRecordSample>()
        var failReads = false
        var lastAggregateStart: Instant? = null
        var lastAggregateEnd: Instant? = null
        var lastReadStart: Instant? = null
        var lastReadEnd: Instant? = null

        override suspend fun hasReadPermission(metric: HealthMetric) = permitted
        override suspend fun hasHistoryReadPermission() = historyPermitted
        override suspend fun readAccess(metric: HealthMetric) = HealthReadAccess(
            permitted, historyPermitted,
            FirstGrantWindow(Instant.parse("2026-09-01T00:00:00Z"), Instant.parse("2026-09-01T00:00:00Z")),
        )
        override suspend fun supports(metric: HealthMetric) = true

        override suspend fun aggregate(
            metric: HealthMetric,
            start: Instant,
            end: Instant,
            originPackage: String?,
        ): AggregateSample {
            aggregateCalls++
            lastAggregateStart = start
            lastAggregateEnd = end
            return aggregateSample
        }

        override suspend fun readRecords(metric: HealthMetric, start: Instant, end: Instant): List<HealthRecordSample> {
            lastReadStart = start
            lastReadEnd = end
            if (failReads) throw IOException("simulated provider interruption")
            return records
        }
    }
}
