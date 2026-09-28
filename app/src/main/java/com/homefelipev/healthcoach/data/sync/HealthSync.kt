package com.homefelipev.healthcoach.data.sync

import android.content.Context
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectDataSource
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectGateway
import com.homefelipev.healthcoach.data.healthconnect.CapabilityState
import com.homefelipev.healthcoach.data.healthconnect.DefaultHealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthConnectPermissions
import com.homefelipev.healthcoach.data.healthconnect.HealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricAvailability
import com.homefelipev.healthcoach.data.healthconnect.MetricSourcePolicy
import com.homefelipev.healthcoach.data.healthconnect.ProviderState
import java.nio.channels.OverlappingFileLockException
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

enum class SyncOutcome { SUCCESS, PARTIAL, SKIPPED, RETRY, FAILED, BUSY }

data class SyncReport(
    val startedAt: Instant,
    val finishedAt: Instant,
    val periodStart: LocalDate,
    val periodEnd: LocalDate,
    val foundMetrics: Map<String, Int>,
    val uploadedRows: Int,
    val incompleteMetrics: Map<String, String>,
    val ambiguousOrigins: Map<String, Set<String>>,
    val outcome: SyncOutcome,
    val detail: String,
)

/** Today's date and six preceding local dates, inclusive. */
fun reconciliationDates(today: LocalDate): List<LocalDate> = (6L downTo 0L).map(today::minusDays)

class SyncStateStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("health_sync_state", Context.MODE_PRIVATE)
    private fun key(userId: String, suffix: String) = "$userId:$suffix"

    fun origin(userId: String, metric: HealthMetric): String? =
        prefs.getString(key(userId, "origin:${metric.name}"), null)

    fun selectOrigin(userId: String, metric: HealthMetric, packageName: String) {
        require(!metric.isPlatformAggregated && packageName.isNotBlank())
        prefs.edit().putString(key(userId, "origin:${metric.name}"), packageName).apply()
    }

    fun consented(userId: String): Boolean = prefs.getBoolean(key(userId, "sync_consent"), false)

    fun setConsent(userId: String, allowed: Boolean) {
        prefs.edit().putBoolean(key(userId, "sync_consent"), allowed).commit()
    }

    fun save(userId: String, report: SyncReport) {
        val json = JSONObject()
            .put("started_at", report.startedAt.toString())
            .put("finished_at", report.finishedAt.toString())
            .put("period_start", report.periodStart.toString())
            .put("period_end", report.periodEnd.toString())
            .put("found", JSONObject(report.foundMetrics))
            .put("uploaded", report.uploadedRows)
            .put("incomplete", JSONObject(report.incompleteMetrics))
            .put("outcome", report.outcome.name)
            .put("detail", report.detail)
        val ambiguous = JSONObject()
        report.ambiguousOrigins.forEach { (metric, origins) ->
            ambiguous.put(metric, JSONArray(origins.sorted()))
        }
        json.put("ambiguous", ambiguous)
        prefs.edit().putString(key(userId, "report"), json.toString()).apply()
    }

    fun report(userId: String): SyncReport? = try {
        val json = JSONObject(prefs.getString(key(userId, "report"), null) ?: return null)
        fun stringMap(name: String) = json.getJSONObject(name).let { obj ->
            obj.keys().asSequence().associateWith(obj::getString)
        }
        val found = json.getJSONObject("found").let { obj ->
            obj.keys().asSequence().associateWith(obj::getInt)
        }
        val ambiguous = json.getJSONObject("ambiguous").let { obj ->
            obj.keys().asSequence().associateWith { metric ->
                obj.getJSONArray(metric).let { array -> (0 until array.length()).map(array::getString).toSet() }
            }
        }
        SyncReport(Instant.parse(json.getString("started_at")), Instant.parse(json.getString("finished_at")),
            LocalDate.parse(json.getString("period_start")), LocalDate.parse(json.getString("period_end")),
            found, json.getInt("uploaded"), stringMap("incomplete"), ambiguous,
            SyncOutcome.valueOf(json.getString("outcome")), json.getString("detail"))
    } catch (_: Exception) { null }
}

class HealthSync(
    private val context: Context,
    private val sessions: SupabaseSessionStore = SupabaseSessionStore(context),
    private val state: SyncStateStore = SyncStateStore(context),
    private val repository: HealthConnectRepository = DefaultHealthConnectRepository(AndroidHealthConnectDataSource(context)),
    private val uploader: DailyMetricsUploader = DailyMetricsUploader(),
    private val clock: Clock = Clock.systemUTC(),
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    /** The file lock serializes manual and scheduled runs, including across process restarts. */
    suspend fun run(background: Boolean): SyncReport? = withContext(Dispatchers.IO) {
        val session = sessions.current() ?: return@withContext null
        if (!state.consented(session.userId)) {
            return@withContext report(session.userId, SyncOutcome.SKIPPED, "Sincronização não autorizada.")
        }
        val lockFile = context.filesDir.resolve("health_sync.lock")
        java.io.RandomAccessFile(lockFile, "rw").use { file ->
            val lock = try { file.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
            if (lock == null) return@withContext report(session.userId, SyncOutcome.BUSY, "Já existe uma sincronização em andamento.")
            lock.use {
                val started = clock.instant()
                val dates = reconciliationDates(started.atZone(zone).toLocalDate())
                fun finish(found: Map<String, Int>, uploaded: Int, incomplete: Map<String, String>,
                    ambiguous: Map<String, Set<String>>, outcome: SyncOutcome, detail: String): SyncReport {
                    val result = SyncReport(started, clock.instant(), dates.first(), dates.last(),
                        found, uploaded, incomplete, ambiguous, outcome, detail)
                    state.save(session.userId, result)
                    return result
                }
                val found = mutableMapOf<String, Int>()
                val incomplete = mutableMapOf<String, String>()
                val ambiguous = mutableMapOf<String, Set<String>>()
                val upload = mutableListOf<HealthMetricSnapshot>()
                try {
                    if (background) {
                        val gateway = AndroidHealthConnectGateway(context)
                        if (gateway.providerState() != ProviderState.AVAILABLE) {
                            return@withContext finish(emptyMap(), 0, emptyMap(), emptyMap(), SyncOutcome.SKIPPED,
                                "Health Connect indisponível neste aparelho.")
                        }
                        val granted = gateway.grantedPermissions()
                        if (gateway.capabilities(granted).background != CapabilityState.AVAILABLE_AND_GRANTED) {
                            return@withContext finish(emptyMap(), 0, emptyMap(), emptyMap(), SyncOutcome.SKIPPED,
                                "Leitura em background não autorizada. Use Sincronizar agora com o app aberto.")
                        }
                    }
                    for (metric in HealthMetric.entries) {
                        val policy = if (metric.isPlatformAggregated) MetricSourcePolicy.PlatformAggregate
                            else MetricSourcePolicy.SingleOrigin(state.origin(session.userId, metric))
                        val snapshots = repository.readSnapshot(metric, dates, zone, policy)
                        // A new unambiguous origin becomes a stable per-user choice before the first upload.
                        if (policy is MetricSourcePolicy.SingleOrigin && policy.packageName == null) {
                            snapshots.flatMap { it.origins }.toSet().singleOrNull()?.let {
                                state.selectOrigin(session.userId, metric, it)
                            }
                        }
                        val name = metric.name.lowercase()
                        found[name] = snapshots.count { it.availability == MetricAvailability.AVAILABLE }
                        val blocked = snapshots.filterNot(HealthMetricSnapshot::readComplete)
                        if (blocked.isNotEmpty()) {
                            incomplete[name] = blocked.map { it.availability.name.lowercase() }.distinct().joinToString(", ")
                            blocked.filter { it.availability == MetricAvailability.SOURCE_AMBIGUOUS }
                                .flatMap { it.origins }.toSet().takeIf { it.isNotEmpty() }?.let { ambiguous[name] = it }
                        }
                        upload += snapshots.filter(HealthMetricSnapshot::readComplete)
                    }
                    // Logout or a different login during the read must not upload into a new account.
                    if (sessions.current()?.userId != session.userId || !state.consented(session.userId)) {
                        return@withContext finish(found, 0, incomplete, ambiguous, SyncOutcome.SKIPPED,
                            "A sessão ou autorização mudou durante a leitura; nenhum dado foi enviado.")
                    }
                    if (upload.isNotEmpty()) {
                        uploader.upsert(session.userId, sessions.current()!!.accessToken, upload)
                    }
                    val outcome = if (incomplete.isEmpty() && upload.size == dates.size * HealthMetric.entries.size)
                        SyncOutcome.SUCCESS else SyncOutcome.PARTIAL
                    finish(found, upload.size, incomplete, ambiguous, outcome,
                        if (outcome == SyncOutcome.SUCCESS) "Upload confirmado." else "Upload parcial; leituras incompletas preservadas.")
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: RetryableSyncException) {
                    finish(found, 0, incomplete, ambiguous, SyncOutcome.RETRY, failure.message ?: "Falha temporária.")
                } catch (failure: Exception) {
                    finish(found, 0, incomplete, ambiguous, SyncOutcome.FAILED, failure.message ?: "Falha na sincronização.")
                }
            }
        }
    }

    private fun report(userId: String, outcome: SyncOutcome, detail: String): SyncReport {
        val now = clock.instant()
        val dates = reconciliationDates(now.atZone(zone).toLocalDate())
        return SyncReport(now, now, dates.first(), dates.last(), emptyMap(), 0, emptyMap(), emptyMap(), outcome, detail)
            .also { state.save(userId, it) }
    }
}

class DailyMetricsUploader(private val http: SupabaseHttp = SupabaseHttp()) {
    suspend fun upsert(userId: String, accessToken: String, snapshots: List<HealthMetricSnapshot>) {
        if (snapshots.isEmpty()) return
        require(snapshots.all(HealthMetricSnapshot::readComplete))
        require(snapshots.map { it.localDate to it.metric }.distinct().size == snapshots.size) {
            "Duplicate daily metric in the same upload."
        }
        val payload = JSONArray()
        snapshots.forEach { payload.put(dailyRow(userId, it)) }
        http.request("/rest/v1/daily_metrics?on_conflict=user_id,local_date,metric", "POST",
            payload.toString(), accessToken,
            mapOf("Content-Profile" to "api", "Prefer" to "resolution=merge-duplicates,return=minimal"))
    }
}

internal fun dailyRow(userId: String, snapshot: HealthMetricSnapshot): JSONObject {
    require(snapshot.readComplete)
    return JSONObject()
        .put("user_id", userId)
        .put("local_date", snapshot.localDate.toString())
        .put("metric", snapshot.metric.name.lowercase())
        .put("availability", snapshot.availability.name.lowercase())
        .put("value", snapshot.value ?: JSONObject.NULL)
        .put("unit", snapshot.unit)
        .put("analysis_timezone", snapshot.analysisTimezone)
        .put("read_at", snapshot.readAt.toString())
        .put("is_provisional", snapshot.provisional)
}
