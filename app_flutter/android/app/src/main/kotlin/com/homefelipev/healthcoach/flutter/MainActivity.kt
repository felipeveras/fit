package com.homefelipev.healthcoach.flutter

import android.content.Intent
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
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
    private val calls = mutableSetOf<MethodChannel.Result>()
    private var permissionResult: MethodChannel.Result? = null
    private val gateway by lazy { AndroidHealthConnectGateway(this) }
    private val grants by lazy { androidFirstGrantTracker(this) }
    private val repository by lazy {
        DefaultHealthConnectRepository(AndroidHealthConnectDataSource(gateway, grants))
    }
    private val launcher = registerForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) {
        val pending = permissionResult ?: return@registerForActivityResult
        permissionResult = null
        execute(pending) { permissions() }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.homefelipev.healthcoach/health")
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.argument<Int>("version") != HEALTH_BRIDGE_VERSION) {
            result.error("unsupported_version", "Bridge version must be 1", null)
            return
        }
        when (call.method) {
            "getAvailability" -> result.success(envelope("provider" to gateway.providerState().wire()))
            "getPermissions" -> execute(result) { permissions() }
            "requestPermissions" -> request(call, result)
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
        val kind = call.argument<String>("kind")
        if (kind !in setOf("data", "history")) {
            result.error("invalid_arguments", "Unknown permission kind", null)
            return
        }
        permissionResult = result
        execute(result, complete = false) {
            requireProvider()
            val granted = gateway.grantedPermissions()
            val requested = if (kind == "data") HealthConnectPermissions.dataRead - granted
            else if (gateway.capabilities(granted).history == CapabilityState.NOT_GRANTED)
                setOf(HealthConnectPermissions.historyRead) else emptySet()
            if (requested.isEmpty()) {
                result.success(permissions())
                calls.remove(result)
                permissionResult = null
            } else {
                launcher.launch(requested)
            }
            emptyMap()
        }
    }

    private suspend fun permissions(): Map<String, Any?> {
        requireProvider()
        val granted = gateway.grantedPermissions()
        grants.observe(granted.any { it in HealthConnectPermissions.dataRead })
        val capabilities = gateway.capabilities(granted)
        return envelope("granted" to granted.toList(), "required" to HealthConnectPermissions.dataRead.toList(),
            "history" to capabilities.history.wire(), "background" to capabilities.background.wire())
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
                if (permissionResult === result) permissionResult = null
                if (calls.remove(result)) result.error(
                    if (failure is ProviderUnavailable) "provider_unavailable" else "health_connect_error",
                    "Health Connect operation failed", null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel.setMethodCallHandler(null)
        scope.cancel()
        permissionResult = null
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
