package com.homefelipev.healthcoach.data.autosend

import android.app.Application
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE)
class AutoSendPreferencesTest {
    private val context: Application = RuntimeEnvironment.getApplication()

    @Test
    fun defaultsToDisabledWithDefaultHourAndNoSentDate() {
        val preferences = AutoSendPreferences(context)
        assertFalse(preferences.enabled)
        assertEquals(AutoSendPreferences.DEFAULT_HOUR, preferences.hour)
        assertNull(preferences.lastSentDate())
    }

    @Test
    fun persistsEnabledAndHour() {
        val preferences = AutoSendPreferences(context)
        preferences.enabled = true
        preferences.hour = 7
        assertTrue(AutoSendPreferences(context).enabled)
        assertEquals(7, AutoSendPreferences(context).hour)
    }

    @Test
    fun clampsHourIntoValidRange() {
        val preferences = AutoSendPreferences(context)
        preferences.hour = 42
        assertEquals(23, preferences.hour)
        preferences.hour = -3
        assertEquals(0, preferences.hour)
    }

    @Test
    fun guardAllowsSendOncePerDate() {
        val preferences = AutoSendPreferences(context)
        val today = LocalDate.of(2026, 10, 6)
        assertTrue(preferences.shouldSend(today))
        preferences.markSent(today)
        assertEquals(today, preferences.lastSentDate())
        assertFalse(preferences.shouldSend(today))
        assertTrue(preferences.shouldSend(today.plusDays(1)))
    }
}
