package com.homefelipev.healthcoach.flutter

import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import java.util.Locale

object HealthBridgeDto {
    fun snapshot(s: HealthMetricSnapshot): Map<String, Any?> = mapOf(
        "metric" to s.metric.name.lowercase(Locale.ROOT),
        "availability" to s.availability.name.lowercase(Locale.ROOT),
        "value" to s.value, "unit" to s.unit, "localDate" to s.localDate.toString(),
        "timezone" to s.analysisTimezone, "periodStartAt" to s.periodStartAt.toString(),
        "periodEndAt" to s.periodEndAt.toString(), "origins" to s.origins.toList(),
        "sampleCount" to s.sampleCount, "observedAt" to s.observedAt?.toString(),
        "readAt" to s.readAt.toString(), "readComplete" to s.readComplete,
        "provisional" to s.provisional, "aggregationMethod" to s.aggregationMethod,
        "qualityFlags" to s.qualityFlags.toList(), "configVersion" to s.configVersion,
        "mappingVersion" to s.mappingVersion, "sourcePolicyVersion" to s.sourcePolicyVersion,
    )
}
