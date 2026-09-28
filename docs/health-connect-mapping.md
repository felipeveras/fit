# Health Coach — mapeamento Health Connect v1

> **Planejamento histórico da HOM-25.** O contrato ativo do banco para a V1 está em [supabase/README.md](../supabase/README.md). RPCs, executores, lease, writer e Hermes descritos aqui foram adiados.

Planejamento HOM-25, 26/09/2026; implementação e verificação em aparelho pertencem à HOM-27. Normalização alimenta [database-schema.md](database-schema.md) e [sync-strategy.md](sync-strategy.md). Tipos abaixo são os contratos alvo, não confirmação de que Garmin/Health Sync os esteja exportando.

## 1. Plataforma e consentimento

Baseline Android `minSdk 28`; verificar `getSdkStatus` e disponibilidade de features em execução. Health Connect é integrado ao sistema no Android 14+; aparelhos anteriores compatíveis usam o provedor instalado. Android 9+ é necessário para usar a plataforma, mesmo que o SDK aceite Android 8, segundo o [guia oficial](https://developer.android.com/health-and-fitness/health-connect/get-started). Não presumir que presença do SDK implica serviço ou feature disponíveis.

Preferir release estável e fixar versão no scaffold: a [página de releases consultada](https://developer.android.com/jetpack/androidx/releases/health-connect) lista `1.1.0` estável. Revalidar antes de implementar; não adotar automaticamente a alpha usada em exemplos da documentação. Kotlin, Compose, Room, WorkManager e cliente Supabase terão versões compatíveis fixadas por HOM-27, sem instalar dependências nesta issue.

Solicitar apenas leitura das sete métricas usadas; recusa de uma não bloqueia as demais. Reavaliar permissões antes de cada execução e depois de voltar à UI. Declarações de manifest, rationale e eventuais declarações de distribuição devem corresponder ao uso real; detalhes em [tipos e permissões oficiais](https://developer.android.com/health-and-fitness/health-connect/data-types).

| Capacidade adicional | Permissão Android | Comportamento planejado |
| --- | --- | --- |
| Leitura em background | `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND` | Pedir separadamente, conferir `FEATURE_READ_HEALTH_DATA_IN_BACKGROUND`; sem feature/grant, leitura foreground/manual |
| Histórico ampliado | `android.permission.health.READ_HEALTH_DATA_HISTORY` | Pedir com justificativa para backfill até 90 dias, conferindo `FEATURE_READ_HEALTH_DATA_HISTORY`; sem grant, respeitar limite real |

O acesso padrão é limitado a até 30 dias anteriores à primeira concessão de permissão, não uma janela móvel que permita reler qualquer histórico. Reinstalação reinicia concessões. Assim, 90 dias de consulta Hermes podem conter lacunas no início. Os detalhes de [leitura/histórico/background](https://developer.android.com/health-and-fitness/health-connect/read-data) exigem tratamento explícito, sem retry infinito de uma restrição de consentimento.

## 2. Métricas iniciais

Permissões na tabela são de leitura; o Hub não solicita permissões WRITE. Unidades exibidas podem ser convertidas na UI (por exemplo segundos → horas, metros → km), mas persistência usa as unidades indicadas.

| Métrica / chave interna | Record / permissão | Valor diário canônico e regra v1 |
| --- | --- | --- |
| Passos / `steps` | `StepsRecord`; `READ_STEPS` | `COUNT_TOTAL` via Aggregate API; `count`, inteiro. Não somar listas de registros de múltiplos apps |
| Sono / `sleep_duration` | `SleepSessionRecord`; `READ_SLEEP` | Duração unida das sessões encerradas na data, de uma origem selecionada; `s`. V1 mede duração de sessão, com flag `session_duration_proxy`, sem chamar o valor de tempo efetivamente dormido |
| FC em repouso / `resting_heart_rate` | `RestingHeartRateRecord`; `READ_RESTING_HEART_RATE` | Média aritmética das observações diárias da origem selecionada; `bpm`. Não substituir por média/min de `HeartRateRecord` |
| Calorias ativas / `active_energy` | `ActiveCaloriesBurnedRecord`; `READ_ACTIVE_CALORIES_BURNED` | `ACTIVE_CALORIES_TOTAL` via Aggregate API; energia em `kcal` |
| Calorias totais / `total_energy` | `TotalCaloriesBurnedRecord`; `READ_TOTAL_CALORIES_BURNED` | `ENERGY_TOTAL` via Aggregate API; `kcal`. Não somar calorias ativas novamente e não derivar de BMR se ausente |
| Distância / `distance` | `DistanceRecord`; `READ_DISTANCE` | `DISTANCE_TOTAL` via Aggregate API; `m`. Não estimar passos × passada |
| Peso / `weight` | `WeightRecord`; `READ_WEIGHT` | Última observação na data da origem selecionada; `kg`. Preservar instante; não preencher dias sem medição |

Os nomes de manifest são `android.permission.health.<READ_…>`; gerar os contratos de leitura pelo helper `HealthPermission.getReadPermission(recordClass)` no adapter futuro. Tipos/permissões foram conferidos na [referência oficial](https://developer.android.com/health-and-fitness/health-connect/data-types); funções/constantes devem ser compiladas contra a versão fixada em HOM-27.

Métodos do diário: `hc_aggregate_total_v1` para cumulativas; `sleep_session_duration_v1` para sono; `selected_origin_mean_v1` para FC; `selected_origin_last_v1` para peso. A disponibilidade de estágio de sono pode servir a evolução futura, mas não altera silenciosamente a definição de sono v1. Para mudar para tempo dormido, versionar método/mapping e recalcular períodos comparáveis.

## 3. Origem e deduplicação

`metadata.dataOrigin.packageName` identifica o aplicativo que escreveu em Health Connect. Ele pode ser Health Sync e não Garmin. Preservar origens retornadas pela leitura/agregação; não fixar nomes de pacotes ainda não observados. Descobrir pacotes por métrica em foreground e mostrar a escolha no diagnóstico.

Política inicial:

- Passos, distância e energias usam Aggregate API, com preferência da plataforma quando aplicável. A plataforma aplica prioridade/deduplicação a tipos de Activity/Sleep, não a toda métrica indiscriminadamente. Não recalcular total como soma de todos os records. Conferir valores com múltiplas origens em HOM-27; se o tipo/fornecedor continuar duplicando, selecionar uma origem explicitamente e versionar a política.
- Sono, FC repouso, peso, HRV e atividades usam uma origem por métrica. Uma única origem descoberta pode ser adotada; se houver várias e não houver escolha anterior, retornar `source_ambiguous` e pedir seleção na UI futura. Nunca escolher a origem que produz “melhor” número.
- IDs iguais em páginas/retries são o mesmo registro: deduplicar por `metadata.id`. `clientRecordId`/`clientRecordVersion`, quando presentes, ajudam diagnóstico, mas não são chave global nem requisito imposto a produtor externo. Empates de observações: `time`, depois `lastModifiedTime`, depois `metadata.id`, com ordenação estável.
- Não misturar namespaces de stores/aparelhos. IDs Health Connect não são prometidos como portáveis; o writer ativo e a substituição completa por dia evitam união de snapshots de aparelhos distintos.

A semântica da plataforma e o filtro `dataOriginFilter` constam em [Read aggregated data](https://developer.android.com/health-and-fitness/health-connect/aggregate-data). Números agregados ausentes devem continuar null no Hub mesmo quando exemplos de SDK convertem ausência em zero.

## 4. Datas, intervalos e casos de borda

Fuso de análise pertence ao perfil, inicialmente `America/Sao_Paulo`, não ao fuso transitório do aparelho. Calcular início/fim de cada data com `ZoneId`, convertendo fronteiras em instantes UTC. Dia pode ter 23/25 horas; não dividir por blocos fixos de 24h. Guardar fuso, fronteiras, método e versão em cada snapshot.

Métricas cumulativas: pedir agregado exatamente para as fronteiras do dia; a plataforma trata contribuições dos intervalos. Se usar buckets por período no SDK, seguir exigência de `LocalDateTime`, sem passar `Instant` onde não é aceito. Não dividir manualmente passos/energia proporcionalmente ao tempo supondo intensidade uniforme.

Peso/FC/HRV: atribuir pelo instante convertido ao fuso de análise. “Última leitura” e “última medição” não são iguais: guardar `read_at` e `observed_at` separadamente. Para cumulativas, agregação pode não fornecer instante/contagem dos records; usar metadados da leitura paginada que alimenta o índice local quando disponíveis, mantendo esses campos null quando desconhecidos. `read_at` não é fallback de `observed_at`.

Sono: atribuir toda sessão ao dia em que termina no fuso de análise, inclusive cochilos. Exemplo: 25/09 23:00 → 26/09 07:00 pertence a 26/09 e representa oito horas de sessão. Ler sessões que atravessam a fronteira e filtrar por data de término; não restringir somente a data de início nem cortar o sono à meia-noite. Usar a seleção de intervalos sobrepostos conforme comportamento da versão fixada do SDK, cobrindo início anterior ao dia; testar sessões longas, fronteiras e paginação em HOM-27. Não aplicar lookback fixo que exclua silenciosamente sessão longa.

Sobreposição de sessões da mesma origem: unir intervalos antes de somar, mantendo IDs/intervalos no índice local para detectar correções. V1 não subtrai estágio awake nem presume que toda sessão seja sono efetivo. A UI deve indicar duração registrada da sessão e o coach preservar a flag; [modelo de sessões e estágios](https://developer.android.com/health-and-fitness/health-connect/features/sleep-sessions) distingue esses conceitos. Dados inválidos (`end <= start`, valor não finito etc.) produzem erro de qualidade e não substituem valor anterior por zero.

Hoje é provisório até a próxima data; encerrar o dia não garante que o produtor terminou de enviar dados. `read_complete` significa que a consulta terminou, não que Garmin/Health Sync sincronizou tudo. Sessão de treino pertence à data de início e guarda intervalo completo; sessão de sono pertence à data de término. Regras diferentes são intencionais e versionadas.

Mudança de fuso/método/origem usa update_analysis_config_v1 (mapping muda somente por migration administrativa), nunca alteração só no Room. Config_version global sobe, bloqueia fila antiga e degrada todas as projeções persistidas; v1 escolhe conservadoramente releitura dos tipos, mesmo quando somente uma preferência mudou. Recalcular histórico acessível; restante conserva versões/fuso antigos e verification_state=unverified_history. Não relabelar data antiga ao mudar fuso nem afirmar comparabilidade entre versões incompatíveis. Regra normativa em [verificação histórica](sync-strategy.md#history-verification).

## 5. Opcionais

| Métrica | Tipo / permissão | Gate de habilitação |
| --- | --- | --- |
| HRV | `HeartRateVariabilityRmssdRecord`; `READ_HEART_RATE_VARIABILITY`; `ms` | Observar exportação consistente na origem real, significado RMSSD e timestamps; média diária das amostras da origem selecionada. Não converter SDNN nem inventar HRV a partir de FC |
| Treinos | `ExerciseSessionRecord`; `READ_EXERCISE` | Validar tipo/intervalo/IDs/origem e correções em aparelho; conservar código original de tipo e mapear rótulo no app. Não solicitar rotas/GPS nem inferir calorias de sessão |

HOM-26 pode preparar armazenamento opcional. Ausência de HRV/treinos não bloqueia as sete métricas, sync, Saúde ou Semana. A confiabilidade não pode ser confirmada neste checkout, pois não existe conexão ao aparelho ou amostra real.

## 6. Estados e contrato do adapter

| Estado | Significado | Consequência no sync |
| --- | --- | --- |
| `available` | Consulta completa retornou valor válido | Substituir snapshot, inclusive zero realmente observado |
| `no_data` | Consulta completa do intervalo autorizado sem valor | Persistir null; pode remover valor que foi excluído na origem |
| `permission_denied` | Permissão da métrica ausente/revogada | Preservar remoto, indicar necessidade de ação |
| `history_restricted` | Dia solicitado fora do alcance autorizado | Não consultar indefinidamente; relatar lacuna |
| `unsupported` | Provedor/capacidade indisponível | Diagnóstico com instalar/atualizar quando pertinente |
| `read_error` | Falha técnica, quota ou leitura interrompida | Não marcar intervalo completo nem apagar dados |
| `source_ambiguous` | Várias origens em método que requer uma | Aguardar escolha, sem somar ou trocar silenciosamente |

Estado de plataforma adicional: `available`, `provider_missing_or_update_required`, `unavailable`; estado de background: `available_and_granted`, `not_granted`, `feature_unavailable`, `os_deferred`. Eles não se confundem com existência de registros.

Adapter deve consumir todas as páginas; fim de paginação considera token null ou vazio. Por métrica, leitura/agregação gera DTO do [contrato Android](architecture.md). Se houver falha em uma página, nenhum resultado daquele dia/tipo pode ser completo. Índice local guarda (source_scope_id,record_type,hc_id,origin,start/end/time,lastModifiedTime,affected_dates) para changes/exclusões, sem enviar série bruta ao banco. Source_scope_id vem exclusivamente do register/get/begin/renew do servidor; índice/tokens nunca atravessam namespace. Antes de cadastro online, leituras offline são candidatos locais sem scope de upload.

O adapter não promove verificação histórica: retorna disponibilidade/read_complete e evidência de impedimento. Apenas commit completo em contexto vigente produz verified no banco; permission_denied/history_restricted/change_tracking_lost podem gerar intenção separada de mark_history_unverified_v1, sem converter ausência de acesso em no_data. Leitura impedida conserva valor remoto; timeout/quota/provider temporariamente indisponível não gera degradação automática. Para workouts, retornar conjunto completo por data de início conforme [payload de atividades](sync-strategy.md#activity-payload); items=[] após leitura completa é no_data, com day state verificado. Changes com uma sessão isolada não prova conjunto completo nem autoriza apagar outras.

Plano do run sempre inclui as sete métricas em todas as datas pedidas, mais hrv_rmssd/exercise_sessions apenas se habilitados no perfil. Permissão negada não reduz expected_data_types: se outras datas/tipos foram confirmados, finish é partial; sem confirmação e com impedimento é blocked. Available/no_data completos contam para success mesmo sem valor novo; somente confirmação remota de todos os alvos atualiza last_success_at. Regras completas em [status de execução](sync-strategy.md#run-status), compartilhadas pelo adapter/worker/diagnóstico.

Normalização numérica usa HALF_UP decimal a três casas após conversão/agregação, conforme [schema](database-schema.md); passos permanecem inteiros. Não truncar duração/valor para caber em payload. Para hoje, is_provisional é true independentemente do término da consulta; dia fechado recalculado é false. Observed_at é null quando agregado não fornece instante e não há leitura paginada completa que o determine; sample_count é null quando desconhecido, 0 em no_data de leitura paginada vazia (pode continuar null em agregação). Origins de no_data é [], não pacote imaginado; preferência selecionada permanece na configuração.

### Seleção de origem e reset do store

No primeiro acesso, descobrir origens de todo histórico autorizado solicitado, por tipo, sem escolher pelo maior valor. Se tipo single_origin tem um pacote, persistir a escolha via update_analysis_config antes de begin; se nenhum pacote e consulta completa vazia, no_data é válido mesmo com escolha pendente. Múltiplos pacotes sem preferência retornam source_ambiguous. Preferência já definida e nenhuma leitura dessa origem retorna no_data, sem trocar origem. Platform_aggregate usa só comportamento de prioridade da plataforma; se validação detectar duplicação, selecionar explicitamente pacote/versão pelo mesmo contrato, antes de aceitar dados reais.

Não existe ID global de store fornecido por este contrato. Android persiste indicação local de continuidade (installation UUID, provedor/configuração e índice); reinstalação/limpeza detectada ou continuidade incerta solicita reset_source_scope explícito. Perda de token/índice sozinha, com continuidade conhecida, não cria namespace novo: marca change_tracking_lost e reconcilia histórico acessível. Conta/epoch/scope diferentes invalidam tokens, índices e envelopes associados, sem presumir portabilidade de hc_record_id. Detalhes e devolução do namespace em [cadastro de writer](sync-strategy.md#auxiliary-contracts).

## 7. Verificação futura de HOM-27

Registrar versão Android/API, provedor/SDK e origem observada por métrica sem expor dados pessoais nos logs. Testar Android anterior a 14 com provedor e Android 14+ com features disponíveis/indisponíveis, em ambientes acessíveis à equipe.

Critérios: permissão parcial e revogação; leitura vazia versus zero observado; null de aggregate; dois produtores sobrepostos; mudança de origem; peso com múltiplas medições; FC genérica sem FC repouso; conversão kcal/kg/m; sono cruzando meia-noite, sobreposição e sessão longa; paginação interrompida; restrição de histórico; dia de 23/25 horas; treino/HRV ausentes. Comparar valores com Health Connect na política selecionada, sem exigir igualdade com números Garmin que ainda não chegaram à plataforma.

Dados do diagnóstico podem indicar atraso da origem com base na observação mais recente. O app não possui acesso ao estado interno do Garmin/Health Sync e deve dizer isso explicitamente, sem atribuir causa de falha sem evidência.
