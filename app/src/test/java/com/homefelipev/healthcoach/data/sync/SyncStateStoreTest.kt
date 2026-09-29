package com.homefelipev.healthcoach.data.sync

import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE)
class SyncStateStoreTest {
    @Test
    fun consentAndOriginAreScopedToOneAccountAndPersistAcrossInstances() {
        val context = RuntimeEnvironment.getApplication()
        val first = SyncStateStore(context)
        assertFalse(first.consented("account-a"))
        first.setConsent("account-a", true)
        first.selectOrigin("account-a", HealthMetric.WEIGHT, "example.weight")

        val reopened = SyncStateStore(context)
        assertTrue(reopened.consented("account-a"))
        assertFalse(reopened.consented("account-b"))
        assertEquals("example.weight", reopened.origin("account-a", HealthMetric.WEIGHT))
        assertEquals(null, reopened.origin("account-b", HealthMetric.WEIGHT))

        reopened.setConsent("account-a", false)
        assertFalse(first.consented("account-a"))
    }
}
