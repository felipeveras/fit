package com.homefelipev.healthcoach.data.healthconnect

import java.math.BigDecimal
import java.math.RoundingMode
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.CancellationException

interface HealthConnectRepository {
    suspend fun readSnapshot(
        metric: HealthMetric,
        dates: List<LocalDate>,
        analysisZone: ZoneId,
        sourcePolicy: MetricSourcePolicy,
        configVersion: Int = 1,
        mappingVersion: Int = 1,
        sourcePolicyVersion: Int = 1,
    ): List<HealthMetricSnapshot>
}

interface HealthConnectDataSource {
    suspend fun hasReadPermission(metric: HealthMetric): Boolean
    suspend fun hasHistoryReadPermission(): Boolean
    suspend fun supports(metric: HealthMetric): Boolean
    suspend fun readAccess(metric: HealthMetric): HealthReadAccess
    suspend fun aggregate(metric: HealthMetric, start: Instant, end: Instant, originPackage: String? = null): AggregateSample
    /** Complete, paginated observations attributed to [start,end); sleep is attributed by END. */
    suspend fun readRecords(metric: HealthMetric, start: Instant, end: Instant): List<HealthRecordSample>
}

data class AggregateSample(val value: Double?, val origins: Set<String>, val sampleCount: Int? = null)

data class HealthRecordSample(
    val id: String,
    val origin: String,
    val start: Instant,
    val end: Instant,
    val value: Double? = null,
    val lastModifiedAt: Instant = Instant.EPOCH,
)

class DefaultHealthConnectRepository(
    private val source: HealthConnectDataSource,
    private val clock: Clock = Clock.systemUTC(),
) : HealthConnectRepository {
    override suspend fun readSnapshot(
        metric: HealthMetric,
        dates: List<LocalDate>,
        analysisZone: ZoneId,
        sourcePolicy: MetricSourcePolicy,
        configVersion: Int,
        mappingVersion: Int,
        sourcePolicyVersion: Int,
    ): List<HealthMetricSnapshot> {
        require(configVersion > 0 && mappingVersion > 0 && sourcePolicyVersion > 0)
        val requested = dates.distinct().sorted()
        if (requested.isEmpty()) return emptyList()
        fun start(date: LocalDate) = date.atStartOfDay(analysisZone).toInstant()
        fun end(date: LocalDate) = date.plusDays(1).atStartOfDay(analysisZone).toInstant()
        fun snapshot(date: LocalDate, reading: Reading): HealthMetricSnapshot {
            val finished = clock.instant().truncatedTo(ChronoUnit.MILLIS)
            return HealthMetricSnapshot(
                localDate = date, metric = metric, analysisTimezone = analysisZone.id,
                availability = reading.availability, value = reading.value, unit = metric.unit,
                periodStartAt = start(date), periodEndAt = end(date), origins = reading.origins,
                sampleCount = reading.count, observedAt = reading.observedAt?.truncatedTo(ChronoUnit.MILLIS),
                readAt = finished,
                readComplete = reading.availability in setOf(MetricAvailability.AVAILABLE, MetricAvailability.NO_DATA),
                provisional = date >= finished.atZone(analysisZone).toLocalDate(),
                aggregationMethod = metric.aggregationMethod, configVersion = configVersion,
                mappingVersion = mappingVersion, sourcePolicyVersion = sourcePolicyVersion,
                qualityFlags = reading.flags,
            )
        }

        val access = try {
            if (!source.supports(metric)) return requested.map { snapshot(it, Reading(MetricAvailability.UNSUPPORTED)) }
            source.readAccess(metric)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return requested.map { snapshot(it, Reading(MetricAvailability.READ_ERROR)) }
        }
        val impediments = requested.associateWith { access.impediment(start(it)) }
        val readable = requested.filter { impediments[it] == null }

        if (metric.isPlatformAggregated) {
            val origin = (sourcePolicy as? MetricSourcePolicy.SingleOrigin)?.packageName
            // Pending single-origin policies must discover the entire requested period first.
            val readings = readable.associateWith { date ->
                try {
                    val aggregate = source.aggregate(metric, start(date), end(date), origin)
                    require(aggregate.sampleCount == null || aggregate.sampleCount >= 0)
                    if (aggregate.value == null) Reading(MetricAvailability.NO_DATA)
                    else Reading(MetricAvailability.AVAILABLE, normalize(metric, aggregate.value), aggregate.origins, aggregate.sampleCount)
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: SecurityException) { Reading(failureAvailability(metric)) }
                catch (_: Exception) { Reading(MetricAvailability.READ_ERROR) }
            }
            val origins = readings.values.flatMap { it.origins }.toSet()
            val incomplete = readings.values.any { it.availability !in setOf(MetricAvailability.AVAILABLE, MetricAvailability.NO_DATA) }
            return requested.map { date ->
                val reading = impediments[date]?.let { Reading(it) } ?: readings.getValue(date)
                val resolved = if (sourcePolicy is MetricSourcePolicy.SingleOrigin && origin == null && reading.value != null) {
                    when {
                        origins.size > 1 -> Reading(MetricAvailability.SOURCE_AMBIGUOUS, origins = origins)
                        incomplete -> Reading(MetricAvailability.READ_ERROR)
                        else -> reading
                    }
                } else reading
                snapshot(date, resolved)
            }
        }

        // One complete read: a failed page cannot publish daily replacements from partial records.
        val records = try {
            if (readable.isEmpty()) emptyList()
            else source.readRecords(metric, start(readable.first()), end(readable.last()))
                .groupBy(HealthRecordSample::id).values.map { duplicates ->
                    duplicates.maxWith(compareBy(HealthRecordSample::lastModifiedAt, HealthRecordSample::start, HealthRecordSample::id))
                }
                .filter { record -> recordDate(metric, record, analysisZone) in readable }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            val availability = if (failure is SecurityException) failureAvailability(metric) else MetricAvailability.READ_ERROR
            return requested.map { snapshot(it, Reading(impediments[it] ?: availability)) }
        }
        val origins = records.map(HealthRecordSample::origin).toSet()
        val preferred = (sourcePolicy as? MetricSourcePolicy.SingleOrigin)?.packageName
        val selectedOrigin = preferred ?: origins.singleOrNull()
        return requested.map { date ->
            val impediment = impediments[date]
            if (impediment != null) snapshot(date, Reading(impediment))
            else {
                val daily = records.filter { recordDate(metric, it, analysisZone) == date }
                val reading = when {
                    daily.isEmpty() -> Reading(MetricAvailability.NO_DATA, count = 0)
                    preferred == null && origins.size > 1 -> Reading(MetricAvailability.SOURCE_AMBIGUOUS, origins = origins)
                    else -> try { mapRecords(metric, daily.filter { it.origin == selectedOrigin }) }
                    catch (_: IllegalArgumentException) { Reading(MetricAvailability.READ_ERROR, flags = setOf("invalid_measurement")) }
                }
                snapshot(date, reading)
            }
        }
    }

    private suspend fun failureAvailability(metric: HealthMetric): MetricAvailability = try {
        // A security failure with a still-granted metric is not evidence of revocation.
        if (source.hasReadPermission(metric)) MetricAvailability.READ_ERROR else MetricAvailability.PERMISSION_DENIED
    } catch (cancelled: CancellationException) { throw cancelled }
    catch (_: Exception) { MetricAvailability.READ_ERROR }

    private fun recordDate(metric: HealthMetric, record: HealthRecordSample, zone: ZoneId) =
        (if (metric == HealthMetric.SLEEP_DURATION) record.end else record.start).atZone(zone).toLocalDate()

    private fun mapRecords(metric: HealthMetric, selected: List<HealthRecordSample>): Reading {
        if (selected.isEmpty()) return Reading(MetricAvailability.NO_DATA, count = 0)
        require(selected.all { it.id.isNotEmpty() && it.origin.isNotEmpty() })
        val value: Double
        val observed: Instant
        val flags: Set<String>
        when (metric) {
            HealthMetric.SLEEP_DURATION -> {
                require(selected.all { it.end > it.start })
                var mergedEnd: Instant? = null
                var seconds = BigDecimal.ZERO
                selected.sortedBy(HealthRecordSample::start).forEach { session ->
                    val from = mergedEnd?.let { maxOf(session.start, it) } ?: session.start
                    if (session.end > from) {
                        val duration = Duration.between(from, session.end)
                        seconds += BigDecimal.valueOf(duration.seconds).add(BigDecimal.valueOf(duration.nano.toLong(), 9))
                    }
                    mergedEnd = maxOf(mergedEnd ?: session.end, session.end)
                }
                value = seconds.setScale(3, RoundingMode.HALF_UP).toDouble()
                observed = selected.maxOf(HealthRecordSample::end)
                flags = setOf("session_duration_proxy")
            }
            HealthMetric.RESTING_HEART_RATE -> {
                require(selected.all { it.value != null && it.value.isFinite() && it.value >= 0.0 })
                value = selected.map { it.value!! }.average()
                observed = selected.maxOf(HealthRecordSample::start)
                flags = emptySet()
            }
            HealthMetric.WEIGHT -> {
                require(selected.all { it.value != null && it.value.isFinite() && it.value > 0.0 })
                val last = selected.maxWith(compareBy(HealthRecordSample::start, HealthRecordSample::lastModifiedAt, HealthRecordSample::id))
                value = last.value!!
                observed = last.start
                flags = emptySet()
            }
            else -> error("$metric requires aggregation")
        }
        return Reading(MetricAvailability.AVAILABLE, normalize(metric, value), selected.map { it.origin }.toSet(), selected.size, observed, flags)
    }

    private fun normalize(metric: HealthMetric, value: Double): Double {
        require(value.isFinite() && value >= 0.0)
        if (metric == HealthMetric.STEPS) {
            require(value <= 9_007_199_254_740_991.0 && value == kotlin.math.floor(value))
            return value
        }
        val normalized = BigDecimal.valueOf(value).setScale(3, RoundingMode.HALF_UP).toDouble()
        require(metric != HealthMetric.WEIGHT || normalized > 0.0)
        return normalized
    }

    private data class Reading(
        val availability: MetricAvailability,
        val value: Double? = null,
        val origins: Set<String> = emptySet(),
        val count: Int? = null,
        val observedAt: Instant? = null,
        val flags: Set<String> = emptySet(),
    )
}
