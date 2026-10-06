package com.homefelipev.healthcoach.data.autosend

import android.content.Context
import java.time.LocalDate

/**
 * Minimal local state for the daily automation: whether it is enabled, the preferred hour,
 * and the last date already sent automatically (to avoid a duplicate for the same day).
 *
 * Backup/transfer excluded via data_extraction_rules.xml and backup_rules.xml.
 */
class AutoSendPreferences(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    var enabled: Boolean
        get() = preferences.getBoolean(KEY_ENABLED, false)
        set(value) = preferences.edit().putBoolean(KEY_ENABLED, value).apply()

    var hour: Int
        get() = preferences.getInt(KEY_HOUR, DEFAULT_HOUR)
        set(value) = preferences.edit().putInt(KEY_HOUR, value.coerceIn(0, 23)).apply()

    fun lastSentDate(): LocalDate? =
        preferences.getString(KEY_LAST_SENT_DATE, null)?.let { raw -> runCatching { LocalDate.parse(raw) }.getOrNull() }

    fun markSent(date: LocalDate) = preferences.edit().putString(KEY_LAST_SENT_DATE, date.toString()).apply()

    /** True when [date] was not sent automatically yet. */
    fun shouldSend(date: LocalDate): Boolean = lastSentDate() != date

    companion object {
        const val PREFERENCES_NAME = "auto_send"
        const val KEY_ENABLED = "auto_send_enabled"
        const val KEY_HOUR = "auto_send_hour"
        const val KEY_LAST_SENT_DATE = "auto_send_last_date"
        const val DEFAULT_HOUR = 21
    }
}
