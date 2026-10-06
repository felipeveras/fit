package com.homefelipev.healthcoach.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.homefelipev.healthcoach.data.autosend.AutoSendPreferences
import com.homefelipev.healthcoach.data.autosend.DailySummaryScheduler
import com.homefelipev.healthcoach.data.telegram.TelegramConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class AutoSendUiState(
    val configured: Boolean = false,
    val enabled: Boolean = false,
    val hour: Int = AutoSendPreferences.DEFAULT_HOUR,
)

class AutoSendViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = AutoSendPreferences(application)

    private val mutable = MutableStateFlow(
        AutoSendUiState(
            configured = TelegramConfig.fromBuildConfig().configured,
            enabled = preferences.enabled,
            hour = preferences.hour,
        ),
    )
    val state = mutable.asStateFlow()

    fun setEnabled(enabled: Boolean) {
        preferences.enabled = enabled
        DailySummaryScheduler.sync(getApplication())
        mutable.value = mutable.value.copy(enabled = enabled)
    }
}
