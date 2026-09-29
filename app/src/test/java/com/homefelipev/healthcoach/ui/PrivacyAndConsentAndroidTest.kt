package com.homefelipev.healthcoach.ui

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import com.homefelipev.healthcoach.R
import com.homefelipev.healthcoach.data.healthconnect.*
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 34])
class PrivacyAndConsentAndroidTest {
    @Test fun bothPrivacyEntryPointsResolveToTheDedicatedPolicyActivity() {
        val app = RuntimeEnvironment.getApplication()
        val resolved = app.packageManager.resolveActivity(Intent("androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE").setPackage(app.packageName), PackageManager.MATCH_DEFAULT_ONLY)
            ?: app.packageManager.resolveActivity(Intent("androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE").setPackage(app.packageName), 0)
        assertEquals(PermissionsRationaleActivity::class.java.name, resolved!!.activityInfo.name)
        val alias = app.packageManager.getActivityInfo(ComponentName(app.packageName, "com.homefelipev.healthcoach.HealthConnectPermissionUsage"), 0)
        assertEquals(PermissionsRationaleActivity::class.java.name, alias.targetActivity)
        assertEquals("android.permission.START_VIEW_PERMISSION_USAGE", alias.permission)
        val policy = app.getString(R.string.privacy_body)
        for (topic in listOf("Finalidade", "Acesso", "Envio e armazenamento", "Supabase",
            "Autorizar envio ao Supabase", "Parar sincronização", "não apagam valores")) {
            assertTrue(topic, policy.contains(topic))
        }
    }

    @Test fun consentSurvivesRecreationAndReadsWithoutMovingTheGrantWindow() {
        val app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("health_connect_consent", 0).edit().clear().commit()
        val installed = Instant.parse("2026-09-01T00:00:00Z")
        val observed = installed.plusSeconds(3600)
        val first = FirstGrantTracker(AndroidFirstGrantStore(app), installed, Clock.fixed(observed, ZoneOffset.UTC)).observe(true)
        val later = FirstGrantTracker(AndroidFirstGrantStore(app), installed, Clock.fixed(observed.plusSeconds(90 * 86400L), ZoneOffset.UTC)).observe(true)
        assertEquals(first, later)
        assertEquals(FirstGrantWindow(installed, observed), later)
    }

    @Test fun manifestDeclaresOnlyReadDataAndSeparateHistoryBackgroundPermissions() {
        val app = RuntimeEnvironment.getApplication()
        val requested = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty().toSet()
        assertTrue(requested.containsAll(HealthConnectPermissions.dataRead))
        assertTrue(HealthConnectPermissions.historyRead in requested)
        assertTrue(HealthConnectPermissions.backgroundRead in requested)
        assertFalse(requested.any { it.contains("WRITE_") })
    }
}
