package com.homefelipev.healthcoach.data.healthconnect

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures

enum class ProviderState { AVAILABLE, PROVIDER_MISSING_OR_UPDATE_REQUIRED, UNAVAILABLE }
enum class CapabilityState { AVAILABLE_AND_GRANTED, NOT_GRANTED, FEATURE_UNAVAILABLE, OS_DEFERRED }
enum class ReadCapability { HISTORY, BACKGROUND }

data class ReadCapabilities(val history: CapabilityState, val background: CapabilityState)

interface HealthConnectPermissionGateway {
    fun providerState(): ProviderState
    suspend fun grantedPermissions(): Set<String>
    fun capabilities(granted: Set<String>): ReadCapabilities
}

class AndroidHealthConnectGateway(
    private val clientFactory: () -> HealthConnectClient,
    private val statusReader: () -> ProviderState,
) : HealthConnectPermissionGateway {
    constructor(context: Context) : this(
        { HealthConnectClient.getOrCreate(context.applicationContext) },
        {
            when (HealthConnectClient.getSdkStatus(context.applicationContext)) {
                HealthConnectClient.SDK_AVAILABLE -> ProviderState.AVAILABLE
                HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED
                else -> ProviderState.UNAVAILABLE
            }
        },
    )

    // Reacquire after provider changes; never cache an unavailable client in the UI.
    fun client() = clientFactory()
    override fun providerState() = statusReader()
    override suspend fun grantedPermissions() = client().permissionController.getGrantedPermissions()
    override fun capabilities(granted: Set<String>): ReadCapabilities {
        val features = client().features
        fun state(feature: Int, permission: String) = when {
            features.getFeatureStatus(feature) != HealthConnectFeatures.FEATURE_STATUS_AVAILABLE -> CapabilityState.FEATURE_UNAVAILABLE
            permission !in granted -> CapabilityState.NOT_GRANTED
            else -> CapabilityState.AVAILABLE_AND_GRANTED
        }
        return ReadCapabilities(
            state(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY, HealthConnectPermissions.historyRead),
            state(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND, HealthConnectPermissions.backgroundRead),
        )
    }
}
