package com.homefelipev.healthcoach.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectDataSource
import com.homefelipev.healthcoach.data.healthconnect.DefaultHealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthConnectRepository
import com.homefelipev.healthcoach.data.telegram.DailyHealthSummary
import com.homefelipev.healthcoach.data.telegram.HealthSummarySender
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class TelegramStatus { IDLE, SENDING, SENT }

data class TelegramUiState(
    val configured: Boolean = false,
    val status: TelegramStatus = TelegramStatus.IDLE,
    val error: String? = null,
)

class TelegramViewModel(application: Application) : AndroidViewModel(application) {
    private val repository: HealthConnectRepository =
        DefaultHealthConnectRepository(AndroidHealthConnectDataSource(application))
    private val sender = HealthSummarySender()
    private val mutable = MutableStateFlow(TelegramUiState(configured = sender.configured))
    val state = mutable.asStateFlow()

    fun send() {
        if (mutable.value.status == TelegramStatus.SENDING) return
        viewModelScope.launch {
            mutable.value = mutable.value.copy(status = TelegramStatus.SENDING, error = null)
            try {
                val reading = withContext(Dispatchers.IO) {
                    val zone = ZoneId.systemDefault()
                    val date = LocalDate.now(zone)
                    val snapshots = DailyHealthSummary.collect(repository, date, zone)
                    date to snapshots
                }
                sender.send(reading.first, reading.second)
                mutable.value = mutable.value.copy(status = TelegramStatus.SENT)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                mutable.value = mutable.value.copy(status = TelegramStatus.IDLE,
                    error = failure.message ?: "Falha ao enviar para o Telegram.")
            }
        }
    }
}
