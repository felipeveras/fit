package com.homefelipev.healthcoach.flutter

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.homefelipev.healthcoach.data.healthconnect.*
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class ExerciseSample(val id: String, val origin: String, val start: Instant,
    val end: Instant, val modified: Instant, val type: Int, val running: Boolean)
data class ExercisePage(val records: List<ExerciseSample>, val next: String?)

interface ExerciseSource {
    fun provider(): ProviderState
    suspend fun access(): HealthReadAccess
    suspend fun page(start: Instant, end: Instant, token: String?, origin: String?): ExercisePage
}

class AndroidExerciseSource(private val gateway: AndroidHealthConnectGateway,
    private val grants: FirstGrantTracker) : ExerciseSource {
    override fun provider() = gateway.providerState()
    override suspend fun access(): HealthReadAccess {
        val granted = gateway.grantedPermissions()
        return HealthReadAccess(permission in granted,
            gateway.capabilities(granted).history == CapabilityState.AVAILABLE_AND_GRANTED,
            grants.observe(permission in granted || granted.any { it in HealthConnectPermissions.dataRead }))
    }
    override suspend fun page(start: Instant, end: Instant, token: String?, origin: String?): ExercisePage {
        val response = gateway.client().readRecords(ReadRecordsRequest(
            recordType = ExerciseSessionRecord::class,
            timeRangeFilter = TimeRangeFilter.between(start, end),
            dataOriginFilter = origin?.let { setOf(DataOrigin(it)) } ?: emptySet(),
            pageSize = 1000, pageToken = token))
        return ExercisePage(response.records.map {
            ExerciseSample(it.metadata.id, it.metadata.dataOrigin.packageName, it.startTime,
                it.endTime, it.metadata.lastModifiedTime, it.exerciseType,
                it.exerciseType == ExerciseSessionRecord.EXERCISE_TYPE_RUNNING ||
                    it.exerciseType == ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL)
        }, response.pageToken)
    }
    companion object {
        val permission = HealthPermission.getReadPermission(ExerciseSessionRecord::class)
    }
}

/** Completeness is per local start day. A failed page invalidates the entire readable batch. */
class HealthExerciseReader(private val source: ExerciseSource,
    private val clock: Clock = Clock.systemUTC()) {
    suspend fun read(days: Int, zone: ZoneId, origin: String? = null): Map<String, Any?> {
        require(days in setOf(1, 7, 30, 90))
        require(origin == null || origin.isNotBlank())
        val now = clock.instant()
        val today = now.atZone(zone).toLocalDate()
        val dates = (0 until days).map { today.minusDays(it.toLong()) }
        val states = linkedMapOf<LocalDate, MetricAvailability?>()
        var samples = emptyList<ExerciseSample>()
        try {
            if (source.provider() != ProviderState.AVAILABLE) {
                dates.forEach { states[it] = MetricAvailability.UNSUPPORTED }
            } else {
                val access = source.access()
                dates.forEach { states[it] = access.impediment(it.atStartOfDay(zone).toInstant()) }
                val readable = dates.filter { states[it] == null }
                if (readable.isNotEmpty()) {
                    val start = readable.minOrNull()!!.atStartOfDay(zone).toInstant()
                    val end = today.plusDays(1).atStartOfDay(zone).toInstant()
                    val records = mutableListOf<ExerciseSample>()
                    val tokens = mutableSetOf<String>()
                    var token: String? = null
                    do {
                        currentCoroutineContext().ensureActive()
                        val page = source.page(start, end, token, origin)
                        records += page.records
                        token = page.next?.takeIf { it.isNotEmpty() }
                        check(token == null || tokens.add(token)) { "Repeated page token" }
                    } while (token != null)
                    // Reject malformed identities rather than manufacturing deduplication keys.
                    records.forEach { check(it.id.isNotBlank() && it.origin.isNotBlank() && it.start < it.end) }
                    samples = records.groupBy { it.origin to it.id }.values.map { versions ->
                        versions.maxWith(compareBy<ExerciseSample> { it.modified }
                            .thenBy { it.start }.thenBy { it.end }.thenBy { it.type })
                    }.filter {
                        it.start >= start && it.start < end && it.end <= now &&
                            (origin == null || it.origin == origin)
                    }.sortedWith(compareBy<ExerciseSample> { it.start }.thenBy { it.origin }.thenBy { it.id })
                }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            samples = emptyList()
            dates.forEach {
                if (states[it] == null) states[it] = if (failure is SecurityException)
                    MetricAvailability.PERMISSION_DENIED else MetricAvailability.READ_ERROR
            }
        }
        val coverage = dates.map { date ->
            val entries = samples.filter { it.start.atZone(zone).toLocalDate() == date }
            val status = states[date] ?: if (entries.isEmpty()) MetricAvailability.NO_DATA else MetricAvailability.AVAILABLE
            mapOf("date" to date.toString(), "availability" to status.name.lowercase(java.util.Locale.ROOT),
                "readComplete" to (states[date] == null), "provisional" to (date == today),
                "origins" to entries.map { it.origin }.distinct().sorted(),
                "errorCode" to when (status) {
                    MetricAvailability.READ_ERROR -> "read_failed_or_history_boundary_uncertain"
                    MetricAvailability.PERMISSION_DENIED -> "exercise_permission_denied"
                    MetricAvailability.UNSUPPORTED -> "provider_unavailable"
                    MetricAvailability.HISTORY_RESTRICTED -> "history_restricted"
                    else -> null
                })
        }
        return mapOf("version" to 1, "days" to days, "timezone" to zone.id, "readAt" to now.toString(),
            "sourcePolicy" to if (origin == null) "all_origins" else "single_origin",
            "originPackage" to origin, "coverage" to coverage, "sessions" to samples.map {
                mapOf("id" to it.id, "origin" to it.origin,
                    "date" to it.start.atZone(zone).toLocalDate().toString(), "startAt" to it.start.toString(),
                    "endAt" to it.end.toString(), "lastModifiedAt" to it.modified.toString(),
                    "exerciseType" to it.type, "isRunning" to it.running)
            })
    }
}
