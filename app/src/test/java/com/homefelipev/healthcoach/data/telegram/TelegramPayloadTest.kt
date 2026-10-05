package com.homefelipev.healthcoach.data.telegram

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE)
class TelegramPayloadTest {
    private val config = TelegramConfig(botToken = "123:abc", chatId = "-100123", threadId = null)

    @Test
    fun sendsToChatWhenThreadIsAbsent() {
        val payload = sendMessagePayload(config, "olá")
        assertEquals("-100123", payload.getString("chat_id"))
        assertEquals("olá", payload.getString("text"))
        assertFalse(payload.has("message_thread_id"))
    }

    @Test
    fun includesThreadIdWhenConfigured() {
        val payload = sendMessagePayload(config.copy(threadId = 42L), "olá")
        assertEquals(42, payload.getInt("message_thread_id"))
    }

    @Test
    fun blankTokenOrChatIsNotConfigured() {
        assertFalse(config.copy(botToken = "").configured)
        assertFalse(config.copy(chatId = "").configured)
        assertEquals(true, config.configured)
    }
}
