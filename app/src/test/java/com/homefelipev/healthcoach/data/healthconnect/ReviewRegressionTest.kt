package com.homefelipev.healthcoach.data.healthconnect

import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ReviewRegressionTest {
    private val date = LocalDate.parse("2026-09-25")
    private val zone = ZoneOffset.UTC
    private val clock = MutableClock(Instant.parse("2026-09-26T12:00:00Z"))

    @Test fun accessibleHistoryDoesNotExpireAsTodayAdvances() = runBlocking {
        val source = Source().apply { aggregateSample = AggregateSample(123.0, setOf("writer")) }
        val result = read(source, HealthMetric.STEPS, listOf(date.minusDays(40)), MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.AVAILABLE, result.availability)
        assertEquals(1, source.aggregateCalls)
        clock.now = clock.now.plusSeconds(90 * 86400L)
        assertEquals(MetricAvailability.AVAILABLE,
            read(source, HealthMetric.STEPS, listOf(date.minusDays(40)), MetricSourcePolicy.PlatformAggregate).single().availability)
    }

    @Test fun pendingOriginMustBeStableAcrossTheWholeRequestedPeriod() = runBlocking {
        val source = Source().apply {
            records = listOf(measurement("a", "scale.a", date, 72.0), measurement("b", "scale.b", date.plusDays(1), 80.0))
        }
        val result = read(source, HealthMetric.WEIGHT, listOf(date, date.plusDays(1)), MetricSourcePolicy.SingleOrigin(null))
        assertTrue(result.all { it.availability == MetricAvailability.SOURCE_AMBIGUOUS && !it.readComplete })
    }

    @Test fun sleepEndingTomorrowDoesNotContributeToTodaysMetadata() = runBlocking {
        val source = Source().apply {
            records = listOf(sleep("tomorrow", "writer", "2026-09-25T23:00:00Z", "2026-09-26T07:00:00Z"))
        }
        val result = read(source, HealthMetric.SLEEP_DURATION).single()
        assertEquals(MetricAvailability.NO_DATA, result.availability)
        assertTrue(result.origins.isEmpty())
        assertEquals(0, result.sampleCount)
        assertNull(result.observedAt)
    }

    @Test fun sleepOriginDiscoveryExcludesSessionsEndingOutsideRequestedDates() = runBlocking {
        val source = Source().apply {
            records = listOf(
                sleep("today", "writer.a", "2026-09-25T01:00:00Z", "2026-09-25T07:00:00Z"),
                sleep("tomorrow", "writer.b", "2026-09-25T23:00:00Z", "2026-09-26T07:00:00Z"),
            )
        }
        val result = read(source, HealthMetric.SLEEP_DURATION).single()
        assertEquals(MetricAvailability.AVAILABLE, result.availability)
        assertEquals(setOf("writer.a"), result.origins)
        assertEquals(1, result.sampleCount)
    }

    @Test(expected = CancellationException::class)
    fun cancellationEscapesTheRepository() = runBlocking {
        val source = Source().apply { failure = CancellationException("cancelled") }
        read(source, HealthMetric.WEIGHT)
        Unit
    }

    @Test fun readAtAndProvisionalStateAreDeterminedAtCompletion() = runBlocking {
        clock.now = Instant.parse("2026-09-25T23:59:59.999123456Z")
        val source = Source().apply {
            aggregateSample = AggregateSample(12.0, setOf("writer"))
            onRead = { clock.now = Instant.parse("2026-09-26T00:00:01.123456789Z") }
        }
        val result = read(source, HealthMetric.STEPS, policy = MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(Instant.parse("2026-09-26T00:00:01.123Z"), result.readAt)
        assertFalse(result.provisional)
    }

    @Test fun invalidAggregateValuesAreIncompleteErrorsRatherThanNormalizedSuccess() = runBlocking {
        for ((metric, value) in listOf(
            HealthMetric.DISTANCE to -5.0, HealthMetric.STEPS to 3.9, HealthMetric.ACTIVE_ENERGY to Double.NaN,
            HealthMetric.STEPS to 9_007_199_254_740_992.0, HealthMetric.TOTAL_ENERGY to Double.POSITIVE_INFINITY,
        )) {
            val source = Source().apply { aggregateSample = AggregateSample(value, setOf("writer")) }
            val result = read(source, metric, policy = MetricSourcePolicy.PlatformAggregate).single()
            assertEquals(MetricAvailability.READ_ERROR, result.availability)
            assertFalse(result.readComplete)
            assertNull(result.value)
        }
    }

    @Test fun invalidNewestWeightIsNotSilentlyReplacedByAnOlderValue() = runBlocking {
        val source = Source().apply {
            records = listOf(measurement("a", "writer", date, 72.0), measurement("b", "writer", date, Double.NaN).copy(start = date.atTime(1, 0).toInstant(zone)))
        }
        assertEquals(MetricAvailability.READ_ERROR, read(source, HealthMetric.WEIGHT).single().availability)
    }

    @Test fun weightTiesUseModificationTimeThenStableIdRegardlessOfPageOrder() = runBlocking {
        val old = measurement("z", "writer", date, 72.0).copy(lastModifiedAt = Instant.parse("2026-09-25T01:00:00Z"))
        val newer = measurement("a", "writer", date, 73.0).copy(lastModifiedAt = Instant.parse("2026-09-25T02:00:00Z"))
        for (records in listOf(listOf(old, newer), listOf(newer, old))) {
            val result = read(Source().apply { this.records = records }, HealthMetric.WEIGHT).single()
            assertEquals(73.0, result.value!!, 0.0)
        }
        val sameModified = newer.copy(id = "b", value = 74.0)
        assertEquals(74.0, read(Source().apply { records = listOf(sameModified, newer) }, HealthMetric.WEIGHT).single().value!!, 0.0)
    }

    @Test fun duplicateIdsAreCountedOnceAndKeepTheLatestModification() = runBlocking {
        val old = measurement("same", "writer", date, 72.0)
        val updated = old.copy(value = 73.0, lastModifiedAt = Instant.parse("2026-09-25T01:00:00Z"))
        val result = read(Source().apply { records = listOf(old, updated, updated) }, HealthMetric.WEIGHT).single()
        assertEquals(73.0, result.value!!, 0.0)
        assertEquals(1, result.sampleCount)
    }

    @Test fun selectedMissingOriginStaysEmptyRatherThanFallingBack() = runBlocking {
        val source = Source().apply { records = listOf(measurement("other", "writer.b", date, 80.0)) }
        val result = read(source, HealthMetric.WEIGHT, policy = MetricSourcePolicy.SingleOrigin("writer.a")).single()
        assertEquals(MetricAvailability.NO_DATA, result.availability)
        assertEquals(0, result.sampleCount)
        assertTrue(result.origins.isEmpty())
    }

    @Test fun sleepAtMidnightBelongsToTheDateOnWhichItEndsAndKeepsFullDuration() = runBlocking {
        val source = Source().apply {
            records = listOf(sleep("boundary", "writer", "2026-09-24T20:00:00Z", "2026-09-25T00:00:00Z"))
        }
        val result = read(source, HealthMetric.SLEEP_DURATION, listOf(date.minusDays(1), date))
        assertEquals(MetricAvailability.NO_DATA, result[0].availability)
        assertEquals(4 * 3600.0, result[1].value!!, 0.0)
    }

    @Test fun sleepUnionRoundsOnlyAfterSummingSubMillisecondIntervals() = runBlocking {
        val source = Source().apply {
            records = listOf(
                sleep("a", "writer", "2026-09-25T01:00:00Z", "2026-09-25T01:00:00.0004Z"),
                sleep("b", "writer", "2026-09-25T02:00:00Z", "2026-09-25T02:00:00.0004Z"),
            )
        }
        assertEquals(0.001, read(source, HealthMetric.SLEEP_DURATION).single().value!!, 0.0)
    }

    @Test fun restrictedAndUnknownHistoryNeverBecomeCompleteEmptySnapshots() = runBlocking {
        val source = Source()
        val restricted = read(source, HealthMetric.STEPS, listOf(LocalDate.parse("2026-07-01")), MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.HISTORY_RESTRICTED, restricted.availability)
        assertFalse(restricted.readComplete)
        assertEquals(0, source.aggregateCalls)
        source.grantWindow = FirstGrantWindow(Instant.parse("2026-08-01T00:00:00Z"), Instant.parse("2026-09-01T00:00:00Z"))
        val uncertain = read(source, HealthMetric.STEPS, listOf(LocalDate.parse("2026-07-15")), MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.READ_ERROR, uncertain.availability)
        assertFalse(uncertain.readComplete)
        assertEquals(0, source.aggregateCalls)
    }

    @Test fun historyGrantAllowsOldDaysAndGenericSecurityFailureIsNotRevocation() = runBlocking {
        val source = Source().apply { historyGranted = true }
        assertEquals(MetricAvailability.NO_DATA, read(source, HealthMetric.WEIGHT, listOf(LocalDate.parse("2018-01-01"))).single().availability)
        source.failure = SecurityException("restricted or changed provider")
        assertEquals(MetricAvailability.READ_ERROR, read(source, HealthMetric.WEIGHT).single().availability)
        source.permitted = false
        assertEquals(MetricAvailability.PERMISSION_DENIED, read(source, HealthMetric.WEIGHT).single().availability)
    }

    @Test fun invalidMixedRestingHeartRateDoesNotPublishAFilteredMean() = runBlocking {
        val source = Source().apply { records = listOf(measurement("a", "writer", date, 60.0), measurement("b", "writer", date, Double.NaN)) }
        assertEquals(MetricAvailability.READ_ERROR, read(source, HealthMetric.RESTING_HEART_RATE).single().availability)
    }

    @Test fun roundingCannotTurnPositiveWeightIntoAnAvailableZero() = runBlocking {
        val source = Source().apply { records = listOf(measurement("tiny", "writer", date, 0.0001)) }
        assertEquals(MetricAvailability.READ_ERROR, read(source, HealthMetric.WEIGHT).single().availability)
    }

    @Test fun emptyAggregateDiscardsUnusedOriginMetadata() = runBlocking {
        val source = Source().apply { aggregateSample = AggregateSample(null, setOf("unused"), 4) }
        val result = read(source, HealthMetric.DISTANCE, policy = MetricSourcePolicy.PlatformAggregate).single()
        assertEquals(MetricAvailability.NO_DATA, result.availability)
        assertTrue(result.origins.isEmpty())
        assertNull(result.sampleCount)
    }

    private suspend fun read(source: Source, metric: HealthMetric, dates: List<LocalDate> = listOf(date), policy: MetricSourcePolicy = MetricSourcePolicy.SingleOrigin(null)) =
        DefaultHealthConnectRepository(source, clock).readSnapshot(metric, dates, zone, policy)

    private fun measurement(id: String, origin: String, day: LocalDate, value: Double) =
        HealthRecordSample(id, origin, day.atStartOfDay(zone).toInstant(), day.atStartOfDay(zone).toInstant(), value)

    private fun sleep(id: String, origin: String, start: String, end: String) =
        HealthRecordSample(id, origin, Instant.parse(start), Instant.parse(end))

    private class MutableClock(var now: Instant) : Clock() {
        override fun instant() = now
        override fun getZone(): ZoneId = ZoneOffset.UTC
        override fun withZone(zone: ZoneId): Clock = this
    }

    private class Source : HealthConnectDataSource {
        var records = emptyList<HealthRecordSample>()
        var aggregateSample = AggregateSample(null, emptySet())
        var failure: Exception? = null
        var onRead: () -> Unit = {}
        var aggregateCalls = 0
        var permitted = true
        var historyGranted = false
        var grantWindow = FirstGrantWindow(Instant.parse("2026-08-01T00:00:00Z"), Instant.parse("2026-08-01T00:00:00Z"))
        override suspend fun supports(metric: HealthMetric) = true
        override suspend fun hasReadPermission(metric: HealthMetric) = permitted
        override suspend fun hasHistoryReadPermission() = false
        override suspend fun readAccess(metric: HealthMetric) = HealthReadAccess(
            permitted, historyGranted, grantWindow,
        )
        override suspend fun aggregate(metric: HealthMetric, start: Instant, end: Instant, originPackage: String?): AggregateSample {
            aggregateCalls++
            failure?.let { throw it }
            onRead()
            return aggregateSample
        }
        override suspend fun readRecords(metric: HealthMetric, start: Instant, end: Instant): List<HealthRecordSample> {
            failure?.let { throw it }
            onRead()
            return records.filter {
                val time = if (metric == HealthMetric.SLEEP_DURATION) it.end else it.start
                time >= start && time < end
            }
        }
    }
}
