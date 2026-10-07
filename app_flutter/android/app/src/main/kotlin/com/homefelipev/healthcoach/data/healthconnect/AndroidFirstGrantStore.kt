package com.homefelipev.healthcoach.data.healthconnect

import android.annotation.SuppressLint
import android.content.Context
import java.time.Clock
import java.time.Instant

/** Consent metadata only; excluded from both backup and device transfer. */
class AndroidFirstGrantStore(context: Context) : FirstGrantStore {
    private val preferences = context.applicationContext.getSharedPreferences("health_connect_consent", Context.MODE_PRIVATE)
    override fun load(): FirstGrantWindow? {
        val lower = preferences.getString("first_grant_not_before", null) ?: return null
        val upper = preferences.getString("first_grant_not_after", null) ?: return null
        return FirstGrantWindow(Instant.parse(lower), Instant.parse(upper))
    }
    // KTX edit returns Unit; this boundary must detect a failed synchronous commit.
    @SuppressLint("UseKtx")
    override fun save(window: FirstGrantWindow) {
        check(preferences.edit()
            .putString("first_grant_not_before", window.notBefore.toString())
            .putString("first_grant_not_after", window.notAfter.toString())
            .commit()) { "Could not persist consent metadata" }
    }
}

@Suppress("DEPRECATION")
fun androidFirstGrantTracker(context: Context, clock: Clock = Clock.systemUTC()): FirstGrantTracker {
    val app = context.applicationContext
    val installed = Instant.ofEpochMilli(app.packageManager.getPackageInfo(app.packageName, 0).firstInstallTime)
    return FirstGrantTracker(AndroidFirstGrantStore(app), installed, clock)
}
