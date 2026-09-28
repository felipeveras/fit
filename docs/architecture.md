# Health Coach — arquitetura e contratos v1

> **Planejamento histórico (HOM-25).** A HOM-26 foi simplificada para uso pessoal.
> Para o modelo de banco atual, veja [supabase/README.md](../supabase/README.md).

Planejamento da [HOM-25](https://linear.app/homefelipev/issue/HOM-25/planejar-arquitetura-e-contratos-do-health-coach), em 26/09/2026; revisão documental após recuperação da sessão. Status: contratos v1 fechados para execução futura; validações de ambiente pendentes estão explicitadas abaixo. Este documento não atesta implementação, provisionamento ou aceite operacional.

## 1. Evidências e estado atual

- Repositório: `https://github.com/felipeveras/fit.git`; HEAD inspecionado: `ad071cf` (`chore: initialize repository`). Branch: `felipeverasg/hom-25-planejar-arquitetura-e-contratos-do-health-coach`.
- Antes deste planejamento, a árvore rastreada tinha somente `README.md`, com o título “Personal Hub - Health Coach”; o working tree estava limpo. O histórico e as branches disponíveis não contêm aplicação anterior.
- Não existem Gradle, Kotlin, Compose, manifests Android, migrations, configuração Supabase, Hermes, bot Telegram, testes ou CI neste checkout. Não há `AGENTS.md` no workspace nem nos diretórios ancestrais inspecionados.
- A leitura integral de HOM-25 e HOM-26–HOM-34 incluiu descrição, comentários, filhos, anexos, relações e atividade: sem conteúdo adicional, sem truncamento e sem erros parciais. As dez issues estavam em Backlog. Não há relações formais entre elas.
- O [projeto](https://linear.app/homefelipev/project/personal-hub-health-coach-fe79a72d39f3) define Kotlin/Compose, Supabase como fonte estruturada de verdade, reconciliação idempotente, observabilidade e Telegram como conversa. Não possui recursos ou milestones anexados.
- HOM-29 menciona layout existente e HOM-34 menciona mockup aprovado; nenhum desses artefatos está neste repositório ou nas issues consultadas. Tampouco foram verificados recursos externos já provisionados. Ausência no checkout não prova ausência fora dele.
- O Orca não resolveu o vínculo via `--current`; as consultas usaram explicitamente `HOM-25` e o workspace Linear `7b3f900e-8e55-471f-b1c6-f1650c904c09`. Nenhum estado ou relacionamento foi alterado no Linear.

Portanto, não existe arquitetura implementada a preservar neste checkout. A arquitetura abaixo é alvo de reconstrução, baseada nos requisitos das issues, e não uma descrição de código existente.

## 2. Escopo e responsabilidades

Fluxo alvo:

```text
Garmin / Health Sync / outros produtores
                  │ gravação externa (não controlada pelo Hub)
                  ▼
            Health Connect no aparelho
                  │ leitura autorizada
                  ▼
       Android Kotlin/Compose + Room + WorkManager
                  │ Supabase Auth + Data API/RPC nativa
                  ▼
       Supabase Cloud: Postgres + RLS + contratos v1
                  ▲                         │ leitura
                  │ SQL restrito            ▼
       Hermes: ferramentas determinísticas → geração de insights
                  │
                  ▼
       Telegram: conversa privada e contexto de insight
```

| Componente | Responsabilidade | Limite |
| --- | --- | --- |
| Garmin / Health Sync | Produzir/importar registros para Health Connect | Não presumir latência, cobertura nem nome de pacote; não integrar API Garmin neste MVP |
| Health Connect | Consentimento e registros de origem locais | Não é banco remoto nem agenda de execução do Hub |
| Android | Ler, normalizar, reconciliar, subir dados e mostrar Saúde/Semana/diagnóstico/insights | Não gerar diagnóstico clínico, executar SQL arbitrário nem portar segredo administrativo |
| Supabase | Auth, persistência, isolamento, transações, consultas compartilhadas e recibos | Sem servidor HTTP próprio, Edge Function ou API intermediária no MVP; RPC nativa é parte do banco |
| Hermes | Consultar períodos/tendências/atividades e persistir poucos insights com evidências | Não alterar dados coletados, permissões, usuário, schema ou writer ativo |
| Telegram | Interface conversacional, identificação do remetente e continuação de um insight | Não armazenar o dataset como fonte de verdade; link não concede acesso |
| Codex/Orca administrativo | Migrations e configuração do projeto dedicado em HOM-26 | Credenciais e MCP independentes das credenciais de execução de Android/Hermes |

O Android inicia com um módulo Gradle e pacotes lógicos `ui`, `domain`, `data/healthconnect`, `data/local`, `data/remote` e `sync`. Compose → ViewModel → casos de uso → interfaces de repository; implementações dependem dos SDKs. Coroutines/Flow para leitura e estados, Room para cache/outbox/índice local e WorkManager para trabalho persistente. Evitar fragmentação em múltiplos módulos antes de haver necessidade real. O scaffold é trabalho de HOM-27, compartilhado com HOM-28/29/31, e não desta issue.

## 3. Decisões fechadas para v1

| ID | Decisão | Motivo / consequência |
| --- | --- | --- |
| D01 | Kotlin/Compose nativo; baseline planejada `minSdk 28` | Health Connect exige aparelho compatível; `compileSdk`, `targetSdk` e versões serão fixados no scaffold após conferir ambiente e releases |
| D02 | Android lê Health Connect; não escreve de volta | Evita ciclos de importação e duplicação; sete métricas iniciais em [mapping](health-connect-mapping.md) |
| D03 | Supabase Cloud dedicado e acesso direto | Cumpre HOM-26/32; sem API intermediária própria |
| D04 | Um usuário inicialmente, com `user_id` em todas as entidades | Evita depender de “single user” para segurança; testar também isolamento com segunda conta |
| D05 | Um aparelho escritor ativo por usuário, com `writer_epoch` emitido no banco | Store Health Connect é local; proíbe juntar snapshots divergentes de aparelhos. Segundo aparelho pode ler; troca explícita de writer invalida filas antigas |
| D06 | Snapshot diário por métrica, sem série bruta na nuvem | Menos dados sensíveis e custo; índice mínimo de IDs/intervalos fica no aparelho para exclusões. Atividades opcionais são registros próprios |
| D07 | Fuso de análise persistido; UTC para instantes, datas no fuso do perfil | Padrão inicial `America/Sao_Paulo`, confirmado no cadastro. Viagem não muda retrospectivamente os dias |
| D08 | Dia/métrica é substituído integralmente após leitura completa | Upsert não soma upload; leitura vazia completa apaga valor anterior, erro/permissão ausente não apaga |
| D09 | Janela de sete datas: hoje e seis anteriores; auditoria semanal de 30 dias | Corrige atraso e exclusões; Changes API auxilia alterações antigas, sem substituir releitura |
| D10 | Data API expõe somente schema `api`, com views e RPCs versionadas | Tabelas de `health`, `coach` e `integration` ficam fora do REST; RLS e grants permanecem necessários |
| D11 | Hermes usa login Postgres próprio, sem privilégios administrativos e com RLS | Acesso SQL direto, TLS e queries parametrizadas; não compartilhar `service_role`, senha `postgres` ou MCP |
| D12 | Agregações semanais/7/30/90 são derivadas no banco | Android e Hermes usam a mesma semântica e cobertura, sem tabela semanal concorrente |
| D13 | Insights separados do estado de leitura no app | Hermes controla conteúdo; Android controla `read_at`/`dismissed_at`, sem poder editar evidências |
| D14 | CTA Telegram referencia ID opaco e exige vínculo validado | Sem métricas no URL; Hermes recupera contexto autorizado do Supabase |
| D15 | Polling no app ao abrir/atualizar; sem Realtime obrigatório | Reduz dependências no MVP; cache exibe idade e cobertura |
| D16 | Consultas e wrappers `SECURITY INVOKER`; escrita por executores privados restritos | Exceção explícita: executores `SECURITY DEFINER` de roles sem login/admin/bypass, com RLS, evitam conceder DML às credenciais Android/Hermes; fronteira em [schema](database-schema.md#write-boundary) |
| D17 | Uma publicação ativa de 0–3 insights por usuário/semana | Revisões substituem a publicação anterior atomicamente, sem acumular slots; histórico substituído permanece auditável |
| D18 | Configuração versionada e verificação histórica separada de disponibilidade | `config_version` rejeita fila antiga; degradação de confiança preserva valores e promoção exige releitura completa |

As decisões são baseline do planejamento, não aprovação externa presumida. Se uma validação contrariar a baseline, registrar a revisão nestes documentos antes da implementação afetada.

## 4. Contratos entre componentes

Todos os DTOs e RPCs abaixo são especificações, não código. `contract_version=1`, UTF-8, instantes ISO 8601 UTC com sufixo Z, datas ISO `YYYY-MM-DD`, intervalos `[início, fim)`. Valores numéricos finitos em unidade canônica; `null` nunca é convertido em zero. Campos desconhecidos podem ser ignorados em leitura; writes rejeitam versão desconhecida e campos desconhecidos. Mudança incompatível cria contrato v2 e migração de consumidores. Parâmetros sem default são obrigatórios; null é explícito onde permitido. Não criar overloads. O catálogo de sync em [operações auxiliares](sync-strategy.md#auxiliary-contracts) é normativo para assinaturas, tipos, respostas, idempotência e conflitos; este documento define integração e os contratos de leitura/coach/Telegram.

### Health Connect → domínio Android

`HealthConnectRepository.readSnapshot(metric, dates, analysisZone, sourcePolicy)` retorna, por dia, `local_date`, `availability`, `value`, `unit`, `period_start_at/end_at`, `origins`, `sample_count`, `observed_at`, `read_at`, `read_complete`, `is_provisional`, `aggregation_method`, `quality_flags`, `config_version`, `mapping_version` e `source_policy_version`. O contexto inclui `source_scope_id`, `writer_epoch` e alcance autorizado por tipo. `readActivitySet(date,context)` retorna o conjunto completo descrito em [sync](sync-strategy.md#activity-payload). Estado de plataforma e permissões acompanha o resultado. Exceção em uma métrica não vira sucesso vazio de todas as métricas.

Estados de disponibilidade: `available`, `no_data`, `permission_denied`, `history_restricted`, `unsupported`, `read_error`, `source_ambiguous`. `available` admite zero observado; `no_data` significa leitura completa sem valor. Somente esses dois podem substituir um snapshot no servidor. Estados restantes vão para diagnóstico; snapshot anterior permanece identificável como histórico/desatualizado.

### Android → Supabase

- `api.register_writer_v1(request)` e `api.get_sync_context_v1()`: cadastro/troca explícita e consulta do writer/configuração. O banco cria e devolve `source_scope_id`; Android nunca escolhe esse UUID. Usuário vem do JWT.
- `api.update_analysis_config_v1(request)`: alteração autenticada e otimista de fuso, preferências e opcionais; cancela lease/fila incompatíveis e reclassifica projeções afetadas atomicamente.
- `api.begin_sync_v1(request)`, `api.renew_sync_lease_v1(request)`: abrir/retomar run e renovar lease de 15 minutos, com token de lease emitido pelo banco. Retomada após expiração troca o token e exige releitura de partes não confirmadas.
- `api.commit_sync_batch_v1(envelope)`: substituição transacional de snapshots/conjuntos completos, conforme [upload](sync-strategy.md). Retorna recibo, revision e contagens; não expõe CRUD de tabelas internas.
- `api.get_sync_receipt_v1(batch_id,payload_hash)`, `api.get_sync_run_v1(run_id)`, `api.list_sync_runs_v1(cursor=null,limit=20)`: recuperar ACK/checkpoints e inspecionar execuções sem adivinhar sucesso.
- `api.mark_history_unverified_v1(request)`: degradar somente confiança/metadados de projeções existentes, sem exigir uma leitura completa e sem aceitar novos valores. Promoção ocorre apenas no commit completo.
- `api.finish_sync_v1(request)`: fecha o run; o servidor calcula `success|partial|failed|blocked|cancelled` pelas [regras uniformes](sync-strategy.md#run-status). Somente `success` atualiza `last_success_at`.
- `api.get_daily_metrics_v1(start_date,end_date)`, `api.get_period_summary_v1(end_date=null,days=7)`, `api.get_activities_v1(start_date,end_date,cursor=null,limit=20)`: usuário sempre do JWT; máximo 90 datas por período (resumo inclui também anterior), páginas de até 100 atividades, ordem estável por (start_at,id).
- `api.get_sync_diagnostics_v1()`: estado remoto e últimas execuções; combinado pelo app com diagnóstico local, inclusive falhas sem internet.
- `api.get_coach_insights_v1(start_date,end_date,cursor=null,limit=20)` e `api.mark_insight_v1(insight_id,action)`: lista até 100 por página, ordem descendente por (created_at,id); action=read|dismiss, marca idempotente, conteúdo imutável pelo Android.

Leituras retornam contract_version, período/fuso solicitado, config_version, data_revision, computed_at e itens; get_period_summary_v1 retorna metrics[], sem paginação. Item diário carrega os campos do diário em [schema](database-schema.md), incluindo verificação histórica. Get_daily_metrics_v1 retorna todas as projeções existentes dos oito tipos suportados por data, mesmo opcionais hoje desligados, sem paginação (até 90×8 linhas); não sintetiza zero para ausência de linha. Get_activities_v1 devolve items[], day_states[] (até 90, repetidos em páginas para contextualizar lacunas) e next_cursor; get_coach_insights_v1 devolve items[], unread_count global das publicações ativas e next_cursor. Cursor default null/limit=20, máximo 100; ordem ascendente por (start_at,id) em atividades e descendente por (created_at,id) em insights, (started_at,run_id) em runs. Filtro de atividades usa start_local_date de origem da projeção, nunca converte silenciosamente histórico de fuso antigo; todas as linhas mostram análise original/solicitada. Cursor é base64url de JSON com chave de ordenação, filtros, config_version e data_revision; divergência exige reiniciar paginação (cursor_conflict), cursor nunca autoriza acesso. Marcas de leitura não mudam data_revision/ordem. Intervalos de leitura não vazios têm até 90 datas; não aceitar user_id. Lista de insights usa interseção do período com o solicitado e somente publicação ativa. Resumo acrescenta cobertura/comparação/lacunas conforme [schema](database-schema.md).

`api.mark_insight_v1(insight_id,action)` retorna `contract_version`, ID, `read_at`, `dismissed_at` e `unread_count`; action read/dismiss só preenche timestamp nulo do proprietário, preservando o primeiro horário. Insight substituído pode ser marcado se ainda retido, mas nunca conta como novo. HTTP 401 tenta renovar sessão uma vez; 403 requer ação; 409 indica conflito; 422 indica contrato inválido; 429/5xx são transitórios. Erros de domínio usam SQLSTATE `PT403/PT404/PT409/PT422`, `message` igual ao código sanitizado (por exemplo `writer_conflict`) e `details/hint=null`, conforme [PostgREST](https://docs.postgrest.org/en/stable/references/errors.html). Para recurso não autorizado e inexistente, mesma resposta `not_found`. SDK trata erros de plataforma não previstos como erro técnico sanitizado, sem expor SQL/segredos. Leituras sem perfil retornam `profile_required`, exceto get_sync_context_v1 que retorna writer_registered=false/context=null; o primeiro register cria perfil/contexto, não login automático.

### Supabase → Hermes

Ferramentas permitidas em HOM-32: get_health_summary(days=7|30|90,end_date), get_health_trends(metric,days,end_date) e list_activities(start_date,end_date,cursor,limit). Funções privadas invoker normativas: health.get_period_summary_v1(end_date=null,days=7), health.get_health_trends_v1(metric,days=7,end_date=null) e health.get_activities_v1(start_date,end_date,cursor=null,limit=20); wrappers api delegam a essas funções, sem usuário livre. Trends retorna summary do tipo e current_series[]/previous_series[] de DTOs diários rotulados; end_date/days/limites iguais aos resumos. Summary e atividades têm os mesmos retornos Android; idade= computed_at−read_at quando conhecido, sem inferir idade da medição ausente. SQL parametrizado, usuário resolvido da credencial; não oferecer execute_sql ao modelo.

HOM-33 usa `coach.begin_weekly_generation_v1(period_start,generator_version,input_revision)`, `coach.renew_generation_lease_v1(generation_id,claim_token)` e `coach.persist_weekly_insights_v1(generation_id,claim_token,input_revision,insights[])`; são funções SQL privadas, ferramentas do runtime, nunca RPCs liberadas ao Android. O banco calcula `generation_key`, fingerprint dos inputs e ID; retorna `disposition=generate|already_current|busy`, geração, chave, fingerprint, revision, claim token e expiração (estes dois null se não houver trabalho adquirido). Semana completa `[segunda,segunda seguinte)`, fechada no fuso do perfil; execução pretendida segunda às 09:00. Apenas versões de gerador cadastradas pelo administrador são aceitas. Inputs abrangem a semana e a anterior, todos os tipos habilitados, incluindo ausência/qualidade/configuração, excluindo horários de rechecagem e a revision global. Mesmos inputs e versão da publicação ativa retornam already_current, mesmo se dados de outra semana alteraram a revision.

Lease de geração de 15 minutos, renovável pelo token; retomar geração running expirada emite novo token, impedindo publicação do worker antigo. Chave `(usuário,semana,generator_version,input_revision)` é idempotente; ID/token não autorizam outro usuário. Consulta usa snapshot SQL consistente, geração ocorre em memória sem transação aberta e publish revalida revision/configuração/fingerprint sob o mesmo advisory lock dos commits de saúde. Conflito exige nova leitura; não publicar evidência antiga. Publicação é uma troca atômica de toda a semana, de zero a três slots; a geração anterior e seus insights ficam superseded, independentemente da razão da revisão. Zero insights é publicação concluída e idempotente, podendo retirar publicação anterior, sem criar placeholders. Assim o limite significa até três atualmente publicados por usuário/semana, não três novos a cada rerun; novas versões históricas podem existir. Detalhes e invariantes em [publicação semanal](database-schema.md#weekly-publication).

Persist_weekly_insights_v1 retorna generation_id, generation_key, input_revision, published_count, insight_ids[], published_at, replayed; hash de publicação é JCS/SHA-256 de {generation_id,input_revision,insights}, excluindo claim_token. Insights[] contém somente type/title/body/evidence; campos de estado/ID/slot/timestamps são emitidos pelo banco. Todas as funções coach retornam também contract_version/computed_at; renew devolve generation_id/claim_expires_at e somente renova claim válido. Replay completed ou superseded com mesmo hash retorna recibo original sem republicar; hash diferente conflita. Coach.fail_weekly_generation_v1(generation_id,claim_token,error_code) fecha tentativa running como failed, libera claim, preserva publicação anterior e retorna status/finished_at; replay de mesma tentativa/código retorna o mesmo resultado, claim de tentativa anterior não encerra tentativa nova. Nova aquisição da mesma chave failed gera novo claim. Revisão obsoleta no publish não grava resultado parcial. Nenhuma função Hermes recebe usuário livre, SQL livre ou estado published escolhido pelo modelo.

Tipos de insight v1: trend, consistency, activity, data_quality; estado published|superseded|withdrawn. Correção invalida gerações afetadas; conteúdo antigo sai da lista padrão e fica auditável. Cobertura quantitativa de cinco de sete dias em ambos os períodos, dados verificados/não provisórios e métodos compatíveis é requisito fechado, não override do modelo; exceção do peso e cobertura de atividades estão no schema. Abaixo disso somente data_quality baseado em lacunas reais, ou zero insights. Limiar de relevância editorial será calibrado em HOM-33 dentro dessas regras, sem afetar contratos/RLS. Não diagnosticar nem atribuir causalidade só por correlação.

### Android → Telegram → Hermes

Formato: `https://t.me/<bot_username>?start=insight_<uuid-sem-hifens>` (40 caracteres no parâmetro). Ao receber `/start`, Hermes exige conversa privada e vínculo ativo de `telegram_user_id`/`chat_id` com o proprietário; consulta ID, período, título, texto e evidências no banco. UUID não é credencial. Link compartilhado com outra conta é negado sem revelar existência/conteúdo.

Vínculo inicial: desafio de 32 bytes aleatórios criptográficos, base64url sem padding (43 caracteres); URL https://t.me/<bot_username>?start=link_<token> (48 caracteres). Validade de dez minutos, SHA-256 dos bytes originais persistido; segredo não fica em claro/log. Api.create_telegram_link_challenge_v1() retorna challenge_id/token/expires_at; invalida desafios anteriores não consumidos. Não usa replay de token: resposta perdida exige novo desafio. Api.get_telegram_link_state_v1() retorna linked, verified_at, active_challenge_id e challenge_expires_at (campos nullable sem respectivo estado); não devolve token/chat IDs. Api.revoke_telegram_link_v1(request) usa contract_version/operation_id/issued_at e expected_verified_at (null quando não vinculado), compara vínculo atual, revoga vínculo/desafios pendentes idempotentemente e retorna linked=false/revoked_at; divergência retorna link_conflict. Replay não revoga vínculo novo e tem recibo sem segredo, como operações auxiliares. Timestamps verified_at são gerados no banco a cada vínculo novo; igualdade usa precisão de milissegundos.

`integration.consume_telegram_link_challenge_v1(token,telegram_user_id,chat_id,chat_type)` é SQL privado Hermes; somente chat_type=private, binding de proprietário ativo, token válido/não expirado e IDs positivos. Adquire lock do proprietário, consome atomicamente e cria/substitui vínculo próprio, sem transferir vínculo de outro proprietário. Replay do mesmo token já consumido pelo mesmo remetente/chat e vínculo ainda ativo retorna linked=true/replayed=true até expirar; outro remetente/revogação/expiração recebe `link_unavailable`, sem revelar existência. O banco confere vínculo; autenticidade de remetente/chat vem do update recebido pelo runtime do bot, nunca de texto do modelo.

`integration.get_telegram_insight_context_v1(insight_id,telegram_user_id,chat_id,chat_type)` retorna ID, período, título, corpo e evidências somente de publicação ativa e vínculo correspondente; demais casos usam `context_unavailable`. Tokens e IDs Telegram são usados só por código determinístico, não por ferramenta arbitrária do modelo. Sem vínculo ou conteúdo retirado, orientar pareamento/atualização sem revelar saúde. Em ausência do app Telegram, abrir link web e manter detalhe no Hub. Username/host/provider são configuração operacional de HOM-32; o transporte v1 será long polling com offset durável e deduplicação de update_id, um consumidor por bot. As regras de payload são compatíveis com o [deep linking oficial](https://core.telegram.org/bots/features#deep-linking).

## 5. Segurança e privacidade

Android usa publishable key e Supabase Auth de usuário permanente pré-cadastrado, inicialmente email/senha com cadastro público e anonymous sign-in desabilitados. Tokens serializados ficam cifrados com AES-GCM e chave não exportável do Android Keystore, em arquivo privado fora de backup; sem tokens em Room/input/log. Renovação por refresh token no SDK, uma tentativa após 401. Logout cancela trabalhos, invalida geração local de sessão, remove sessão/dados locais e solicita sign-out remoto quando online; ausência de rede não mantém fila utilizável. Dados remotos exigem exclusão explícita por fluxo administrativo autenticado no MVP; não conceder DELETE de auth.users aos clientes. Esse fluxo revoga sessões/credencial Hermes e writer/vínculo antes da exclusão em cascata; não presumir que apagar usuário invalida JWT já emitido.

RLS e FORCE RLS nas tabelas de negócio, inclusive privadas. Android lê com `auth.uid()`/proprietário/autenticação permanente; nenhum DML direto. Authorization não depende de `user_metadata`. Views `security_invoker`, consultas/wrappers `SECURITY INVOKER`, EXECUTE revogado de PUBLIC/anon e concedido por assinatura. D16 substitui a antiga exigência de todo mutador ser invoker: somente executores tipados nos schemas privados usam `SECURITY DEFINER`, pertencem a roles restritas sem login e mantêm RLS, identidade derivada da conexão e validação integral. Nenhum executor pertence a postgres/service_role ou permite SQL arbitrário. [Fronteira normativa](database-schema.md#write-boundary), baseada nas [funções oficiais](https://supabase.com/docs/guides/database/functions). Schema exposto/grants e RLS são controles distintos, conforme [schemas](https://supabase.com/docs/guides/api/using-custom-schemas) e [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

Hermes: login próprio NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT, não proprietário de tabelas/sem associação a roles elevadas; invoker resolve usuário pelo binding de current_user=login, executor privado usa session_user original. Nunca lookup pelo current_user do definer, nem GUC definida pelo cliente. Credenciais separadas conforme [roles Supabase](https://supabase.com/docs/guides/database/postgres/roles); segredos no runtime/secret manager; rotacionar/revogar e encerrar conexões para revogação efetiva. Nada de service_role para Hermes.

Modelo recebe somente agregados e evidências necessárias, não tokens, SQL, IDs Telegram ou série bruta. Texto Telegram e conteúdo de insights são dados não confiáveis; ferramentas mantêm autorização independentemente do prompt. Envio de dados a provedor de modelo depende de consentimento e configuração de retenção do runtime, ainda pendentes; bloqueia uso de dados reais no coach até resolução em HOM-32.

Dataset diário/atividades/publicações ativas: até exclusão solicitada, dentro da janela de coleta autorizada; logs/runs/recibos e gerações substituídas/falhas: 90 dias; geração ativa e seus insights não expiram enquanto publicados. Desafios expirados/consumidos: limpeza em até 24 horas. Não gravar métricas/texto de saúde, payloads, emails, URLs com desafios ou segredos em logs. Logs técnicos usam IDs/códigos sanitizados. Dados de desenvolvimento sintéticos. Exclusão de conta remove dependentes/cache, revoga writer/vínculo/credenciais; backups seguem retenção que HOM-26 documenta. Revogar Health Connect impede novas leituras, mas não equivale a exclusão remota.

## 6. Dependências e sequência de execução

As dependências abaixo são inferidas dos requisitos; não são relações já cadastradas no Linear. “Desbloqueada” significa contrato definido, não estado alterado ou prerequisites implementados. HOM-26 e HOM-27 podem iniciar sem escolher nova arquitetura: projeto/região/plano de backup, versões compatíveis, aparelho e pacotes realmente observados são seleção/validação operacional nos gates abaixo. Se um ambiente não suporta um requisito fechado, registrar impedimento e revisão de contrato; não substituir silenciosamente por admin key, soma de origens ou dados fictícios.

| Issue | Escopo original e pré-requisitos técnicos | Efeito da HOM-25 |
| --- | --- | --- |
| [HOM-26](https://linear.app/homefelipev/issue/HOM-26) | Supabase dedicado, MCP limitado ao projeto, migrations, RLS e credenciais | Pode iniciar com schema e matriz de acesso definidos; ainda escolher projeto/região e validar roles |
| [HOM-27](https://linear.app/homefelipev/issue/HOM-27) | Scaffold Android, sete métricas, permissões e repository testável; aparelho de validação | Pode iniciar em paralelo a HOM-26; mapping e estados definidos |
| [HOM-28](https://linear.app/homefelipev/issue/HOM-28) | HOM-26 + HOM-27; sync WorkManager idempotente | Contrato pronto; integração depende de banco e adapter reais |
| [HOM-29](https://linear.app/homefelipev/issue/HOM-29) | Scaffold HOM-27, leituras HOM-26, dados/refresh HOM-28; recuperar baseline visual | Interface/repository pode ser preparado após scaffold; aceite real depende de pipeline. Não depende de HOM-32/33 |
| [HOM-30](https://linear.app/homefelipev/issue/HOM-30) | HOM-26/28 para agregados reais; navegação Saúde em HOM-29 | Semântica de períodos/tendências pronta; não depende de geração de insights |
| [HOM-31](https://linear.app/homefelipev/issue/HOM-31) | Scaffold HOM-27, eventos e execução manual HOM-28, persistência HOM-26 | Modelo de diagnóstico pronto; conclusão depende do pipeline |
| [HOM-32](https://linear.app/homefelipev/issue/HOM-32) | Roles/consultas HOM-26; host Hermes, Telegram e consentimento do modelo | Ferramentas podem iniciar após HOM-26, com fixtures; uso real aguarda HOM-28 |
| [HOM-33](https://linear.app/homefelipev/issue/HOM-33) | HOM-32 + schema HOM-26 + dataset HOM-28 | Formato e geração definidos; não pode validar insights reais sem coleta |
| [HOM-34](https://linear.app/homefelipev/issue/HOM-34) | Scaffold/navegação HOM-27/29/30, leitura HOM-26, conteúdo HOM-33, bot HOM-32 e mockup | Contrato pronto para fixtures; aceite completo ainda depende desses itens |

Primeira frente: HOM-26 e HOM-27. Depois HOM-28 e, sobre scaffold/contratos, HOM-29/31 e ferramentas HOM-32. HOM-30 segue integração das consultas; HOM-33 usa a coleta; HOM-34 integra conteúdo e conversa. Não iniciar implementação de nenhuma delas nesta entrega.

## 7. Decisões de ambiente ainda necessárias e riscos

| Pendência / risco | Baseline ou tratamento | Responsável / gate |
| --- | --- | --- |
| Projeto Supabase, região, custos/backups e autenticação existentes desconhecidos | Projeto dedicado; região próxima ao usuário e política de backup documentada; não assumir recurso provisionado | HOM-26, antes de provisionar |
| Nenhum scaffold Android e nenhum layout/mockup recuperado | Scaffold sob HOM-27; localizar referência visual antes de declarar fidelidade | HOM-27/29/34 |
| Versões de SDK/build e aparelho não registrados | Preferir release estável Health Connect, pinning e lockfiles; testar fornecedor/API e feature flags | HOM-27 |
| Garmin/Health Sync pode não exportar métricas ou atrasar | Descobrir origem real por tipo; dado ausente não é zero. HRV/treinos opcionais exigem evidência | HOM-27, antes de habilitar opcionais |
| Duplicação por múltiplas origens | Agregação da plataforma onde apropriada; origem única para seletores e sono; não inventar pacote Garmin | HOM-27/28 |
| Background/history podem ser negados ou indisponíveis | Foreground/manual e cobertura limitada; não prometer pontualidade ou 90 dias no primeiro acesso | HOM-27/28/31 |
| Mudança de aparelho, fuso ou política invalida snapshots | Writer epoch e reprocessamento; histórico fora do acesso permanece sem reconciliação garantida | HOM-28 |
| Host/linguagem/provider do Hermes e bot desconhecidos | SQL com driver/TLS suportado, roles restritas, username e pareamento validado | HOM-32; CTA de HOM-34 aguarda bot |
| SQL direto exige grants/RLS verificáveis no ambiente | Negar deploy Hermes até teste de identidade/isolamento via conexão real; não recorrer a admin key | HOM-26/32 |
| Consentimento/retention do provedor de modelo não definidos | Ferramentas com dados sintéticos até decisão explícita | HOM-32, antes de enviar saúde real |
| Limiares de relevância e qualidade do coach exigem calibração | Até três insights/semana, cobertura mínima e evidências; validar amostras sem inferência clínica | HOM-33 |
| Mudanças de plataforma | Revalidar documentação na execução; changelog Supabase consultado, upgrade de Postgres de 25/09 não exige migração aqui (não há banco/extensões existentes) | HOM-26, [nota oficial](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes) |

## 8. Critérios de aceite

Aceite de planejamento HOM-25: quatro documentos presentes, links relativos e anchors válidos, estado atual separado do alvo, sete métricas mapeadas, identidade/chaves/unidades/intervalos definidos, reconciliação e recuperação especificadas, matriz de acesso e dependências rastreáveis, validações operacionais identificadas e nenhuma feature/migration/provisionamento criado. A revisão fecha adicionalmente publicação semanal única (incluindo zero/replay), catálogo de operações auxiliares, namespace de store, degradação/promoção histórica e atividades vazias, estados uniformes de run e fronteira de escrita verificável. Evidências de validação documental não atestam os testes futuros. Cada contrato tem uma seção normativa indicada por link; nenhuma decisão de acesso é delegada ao modelo.

Gates futuros de execução, distribuídos entre as issues responsáveis:

- HOM-26: migrations reproduzíveis do zero; grants/RLS negam anon, usuário B e escrita Hermes em saúde; Android não altera conteúdo do coach; advisors sem alertas críticos não tratados.
- HOM-27: leituras reais das sete métricas quando presentes; diferencia permissão negada/sem dado/erro; origem e unidades validadas; opcionais podem estar indisponíveis sem quebrar app.
- HOM-28: replay sem duplicação, correção tardia, remoção na origem, falha/reinício/ACK perdido, conflito de epoch/revision e leitura parcial conforme [cenários de sync](sync-strategy.md).
- HOM-29/30: estado loading/vazio/erro/stale e cobertura explícitos, cálculos iguais ao Hermes, sem espera pelo coach.
- HOM-31: manual usa o mesmo pipeline; diagnóstico distingue leitura da origem, fila local e upload, sem fingir conhecer status interno do Garmin/Health Sync.
- HOM-32/33: queries de 7/30/90 e atividades com escopo mínimo; geração idempotente, evidência verificável, zero insight quando inadequado e nenhuma credencial administrativa no runtime.
- HOM-34: indicador/lista/detalhe e leitura idempotente; CTA recupera contexto da conta vinculada; outra conta, grupo, ID inválido e insight retirado não vazam dados.

## 9. Artefatos relacionados

- [Modelo de dados, consultas e matriz de acesso](database-schema.md).
- [Tipos Health Connect, permissões e semântica por métrica](health-connect-mapping.md).
- [Reconciliação, contrato de upload, falhas e diagnóstico](sync-strategy.md).

Esses documentos são o resultado da etapa de planejamento. Sua existência não substitui os testes de segurança, dispositivo e integração exigidos nas issues de execução.
