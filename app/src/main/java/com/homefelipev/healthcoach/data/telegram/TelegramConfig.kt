package com.homefelipev.healthcoach.data.telegram

import com.homefelipev.healthcoach.BuildConfig

data class TelegramConfig(
    val botToken: String,
    val chatId: String,
    val threadId: Long?,
) {
    val configured: Boolean get() = botToken.isNotBlank() && chatId.isNotBlank()

    companion object {
        fun fromBuildConfig(): TelegramConfig = TelegramConfig(
            botToken = BuildConfig.TELEGRAM_BOT_TOKEN,
            chatId = BuildConfig.TELEGRAM_CHAT_ID,
            threadId = BuildConfig.TELEGRAM_THREAD_ID.trim().takeIf(String::isNotEmpty)?.toLongOrNull(),
        )
    }
}
