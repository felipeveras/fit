package com.homefelipev.healthcoach.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.homefelipev.healthcoach.data.healthconnect.HealthMetric
import com.homefelipev.healthcoach.data.sync.HealthSync
import com.homefelipev.healthcoach.data.sync.HealthSyncScheduler
import com.homefelipev.healthcoach.data.sync.SupabaseSessionStore
import com.homefelipev.healthcoach.data.sync.SyncAuthException
import com.homefelipev.healthcoach.data.sync.SyncReport
import com.homefelipev.healthcoach.data.sync.SyncStateStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class HealthSyncUiState(
    val signedIn: Boolean = false,
    val userId: String? = null,
    val consented: Boolean = false,
    val busy: Boolean = false,
    val report: SyncReport? = null,
    val error: String? = null,
)

class HealthSyncViewModel(application: Application) : AndroidViewModel(application) {
    private val sessions = SupabaseSessionStore(application)
    private val stateStore = SyncStateStore(application)
    private val sync = HealthSync(application, sessions, stateStore)
    private val mutable = MutableStateFlow(HealthSyncUiState(signedIn = sessions.hasSession()))
    val state = mutable.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            try {
                val session = sessions.current()
                mutable.value = mutable.value.copy(signedIn = session != null, userId = session?.userId,
                    consented = session?.let { stateStore.consented(it.userId) } ?: false,
                    report = session?.let { stateStore.report(it.userId) })
                if (session != null && stateStore.consented(session.userId)) HealthSyncScheduler.schedule(getApplication())
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: SyncAuthException) {
                HealthSyncScheduler.cancel(getApplication())
                mutable.value = HealthSyncUiState(error = "Sessão expirada. Entre novamente.")
            }
            catch (failure: Exception) { mutable.value = mutable.value.copy(error = failure.message) }
        }
    }

    fun signIn(email: String, password: String) {
        if (email.isBlank() || password.isBlank()) {
            mutable.value = mutable.value.copy(error = "Informe email e senha.")
            return
        }
        viewModelScope.launch {
            mutable.value = mutable.value.copy(busy = true, error = null)
            try {
                val session = sessions.signIn(email, password)
                mutable.value = HealthSyncUiState(signedIn = true, userId = session.userId,
                    consented = stateStore.consented(session.userId), report = stateStore.report(session.userId))
                if (stateStore.consented(session.userId)) HealthSyncScheduler.schedule(getApplication())
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { mutable.value = mutable.value.copy(error = failure.message) }
            finally { mutable.value = mutable.value.copy(busy = false) }
        }
    }

    fun signOut() {
        viewModelScope.launch {
            mutable.value = mutable.value.copy(busy = true)
            try {
                HealthSyncScheduler.cancel(getApplication())
                sessions.signOut()
                mutable.value = HealthSyncUiState()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { mutable.value = mutable.value.copy(error = failure.message, busy = false) }
        }
    }

    fun syncNow() {
        if (mutable.value.busy || !mutable.value.signedIn || !mutable.value.consented) return
        viewModelScope.launch {
            mutable.value = mutable.value.copy(busy = true, error = null)
            try {
                val report = sync.run(background = false)
                mutable.value = mutable.value.copy(report = report, error = if (report == null) "Entre novamente na sua conta." else null)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { mutable.value = mutable.value.copy(error = failure.message) }
            finally { mutable.value = mutable.value.copy(busy = false) }
        }
    }

    fun authorizeSync() {
        val userId = mutable.value.userId ?: return
        stateStore.setConsent(userId, true)
        HealthSyncScheduler.schedule(getApplication())
        mutable.value = mutable.value.copy(consented = true)
    }

    fun revokeSync() {
        val userId = mutable.value.userId ?: return
        stateStore.setConsent(userId, false)
        HealthSyncScheduler.cancel(getApplication())
        mutable.value = mutable.value.copy(consented = false)
    }

    fun selectOrigin(metric: HealthMetric, packageName: String) {
        val userId = mutable.value.userId ?: return
        stateStore.selectOrigin(userId, metric, packageName)
        syncNow()
    }
}
