package com.homefelipev.healthcoach.ui

import com.homefelipev.healthcoach.data.healthconnect.*
import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class HealthConnectPermissionsControllerTest {
    private val required = (1..7).map { "permission.$it" }.toSet()
    private val observed = Instant.parse("2026-09-01T00:00:00Z")
    private val clock = Clock.fixed(observed, ZoneOffset.UTC)
    private val store = MemoryGrantStore()
    private val gateway = Gateway()
    private val controller = HealthConnectPermissionsController(gateway, FirstGrantTracker(store, observed, clock), required)

    @Test fun partialResultRefreshesAllSevenGrantsAndManagementOpensSettings() = runBlocking {
        gateway.granted = required.take(6).toSet()
        assertEquals(PermissionAction.Request(required - gateway.granted), controller.dataAction())
        // SDK returns just the newly requested permission. The controller deliberately ignores
        // that subset and queries the authoritative complete set after the result.
        gateway.granted = required + HealthConnectPermissions.historyRead
        val updated = controller.afterPermissionResult()
        assertEquals(required, updated.granted)
        assertEquals(PermissionAction.Manage, controller.dataAction())
    }

    @Test fun resumeAfterProviderInstallationReacquiresPermissions() = runBlocking {
        gateway.provider = ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED
        assertEquals(ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED, controller.refresh().provider)
        assertEquals(0, gateway.reads)
        gateway.provider = ProviderState.AVAILABLE
        gateway.granted = required
        assertEquals(required, controller.refresh().granted)
        gateway.provider = ProviderState.UNAVAILABLE
        assertTrue(controller.refresh().granted.isEmpty())
        gateway.provider = ProviderState.AVAILABLE
        assertEquals(required, controller.refresh().granted)
    }

    @Test fun providerAndPermissionFailuresAreSanitizedAndRetryRecovers() = runBlocking {
        for (error in listOf(IOException("sensitive provider detail"), IllegalStateException("gone"), SecurityException("revoked"))) {
            gateway.failure = error
            val failed = controller.refresh()
            assertEquals("health_connect_permissions_unavailable", failed.errorCode)
            assertFalse(failed.busy)
            assertTrue(failed.granted.isEmpty())
            assertEquals(PermissionAction.None, controller.dataAction())
            gateway.failure = null
            gateway.granted = required
            assertEquals(required, controller.refresh().granted)
            assertNull(controller.state.value.errorCode)
        }
    }

    @Test fun featureFailureAndActionFailureLeaveRecoverableStates() = runBlocking {
        gateway.granted = required
        gateway.featureFailure = IOException("feature error")
        assertNotNull(controller.refresh().errorCode)
        gateway.featureFailure = null
        controller.refresh()
        controller.actionFailed()
        assertEquals("health_connect_action_failed", controller.state.value.errorCode)
        assertNull(controller.refresh().errorCode)
    }

    @Test fun revocationOnResumeUpdatesTheCompletePermissionSet() = runBlocking {
        gateway.granted = required
        controller.refresh()
        gateway.granted = required.take(2).toSet()
        assertEquals(gateway.granted, controller.refresh().granted)
        assertEquals(PermissionAction.Request(required - gateway.granted), controller.dataAction())
    }

    @Test fun unavailableCapabilitiesAreNeverRequestedAndRequestsAreSeparate() = runBlocking {
        gateway.granted = required.take(1).toSet()
        gateway.history = CapabilityState.FEATURE_UNAVAILABLE
        gateway.background = CapabilityState.NOT_GRANTED
        assertEquals(PermissionAction.None, controller.capabilityAction(ReadCapability.HISTORY))
        assertEquals(PermissionAction.Request(setOf(HealthConnectPermissions.backgroundRead)), controller.capabilityAction(ReadCapability.BACKGROUND))
        gateway.history = CapabilityState.NOT_GRANTED
        assertEquals(PermissionAction.Request(setOf(HealthConnectPermissions.historyRead)), controller.capabilityAction(ReadCapability.HISTORY))
        gateway.history = CapabilityState.AVAILABLE_AND_GRANTED
        assertEquals(PermissionAction.Manage, controller.capabilityAction(ReadCapability.HISTORY))
        gateway.background = CapabilityState.OS_DEFERRED
        assertEquals(PermissionAction.None, controller.capabilityAction(ReadCapability.BACKGROUND))
        assertEquals(gateway.granted, controller.state.value.granted)
    }

    @Test(expected = CancellationException::class) fun cancellationStillPropagates() = runBlocking {
        gateway.failure = CancellationException()
        controller.refresh()
        Unit
    }

    @Test fun firstConsentIsPersistedAndNeverMovesOnRefreshOrPartialRevocation() = runBlocking {
        controller.refresh()
        assertNull(store.window)
        gateway.granted = required.take(1).toSet()
        controller.refresh()
        assertEquals(FirstGrantWindow(observed, observed), store.window)
        val later = FirstGrantTracker(store, observed, Clock.fixed(observed.plusSeconds(90 * 86400L), ZoneOffset.UTC))
        assertEquals(store.window, later.observe(true))
        gateway.granted = emptySet()
        controller.refresh()
        assertEquals(FirstGrantWindow(observed, observed), store.window)
    }

    private class MemoryGrantStore : FirstGrantStore {
        var window: FirstGrantWindow? = null
        override fun load() = window
        override fun save(window: FirstGrantWindow) { this.window = window }
    }

    private class Gateway : HealthConnectPermissionGateway {
        var provider = ProviderState.AVAILABLE
        var granted = emptySet<String>()
        var history = CapabilityState.NOT_GRANTED
        var background = CapabilityState.NOT_GRANTED
        var failure: Exception? = null
        var featureFailure: Exception? = null
        var reads = 0
        override fun providerState(): ProviderState { failure?.let { throw it }; return provider }
        override suspend fun grantedPermissions(): Set<String> { reads++; failure?.let { throw it }; return granted }
        override fun capabilities(granted: Set<String>): ReadCapabilities {
            featureFailure?.let { throw it }
            return ReadCapabilities(history, background)
        }
    }
}
