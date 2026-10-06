package com.homefelipev.healthcoach.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectDataSource
import com.homefelipev.healthcoach.data.healthconnect.DefaultHealthConnectRepository
import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricSourcePolicy
import com.homefelipev.healthcoach.data.telegram.DailyHealthSummary
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HealthReadUiState(
    val busy: Boolean = false,
    val entries: List<HealthReadViewModel.Entry> = emptyList(),
    val finishedAt: Instant? = null,
    val error: String? = null,
)

class HealthReadViewModel(application: Application) : AndroidViewModel(application) {
    data class Entry(val metric: HealthMetric, val snapshot: HealthMetricSnapshot)

    private val repository = DefaultHealthConnectRepository(AndroidHealthConnectDataSource(application))
    private val zone: ZoneId = ZoneId.systemDefault()

    private val mutable = MutableStateFlow(HealthReadUiState())
    val state = mutable.asStateFlow()

    fun read() {
        if (mutable.value.busy) return
        viewModelScope.launch {
            mutable.value = mutable.value.copy(busy = true, error = null)
            try {
                val today = LocalDate.now(zone)
                val dates = (6L downTo 0L).map(today::minusDays)
                val entries = withContext(Dispatchers.IO) {
                    HealthMetric.entries.flatMap { metric ->
                        val policy = if (metric.isPlatformAggregated) MetricSourcePolicy.PlatformAggregate
                        else MetricSourcePolicy.SingleOrigin(null)
                        repository.readSnapshot(metric, dates, zone, policy).map { Entry(metric, it) }
                    }
                }
                mutable.value = HealthReadUiState(entries = entries, finishedAt = Instant.now())
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                mutable.value = mutable.value.copy(busy = false,
                    error = failure.message ?: "Falha ao ler o Health Connect.")
            }
        }
    }
}
