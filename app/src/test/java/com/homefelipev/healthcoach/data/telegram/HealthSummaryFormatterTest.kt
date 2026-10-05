package com.homefelipev.healthcoach.data.telegram

import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricAvailability
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthSummaryFormatterTest {
    private val day = LocalDate.parse("2026-10-05")

    @Test
    fun rendersOnlyAvailableMetricsInHumanOrder() {
        val message = HealthSummaryFormatter.format(day, listOf(
            snapshot(HealthMetric.WEIGHT, 85.4),
            snapshot(HealthMetric.STEPS, 9842.0),
            snapshot(HealthMetric.SLEEP_DURATION, 7 * 3600.0 + 18 * 60.0),
            snapshot(HealthMetric.RESTING_HEART_RATE, 57.0),
            snapshot(HealthMetric.ACTIVE_ENERGY, 684.0),
            snapshot(HealthMetric.DISTANCE, 7200.0),
        ))
        assertEquals(
            """
            📊 App Fit — 05/10/2026
            ⚖️ Peso: 85,4 kg
            👟 Passos: 9.842
            😴 Sono: 7h18
            ❤️ FC repouso: 57 bpm
            🔥 Calorias ativas: 684 kcal
            📏 Distância: 7,2 km
            """.trimIndent(),
            message,
        )
    }

    @Test
    fun includesTotalEnergyWhenAvailable() {
        val message = HealthSummaryFormatter.format(day, listOf(snapshot(HealthMetric.TOTAL_ENERGY, 2310.0)))
        assertTrue(message.contains("⚡ Calorias totais: 2.310 kcal"))
    }

    @Test
    fun observedZeroIsShownWhileNoDataAndIncompleteReadsAreOmitted() {
        val message = HealthSummaryFormatter.format(day, listOf(
            snapshot(HealthMetric.STEPS, 0.0),
            snapshot(HealthMetric.WEIGHT, null, MetricAvailability.NO_DATA),
            snapshot(HealthMetric.ACTIVE_ENERGY, null, MetricAvailability.READ_ERROR),
            snapshot(HealthMetric.DISTANCE, null, MetricAvailability.PERMISSION_DENIED),
        ))
        assertTrue(message.contains("👟 Passos: 0"))
        assertFalse(message.contains("Peso"))
        assertFalse(message.contains("Calorias ativas"))
        assertFalse(message.contains("Distância"))
    }

    @Test
    fun reportsMissingMetricsWhenNothingIsAvailable() {
        val message = HealthSummaryFormatter.format(day, listOf(
            snapshot(HealthMetric.STEPS, null, MetricAvailability.PERMISSION_DENIED),
        ))
        assertEquals("📊 App Fit — 05/10/2026\nNenhuma métrica disponível.", message)
    }

    private fun snapshot(
        metric: HealthMetric,
        value: Double?,
        availability: MetricAvailability = if (value == null) MetricAvailability.NO_DATA else MetricAvailability.AVAILABLE,
    ): HealthMetricSnapshot {
        val complete = availability == MetricAvailability.AVAILABLE || availability == MetricAvailability.NO_DATA
        return HealthMetricSnapshot(
            localDate = day, metric = metric, analysisTimezone = "America/Sao_Paulo",
            availability = availability, value = value, unit = metric.unit,
            periodStartAt = day.atStartOfDay(ZoneOffset.UTC).toInstant(),
            periodEndAt = day.plusDays(1).atStartOfDay(ZoneOffset.UTC).toInstant(),
            origins = if (value == null) emptySet() else setOf("example.writer"),
            sampleCount = if (value == null) 0 else 1,
            observedAt = if (value == null) null else Instant.parse("2026-10-05T12:00:00Z"),
            readAt = Instant.parse("2026-10-05T13:00:00Z"), readComplete = complete,
            provisional = true, aggregationMethod = metric.aggregationMethod,
            configVersion = 1, mappingVersion = 1, sourcePolicyVersion = 1,
        )
    }
}
