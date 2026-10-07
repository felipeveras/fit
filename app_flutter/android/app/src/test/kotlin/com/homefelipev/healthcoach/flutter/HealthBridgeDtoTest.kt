package com.homefelipev.healthcoach.flutter

import com.homefelipev.healthcoach.data.healthconnect.*
import java.time.Instant
import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

class HealthBridgeDtoTest {
    @Test fun wireFormatPreservesNullCoverageOriginAndUnits() {
        for (availability in MetricAvailability.entries) {
            val available = availability == MetricAvailability.AVAILABLE
            val snapshot = HealthMetricSnapshot(
                localDate = LocalDate.parse("2026-10-06"), metric = HealthMetric.STEPS,
                analysisTimezone = "America/Sao_Paulo", availability = availability,
                value = if (available) 0.0 else null, unit = "count",
                periodStartAt = Instant.parse("2026-10-06T03:00:00Z"),
                periodEndAt = Instant.parse("2026-10-07T03:00:00Z"),
                origins = if (available) setOf("producer") else emptySet(),
                sampleCount = if (available) 1 else null, observedAt = null,
                readAt = Instant.parse("2026-10-06T12:00:00Z"),
                readComplete = availability in setOf(MetricAvailability.AVAILABLE, MetricAvailability.NO_DATA),
                provisional = true, aggregationMethod = "hc_aggregate_total_v1",
                configVersion = 1, mappingVersion = 1, sourcePolicyVersion = 1,
            )
            val dto = HealthBridgeDto.snapshot(snapshot)
            assertEquals(availability.name.lowercase(), dto["availability"])
            assertEquals("steps", dto["metric"])
            assertEquals(snapshot.value, dto["value"])
            assertEquals(snapshot.readComplete, dto["readComplete"])
            assertEquals(snapshot.origins.toList(), dto["origins"])
            assertEquals("America/Sao_Paulo", dto["timezone"])
            assertEquals("2026-10-06T03:00:00Z", dto["periodStartAt"])
            assertEquals(1, dto["mappingVersion"])
        }
    }
}
