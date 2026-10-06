package com.homefelipev.healthcoach.flutter

import com.homefelipev.healthcoach.data.healthconnect.*
import java.time.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class HealthExerciseReaderTest {
    private val now = Instant.parse("2026-10-06T15:00:00Z")
    private val zone = ZoneId.of("America/Sao_Paulo")
    private class Source : ExerciseSource {
        var permission = true
        var history = true
        var providerState = ProviderState.AVAILABLE
        var calls = 0
        var fetch: suspend (String?) -> ExercisePage = { ExercisePage(emptyList(), null) }
        override fun provider() = providerState
        override suspend fun access() = HealthReadAccess(permission, history,
            FirstGrantWindow(Instant.parse("2026-10-01T00:00:00Z"), Instant.parse("2026-10-01T00:00:00Z")))
        override suspend fun page(start: Instant, end: Instant, token: String?, origin: String?): ExercisePage {
            calls++
            return fetch(token)
        }
    }
    private fun sample(origin: String = "producer", modified: Instant = now) = ExerciseSample(
        "stable", origin, Instant.parse("2026-10-06T10:00:00Z"),
        Instant.parse("2026-10-06T11:00:00Z"), modified, 56, true)
    private suspend fun read(source: Source, days: Int = 1) =
        HealthExerciseReader(source, Clock.fixed(now, ZoneOffset.UTC)).read(days, zone)
    @Suppress("UNCHECKED_CAST")
    private fun coverage(result: Map<String, Any?>) = result["coverage"] as List<Map<String, Any?>>

    @Test fun deniedExerciseDoesNotReadEvenWithOtherDataAvailable() = runBlocking {
        val source = Source().apply { permission = false }
        assertEquals("permission_denied", coverage(read(source)).single()["availability"])
        assertEquals(0, source.calls)
    }
    @Test fun pagesDeduplicateOnlyWithinOriginAndChooseLatestRevision() = runBlocking {
        val source = Source().apply { fetch = { token ->
            if (token == null) ExercisePage(listOf(sample(modified = now.minusSeconds(60))), "next")
            else ExercisePage(listOf(sample(), sample("other")), "")
        } }
        val result = read(source)
        assertEquals(2, source.calls)
        assertEquals(2, (result["sessions"] as List<*>).size)
        assertEquals("available", coverage(result).single()["availability"])
    }
    @Test fun secondPageFailureDiscardsPartialData() = runBlocking {
        val source = Source().apply { fetch = { token ->
            if (token == null) ExercisePage(listOf(sample()), "next") else error("failure")
        } }
        val result = read(source)
        assertTrue((result["sessions"] as List<*>).isEmpty())
        assertEquals(false, coverage(result).single()["readComplete"])
    }
    @Test fun repeatedTokenCannotPublishPartialData() = runBlocking {
        val source = Source().apply { fetch = { ExercisePage(listOf(sample()), "repeat") } }
        assertEquals("read_error", coverage(read(source)).single()["availability"])
        assertEquals(2, source.calls)
    }
    @Test fun revocationDuringPagingReportsDeniedAndDiscardsSessions() = runBlocking {
        val source = Source().apply { fetch = { token ->
            if (token == null) ExercisePage(listOf(sample()), "next") else throw SecurityException()
        } }
        val result = read(source)
        assertTrue((result["sessions"] as List<*>).isEmpty())
        assertEquals("permission_denied", coverage(result).single()["availability"])
    }
    @Test fun emptyAndUnsupportedAreDistinct() = runBlocking {
        val source = Source()
        assertEquals("no_data", coverage(read(source)).single()["availability"])
        source.providerState = ProviderState.UNAVAILABLE
        assertEquals("unsupported", coverage(read(source)).single()["availability"])
        assertEquals(1, source.calls)
    }
    @Test fun restrictedHistoryDoesNotBecomeZeroOrInvalidateRecentDays() = runBlocking {
        val source = Source().apply { history = false }
        val days = coverage(read(source, 90))
        assertTrue(days.any { it["availability"] == "history_restricted" && it["readComplete"] == false })
        assertEquals("no_data", days.first()["availability"])
    }
    @Test fun overnightSessionUsesStartDayAndFutureSessionIsExcluded() = runBlocking {
        val overnight = sample().copy(start = Instant.parse("2026-10-06T02:00:00Z"),
            end = Instant.parse("2026-10-06T04:00:00Z"))
        val source = Source().apply { fetch = { ExercisePage(listOf(overnight,
            sample().copy(id = "future", end = now.plusSeconds(60))), null) } }
        val result = read(source, 7)
        assertEquals("available", coverage(result)[1]["availability"])
        assertEquals("no_data", coverage(result)[0]["availability"])
        assertEquals(1, (result["sessions"] as List<*>).size)
    }
    @Test fun cancellationPropagates() = runBlocking {
        val source = Source().apply { fetch = { throw CancellationException("detached") } }
        try { read(source); fail("Cancellation swallowed") }
        catch (_: CancellationException) { }
    }
}
