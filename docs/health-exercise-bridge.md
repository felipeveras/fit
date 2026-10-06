# Contrato de exercícios — #19 → #21

Implementação adicional, compatível com o bridge versão **1**, canal
`com.homefelipev.healthcoach/health`. MethodChannel fica somente no adapter
`MethodChannelHealthRepository`, que implementa `HealthExerciseRepository` e
`HealthRepository`. Os implementadores existentes da segunda interface não mudam.

## Chamadas

Todas recebem `version: 1` e respondem com `version: 1`.

| Método | Argumentos adicionais | Resposta |
|---|---|---|
| `getExercisePermissions` | nenhum | `provider`, `granted` (bool), `history` |
| `requestExercisePermission` | nenhum | mesma resposta, após o diálogo nativo |
| `getExerciseSessions` | `days`: 1/7/30/90; `originPackage`: string opcional | período descrito abaixo |

O diálogo solicita **somente READ_EXERCISE**. Não exige nem solicita passos ou
as outras sete métricas. O diálogo de métricas não solicita exercício. Histórico
ampliado usa a chamada existente `requestPermissions(kind: history)` e continua
opcional. Apenas um diálogo pode estar pendente: concorrência retorna
`permission_request_in_progress`. Cancelar/negar retorna o estado efetivo.

`provider`: `available`, `provider_missing_or_update_required`, `unavailable`.
`history`: `available_and_granted`, `not_granted`, `feature_unavailable`, `os_deferred`.
Falhas de transporte usam `HealthFailure` (`bridge_unavailable`, `bridge_detached`,
`unsupported_version`, `invalid_arguments`, `invalid_response`, `health_connect_error`,
`provider_unavailable`). Não há mensagens com dados de saúde nos erros.

## Período e cobertura

Resposta: `days`, `timezone` (zona do aparelho), `readAt` (UTC ISO-8601),
`sourcePolicy` (`all_origins` ou `single_origin`), `originPackage` (null ou filtro),
`coverage` e `sessions`. Datas locais seguem `yyyy-MM-dd`.

Cada cobertura contém `date`, `availability`, `readComplete`, `provisional`,
`origins` e `errorCode` nullable. Estados: `available`, `no_data`,
`permission_denied`, `history_restricted`, `unsupported`, `read_error`.
`no_data` é leitura completa vazia; os demais estados indisponíveis **não são zero**.
Hoje é provisional: completo significa que todas as páginas da consulta foram
lidas até `readAt`, não que o restante do dia está observado.

Histórico usa os limites conservadores do primeiro consentimento já existentes:
dias comprovadamente inacessíveis ficam `history_restricted`; fronteiras incertas
ficam `read_error`. Dias recentes podem ser retornados mesmo quando antigos estão
restritos. Falha de página/token repetido invalida toda a parte consultável, sem
publicar páginas parciais. Revogação com SecurityException vira `permission_denied`.
Cancelamento de coroutine se propaga. `errorCode`:
`exercise_permission_denied`, `provider_unavailable`, `history_restricted`,
`read_failed_or_history_boundary_uncertain`, ou null.

Cada sessão: `id`, `origin` (package produtor), `date`, `startAt`, `endAt`,
`lastModifiedAt`, `exerciseType` (int SDK), `isRunning` (corrida externa/esteira).
O dia é atribuído pelo **início**, inclusive sessões que atravessam meia-noite.
Só sessões encerradas até `readAt`; duração é a diferença dos timestamps.
Não transmite título, notas, rota, segmentos ou localização.

Deduplicação usa `(origin, id)`, escolhendo a revisão de maior `lastModifiedAt`.
Não funde cópias Garmin/Health Sync de origens diferentes: o consumidor pode
escolher `originPackage` explicitamente. Não somar indiscriminadamente origens
para concluir hábitos. IDs vazios invalidam a leitura; não há IDs inventados.

## Uso pela #21

Injetar `HealthExerciseRepository` separadamente. Consultar permissão de exercício
antes de exibir o CTA opcional, sem bloquear passos. Para avaliar ausência de
corrida, exigir cobertura completa do dia; hoje ainda é provisional. Ausência de
permissão, erro ou histórico inacessível deixa o hábito desconhecido. Persistir
identidade composta somente conforme a política de dados do módulo consumidor.

## Validação centralizada

Os novos testes Dart e Kotlin foram escritos, **não executados neste estágio**.
Executar format/analyze/test/build/lint sequencialmente no worktree central e
registrar resultado por SHA. Casos nativos: paginação, repetição de token, falha
na segunda página, fontes distintas, revogação, histórico, overnight e cancelamento.
No aparelho: concessão somente exercício, somente passos, negação/revogação,
duas fontes, sessão overnight, corrida/esteira e provider indisponível.
