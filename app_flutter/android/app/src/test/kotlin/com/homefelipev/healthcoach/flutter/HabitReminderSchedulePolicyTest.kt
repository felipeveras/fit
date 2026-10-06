package com.homefelipev.healthcoach.flutter

import java.time.LocalDate
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HabitReminderSchedulePolicyTest {
    private val monday = LocalDate.parse("2026-10-05")

    @Test fun honorsStartDateWeekdaysAndExcludedDays() {
        assertFalse(ReminderSchedulePolicy.isScheduled("daily", emptySet(), 1, monday, monday.minusDays(1)))
        assertTrue(ReminderSchedulePolicy.isScheduled("specificDays", setOf(1, 3), 1, monday, monday))
        assertFalse(ReminderSchedulePolicy.isScheduled("specificDays", setOf(1, 3), 1, monday, monday.plusDays(1)))
        assertFalse(ReminderSchedulePolicy.isScheduled("daily", emptySet(), 1, monday, monday, restDay = true))
        assertFalse(ReminderSchedulePolicy.isScheduled("daily", emptySet(), 1, monday, monday, vacation = true))
    }

    @Test fun honorsIntervalsAndKeepsPeriodTargetsUntilTheyAreReached() {
        assertTrue(ReminderSchedulePolicy.isScheduled("everyNDays", emptySet(), 2, monday, monday.plusDays(4)))
        assertFalse(ReminderSchedulePolicy.isScheduled("everyNDays", emptySet(), 2, monday, monday.plusDays(3)))
        assertTrue(ReminderSchedulePolicy.isScheduled("weeklyTarget", emptySet(), 1, monday, monday.plusDays(2)))
        assertTrue(ReminderSchedulePolicy.periodTargetStillDue("weeklyTarget", targetCount = 3, successes = 2))
        assertFalse(ReminderSchedulePolicy.periodTargetStillDue("monthlyTarget", targetCount = 3, successes = 3))
    }
}
