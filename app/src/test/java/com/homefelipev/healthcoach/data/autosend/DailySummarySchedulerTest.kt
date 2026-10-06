package com.homefelipev.healthcoach.data.autosend

import java.time.Duration
import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class DailySummarySchedulerTest {
    private val zone = ZoneId.of("UTC")

    @Test
    fun schedulesLaterTodayWhenHourIsAhead() {
        val now = LocalDateTime.of(2026, 10, 6, 8, 0)
        assertEquals(Duration.ofHours(13), DailySummaryScheduler.initialDelay(21, now, zone))
    }

    @Test
    fun schedulesNextDayWhenHourAlreadyPassed() {
        val now = LocalDateTime.of(2026, 10, 6, 22, 30)
        assertEquals(Duration.ofHours(22).plusMinutes(30), DailySummaryScheduler.initialDelay(21, now, zone))
    }

    @Test
    fun schedulesNextDayAtExactlyTheHour() {
        val now = LocalDateTime.of(2026, 10, 6, 21, 0)
        assertEquals(Duration.ofHours(24), DailySummaryScheduler.initialDelay(21, now, zone))
    }
}
