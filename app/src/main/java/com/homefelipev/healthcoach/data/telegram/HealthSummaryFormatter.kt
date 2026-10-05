package com.homefelipev.healthcoach.data.telegram

import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import com.homefelipev.healthcoach.data.healthconnect.MetricAvailability
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToLong

object HealthSummaryFormatter {
    private val locale = Locale.forLanguageTag("pt-BR")
    private val dateFormat = DateTimeFormatter.ofPattern("dd/MM/yyyy")
    private val order = listOf(
        HealthMetric.WEIGHT, HealthMetric.STEPS, HealthMetric.SLEEP_DURATION,
        HealthMetric.RESTING_HEART_RATE, HealthMetric.ACTIVE_ENERGY, HealthMetric.TOTAL_ENERGY,
        HealthMetric.DISTANCE,
    )

    fun format(date: LocalDate, snapshots: List<HealthMetricSnapshot>): String {
        val available = snapshots.filter { it.availability == MetricAvailability.AVAILABLE }.associateBy { it.metric }
        val lines = mutableListOf("📊 App Fit — ${date.format(dateFormat)}")
        order.forEach { metric ->
            val value = available[metric]?.value ?: return@forEach
            lines += metricLine(metric, value)
        }
        if (lines.size == 1) lines += "Nenhuma métrica disponível."
        return lines.joinToString("\n")
    }

    private fun metricLine(metric: HealthMetric, value: Double): String = when (metric) {
        HealthMetric.WEIGHT -> "⚖️ Peso: ${decimal(value)} kg"
        HealthMetric.STEPS -> "👟 Passos: ${integer(value)}"
        HealthMetric.SLEEP_DURATION -> "😴 Sono: ${duration(value)}"
        HealthMetric.RESTING_HEART_RATE -> "❤️ FC repouso: ${integer(value)} bpm"
        HealthMetric.ACTIVE_ENERGY -> "🔥 Calorias ativas: ${integer(value)} kcal"
        HealthMetric.TOTAL_ENERGY -> "⚡ Calorias totais: ${integer(value)} kcal"
        HealthMetric.DISTANCE -> "📏 Distância: ${decimal(value / 1000.0)} km"
    }

    private fun decimal(value: Double) = String.format(locale, "%.1f", value)

    private fun integer(value: Double) = NumberFormat.getIntegerInstance(locale).format(value.roundToLong())

    private fun duration(seconds: Double): String {
        val minutes = (seconds / 60.0).roundToLong()
        return "${minutes / 60}h${(minutes % 60).toString().padStart(2, '0')}"
    }
}
