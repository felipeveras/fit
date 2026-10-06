package com.homefelipev.healthcoach.flutter

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Both Health Connect policy entry points work without a Flutter engine. */
class PermissionsRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val inset = (24 * resources.displayMetrics.density).toInt()
            setPadding(inset, inset, inset, inset)
            addView(TextView(context).apply {
                textSize = 24f
                text = "Privacidade e uso dos dados"
            })
            addView(TextView(context).apply {
                textSize = 18f
                text = "O App Fit lê passos, sessões de sono, frequência cardíaca em repouso, calorias, " +
                    "distância e peso somente conforme suas permissões. Sono representa duração das sessões, " +
                    "não tempo efetivamente dormido. Não fornece diagnóstico clínico.\n\n" +
                    "Os dados de saúde são lidos no aparelho e não são espelhados em banco próprio. " +
                    "O envio manual opcional ao Telegram envia apenas métricas disponíveis ao bot/chat configurado, " +
                    "sem servidor intermediário. Preferências do bot, horário do último envio e metadados " +
                    "do primeiro consentimento são guardados localmente, sem backup.\n\n" +
                    "Sessões de exercício e corrida têm permissão opcional independente das demais métricas. " +
                    "Não lemos rotas nem localização dos exercícios.\n\n" +
                    "Você pode negar ou revogar acesso no Health Connect. Histórico ampliado é opcional. " +
                    "Limpar os dados do app remove os registros locais. Revogar acesso não exclui dados do produtor."
            })
            addView(Button(context).apply { text = "Voltar"; setOnClickListener { finish() } })
        }
        setContentView(ScrollView(this).apply { addView(content) })
    }
}
