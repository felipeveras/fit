package com.homefelipev.healthcoach.data.healthconnect

import java.time.Clock
import java.time.Duration
import java.time.Instant

/** Bounds on the FIRST grant, not a rolling lookback from the current date. */
data class FirstGrantWindow(val notBefore: Instant, val notAfter: Instant) {
    init { require(notBefore <= notAfter) }
}

data class HealthReadAccess(
    val metricGranted: Boolean,
    val historyGranted: Boolean,
    val firstGrant: FirstGrantWindow?,
) {
    fun impediment(start: Instant): MetricAvailability? {
        if (!metricGranted) return MetricAvailability.PERMISSION_DENIED
        if (historyGranted) return null
        val grant = firstGrant ?: return MetricAvailability.READ_ERROR
        // Only assert history_restricted when proven. Uncertain boundaries are incomplete.
        if (start < grant.notBefore.minus(Duration.ofDays(30))) return MetricAvailability.HISTORY_RESTRICTED
        if (start < grant.notAfter.minus(Duration.ofDays(30))) return MetricAvailability.READ_ERROR
        return null
    }
}

interface FirstGrantStore {
    fun load(): FirstGrantWindow?
    fun save(window: FirstGrantWindow)
}

/** SDK 1.1.0 has no grant timestamp API. Persist an honest bound without refreshing it. */
class FirstGrantTracker(
    private val store: FirstGrantStore,
    private val installationAt: Instant,
    private val clock: Clock = Clock.systemUTC(),
) {
    @Synchronized
    fun observe(hasDataPermission: Boolean): FirstGrantWindow? {
        store.load()?.let { return it }
        if (!hasDataPermission) return null
        val observed = clock.instant()
        val window = FirstGrantWindow(minOf(installationAt, observed), observed)
        store.save(window)
        return window
    }
}
