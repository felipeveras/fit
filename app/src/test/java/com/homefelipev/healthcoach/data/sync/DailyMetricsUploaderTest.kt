package com.homefelipev.healthcoach.data.sync

import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricAvailability
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE)
class DailyMetricsUploaderTest {
    private val day = LocalDate.parse("2026-09-28")

    @Test
    fun recentWindowIncludesTodayAndSixPreviousDates() {
        assertEquals(7, reconciliationDates(day).size)
        assertEquals(LocalDate.parse("2026-09-22"), reconciliationDates(day).first())
        assertEquals(day, reconciliationDates(day).last())
    }

    @Test
    fun upsertUsesOwnerScopedKeyAndReplacesLateValues() = runBlocking {
        val http = RecordingHttp()
        val uploader = DailyMetricsUploader(http)
        uploader.upsert("user-a", "token", listOf(snapshot(100.0)))
        uploader.upsert("user-a", "token", listOf(snapshot(90.0)))

        assertEquals(2, http.calls.size)
        http.calls.forEach { call ->
            assertEquals("POST", call.method)
            assertEquals("/rest/v1/daily_metrics?on_conflict=user_id,local_date,metric", call.path)
            assertEquals("api", call.headers["Content-Profile"])
            assertEquals("resolution=merge-duplicates,return=minimal", call.headers["Prefer"])
            assertEquals("token", call.token)
            val row = JSONArray(call.body).getJSONObject(0)
            assertEquals("user-a", row.getString("user_id"))
            assertEquals("2026-09-28", row.getString("local_date"))
            assertEquals("steps", row.getString("metric"))
            assertEquals("America/Sao_Paulo", row.getString("analysis_timezone"))
        }
        assertEquals(100.0, JSONArray(http.calls[0].body).getJSONObject(0).getDouble("value"), 0.0)
        assertEquals(90.0, JSONArray(http.calls[1].body).getJSONObject(0).getDouble("value"), 0.0)
    }

    @Test
    fun noDataWritesNullButIncompleteReadsNeverEnterPayload() = runBlocking {
        val http = RecordingHttp()
        val uploader = DailyMetricsUploader(http)
        uploader.upsert("user-a", "token", listOf(snapshot(null)))
        val row = JSONArray(http.calls.single().body).getJSONObject(0)
        assertEquals("no_data", row.getString("availability"))
        assertTrue(row.isNull("value"))
        assertTrue(row.getBoolean("is_provisional"))

        try {
            uploader.upsert("user-a", "token", listOf(snapshot(null, MetricAvailability.READ_ERROR)))
            throw AssertionError("Expected incomplete snapshot to be rejected")
        } catch (_: IllegalArgumentException) {
            assertEquals(1, http.calls.size)
        }
    }

    @Test
    fun duplicateMetricDateInOneBatchIsRejected() = runBlocking {
        val http = RecordingHttp()
        try {
            DailyMetricsUploader(http).upsert("user-a", "token", listOf(snapshot(100.0), snapshot(90.0)))
            throw AssertionError("Expected duplicate to be rejected")
        } catch (_: IllegalArgumentException) {
            assertTrue(http.calls.isEmpty())
        }
    }

    private fun snapshot(value: Double?, availability: MetricAvailability =
        if (value == null) MetricAvailability.NO_DATA else MetricAvailability.AVAILABLE): HealthMetricSnapshot {
        val complete = availability == MetricAvailability.AVAILABLE || availability == MetricAvailability.NO_DATA
        return HealthMetricSnapshot(
            localDate = day, metric = HealthMetric.STEPS, analysisTimezone = "America/Sao_Paulo",
            availability = availability, value = value, unit = "count",
            periodStartAt = day.atStartOfDay(ZoneOffset.UTC).toInstant(),
            periodEndAt = day.plusDays(1).atStartOfDay(ZoneOffset.UTC).toInstant(),
            origins = if (value == null) emptySet() else setOf("example.writer"),
            sampleCount = if (value == null) 0 else 1,
            observedAt = if (value == null) null else Instant.parse("2026-09-28T12:00:00Z"),
            readAt = Instant.parse("2026-09-28T13:00:00Z"), readComplete = complete,
            provisional = true, aggregationMethod = HealthMetric.STEPS.aggregationMethod,
            configVersion = 1, mappingVersion = 1, sourcePolicyVersion = 1,
        )
    }

    private data class Call(val path: String, val method: String, val body: String,
        val token: String?, val headers: Map<String, String>)

    private class RecordingHttp : SupabaseHttp() {
        val calls = mutableListOf<Call>()
        override suspend fun request(path: String, method: String, body: String?, accessToken: String?,
            headers: Map<String, String>): String {
            calls += Call(path, method, body.orEmpty(), accessToken, headers)
            return ""
        }
    }
}
