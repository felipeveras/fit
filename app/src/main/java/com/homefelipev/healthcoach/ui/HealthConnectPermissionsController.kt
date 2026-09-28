package com.homefelipev.healthcoach.ui

import com.homefelipev.healthcoach.data.healthconnect.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class PermissionsState(
    val provider: ProviderState = ProviderState.UNAVAILABLE,
    val granted: Set<String> = emptySet(),
    val capabilities: ReadCapabilities = ReadCapabilities(CapabilityState.FEATURE_UNAVAILABLE, CapabilityState.FEATURE_UNAVAILABLE),
    val busy: Boolean = false,
    val errorCode: String? = null,
)

sealed interface PermissionAction {
    data class Request(val permissions: Set<String>) : PermissionAction
    data object Manage : PermissionAction
    data object None : PermissionAction
}

/** Permission results are hints to refresh, never a replacement for the full SDK state. */
class HealthConnectPermissionsController(
    private val gateway: HealthConnectPermissionGateway,
    private val grants: FirstGrantTracker,
    private val required: Set<String> = HealthConnectPermissions.dataRead,
) {
    private val mutableState = MutableStateFlow(PermissionsState())
    val state = mutableState.asStateFlow()
    private val mutex = Mutex()

    suspend fun refresh(): PermissionsState = mutex.withLock { refreshLocked() }

    suspend fun afterPermissionResult(): PermissionsState = refresh()

    suspend fun dataAction(): PermissionAction = mutex.withLock {
        val current = refreshLocked()
        if (current.errorCode != null || current.provider != ProviderState.AVAILABLE) PermissionAction.None
        else (required - current.granted).let { missing ->
            if (missing.isEmpty()) PermissionAction.Manage else PermissionAction.Request(missing)
        }
    }

    suspend fun capabilityAction(capability: ReadCapability): PermissionAction = mutex.withLock {
        val current = refreshLocked()
        val status = if (capability == ReadCapability.HISTORY) current.capabilities.history else current.capabilities.background
        when {
            current.errorCode != null || current.provider != ProviderState.AVAILABLE || current.granted.isEmpty() -> PermissionAction.None
            status == CapabilityState.NOT_GRANTED -> PermissionAction.Request(setOf(
                if (capability == ReadCapability.HISTORY) HealthConnectPermissions.historyRead else HealthConnectPermissions.backgroundRead,
            ))
            status == CapabilityState.AVAILABLE_AND_GRANTED -> PermissionAction.Manage
            else -> PermissionAction.None
        }
    }

    fun actionFailed() {
        mutableState.value = mutableState.value.copy(errorCode = "health_connect_action_failed", busy = false)
    }

    private suspend fun refreshLocked(): PermissionsState {
        mutableState.value = mutableState.value.copy(busy = true, errorCode = null)
        try {
            val provider = gateway.providerState()
            mutableState.value = if (provider != ProviderState.AVAILABLE) PermissionsState(provider = provider)
            else {
                val allGranted = gateway.grantedPermissions()
                val dataGranted = allGranted.intersect(required)
                grants.observe(dataGranted.isNotEmpty())
                PermissionsState(provider, dataGranted, gateway.capabilities(allGranted))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            mutableState.value = PermissionsState(errorCode = "health_connect_permissions_unavailable")
        } finally {
            mutableState.value = mutableState.value.copy(busy = false)
        }
        return mutableState.value
    }
}
