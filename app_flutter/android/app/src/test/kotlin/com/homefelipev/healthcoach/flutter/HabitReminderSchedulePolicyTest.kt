package com.homefelipev.healthcoach.flutter

import java.time.LocalDate
import org.junit.Assert.assertEquals
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

    @Test fun partialWeeklyStartReducesTargetAndStopsAfterItIsMet() {
        val friday = monday.plusDays(4)
        val target = ReminderSchedulePolicy.adjustedPeriodTarget("weeklyTarget", 7, friday, friday)
        assertEquals(3, target)
        assertTrue(ReminderSchedulePolicy.periodTargetStillDue("weeklyTarget", target, 2))
        assertFalse(ReminderSchedulePolicy.periodTargetStillDue("weeklyTarget", target, 3))
    }

    @Test fun restAndVacationReduceWholePeriodTargetsEvenBeforeExcludedDatesArrive() {
        val excluded = setOf(monday.plusDays(2), monday.plusDays(3), monday.plusDays(4))
        assertEquals(4, ReminderSchedulePolicy.adjustedPeriodTarget("weeklyTarget", 7, monday, monday, excluded))
        val octoberStart = LocalDate.parse("2026-10-01")
        val vacation = (0L..9L).map { octoberStart.plusDays(it) }.toSet()
        assertEquals(21, ReminderSchedulePolicy.adjustedPeriodTarget("monthlyTarget", 31, octoberStart, octoberStart, vacation))
        val allDays = (0L..6L).map { monday.plusDays(it) }.toSet()
        assertEquals(0, ReminderSchedulePolicy.adjustedPeriodTarget("weeklyTarget", 7, monday, monday, allDays))
        assertFalse(ReminderSchedulePolicy.periodTargetStillDue("weeklyTarget", 0, 0))
    }

    @Test fun multipleSameDayOccurrencesMeetTargetButExcludedOccurrencesDoNotCount() {
        val excluded = monday.plusDays(1)
        val successes = ReminderSchedulePolicy.successfulOccurrences(listOf(monday, monday, monday, excluded), setOf(excluded))
        assertEquals(3, successes)
        assertFalse(ReminderSchedulePolicy.periodTargetStillDue("monthlyTarget", 3, successes))
    }

    @Test fun automaticStepsUseOnlyMeasuredDaysForThePeriodTarget() {
        assertEquals(0, ReminderSchedulePolicy.adjustedPeriodTarget("weeklyTarget", 7, monday, monday, measuredDays = 0))
        assertEquals(2, ReminderSchedulePolicy.adjustedPeriodTarget("weeklyTarget", 7, monday, monday.plusDays(3), measuredDays = 2))
    }
    @Test
    fun exerciseCoverageDoesNotTurnPermissionFailuresOrProvisionalDaysIntoMisses() {
        assertFalse(ReminderSchedulePolicy.healthDayCovered(true, "permissionDenied", false, false, true, false))
        assertFalse(ReminderSchedulePolicy.healthDayCovered(true, "historyRestricted", false, false, false, false))
        assertFalse(ReminderSchedulePolicy.healthDayCovered(true, "readError", false, false, false, false))
        assertFalse(ReminderSchedulePolicy.healthDayCovered(true, "noData", true, true, false, false))
        assertTrue(ReminderSchedulePolicy.healthDayCovered(true, "noData", true, false, false, false))
        assertTrue(ReminderSchedulePolicy.healthDayCovered(true, "available", true, true, true, false))
        assertTrue(ReminderSchedulePolicy.healthDayCovered(true, "permissionDenied", false, true, false, true))
        assertFalse(ReminderSchedulePolicy.healthDayCovered(false, "noData", true, false, false, false))
        assertTrue(ReminderSchedulePolicy.healthDayCovered(false, "available", true, true, false, false))
    }
}
