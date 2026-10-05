package com.homefelipev.healthcoach.data.telegram

import com.homefelipev.healthcoach.data.healthconnect.HealthMetricSnapshot
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class TelegramException(message: String) : Exception(message)

internal fun sendMessagePayload(config: TelegramConfig, text: String): JSONObject =
    JSONObject().put("chat_id", config.chatId).put("text", text).apply {
        config.threadId?.let { put("message_thread_id", it) }
    }

open class TelegramHttp {
    open suspend fun sendMessage(config: TelegramConfig, text: String): String = withContext(Dispatchers.IO) {
        require(config.configured) { "Telegram não configurado." }
        val payload = sendMessagePayload(config, text)
        val connection = (URL("https://api.telegram.org/bot${config.botToken}/sendMessage").openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val response = (if (code in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) throw TelegramException("Telegram recusou o envio (HTTP $code).")
            if (!JSONObject(response).optBoolean("ok", false)) throw TelegramException("Telegram retornou uma resposta inesperada.")
            response
        } catch (failure: IOException) {
            throw TelegramException(failure.message ?: "Falha de rede ao contatar o Telegram.")
        } finally {
            connection.disconnect()
        }
    }
}

class HealthSummarySender(
    private val http: TelegramHttp = TelegramHttp(),
    private val config: TelegramConfig = TelegramConfig.fromBuildConfig(),
) {
    val configured: Boolean get() = config.configured

    suspend fun send(date: LocalDate, snapshots: List<HealthMetricSnapshot>) {
        http.sendMessage(config, HealthSummaryFormatter.format(date, snapshots))
    }
}
