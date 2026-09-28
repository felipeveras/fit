package com.homefelipev.healthcoach.data.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.homefelipev.healthcoach.BuildConfig
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.time.Clock
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

class RetryableSyncException(message: String) : IOException(message)
class SyncAuthException(message: String) : Exception(message)

open class SupabaseHttp {
    open suspend fun request(path: String, method: String, body: String? = null, accessToken: String? = null,
        headers: Map<String, String> = emptyMap()): String = withContext(Dispatchers.IO) {
        if (BuildConfig.SUPABASE_PUBLISHABLE_KEY.isBlank()) {
            throw SyncAuthException("Configure supabasePublishableKey no Gradle ou SUPABASE_PUBLISHABLE_KEY.")
        }
        val connection = (URL(BuildConfig.SUPABASE_URL + path).openConnection() as HttpURLConnection)
        try {
            connection.requestMethod = method
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("apikey", BuildConfig.SUPABASE_PUBLISHABLE_KEY)
            if (accessToken != null) connection.setRequestProperty("Authorization", "Bearer $accessToken")
            connection.setRequestProperty("Accept", "application/json")
            headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = connection.responseCode
            val response = (if (code in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            when {
                code in 200..299 -> response
                code == 429 || code >= 500 -> throw RetryableSyncException("Servidor indisponível (HTTP $code).")
                path.startsWith("/auth/v1/token") && code in 400..499 ->
                    throw SyncAuthException("Não foi possível entrar ou renovar a sessão (HTTP $code).")
                code == 401 || code == 403 -> throw SyncAuthException("Sessão sem autorização (HTTP $code).")
                else -> throw IllegalStateException("Supabase recusou a operação (HTTP $code).")
            }
        } catch (failure: IOException) {
            throw RetryableSyncException(failure.message ?: "Falha de rede.")
        } finally {
            connection.disconnect()
        }
    }
}

data class SupabaseSession(val userId: String, val accessToken: String, val refreshToken: String, val expiresAtEpochSecond: Long)

class SupabaseSessionStore(
    context: Context,
    private val http: SupabaseHttp = SupabaseHttp(),
    private val clock: Clock = Clock.systemUTC(),
) {
    private val prefs = context.applicationContext.getSharedPreferences("supabase_session", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val alias = "app_fit_supabase_session_v1"

    fun hasSession(): Boolean = prefs.contains("session")

    suspend fun signIn(email: String, password: String): SupabaseSession = mutex.withLock {
        val body = JSONObject().put("email", email.trim()).put("password", password).toString()
        val response = http.request("/auth/v1/token?grant_type=password", "POST", body)
        parseSession(JSONObject(response)).also { save(it) }
    }

    suspend fun current(): SupabaseSession? = mutex.withLock {
        val stored = read() ?: return@withLock null
        if (stored.expiresAtEpochSecond > clock.instant().epochSecond + 60) return@withLock stored
        try {
            val body = JSONObject().put("refresh_token", stored.refreshToken).toString()
            parseSession(JSONObject(http.request("/auth/v1/token?grant_type=refresh_token", "POST", body)))
                .also { save(it) }
        } catch (failure: SyncAuthException) {
            clear()
            throw failure
        }
    }

    suspend fun signOut() = mutex.withLock {
        val session = read()
        try {
            if (session != null) http.request("/auth/v1/logout", "POST", accessToken = session.accessToken)
        } catch (_: Exception) {
            // Local sign out always removes credentials, including while offline.
        } finally {
            clear()
        }
    }

    private fun parseSession(json: JSONObject): SupabaseSession {
        val user = json.getJSONObject("user").getString("id")
        val expiresIn = json.getLong("expires_in")
        require(expiresIn > 0)
        return SupabaseSession(user, json.getString("access_token"), json.getString("refresh_token"),
            clock.instant().epochSecond + expiresIn)
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }

    private fun save(session: SupabaseSession) {
        val plain = JSONObject().put("user_id", session.userId).put("access_token", session.accessToken)
            .put("refresh_token", session.refreshToken).put("expires_at", session.expiresAtEpochSecond)
            .toString().toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, secretKey()) }
        val encrypted = cipher.iv + cipher.doFinal(plain)
        prefs.edit().putString("session", Base64.getEncoder().encodeToString(encrypted)).apply()
    }

    private fun read(): SupabaseSession? {
        val encoded = prefs.getString("session", null) ?: return null
        return try {
            val bytes = Base64.getDecoder().decode(encoded)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            }
            val json = JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
            SupabaseSession(json.getString("user_id"), json.getString("access_token"),
                json.getString("refresh_token"), json.getLong("expires_at"))
        } catch (_: Exception) {
            clear()
            null
        }
    }

    private fun clear() { prefs.edit().remove("session").apply() }
}
