package com.homefelipev.healthcoach.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.homefelipev.healthcoach.data.healthconnect.AndroidHealthConnectGateway
import com.homefelipev.healthcoach.data.healthconnect.androidFirstGrantTracker
import kotlinx.coroutines.launch

class HealthConnectPermissionsViewModel(application: Application) : AndroidViewModel(application) {
    val controller = HealthConnectPermissionsController(AndroidHealthConnectGateway(application), androidFirstGrantTracker(application))
    val state = controller.state
    fun refresh() { viewModelScope.launch { controller.refresh() } }
    fun afterPermissionResult() { viewModelScope.launch { controller.afterPermissionResult() } }
}
