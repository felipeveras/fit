# Validação física e cutover Flutter

Status desta entrega: treinos, hábitos e bridges estão integrados no Flutter.
Os checks centrais devem ter resultados e SHA final registrados pelo coordenador;
este checklist não declara que a rodada integrada ou CI remoto foi concluída.
O proprietário confirmou que ainda não validou dados reais e Telegram em aparelho
físico. O emulador sem produtor não comprova paridade. Kotlin legado permanece
disponível, com applicationId Flutter separado, e a #19 permanece aberta.


## Checks centrais (sequenciais)

No diretório `app_flutter`: `flutter pub get`, `dart format lib test`,
`flutter analyze`, `flutter test`, `flutter build apk --debug`.
Depois, em `app_flutter/android`: `./gradlew :app:testDebugUnitTest :app:lintDebug`.
No Windows, usar gradlew.bat e o helper `tool/lint-android.ps1` para local.properties.
Não executar Gradle em paralelo entre worktrees. Revisar diff produzido pelo format.
O workflow Flutter aceita workflow_dispatch e guarda APK/relatórios; registrar o
link da execução e confirmar artefatos antes de considerar CI validado.

## Aparelho real

1. Executar `adb devices -l`; escolher serial físico explicitamente, sem usar
   `emulator-5554`. Registrar modelo/API, SHA, versões dos produtores e timezone.
2. Instalar com `adb -s SERIAL install -r app_flutter/build/app/outputs/flutter-apk/app-debug.apk`
   a partir da raiz. Abrir `adb -s SERIAL shell am start -n com.homefelipev.healthcoach.flutter/.MainActivity`.
3. Conceder pela UI do Health Connect, sem adb grant: sete métricas, somente passos,
   somente exercícios, histórico opcional, negar e revogar. Reiniciar/retomar app.
4. Comparar com Kotlin e fonte produtora: hoje/7/30/90 dias, unidades, valores null,
   origens, limites históricos, sono overnight e exercícios/corridas. Registrar
   dados anonimizados, sem tokens, IDs pessoais ou capturas de configurações Telegram.
5. Confirmar home, configurações, estados vazios/erro e funcionamento sem IA.
   Para #21, verificar origem selecionada e deduplicação após nova importação.
6. Apenas em sessão explicitamente autorizada para envio: configurar bot/chat de
   teste no aparelho, enviar resumo uma vez, comparar conteúdo/horário/ausências
   com Kotlin e verificar proteção contra duplo envio. Não registrar credenciais.
7. Reiniciar aparelho e testar agendamento/background conforme implementação
   integrada e permissões disponíveis; não inferir funcionamento de envio diário
   automático a partir de um envio manual.

## Gate de cutover

Ainda pendentes: paridade física com dados reais, Telegram real autorizado,
agendamento/background e evidências dos checks/CI da composição integrada. Decidir
applicationId definitivo, assinatura/versionCode, migração de preferências e
credenciais/consentimento, procedimento de atualização e rollback antes de trocar
o launcher/distribuição. Não copiar dados ou segredos entre apps silenciosamente.
Só apos evidências e decisão do coordenador realizar cutover; este commit não o faz.
