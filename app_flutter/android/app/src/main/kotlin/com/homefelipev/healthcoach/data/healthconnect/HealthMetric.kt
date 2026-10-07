package com.homefelipev.healthcoach.data.healthconnect

enum class HealthMetric(
    val dataTypeName: String,
    val unit: String,
    val aggregationMethod: String,
    val isPlatformAggregated: Boolean,
) {
    STEPS("StepsRecord", "count", "hc_aggregate_total_v1", true),
    SLEEP_DURATION("SleepSessionRecord", "s", "sleep_session_duration_v1", false),
    RESTING_HEART_RATE("RestingHeartRateRecord", "bpm", "selected_origin_mean_v1", false),
    ACTIVE_ENERGY("ActiveCaloriesBurnedRecord", "kcal", "hc_aggregate_total_v1", true),
    TOTAL_ENERGY("TotalCaloriesBurnedRecord", "kcal", "hc_aggregate_total_v1", true),
    DISTANCE("DistanceRecord", "m", "hc_aggregate_total_v1", true),
    WEIGHT("WeightRecord", "kg", "selected_origin_last_v1", false),
}

enum class MetricAvailability {
    AVAILABLE,
    NO_DATA,
    PERMISSION_DENIED,
    HISTORY_RESTRICTED,
    UNSUPPORTED,
    READ_ERROR,
    SOURCE_AMBIGUOUS,
}

sealed interface MetricSourcePolicy {
    data object PlatformAggregate : MetricSourcePolicy
    data class SingleOrigin(val packageName: String?) : MetricSourcePolicy
}

data class HealthMetricSnapshot(
    val localDate: java.time.LocalDate,
    val metric: HealthMetric,
    val analysisTimezone: String,
    val availability: MetricAvailability,
    val value: Double?,
    val unit: String,
    val periodStartAt: java.time.Instant,
    val periodEndAt: java.time.Instant,
    val origins: Set<String>,
    val sampleCount: Int?,
    val observedAt: java.time.Instant?,
    val readAt: java.time.Instant,
    val readComplete: Boolean,
    val provisional: Boolean,
    val aggregationMethod: String,
    val configVersion: Int,
    val mappingVersion: Int,
    val sourcePolicyVersion: Int,
    val qualityFlags: Set<String> = emptySet(),
) {
    init {
        require((availability == MetricAvailability.AVAILABLE) == (value != null)) {
            "Only available snapshots carry a value."
        }
        require(value == null || value.isFinite())
        require(value == null || value >= 0.0)
        require(metric != HealthMetric.WEIGHT || value == null || value > 0.0)
        require(metric != HealthMetric.STEPS || value == null || (value <= 9_007_199_254_740_991.0 && value == kotlin.math.floor(value)))
        require(unit == metric.unit)
        require(periodEndAt > periodStartAt)
        require(sampleCount == null || sampleCount >= 0)
        require(configVersion > 0 && mappingVersion > 0 && sourcePolicyVersion > 0)
        require(readComplete == (availability in setOf(MetricAvailability.AVAILABLE, MetricAvailability.NO_DATA)))
        if (availability == MetricAvailability.NO_DATA) {
            require(origins.isEmpty() && observedAt == null && (sampleCount == null || sampleCount == 0))
        }
    }
}
