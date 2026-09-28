# HOM-27 — correções do review independente

Escopo: integração Health Connect, consentimento, normalização e testes. Nenhuma implementação de sync remoto, WorkManager, Room, Supabase, Hermes, Telegram ou métricas opcionais foi adicionada. Os documentos da HOM-25 são planejamento histórico; o contrato ativo de banco da V1 está em [supabase/README.md](../supabase/README.md). Esta branch não altera esses documentos além do que já entrou em `main` pela HOM-26.

## Validação antes das alterações

As causas foram verificadas individualmente no código original, no manifest, nas regras de mapeamento Health Connect planejadas na HOM-25 e nas fontes do SDK Health Connect 1.1.0. Para problemas do repository foram adicionados oito testes antes de mudar a implementação. A execução `gradlew.bat :app:testDebugUnitTest --tests '*ReviewRegressionTest' --console=plain` terminou com **8 testes, 8 falhas**, reproduzindo alcance móvel do histórico, troca de origem, metadados/ambiguidade de sono, cancelamento capturado, readAt antecipado e validação numérica parcial. Os problemas de adapter, desempate, callback, provider, privacidade e capabilities também tiveram confirmação por inspeção das APIs e dos respectivos pontos de integração antes da alteração.

O SDK declara que o resultado de permissões é um subconjunto das permissões solicitadas. Seus tipos de amostras expõem `metadata.lastModifiedTime`. PermissionController 1.1.0 e o HealthConnectManager público do SDK Android 36 não fornecem o timestamp da primeira concessão; não foi inventada uma API para obtê-lo. A ausência de feature e a ausência de grant são verificações diferentes.

## Matriz

Os nomes dos testes abaixo são métodos nas suítes em `app/src/test/java/com/homefelipev/healthcoach/`. IDs/severidades correspondem ao review original.

| Finding | Causa confirmada | Correção | Teste / evidência | Resultado |
| --- | --- | --- | --- | --- |
| 1 — P1, sono entre dias | Query começava à meia-noite; fake anterior ignorava filtros | `TimeRangeFilter.before(end)`, todas as páginas e atribuição por término, sem lookback fixo | `AndroidHealthConnectDataSourceTest.overnightAndLongSleepUseOpenStartAndConsumeAllPagesUntilEmptyToken`, `overnightAdapterReadFeedsTheRepositoryWithoutClippingAtMidnight`; sessão longa de seis dias | Corrigido |
| 2 — P1, histórico | `hoje - 30 dias` e SecurityException tratada sempre como revogação | Alcance estável da primeira concessão observada; restrição provada separada de fronteira incerta; rechecagem de grant em falha de segurança | `ReviewRegressionTest.accessibleHistoryDoesNotExpireAsTodayAdvances`, `restrictedAndUnknownHistoryNeverBecomeCompleteEmptySnapshots`, `historyGrantAllowsOldDaysAndGenericSecurityFailureIsNotRevocation`; persistência Android | Corrigido com tratamento explícito da incerteza do SDK |
| 3 — P1, origem | Descoberta/escolha independente em cada dia | Uma leitura completa e descoberta sobre todo período autorizado solicitado; múltiplas origens pendentes ficam ambíguas | `ReviewRegressionTest.pendingOriginMustBeStableAcrossTheWholeRequestedPeriod`, `selectedMissingOriginStaysEmptyRatherThanFallingBack` | Corrigido |
| 4 — P2, metadados de sono | Origem/contagem consideradas antes da atribuição ao dia | Filtrar por término antes de descobrir origem e contar; no_data exige origins=[], observedAt=null e count=0/null | `ReviewRegressionTest.sleepEndingTomorrowDoesNotContributeToTodaysMetadata`, `sleepOriginDiscoveryExcludesSessionsEndingOutsideRequestedDates`, `sleepAtMidnightBelongsToTheDateOnWhichItEndsAndKeepsFullDuration` | Corrigido |
| 5 — P2, cancelamento | Catch genérico interceptava CancellationException | Propagação de cancelamento no repository, adapter e controlador de permissões | `ReviewRegressionTest.cancellationEscapesTheRepository`, `AndroidHealthConnectDataSourceTest.cancelledSdkPagePropagates`, `HealthConnectPermissionsControllerTest.cancellationStillPropagates` | Corrigido |
| 6 — P2, desempate de peso | Adapter descartava lastModifiedTime; escolha usava só time/id | Preservar modificação e ordenar por time, lastModifiedTime, id; deduplicar IDs por modificação | `ReviewRegressionTest.weightTiesUseModificationTimeThenStableIdRegardlessOfPageOrder`, `duplicateIdsAreCountedOnceAndKeepTheLatestModification`, `AndroidHealthConnectDataSourceTest.sdkWeightTiesSelectTheLatestModifiedObservationEndToEnd` | Corrigido |
| 7 — P2, readAt | Timestamp e provisório calculados antes da leitura | Gerar após leitura/normalização, truncar instantes ao milissegundo, reavaliar dia aberto | `ReviewRegressionTest.readAtAndProvisionalStateAreDeterminedAtCompletion`, incluindo virada de meia-noite | Corrigido |
| 8 — P2, conjunto de permissões | Callback de request parcial substituía o conjunto completo; gerenciamento era no-op | Callback consulta conjunto autoritativo completo; eventos serializados; todas concedidas abrem settings | `HealthConnectPermissionsControllerTest.partialResultRefreshesAllSevenGrantsAndManagementOpensSettings`, `revocationOnResumeUpdatesTheCompletePermissionSet` | Corrigido |
| 9 — P2, erros de provider | Suspend calls/launches sem tratamento recuperável | Estados sanitizados, busy finalizado, retry e tratamento de falhas no lançamento de intents | `HealthConnectPermissionsControllerTest.providerAndPermissionFailuresAreSanitizedAndRetryRecovers`, `featureFailureAndActionFailureLeaveRecoverableStates` | Corrigido |
| 10 — P2, recuperação de provider | remember(client=null) nunca era reavaliado no retorno | Reavaliar SDK/provider e permissões em ON_RESUME e no retry; ações de instalação/atualização | `HealthConnectPermissionsControllerTest.resumeAfterProviderInstallationReacquiresPermissions`, `AndroidHealthConnectDataSourceTest.featuresAndGrantsAreIndependentAndProviderStateIsNotCached` | Corrigido |
| 11 — P2, privacidade | Ambos intents abriam tela de grant sem política | Activity dedicada, texto de finalidade/acesso/armazenamento/retention/sharing/exclusão; consent metadata excluído de backup/transfer | `PrivacyAndConsentAndroidTest.bothPrivacyEntryPointsResolveToTheDedicatedPolicyActivity` em APIs 28/34; XML de backup | Corrigido |
| 12 — P2, capabilities | Histórico consultado mas não declarado/solicitável; background/features ausentes | Declarações READ, capabilities explícitas, solicitações opcionais separadas e condicionadas à feature; recusa mantém foreground | `HealthConnectPermissionsControllerTest.unavailableCapabilitiesAreNeverRequestedAndRequestsAreSeparate`, `AndroidHealthConnectDataSourceTest.featuresAndGrantsAreIndependentAndProviderStateIsNotCached`, `PrivacyAndConsentAndroidTest.manifestDeclaresOnlyReadDataAndSeparateHistoryBackgroundPermissions` | Corrigido |
| 13 — P3, validação numérica | Negativos aceitos, passos truncados, amostras inválidas removidas silenciosamente | Validar conjunto completo, finitude, sinal, passos inteiros/faixa JSON, peso positivo após HALF_UP; erro incompleto | `ReviewRegressionTest.invalidAggregateValuesAreIncompleteErrorsRatherThanNormalizedSuccess`, `invalidNewestWeightIsNotSilentlyReplacedByAnOlderValue`, `invalidMixedRestingHeartRateDoesNotPublishAFilteredMean`, `roundingCannotTurnPositiveWeightIntoAnAvailableZero` | Corrigido |

## Histórico e origem: limites preservados

O primeiro grant real não é consultável por essa versão do SDK. O app registra um intervalo honesto: a concessão não pode anteceder a instalação e já ocorreu quando um grant de dados é observado. O intervalo é persistido localmente e não se move em leituras ordinárias. Antes do limite inferior menos 30 dias, a restrição é provada; depois do limite superior menos 30 dias, a leitura completa é autorizada; no intervalo incerto, o resultado é **read_error/incompleto**, sem no_data e sem afirmar history_restricted. Um grant de histórico com feature disponível permite ler o histórico ampliado. Reinstalação começa com metadados novos, excluídos de backup/transfer. Esse comportamento preserva os estados de disponibilidade definidos para o repository.

Uma origem única descoberta ainda é candidata local. O consumidor futuro HOM-28 deverá definir e persistir uma escolha estável de origem antes do upload, compatível com o contrato de duas tabelas da V1. Este trabalho não implementa a sincronização. Falha em qualquer página invalida a leitura completa do conjunto solicitado, preservando dados anteriores.

## Validação final

Após a atualização para `main` (`05b3426`), `gradlew.bat build --console=plain` terminou com **BUILD SUCCESSFUL** em 1m09s. Gerou `app/build/outputs/apk/debug/app-debug.apk` e `app/build/outputs/apk/release/app-release-unsigned.apk` e validou testes e lint; as suítes de testes estavam `UP-TO-DATE` nessa execução.

| Suíte | Debug | Release | Falhas / erros / ignorados |
| --- | ---: | ---: | --- |
| DefaultHealthConnectRepositoryTest | 7 | 7 | 0 / 0 / 0 |
| ReviewRegressionTest | 18 | 18 | 0 / 0 / 0 |
| AndroidHealthConnectDataSourceTest | 10 | 10 | 0 / 0 / 0 |
| HealthConnectPermissionsControllerTest | 8 | 8 | 0 / 0 / 0 |
| PrivacyAndConsentAndroidTest (APIs 28 e 34) | 6 | 6 | 0 / 0 / 0 |
| **Total** | **49** | **49** | **0 / 0 / 0** |

São **98 execuções aprovadas**. Relatórios: `app/build/reports/tests/testDebugUnitTest/index.html`, `app/build/reports/tests/testReleaseUnitTest/index.html` e `app/build/reports/lint-results-debug.html`. Lint: **0 erros, 8 avisos**, todos de versões mais novas de dependências (seis de produção e dois de teste). Os três avisos adicionais de código foram resolvidos: idioma português informado ao lint, URI via KTX e supressão localizada/documentada para preservar a verificação do resultado de `SharedPreferences.commit()`.

`git diff --cached --check` passou no pacote completo. Após a HOM-26 entrar em `main`, esta branch avançou para `05b3426`; os quatro documentos históricos da HOM-25 vieram dessa atualização, sem edição específica da HOM-27. Nenhum finding foi descartado como não aplicável.

Cobertura adicional: dias de 23/25 horas, união e arredondamento final de intervalos de sono, IDs duplicados, origem escolhida sem fallback, constantes/unidades/filtros da Aggregate API, null versus zero, paginação null/vazia/interrompida/cíclica e negação parcial. Nos agregados de energia, a fonte do SDK 1.1.0 confirma `Energy::kilocalories`; o adapter já convertia corretamente e o fixture foi ajustado a essa unidade.

Não há aparelho/emulador conectado (`adb devices` vazio). Robolectric APIs 28/34 e clientes simulados exercitam manifesto, consentimento e fronteiras SDK; não substituem o gate de leituras reais, comparação com os produtores e compatibilidade do serviço instalado previsto pela HOM-25. Nenhum dado pessoal foi usado nos testes.
