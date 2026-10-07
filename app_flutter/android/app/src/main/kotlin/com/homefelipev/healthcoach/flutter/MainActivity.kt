package com.homefelipev.healthcoach.flutter

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.activity.result.contract.ActivityResultContracts
import com.homefelipev.healthcoach.data.healthconnect.*
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.*

class MainActivity : FlutterFragmentActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var channel: MethodChannel
    private lateinit var habitChannel: MethodChannel
    private var photoPickerResult: MethodChannel.Result? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val calls = mutableSetOf<MethodChannel.Result>()
    private var permissionResult: MethodChannel.Result? = null
    private var permissionKind: String? = null
    private val gateway by lazy { AndroidHealthConnectGateway(this) }
    private val grants by lazy { androidFirstGrantTracker(this) }
    private val exercises by lazy { HealthExerciseReader(AndroidExerciseSource(gateway, grants)) }
    private val repository by lazy {
        DefaultHealthConnectRepository(AndroidHealthConnectDataSource(gateway, grants))
    }
    private val launcher = registerForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) {
        val pending = permissionResult ?: return@registerForActivityResult
        val exercise = permissionKind == "exercise"
        permissionResult = null
        permissionKind = null
        execute(pending) { if (exercise) exercisePermissions() else permissions() }
    }
    private val imagePicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val pending = photoPickerResult ?: return@registerForActivityResult
        photoPickerResult = null
        if (uri == null) {
            pending.success(null)
        } else {
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
                // Some providers return a temporary URI; the selected reference is still useful now.
            }
            pending.success(uri.toString())
        }
    }
    private val notificationPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val pending = notificationPermissionResult ?: return@registerForActivityResult
        notificationPermissionResult = null
        pending.success(granted)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.homefelipev.healthcoach/health")
        channel.setMethodCallHandler(::handle)
        habitChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.homefelipev.healthcoach/habits")
        habitChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickHabitPhoto" -> {
                    if (photoPickerResult != null) result.error("picker_in_progress", "A photo picker is already open", null)
                    else {
                        photoPickerResult = result
                        imagePicker.launch(arrayOf("image/*"))
                    }
                }
                "requestHabitNotifications" -> {
                    if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else if (notificationPermissionResult != null) {
                        result.error("permission_request_in_progress", "Notification permission request is pending", null)
                    } else {
                        notificationPermissionResult = result
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
                "syncHabitReminder" -> {
                    val habitId = call.argument<String>("habitId")
                    val enabled = call.argument<Boolean>("enabled")
                    if (habitId.isNullOrBlank() || enabled == null) result.error("invalid_arguments", "Habit id and enabled state are required", null)
                    else {
                        if (enabled) HabitReminderScheduler.refresh(this, habitId) else HabitReminderScheduler.cancel(this, habitId)
                        result.success(true)
                    }
                }
                "shareHabitSummary" -> {
                    val title = call.argument<String>("title").orEmpty()
                    val text = call.argument<String>("text").orEmpty()
                    if (text.isBlank()) result.error("invalid_arguments", "Share text is required", null)
                    else {
                        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            putExtra(Intent.EXTRA_TEXT, text)
                        }, title.ifBlank { "Compartilhar hábito" }))
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        HabitReminderScheduler.refreshAll(this)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.argument<Any>("version") != HEALTH_BRIDGE_VERSION) {
            result.error("unsupported_version", "Bridge version must be 1", null)
            return
        }
        when (call.method) {
            "getAvailability" -> result.success(envelope("provider" to gateway.providerState().wire()))
            "getPermissions" -> execute(result) { permissions() }
            "requestPermissions" -> request(call, result)
            "getExercisePermissions" -> execute(result) { exercisePermissions() }
            "requestExercisePermission" -> request(call, result)
            "getExerciseSessions" -> {
                val days = call.argument<Any>("days")
                val origin = call.argument<Any>("originPackage")
                if (days !is Int || days !in setOf(1, 7, 30, 90) ||
                    (origin != null && (origin !is String || origin.isBlank()))) {
                    result.error("invalid_arguments", "Invalid exercise period or origin", null)
                } else execute(result) {
                    withContext(Dispatchers.IO) { exercises.read(days, ZoneId.systemDefault(), origin as String?) }
                }
            }
            "openHealthSettings" -> execute(result) {
                val intent = if (gateway.providerState() == ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED)
                    Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata"))
                else Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)
                startActivity(intent)
                envelope("opened" to true)
            }
            "getToday", "getPeriod" -> {
                val days = if (call.method == "getToday") 1 else call.argument<Int>("days")
                if (days == null || (call.method == "getPeriod" && days !in setOf(7, 30, 90))) {
                    result.error("invalid_arguments", "Period must be 7, 30 or 90", null)
                } else execute(result) {
                    requireProvider()
                    withContext(Dispatchers.IO) {
                        val zone = ZoneId.systemDefault()
                        val today = LocalDate.now(zone)
                        val dates = (0 until days).map { today.minusDays(it.toLong()) }
                        val snapshots = HealthMetric.entries.flatMap { metric ->
                            repository.readSnapshot(metric, dates, zone,
                                if (metric.isPlatformAggregated) MetricSourcePolicy.PlatformAggregate
                                else MetricSourcePolicy.SingleOrigin(null))
                        }
                        envelope("days" to days, "timezone" to zone.id,
                            "snapshots" to snapshots.map(HealthBridgeDto::snapshot))
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun request(call: MethodCall, result: MethodChannel.Result) {
        if (permissionResult != null) {
            result.error("permission_request_in_progress", "Permission request is pending", null)
            return
        }
        val kind = if (call.method == "requestExercisePermission") "exercise" else call.argument<String>("kind")
        if (kind !in setOf("data", "history", "exercise")) {
            result.error("invalid_arguments", "Unknown permission kind", null)
            return
        }
        permissionResult = result
        permissionKind = kind
        execute(result, complete = false) {
            requireProvider()
            val granted = gateway.grantedPermissions()
            val requested = if (kind == "exercise") setOf(AndroidExerciseSource.permission) - granted
            else if (kind == "data") HealthConnectPermissions.dataRead - granted
            else if (gateway.capabilities(granted).history == CapabilityState.NOT_GRANTED)
                setOf(HealthConnectPermissions.historyRead) else emptySet()
            if (requested.isEmpty()) {
                result.success(if (kind == "exercise") exercisePermissions() else permissions())
                calls.remove(result)
                permissionResult = null
                permissionKind = null
            } else {
                launcher.launch(requested)
            }
            emptyMap()
        }
    }

    private suspend fun permissions(): Map<String, Any?> {
        requireProvider()
        val granted = gateway.grantedPermissions()
        grants.observe(AndroidExerciseSource.permission in granted || granted.any { it in HealthConnectPermissions.dataRead })
        val capabilities = gateway.capabilities(granted)
        return envelope("granted" to granted.toList(), "required" to HealthConnectPermissions.dataRead.toList(),
            "history" to capabilities.history.wire(), "background" to capabilities.background.wire())
    }

    private suspend fun exercisePermissions(): Map<String, Any?> {
        val provider = gateway.providerState()
        if (provider != ProviderState.AVAILABLE) return envelope("provider" to provider.wire(),
            "granted" to false, "history" to CapabilityState.FEATURE_UNAVAILABLE.wire())
        val granted = gateway.grantedPermissions()
        grants.observe(AndroidExerciseSource.permission in granted || granted.any { it in HealthConnectPermissions.dataRead })
        return envelope("provider" to provider.wire(), "granted" to (AndroidExerciseSource.permission in granted),
            "history" to gateway.capabilities(granted).history.wire())
    }

    private fun requireProvider() {
        if (gateway.providerState() != ProviderState.AVAILABLE) throw ProviderUnavailable()
    }

    private fun execute(result: MethodChannel.Result, complete: Boolean = true,
        block: suspend () -> Map<String, Any?>) {
        calls.add(result)
        scope.launch {
            try {
                val response = block()
                if (complete && calls.remove(result)) result.success(response)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (permissionResult === result) { permissionResult = null; permissionKind = null }
                if (calls.remove(result)) result.error(
                    if (failure is ProviderUnavailable) "provider_unavailable" else "health_connect_error",
                    "Health Connect operation failed", null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel.setMethodCallHandler(null)
        habitChannel.setMethodCallHandler(null)
        photoPickerResult?.error("bridge_detached", "Photo picker was closed", null)
        photoPickerResult = null
        notificationPermissionResult?.error("bridge_detached", "Permission request was closed", null)
        notificationPermissionResult = null
        scope.cancel()
        permissionResult = null
        permissionKind = null
        calls.toList().forEach { it.error("bridge_detached", "Android host detached", null) }
        calls.clear()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private class ProviderUnavailable : Exception()
    companion object {
        const val HEALTH_BRIDGE_VERSION = 1
        fun envelope(vararg fields: Pair<String, Any?>): Map<String, Any?> =
            mapOf("version" to HEALTH_BRIDGE_VERSION, *fields)
        fun Enum<*>.wire() = name.lowercase(java.util.Locale.ROOT)
    }
}
