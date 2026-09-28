package com.homefelipev.healthcoach.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.homefelipev.healthcoach.data.healthconnect.*
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val model: HealthConnectPermissionsViewModel = viewModel()
            val state by model.state.collectAsStateWithLifecycle()
            val scope = rememberCoroutineScope()
            val permissionLauncher = rememberLauncherForActivityResult(
                PermissionController.createRequestPermissionResultContract(),
            ) { model.afterPermissionResult() }
            LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { model.refresh() }

            fun perform(action: PermissionAction) {
                try {
                    when (action) {
                        is PermissionAction.Request -> permissionLauncher.launch(action.permissions)
                        PermissionAction.Manage -> startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS))
                        PermissionAction.None -> Unit
                    }
                } catch (_: Exception) { model.controller.actionFailed() }
            }

            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    Column(
                        Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Text("Health Connect", style = MaterialTheme.typography.headlineMedium)
                        Text("O Health Coach consulta somente os tipos que você autorizar. Você pode revogar o acesso a qualquer momento no Health Connect.")
                        Text("Passos, sessões de sono, frequência cardíaca em repouso, calorias ativas, calorias totais, distância e peso.")
                        val status = when {
                            state.busy -> "Consultando disponibilidade e permissões…"
                            state.errorCode != null -> "Não foi possível acessar o Health Connect. Tente novamente."
                            state.provider == ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED -> "Instale ou atualize o Health Connect e volte para esta tela."
                            state.provider == ProviderState.UNAVAILABLE -> "Health Connect indisponível neste aparelho."
                            else -> "${state.granted.size} de ${HealthConnectPermissions.dataRead.size} permissões de dados concedidas."
                        }
                        Text(status, Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        Button(enabled = !state.busy && state.provider == ProviderState.AVAILABLE,
                            onClick = { scope.launch { perform(model.controller.dataAction()) } }) {
                            Text(if (state.granted.size == HealthConnectPermissions.dataRead.size) "Gerenciar permissões" else "Escolher permissões de dados")
                        }
                        if (state.provider == ProviderState.PROVIDER_MISSING_OR_UPDATE_REQUIRED) {
                            Button(onClick = {
                                try {
                                    startActivity(Intent(Intent.ACTION_VIEW, "https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata".toUri()))
                                } catch (_: Exception) { model.controller.actionFailed() }
                            }) { Text("Instalar ou atualizar Health Connect") }
                        }
                        Button(enabled = !state.busy, onClick = { model.refresh() }) { Text("Verificar novamente") }
                        if (state.provider == ProviderState.AVAILABLE) {
                            Text("Histórico ampliado permite consultar até 90 dias quando autorizado. Sem essa permissão, a cobertura respeita o primeiro consentimento observado.")
                            CapabilityButton("Histórico ampliado", state.capabilities.history, state) {
                                scope.launch { perform(model.controller.capabilityAction(ReadCapability.HISTORY)) }
                            }
                            Text("Leitura com o app fechado é opcional. A autorização não garante horário de execução; você pode continuar com leituras em primeiro plano.")
                            CapabilityButton("Leitura com o app fechado", state.capabilities.background, state) {
                                scope.launch { perform(model.controller.capabilityAction(ReadCapability.BACKGROUND)) }
                            }
                        }
                        TextButton(onClick = { startActivity(Intent(this@MainActivity, PermissionsRationaleActivity::class.java)) }) {
                            Text("Privacidade e uso dos dados")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CapabilityButton(label: String, capability: CapabilityState, state: PermissionsState, onClick: () -> Unit) {
    val suffix = when (capability) {
        CapabilityState.FEATURE_UNAVAILABLE -> "indisponível neste provedor"
        CapabilityState.NOT_GRANTED -> "não autorizado"
        CapabilityState.AVAILABLE_AND_GRANTED -> "autorizado"
        CapabilityState.OS_DEFERRED -> "adiado pelo sistema"
    }
    Text("$label: $suffix")
    Button(
        enabled = !state.busy && state.granted.isNotEmpty() && capability in setOf(CapabilityState.NOT_GRANTED, CapabilityState.AVAILABLE_AND_GRANTED),
        onClick = onClick,
    ) { Text(if (capability == CapabilityState.AVAILABLE_AND_GRANTED) "Gerenciar $label" else "Autorizar $label") }
}
