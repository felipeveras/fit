# Health Coach — modelo de dados v1

> **Planejamento histórico (HOM-25).** A HOM-26 foi simplificada para uso pessoal.
> Para o schema atual, veja [supabase/README.md](../supabase/README.md).

Especificação de planejamento da HOM-25, 26/09/2026. Não contém DDL executável nem migrations. Provisionamento, SQL, funções, policies e testes pertencem à HOM-26. Contexto e decisões em [architecture.md](architecture.md); regras de produção dos valores em [health-connect-mapping.md](health-connect-mapping.md).

## 1. Organização e invariantes

Postgres do projeto Supabase dedicado; confirmar versão >= 15 para views `security_invoker`. Schemas privados `health`, `coach`, `integration`; somente `api` exposto à Data API, sem expor `public` por conveniência. Views de consulta e wrappers RPC v1 em `api`; funções compartilhadas de cálculo nos schemas privados, `SECURITY INVOKER`, mesmo comportamento para Android e Hermes. Exposição exige configuração do schema e grants além das policies, como descrito em [Using Custom Schemas](https://supabase.com/docs/guides/api/using-custom-schemas).

Todas as entidades de negócio têm proprietário `user_id uuid` referenciando `auth.users(id)`, com exclusão em cascata. Relações entre entidades usam FKs compostas incluindo `user_id`, impedindo que um ID da conta B seja vinculado à conta A. UUIDs técnicos são gerados na origem indicada; IDs não autorizam acesso. Instantes `timestamptz`, datas `date`, epoch/revision `bigint >= 0`, valores `numeric` finitos e unidades canônicas. Timestamps de commit/criação remota são emitidos pelo servidor; não confiar no relógio Android para ordenar uploads.

Diário é projeção materializada da origem, não ledger de incrementos. Não guardar séries brutas na nuvem. Null indica ausência; zero observado continua número. Mudança efetiva de valores/qualidade/configuração incrementa data_revision uma vez por operação e invalida gerações afetadas. Atualizar só horários de verificação ou reenviar payload idêntico não altera revisão. Migração e futuras correções administrativas seguem o mesmo lock/invalidação; não alterar projeção à margem do contrato.

## 2. Entidades

### `health.profiles`

PK `user_id`. Campos: `analysis_timezone text` (IANA válida), `config_version bigint > 0`, `source_policy_version integer > 0`, `mapping_version integer > 0`, `hrv_enabled boolean=false`, `activities_enabled boolean=false`, `created_at`, `updated_at`.

Fuso inicial America/Sao_Paulo, confirmado no cadastro. Health.metric_source_preferences: PK (user_id,data_type), tipos do [catálogo](sync-strategy.md#auxiliary-contracts), mode=platform_aggregate|single_origin, origin_package nullable, policy_version, updated_at. Platform aggregate só admite cumulativas e pacote null; demais tipos single_origin. Single origin com pacote null é escolha pendente: múltiplas origens causam source_ambiguous; zero origens após leitura completa permite no_data; única origem deve ser descoberta e salva antes do run. Cadastro cria preferências de todos os tipos com policy_version=1 e modos padrão do mapping. Habilitar opcionais exige gate do mapping. Mudança real incrementa config_version uma vez; mudança de origem/modo/opcional sobe source_policy_version global uma vez e atualiza policy_version das preferências alteradas. Qualquer mudança efetiva invalida todas as projeções/publicações por config_version global, conforme sync. Mapping v1 fixo em 1, só migration administrativa futura incrementa. No-op não incrementa. Hermes só lê configuração.

### `health.sync_state`

PK `user_id`. Campos: `active_installation_id uuid`, `source_scope_id uuid` (namespace do store Health Connect ativo), `writer_epoch bigint`, `data_revision bigint`, `lease_run_id uuid nullable`, `lease_token uuid nullable`, `lease_expires_at`, `last_attempt_at`, `last_success_at`, `last_success_run_id uuid nullable`, `last_completed_period_start/end date nullable`, `updated_at`. Lease run/token/expiração são todos null ou todos preenchidos; validade usa clock_timestamp do servidor, não relógio do aparelho.

Cadastro inicial/troca de writer pelo [catálogo de sync](sync-strategy.md#auxiliary-contracts); epoch e source_scope_id emitidos pelo banco. Namespace não muda por fuso/origem nem é prova física de identidade do store. Store novo não promete mesmas IDs Health Connect. Troca/reset cancela lease, invalida envelopes do epoch antigo e reclassifica projeções preservadas. `last_success_at`/run/período só avançam no finish de success: todas as datas de todos os tipos esperados, inclusive as sete métricas sem permissão, devem estar confirmadas em recibos; no_data completo conta como confirmação. Partial/blocked/failed/cancelled preservam último sucesso. Tipos opcionais desligados não entram no plano. Regras normativas em [status do run](sync-strategy.md#run-status).

### `health.daily_metrics`

PK composta `(user_id,local_date,metric)`. Não incluir run, instalação ou origem na chave canônica: eles mudam, o dia/métrica permanece único.

| Campo | Tipo / regra |
| --- | --- |
| `metric` | `steps`, `sleep_duration`, `resting_heart_rate`, `active_energy`, `total_energy`, `distance`, `weight`; `hrv_rmssd` somente quando habilitado |
| `value` | `numeric nullable`; >= 0; peso > 0 quando presente; passos inteiro; sem NaN/Infinity |
| `unit` | `count`, `s`, `bpm`, `kcal`, `m`, `kg`, `ms`; CHECK fixa o par métrica/unidade |
| `availability` | `available|no_data`; valor não nulo iff available; motivos impeditivos ficam em diagnóstico |
| `analysis_timezone` | Fuso de cálculo do snapshot; igual ao perfil/versão aceitos no commit |
| `period_start_at/end_at` | Limites do dia de análise; fim > início, não assumir 24 horas |
| `observed_at` | Última observação da origem usada; obrigatório null em no_data, nullable em available quando desconhecido |
| `read_at` | Fim da leitura no aparelho, UTC; informativo, não precedência de escrita |
| `sample_count` | Inteiro >= 0 quando conhecido; nullable quando agregado não informa contagem |
| `origins` | Array de pacotes efetivamente usados; não presume que escritor é Garmin |
| `aggregation_method` | Método versionado, por exemplo `hc_aggregate_total_v1`, `selected_origin_mean_v1`, `selected_origin_last_v1`, `sleep_session_duration_v1` |
| `config_version`, `source_policy_version`, `mapping_version` | Versões positivas validadas no commit; não reescrever versões de projeção histórica sem leitura |
| `source_scope_id`, `writer_epoch` | Proveniência do escritor que produziu a projeção |
| `is_provisional` | Hoje ou leitura cujo intervalo ainda está aberto; excluído de semana completa |
| `quality_flags` | Flags de método: `session_duration_proxy`, `missing_stage_coverage`; leitura adiciona `unverified_history` se verification_state exigir, sem aceitar essa flag do upload |
| `verification_state`, `verification_reasons` | `verified|unverified_history` e lista tipada de motivos; verified implica lista vazia; definidos pelo servidor |
| `verification_changed_at`, `last_verified_at` | Horários do servidor; degradação preserva last_verified_at; commit completo atualiza last_verified_at |
| `content_hash` | SHA-256 do conteúdo canônico, incluindo ausência/método/origem; exclui horários de tentativa |
| `revision`, `last_run_id`, `updated_at` | Revisão do dataset no commit e FK composta para run do proprietário |

Não persistir `permission_denied` como no_data nem apagar um valor válido por timeout. Leitura completa agora vazia substitui valor por `(no_data,null)`; essa linha serve de tombstone e evidência de reconciliação. Não criar linha para dia que não pôde ser lido.

### `health.activities` (opcional)

Preparar entidade na HOM-26; ingestão só após validação de treinos na HOM-27. PK `id uuid` gerado no banco; UNIQUE `(user_id,source_scope_id,hc_record_id)`. Campos: `origin_package`, `hc_record_id text`, `source_scope_id uuid`, `source_last_modified_at`, `exercise_type integer`, `start_at/end_at`, `start_local_date`, `analysis_timezone`, `duration_seconds numeric`, `writer_epoch`, `config_version`, `source_policy_version`, `mapping_version`, `verification_state`, `verification_reasons`, `verification_changed_at`, `last_verified_at`, `revision`, `last_run_id`, `updated_at`. Mesma classificação do diário; workouts é sinônimo de atividades, não entidade concorrente.

Selecionar uma origem por tipo; sem rotas GPS/notas/nomes pessoais. Distância/energia de sessão não são campos v1: não inferir do total diário. Conjunto completo substitui sessões cuja data de início pertence ao dia, removendo ausentes inclusive do namespace anterior. Troca de store/origem não duplica intervalo confirmado; histórico restante fica unverified. Cada atividade tem FK composta (user_id,start_local_date) para activity_day_states e classificação/contexto iguais aos da linha diária; trigger verifica isso ao fim da transação. IDs/páginas repetidos não duplicam sessão.

FK/constraint de day states é diferida para validar, ao commit, item_count igual ao número de atividades e availability coerente, também em movimentos. Movimento de ID entre dias exige sets completos de ambas as datas no mesmo envelope; regra e limites em [payload](sync-strategy.md#activity-payload). Não permitir upsert que deixe contagem antiga incorreta ou exclua sessão de dia não confirmado.

### `health.activity_day_states`

PK `(user_id,local_date)`, incluindo dia lido sem treino. Campos: `availability=available|no_data`, `item_count integer >= 0`, `analysis_timezone`, `config_version`, `mapping_version`, `source_policy_version`, `source_scope_id`, `writer_epoch`, `verification_state`, `verification_reasons`, `verification_changed_at`, `last_verified_at`, `read_at`, `content_hash`, `revision`, `last_run_id`, `updated_at`. Available iff item_count > 0. Commit de conjunto completo atualiza essa linha e as atividades na mesma transação; conjunto vazio completo cria no_data/verified e remove as atividades do dia. Tipo impedido não cria linha vazia. Degradação afeta linha diária e atividades vinculadas igualmente. Assim há evidência de releitura também quando o conjunto é vazio.

### `health.sync_runs`

PK `run_id uuid` gerado no Android antes de persistir outbox; UNIQUE `(user_id,run_id)` para FKs compostas. Campos: `installation_id`, `source_scope_id`, `writer_epoch`, `config_version`, `source_policy_version`, `mapping_version`, `expected_data_types text[]`, `trigger=periodic|foreground|manual|backfill|audit`, `requested_start/end date`, `analysis_timezone`, `started_at`, `finished_at nullable`, `status=running|success|partial|failed|blocked|cancelled`, `terminal_reason nullable`, `finish_payload_hash nullable`, `error_stage/code nullable`, `committed_batches`, `uploaded_items`, `changed_items`, `deleted_activities`, `contract_version=1`.

Início/fim e contadores são calculados pelo servidor. Run guarda também last_lease_token/last_lease_expires_at para finish tardio, sem liberar lease de sucessor. Run running com lease vencido aparece interrompido; próxima retomada fecha ou recupera explicitamente. Last_run_id das projeções e last_success_run_id de sync_state são FKs compostas nullable; ao limpar run após 90 dias, primeiro definir referências null mantendo seus timestamps/revision, remover confirmed_targets/results/receipts associados, depois run. Nunca apagar diário/atividades por expiração de telemetria; run recuperável não sobrevive prazo de retenção e outbox válida é no máximo sete dias.

### `health.sync_metric_results`

PK (user_id,run_id,data_type). Campos: requested_start/end, completed_dates date[] derivado de confirmações, date_results jsonb (um objeto por data: local_date, availability, read_complete, upload_state, error_stage/code), origins text[], records_read nullable, items_committed (servidor), source_latest_observed_at nullable, background_feature_available/background_permission_granted/history_permission_granted boolean, error_stage/code nullable, updated_at. Upload_state=confirmed|pending|failed|not_attempted separa leitura de upload. Não existe availability único que oculte dia bloqueado entre dias completos; respostas carregam date_results.

Período solicitado não implica cobertura completa; `completed_dates` distingue dias confirmados de dias impedidos. Contagem nativa de registros e contagem de snapshots enviados são conceitos distintos; se a primeira não existe na API de agregação, permanecer nullable. Não inventar sete “registros lidos” quando foram enviados sete agregados.

### `health.sync_confirmed_targets`

PK `(user_id,run_id,data_type,local_date)`; FK composta para run e batch receipt. Campos: `batch_id`, `availability=available|no_data`, `read_at`, `confirmed_at`. Somente commit completo cria/atualiza fatos de confirmação, inclusive atividades vazias. Servidor deriva completed_dates/contadores/status desses fatos; finish não pode inventar confirmações com relato do cliente. Retenção acompanha run/recibo.

### `health.sync_batch_receipts`

PK `(user_id,batch_id uuid)`; FK composta para `sync_runs`. Campos: `payload_hash`, `run_id`, `source_scope_id`, `writer_epoch`, `lease_token`, `config_version`, `base_revision`, `committed_revision`, `accepted_items`, `changed_items`, `deleted_activities`, `committed_at`. Recibo inclui targets confirmados para reconstrução do checkpoint.

Inserido na mesma transação dos dados e contadores. Mesmo batch e hash retornam o recibo original; mesmo batch com hash diferente é conflito. Manter recibos por 90 dias e limitar outbox a sete dias de idade; depois disso, descartar envelope e reler origem com nova identidade/revision. Esse prazo impede replay depois da expiração de recibos.

### `integration.operation_receipts`

PK `(user_id,operation_id uuid)`, `operation_kind`, `request_hash` (JCS/SHA-256), `response jsonb` sanitizada, `committed_at`. Idempotência auxiliar por 90 dias: mesma identidade/kind/hash devolve resultado original; outro kind/hash conflita. Escrita junto à operação na mesma transação. Não contém segredo Telegram ou credencial; create challenge é explicitamente não replayável. Registro/configuração/histórico/revogação/lease/finish usam essa entidade; begin também mantém run_id como identidade de negócio. Resposta histórica não substitui get_sync_context atual. Recibos não autorizam outros usuários.

<a id="weekly-publication"></a>

### `coach.weekly_publications`

PK `(user_id,period_start)`; period_start é segunda e period_end=period_start+7 dias. `active_generation_id nullable` com FK composta, `updated_at`. Uma geração completed ativa por semana; zero insights mantém ponteiro para geração concluída de zero slots. Configuração/fuso alterados invalidam ponteiros afetados antes de nova geração. É a autoridade para a lista do app, independentemente de state do insight. Existe uma única semana civil por proprietário/data inicial, sem ampliar a chave por versão/fuso.

### `coach.coach_generations`

PK `id uuid`, UNIQUE `(user_id,period_start,period_end,generator_version,input_revision)`. Campos: `generation_key text` calculada como `weekly:v1:<period_start>:<generator_version>:<input_revision>`, `period_start/end date`, `analysis_timezone`, `config_version`, `input_revision`, `input_fingerprint`, `generator_version text`, `prompt_version text`, `model_identifier text`, `status=running|completed|failed|superseded`, `claim_token uuid nullable`, `claim_expires_at nullable`, `publication_hash nullable`, `publication_receipt jsonb nullable`, `started_at`, `finished_at`, `insight_count` entre 0 e 3, `error_code nullable`. UNIQUE `(user_id,generation_key)`; generator_version tem 1–64 caracteres ASCII [A-Za-z0-9_.-], sem dois-pontos. Prompt/model vêm de cadastro administrativo `coach.generator_versions` por version, não são escolhidos pelo modelo.

Generator_versions é metadado administrativo, exceção à propriedade por user_id: PK version, prompt_version/model_identifier imutáveis, enabled boolean. Somente administração escreve; Hermes/executor coach leem, Android não acessa. Alterar prompt/model exige nova version; begin exige enabled=true, publish também, evitando executar versão revogada. Nome do authenticator é constante da migration/configuração administrativa, sem setter cliente. Não armazenar prompts completos nem criar catálogo editável pelo modelo.

Intervalo de semana fechada `[segunda,segunda seguinte)`. Chave é independente do texto. Lock por proprietário serializa aquisição/publicação com commit de saúde; nenhuma chamada ao modelo mantém lock aberto. Começar com revision divergente conflita. Fingerprint JCS/SHA-256 do input de duas semanas inclui configuração e projeções/ausências classificadas, ordenadas por data/tipo/ID; exclui data_revision, read_at, last_verified_at e timestamps administrativos. Mesma versão/fingerprint ativa retorna already_current. Running com claim válido retorna busy (runtime mantém o token obtido na aquisição); expired/failed pode retomar com token novo. Renew estende para agora+15 minutos somente o claim válido. Completed com mesmo publication_hash retorna recibo original; outro conteúdo conflita. Superseded nunca volta a completed por replay.

Publish confere claim, input_revision atual, config/fingerprint e 0–3 itens; calcula evidência novamente no banco e exige igualdade canônica com queries compartilhadas. Substitui atomicamente ponteiro, supersede geração/insights anteriores, insere IDs imutáveis e recibo; vazio é completed com zero slots. Toda geração ativa tem no máximo três insights published e toda linha published pertence à geração ativa. Constraint trigger diferida checa ponteiro/status/contagem/FKs no commit, incluindo troca por zero. Texto/evidência concluídos nunca recebem UPDATE; retirada administrativa/supersede muda só estado/ponteiro. Data_quality pode usar lacunas sem cobertura quantitativa; trend/consistency/activity exigem limiares. Publication_receipt/pub hash sobrevivem em superseded até retenção para replay sem reativação; replay consulta recibo antes do claim/revision e não concede novos efeitos.

### `coach.coach_insights`

PK `id uuid` remoto, UNIQUE `(user_id,generation_id,slot)`; slot 1–3, FK composta para geração. Campos: `period_start/end date`, `analysis_timezone`, `type=trend|consistency|activity|data_quality`, `title text` (1–120 caracteres), `body text` (1–2000), `evidence jsonb`, `input_revision`, `state=published|superseded|withdrawn`, `created_at`, `updated_at`.

Evidence v1 é array de 1–10 objetos com metric, statistic, period_start/end, value nullable, unit, coverage_days, expected_days, aggregation_method, input_revision; comparison opcional usa mesmos campos para semana anterior (sem comparison recursivo). Statistic obrigatório: cumulativas total ou daily_average; sono/FC/HRV mean; peso last; exercise_sessions count. Value corresponde ao campo selecionado no summary, evitando confundir total com média diária em cobertura parcial. Comparison mantém metric/statistic/unit/método. Metric aceita habilitadas e exercise_sessions (count, verified_activity_count_v1). Evidência usa exatamente uma semana inteira do input, não período livre; datas/fuso/revision coincidem com geração. Coverage_days é available_days verificados de métricas; em exercise_sessions, day states verificados inclusive vazios. Data_quality admite null/lacunas verdadeiras. Valores usam precisão das queries; publicação confere retornos, determina slots 1..N pela ordem de insights[] e estado. Nenhum UPDATE Android de conteúdo. Delta deriva-se de value/comparison, sem porcentagem arbitrária enviada. Médias de contagens mantêm unit=count e statistic=daily_average, não se confundem com contagem bruta.

Correção de valores/qualidade/configuração marca superseded todas as gerações ativas cujo input de duas semanas intersecta os tipos/datas afetados, mesmo se a correção não constava no texto, e limpa seus ponteiros. A próxima consulta já as exclui. Publicar nova versão da mesma semana sempre supersede a ativa anterior, mesmo se a revisão global mudou por outra semana. HOM-33 reavalia para nova geração. Preservar gerações substituídas e seus insights por 90 dias; publicação ativa/insights ativos ficam até exclusão solicitada. Antes de limpar geração antiga, remover insights/estados dependentes e manter nenhum ponteiro ativo para ela.

### `coach.insight_user_state`

PK `(user_id,insight_id)`, FK composta para insight. `read_at`, `dismissed_at` nullable e `updated_at`, gerados no banco. Android pode marcar somente próprios insights; Hermes não edita leitura do usuário. Ausência de linha significa não lido/não descartado. Contagem de novos considera `state=published` e ambas as marcas nulas.

### `integration.service_user_bindings`

PK `db_role text`; `user_id`, `enabled boolean`, `created_at`. Administrador cria binding de login Hermes a um único proprietário. Hermes pode consultar somente o binding cujo role é `current_user`, e não escrevê-lo; roles sem binding ativo não enxergam saúde/coach. Policy de identidade não usa `auth.uid()` na conexão SQL direta, pois não há JWT de usuário nesse caminho.

### `integration.telegram_links` e `integration.telegram_link_challenges`

Links: PK `user_id`; UNIQUE `telegram_user_id bigint`, UNIQUE `chat_id bigint`; `verified_at`, `revoked_at nullable`. Apenas pareamento validado cria/atualiza vínculo. Desafios: PK `id uuid`, `user_id`, `token_hash`, `expires_at`, `consumed_at nullable`; hash único, segredo não persistido em claro.

Desafios guardam também consumed_telegram_user_id/chat_id para replay de consumo pelo mesmo remetente; nunca token em claro. Android cria/consulta estado/revoga via RPC, sem SELECT direto de hashes/IDs. Hermes consome desafio/consulta contexto pelo executor, sem SELECT direto dessas tabelas. Getter de estado também usa executor privado somente de leitura para ocultar colunas; sua assinatura é liberada ao Android, sem grant SELECT de desafios. Contratos em [architecture](architecture.md). Se bot compartilhado atender múltiplos usuários futuramente, revisar role por proprietário antes de ampliar acesso.

## 3. Matriz de autorização

| Recurso | Android (`authenticated`, proprietário) | Hermes (login próprio, binding ativo) | Administrativo |
| --- | --- | --- | --- |
| Perfil / preferências | Ler; alterar via contrato validado, acionando recálculo | Ler somente contexto de análise | Configurar/manter |
| Diário / atividades | Ler; gravar via commit do writer ativo | Ler; nunca INSERT/UPDATE/DELETE | Migrations/recuperação auditada |
| Sync state / runs / recibos | Ler e executar ciclo via RPC | Ler revision e cobertura necessárias; sem escrita | Operar/diagnosticar |
| Gerações / insights | Ler somente conteúdo da publicação ativa; sem edição | Ler próprios; gravar por executores tipados, sem DML direto | Operar/retirar |
| Estado de leitura | Ler/marcar próprio | Sem escrita | Recuperação |
| Binding de serviço | Sem acesso | Ler somente próprio binding; sem escrita | Criar/revogar |
| Vínculo Telegram / desafios | RPC de criação/estado/revogação próprios | RPC de consumo e leitura restrita do vínculo | Configurar/revogar |
| DDL, roles, `auth.users`, secrets | Nenhum | Nenhum | Credencial administrativa separada |

<a id="write-boundary"></a>

### Fronteira de escrita, identidade e privilégios

`SECURITY INVOKER` executa com os privilégios do chamador, não é barreira que permite usar grants só dentro de RPC. Por isso D16 corrige a premissa anterior de mutadores exclusivamente invoker: consultas compartilhadas, views e wrappers api permanecem invoker; mutações delegam a funções privadas tipadas `SECURITY DEFINER`. É uma fronteira necessária de privilégio, não um recurso para contornar RLS. [Semântica oficial PostgreSQL](https://www.postgresql.org/docs/current/sql-createfunction.html) e [guia Supabase](https://supabase.com/docs/guides/database/functions).

Todos os roles clientes têm DML, TRUNCATE, REFERENCES, TRIGGER e CREATE revogados nos schemas de negócio; nenhum UPDATE interno de coach é dado ao Android. Grants de leitura são por tabela/coluna e sujeitos a RLS; leitura direta SQL Hermes é permitida somente no próprio dataset, sem acesso a recibos/payloads de sync, estado de leitura, auth.users ou desafios. NÃO existe grant ALL, membership em roles privilegiadas, senha de executor ou executor genérico execute_sql.

| Role privado NOLOGIN | Privilégios internos mínimos (além de SELECT necessário) | Chamadores autorizados dos executores |
| --- | --- | --- |
| `health_executor` | INSERT/UPDATE perfil, preferências, sync state/runs/results/confirmed targets/recibos; INSERT/UPDATE diário e day states; INSERT/UPDATE/DELETE atividades; UPDATE somente status/finished_at de gerações, state/updated_at de insights e ponteiro weekly_publications para invalidação | Somente sessão Android via PostgREST: register/config/begin/renew/commit/mark_history/finish |
| `coach_executor` | INSERT/UPDATE gerações/weekly_publications; INSERT insights; UPDATE state/updated_at de insights; INSERT recibo de publicação na geração; nenhum DML health | Somente login Hermes com binding ativo: begin/renew/publish/fail |
| `integration_executor` | INSERT/UPDATE links/desafios/operation_receipts; INSERT/UPDATE insight_user_state; sem DML health ou conteúdo coach | Android: challenge/state/revoke/mark_insight; Hermes: consume/context |

Executores não são donos das tabelas/schemas, usam NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT, sem membership acessível aos clientes. Health recebe INSERT/SELECT em operation_receipts; coach usa recibo na geração, não operation_receipts. Integração recebe apenas funções/tabelas necessárias. Binding tem policy simples db_role=session_user para executores e db_role=current_user para leitura Hermes, sem consulta recursiva ao próprio binding; executores podem SELECT somente binding da conexão original. Para clientes de gateway não há consulta de binding Hermes. Policies das demais tabelas chamam resolução de identidade que só lê binding, nunca a tabela que está autorizando. FORCE RLS, policies específicas com USING/WITH CHECK de proprietário e CHECK/FKs continuam ativos. Administração possui tabelas/migrations; atribui propriedade apenas das funções privadas ao executor. Limpeza é administrativa, sem grant ao Hermes/Android.

Identidade é rederivada dentro de cada executor antes de ler/escrever/lock, sem user_id/role/policy em argumentos. Login Hermes registrado na session_user usa binding protegido e ignora JWT/GUCs; só lista coach/Telegram autorizada. Invoker direto exige current_user=login; dentro do executor, policy resolve proprietário da session_user original, nunca pelo current_user do definer. Conexão direta/pooler de sessão deve preservar session_user, pooling que altere identidade é proibido. Para authenticator real do PostgREST (nome administrativo protegido), exigir role da requisição authenticated, auth.uid não nulo e is_anonymous=false; só então usar claims verificadas pelo gateway. Helper de policy não consulta profiles/auth.users: evita recursão. Depois da resolução de identidade, executor verifica existência do perfil em operações posteriores; primeiro register depende de FK auth.users, falha sanitizada access_denied se conta excluída. Hermes sem membership em authenticator/authenticated nem SET SESSION AUTHORIZATION. Outra origem negada, inclusive admin simulando cliente fora de teste controlado.

Cada função privada tem assinatura única, allowlist de operação/chamador, `search_path=''` e nomes qualificados inclusive helpers, sem SQL dinâmico. Revogar EXECUTE de PUBLIC/anon e conceder USAGE/EXECUTE apenas das assinaturas necessárias ao role correto, inclusive ao executor para helper compartilhado. Invoker wrapper precisa EXECUTE no executor: a função privada deve validar o contrato inteiro mesmo se chamada diretamente via SQL, não depender da wrapper como autorização. Não expor SECURITY DEFINER em api/public; não criar função sob postgres/service_role. Privado significa fora da Data API, não segurança por nome oculto. Não confiar em marcador GUC de “chamada pela RPC”: login SQL pode alterá-lo.

Todos os mutadores derivam a mesma chave de advisory lock do UUID do proprietário, usam lock transacional antes de tocar state/publicação/configuração e ordem fixa: proprietário → sync_state (se necessário) → semana/geração. Coach usa advisory lock sem UPDATE em sync_state. Receipts são inseridos na mesma transação dos efeitos; invariantes estruturais (Fks compostas, unidades, disponibilidade, slots e ponteiro de publicação) recebem CHECK/constraints/triggers mesmo nos executores. Trigger de imutabilidade nega mudança de proprietário, IDs, dados/evidências publicados e namespaces de projeção sem substituição validada; executores só alteram estados/timestamps permitidos. Limite semanal e invalidation são atômicos, não dependem de ordem de calls do SDK.

HOM-26 deve testar via conexão real: INSERT/UPDATE/DELETE/TRUNCATE diretos Hermes/Android negados; falsificação de JWT/GUC por Hermes não troca usuário; EXECUTE em mutadores health pelo Hermes negado; binding inexistente/desabilitado nega leitura/execução; SET ROLE de executor negado; views preservam RLS; chamada SQL direta de publish/consume valida os mesmos limites/identidade. Testar SQL injection/search_path/temp object, proprietário A/B, concorrência commit/publish, zero/replay e ausência de grants PUBLIC. Esses testes são gates; nenhum banco foi alterado nesta documentação.

## 4. Índices e limites

- Diário: PK `(user_id,local_date,metric)` cobre intervalo por usuário; índice `(user_id,metric,local_date)` somente se plano de tendência o justificar.
- Atividades: UNIQUE de origem; `(user_id,start_at,id)` para paginação e `(user_id,start_local_date)` para substituição por dia.
- Runs: `(user_id,started_at desc)`; results/receipts usam PK e índice da FK `(user_id,run_id)` quando não coberto.
- Insights: `(user_id,state,created_at desc,id)`; FK `(user_id,generation_id)`; índice de não lidos via estado do usuário se necessário.
- Gerações: chave única de geração; desafios por hash e expiração; bindings por role e usuário.
- Indexar toda FK não coberta por prefixo de índice. Inspecionar planos com fixtures representativas; não criar GIN para evidence, partições, vectors ou índices especulativos no MVP.

Queries são limitadas a 90 datas por período; resumo/trends inclui atual e anterior (até 180 datas) explicitamente. Paginação/limites aplicados no banco/ferramentas. Upload até 500 itens/512 KiB/sete datas por envelope, contando sets vazios; não truncar leitura. Evidência/flags têm listas/limites tipados.

## 5. Semântica compartilhada de períodos e tendências

`get_period_summary_v1(end_date=null,days=7)` aceita days 7/30/90. End_date exclusivo default hoje no fuso de análise, usando dias fechados; não admite end_date posterior a hoje. Semana usa segunda até segunda seguinte. Hoje aparece em Saúde com is_provisional, mas não entra em comparação de semana completa. Limite de 90 vale por período: retorno inclui atual e anterior, até 180 datas ao todo para days=90, com lacunas explícitas; isto não amplia backfill/permissão Health Connect.

| Métrica | Resumo de período | Comparação / observação |
| --- | --- | --- |
| Passos, energia ativa/total, distância | Total dos dias disponíveis e média por dia disponível | Total não representa período completo se houver lacunas; comparar média diária somente com cobertura declarada |
| Sono | Média dos totais diários de duração de sono; total auxiliar | Cada dia soma intervalos unidos de sessões/cochilos; proxy mantém flag; não comparar métodos incompatíveis |
| FC repouso | Média dos valores diários | Não substituir por FC genérica; unidade bpm |
| Peso | Última medição no período e data da medição; média dos dias medidos auxiliar | Delta entre últimas medições de cada período; não preencher dias sem pesagem |
| HRV opcional | Média dos valores diários RMSSD disponíveis | Cada dia já agrega suas amostras; não reponderar por contagem, converter SDNN nem tratar ausência como zero |
| Atividades opcionais | Contagem de sessões dos day states verificados no período | Dia vazio confirmado conta como cobertura; 0 é contagem observada de conjunto vazio, não inferência para um dia sem leitura |

Cada item metrics[] contém metric, current e previous (cada qual period_start/end, value, unit, aggregation_method, available_days, verified_days, expected_days, coverage_ratio, first/last_observed_at, missing_dates, unverified_dates), delta_absolute, delta_percent, is_comparable e comparison_reasons[]. Available_days conta somente available, verified, versões compatíveis e não provisórios; verified_days inclui no_data confirmado; coverage_ratio=available_days/expected_days. Zero observado conta como available; null/no_data não conta. Missing_dates inclui ausência de linha/no_data; unverified_dates é lista separada. Summary exclui valores unverified/incompatíveis; diário/atividades históricos os devolvem rotulados com versões/fuso originais e fuso solicitado separado. Métodos/versões mistos ou cobertura insuficiente retornam is_comparable=false, motivos e deltas null. Sem nenhum dia available, value=null e horários de observação null; total parcial não vira zero. Peso usa last_measurement_date e average_value auxiliar; métricas cumulativas incluem daily_average além do total. Período anterior tem mesma duração imediatamente anterior. Comparar cumulativas pela daily_average, FC/sono/HRV pela value média, peso pela última medição; delta_percent=100×(atual−anterior)/anterior, null com base zero/ausente. Não imputar valores. Tipos opcionais desligados ficam fora de resumo/fingerprint, mas histórico rotulado continua consultável por diagnóstico.

Sono/FC/HRV usam média aritmética dos valores DIÁRIOS disponíveis, peso igual por dia; sono diário já é soma de intervalos unidos de sessões/cochilos, não média por sessão. HRV/FC diário já é média de observações; resumo não repondera por sample_count. Essa regra decorre dos snapshots sem série bruta e é igual nos consumidores.

Precisão v1: valores 0..999999999.999, até três casas decimais; adapter arredonda HALF_UP decimal após agregação/conversão, passos inteiros, peso >0. Banco numeric(12,3); faixa garante que quantização de milésimos não colida ao serializar números IEEE-754/JCS. Queries usam numeric para soma/média, arredondam médias/deltas a três casas, cobertura/percentual a seis (empates afastam de zero), sem limitar total de período à faixa de um dia. JSON numérico; hash usa valor normalizado; ingestão rejeita excesso/overflow, não arredonda silenciosamente. Tempo/duração em segundos e unidades da tabela, preservando null/zero.

Valores e `data_revision` de uma consulta devem vir do mesmo snapshot SQL, em uma única instrução/consulta estável. Conjunto de queries Hermes que alimenta uma geração usa transação de leitura REPEATABLE READ, encerrada antes da chamada ao modelo; se ferramentas forem chamadas separadamente, revisions diferentes exigem refazer o conjunto. Não manter transação aberta durante geração. A publicação revalida input_revision sob o advisory lock compartilhado.

Comparação quantitativa requer cobertura >=5/7 em cada período de sete dias (30/90: >=70%), mesma política/método/fuso e histórico verificado. Peso exige ao menos uma medição em cada período, com datas e sem afirmar tendência sustentada com dois pontos. Para atividades, available_days/coverage_days contam day states verificados available ou no_data; sem qualquer dia verificado, count=null, nunca zero inventado. Dados stale continuam consultáveis com idade/cobertura e ressalva no insight; idade superior a seis horas é stale para UI, sem degradar verificação automaticamente. Is_comparable=false mostra dados insuficientes e deltas null. Quantitativo não pode dispensar limiar por instrução do modelo.

## 6. Preparação de HOM-26 e aceite futuro

Ordem: projeto/MCP dedicado e Auth → schemas/grants restritivos → entidades/constraints/índices → RLS → funções/view contracts → fixtures sintéticas e testes de isolamento/conflito → advisors → migrations versionadas e reprodução em ambiente vazio. Segredos ficam fora de migrations e Git. Android/Hermes validam a mesma query e revisão; publicar apenas schema cuja superfície exposta tenha sido auditada.

Testar contas A/B, anon, Android writer antigo/novo, role Hermes com/sem binding, SQL direto do Hermes, views e UPDATEs com tentativa de trocar user_id. Conferir credenciais separadas, exclusão em cascata, confirmação atômica dos recibos, publicação ativa semanal única, limite de três slots entre revisões e evidência inválida. Acrescentar fixtures de namespace/replay/configuração, matriz success/partial/blocked e promoção de histórico/atividade vazia; nenhum teste precisa dados pessoais. HOM-26 deve documentar projeto/região/versão real do Postgres/backup, seleções operacionais que não mudam estes contratos. Segurança deve ser reproduzível do zero com migrations; não há permissão implícita de executar HOM-26 nesta etapa.
