# Health Coach — estratégia de sincronização v1

> **Planejamento histórico (HOM-25).** A HOM-26 foi simplificada para uso pessoal.
> O banco atual usa upsert por chave canônica; veja [supabase/README.md](../supabase/README.md).

Planejamento HOM-25, 26/09/2026. Implementação em HOM-28, apoiada por HOM-26/27; diagnóstico visual em HOM-31. Contratos e segurança em [architecture.md](architecture.md), entidades em [database-schema.md](database-schema.md), leitura em [health-connect-mapping.md](health-connect-mapping.md).

## 1. Objetivo e limites

Direção única: Health Connect → Android → Supabase. Supabase guarda a última projeção confirmada por dia/métrica; a origem continua responsável por produzir/corrigir registros. Não escrever os dados importados de volta a Health Connect. Entrega de requests pode ocorrer mais de uma vez; efeitos são idempotentes mediante chave canônica, revision e recibo transacional. Não alegar exactly-once de transporte.

Um aparelho escritor ativo por usuário, com installation ID local, namespace de store e epoch remotos. WorkManager periódico, ação manual e foreground convergem no mesmo caso de uso. Proteções locais reduzem concorrência; lease/revision no banco são a autoridade quando workers/processos/aparelhos concorrem.

## 2. Agenda e cobertura

| Execução | Intervalo / política |
| --- | --- |
| Primeira conexão | Backfill de até 30 datas acessíveis, dividido em batches; estender a até 90 somente com capacidade/permissão de histórico |
| Periódica | Pretensão a cada seis horas, rede conectada e bateria não baixa; leitura depende também de feature/permissão background |
| Abrir app em foreground | Enfileirar reconciliação se último sucesso tiver mais de seis horas, se permissões/política mudaram ou houver retomada pendente |
| `Sincronizar agora` | Mesmo pipeline, rede necessária para confirmação remota; permitido ler/cachear em foreground offline, exibindo upload pendente |
| Janela recente | Hoje + seis datas anteriores no fuso do perfil; para 26/09, datas 20–26/09, intervalo `[20/09 00:00,27/09 00:00)` com hoje provisório |
| Auditoria ampla | Uma vez por semana quando possível, reler 30 datas acessíveis; backfill manual até 90 quando autorizado |
| Mudanças antigas | Changes API/índice local sinaliza datas fora da janela para releitura direcionada; nunca apenas somar a diferença ao agregado |

Para hoje, consulta termina em `now`, mesmo que o limite do bucket seja meia-noite seguinte; guardar limite do dia e `is_provisional=true`. Auditoria/foreground também respeitam a restrição histórica real por tipo. O período permitido resulta da interseção de intervalo solicitado, histórico disponível e permissões; não declarar datas inacessíveis como completas.

WorkManager fornece execução persistente com horário aproximado, sujeita a Doze e restrições do sistema; agenda de seis horas não é SLA, conforme [PeriodicWorkRequest](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest). Sem leitura background autorizada, permitir leitura em foreground e upload de snapshots já preparados, e indicar o motivo no diagnóstico. Não usar foreground service persistente ou solicitar exceção de bateria automaticamente para contornar consentimento.

## 3. Estado local persistido

Room guarda dados por usuário: cache diário/insights e atividade/day states, configuração de origem/fuso, source_scope_id/epoch/config_version/revision vistos, runs locais, outbox imutável com batch/hash/lease_token e resultados, e índice mínimo de records para changes/deletions. Tokens Health Connect ficam somente no aparelho, separados por tipo e escopo/permissão. Segredos/session não ficam em WorkManager input data; worker recebe somente ID de execução e consulta armazenamento protegido.

Fila e tokens são atualizados em transação local. ACK remoto não pode ser inferido de “request enviado”. Logout/cancelamento impede subir fila de outro usuário. Cache/outbox/índice ficam no sandbox privado e fora de backup automático; o índice não precisa armazenar payload bruto.

Nome de trabalho periódico estável por usuário, único; manual e foreground usam o mesmo serializador persistente. Mutex em memória sozinho não resolve reinício/processo. Registrar uma intenção manual enquanto já existe trabalho, sem disparar uploads concorrentes. Separar etapa de leitura de etapa de upload permite leitura foreground e envio posterior.

## 4. Ciclo de reconciliação

1. **Preflight:** identificar sessão/usuário, estado da plataforma, permissões por tipo, fuso/política, writer e alcance histórico. Falha em uma métrica não elimina snapshots válidos de outras. Se offline, ler em foreground para cache e registrar intenção pendente; ainda não declarar upload ou sucesso remoto.
2. **Reservar execução:** quando online, begin_sync_v1 abre/retoma run e lease de 15 minutos para writer ativo, retorna revision/configuração/token. Leitura/upload mais longos chamam renew_sync_lease_v1 antes de expirar, pretendendo renovar aos dez minutos. Reconectar após coleta offline exige conferir epoch/versões e reler antes de fixar envelope; cache offline é candidato, não confirmação remota. Operações e respostas em [catálogo auxiliar](#auxiliary-contracts).
3. **Ler origem:** para cada tipo/dia, consumir todas as páginas ou agregação, normalizar e deduplicar. Completar intervalo antes de autorizar substituição. Guardar índice de IDs/intervalos e observar permissões entre etapas. Dados válidos de métrica/dia independentes podem continuar, gerando resultado partial.
4. **Preparar outbox:** formar snapshots completos inclusive `no_data`; preparar conjunto completo de atividades por data de início somente se opcional habilitado. Persistir envelope imutável, ID/hash, epoch, revision base e status local antes de enviar.
5. **Commit:** servidor verifica identidade/limites, consulta recibo, adquire advisory lock transacional por proprietário (compartilhado com publicação do coach), bloqueia sync state do usuário, valida lease/epoch/base revision/versões e aplica substituições. Diário e atividade ausente em conjunto confirmado são corrigidos, recibo e contadores gravados, revision emitida e insights afetados invalidados na mesma transação.
6. **Confirmar:** obter recibo remoto; numa transação Room, marcar batch confirmado, atualizar revision/cache e avançar checkpoint aplicável. Só então preparar próximo envelope com revision retornada. Não reutilizar a mesma revision base para dois batches mutáveis concorrentes.
7. **Fechar run:** finish_sync_v1 agrega datas/tipos realmente confirmados e libera lease. Success exige todas as datas de todos os tipos esperados, inclusive as sete métricas sem permissão, conforme [status uniforme](#run-status). Partial mantém sucesso anterior/checkpoint confirmado. Se finish falhar, get_sync_run_v1 e repetir finish com mesma identidade; nunca reenviar dados cegamente.

Snapshots são sempre substituições, inclusive se um dado tardio reduzir o total. A revisão de conteúdo sobe uma vez por batch que altera valores, origem, método, ausência ou qualidade; verificar sem mudanças só atualiza informação de leitura. Não usar “maior total vence”, que impediria exclusões/correções legítimas.

## 5. Contrato transacional do upload

`api.commit_sync_batch_v1(envelope)` é RPC nativa do Supabase, sem serviço intermediário. `user_id` vem de Auth; request não aceita usuário livre. Datas fim são exclusivas. Exemplo ilustrativo de DTO, sem implementação:

```json
{
  "contract_version": 1,
  "run_id": "11111111-1111-4111-8111-111111111111",
  "batch_id": "22222222-2222-4222-8222-222222222222",
  "installation_id": "33333333-3333-4333-8333-333333333333",
  "source_scope_id": "44444444-4444-4444-8444-444444444444",
  "writer_epoch": 1,
  "lease_token": "55555555-5555-4555-8555-555555555555",
  "base_revision": 12,
  "config_version": 1,
  "analysis_timezone": "America/Sao_Paulo",
  "source_policy_version": 1,
  "mapping_version": 1,
  "period_start": "2026-09-25",
  "period_end": "2026-09-26",
  "snapshots": [{
    "local_date": "2026-09-25",
    "metric": "steps",
    "availability": "available",
    "value": 7200,
    "unit": "count",
    "period_start_at": "2026-09-25T03:00:00.000Z",
    "period_end_at": "2026-09-26T03:00:00.000Z",
    "observed_at": "2026-09-26T02:50:00.000Z",
    "read_at": "2026-09-26T12:00:00.000Z",
    "origins": ["example.synthetic.writer"],
    "sample_count": null,
    "aggregation_method": "hc_aggregate_total_v1",
    "read_complete": true,
    "is_provisional": false,
    "quality_flags": []
  }],
  "activity_sets": [],
  "payload_hash": "8190ac8b566648fdce3b558c61990b6863e3c71fa0c66081f08edf7048e40f3b"
}
```

Os IDs/pacote/valores são sintéticos. Canonicalização escolhida: [JCS, RFC 8785](https://www.rfc-editor.org/rfc/rfc8785), UTF-8 e SHA-256; request inclui payload_hash de 64 hex caracteres minúsculos, calculado sobre o envelope sem esse campo. Antes de canonicalizar, ordenar snapshots por (local_date,metric), activity_sets por data, atividades por (start_at,hc_record_id) e arrays de origins/flags lexicalmente, sem duplicatas. Normalizar instantes UTC para exatamente três casas de milissegundos; datas YYYY-MM-DD. Campos nullable aparecem como null, não são omitidos; flags/sets vazios aparecem como []. Inteiros JSON ficam na faixa segura de 53 bits; overflow/não finitos são rejeitados. O servidor recalcula hash da mesma representação, não confia no hash enviado.

Content_hash é calculado pelo servidor (não enviado no snapshot), JCS/SHA-256 de local_date, metric, availability, value, unit, period_start_at/end_at, observed_at, origins, sample_count, aggregation_method, is_provisional, quality_flags de método, analysis_timezone, config_version, mapping_version, source_policy_version e verification_state/reasons. Commit completo calcula verified/[]; mark_history recalcula só classificação. Exclui batch/run, instalação/epoch/scope, read_at e timestamps de verificação/tentativa. Troca de scope invalida qualidade via estado; promoção altera revisão mesmo com valor igual. Números seguem [precisão v1](database-schema.md). HOM-26/28 devem compartilhar fixtures de hash; o algoritmo está fechado.

Resposta de exemplo:

```json
{
  "contract_version": 1,
  "run_id": "11111111-1111-4111-8111-111111111111",
  "batch_id": "22222222-2222-4222-8222-222222222222",
  "committed_revision": 13,
  "payload_hash": "8190ac8b566648fdce3b558c61990b6863e3c71fa0c66081f08edf7048e40f3b",
  "source_scope_id": "44444444-4444-4444-8444-444444444444",
  "writer_epoch": 1,
  "lease_token": "55555555-5555-4555-8555-555555555555",
  "config_version": 1,
  "accepted_items": 1,
  "changed_items": 1,
  "deleted_activities": 0,
  "committed_at": "2026-09-26T12:00:01.000Z",
  "computed_at": "2026-09-26T12:00:01.000Z",
  "confirmed_targets": [{
    "data_type": "steps",
    "local_date": "2026-09-25",
    "availability": "available",
    "read_at": "2026-09-26T12:00:00.000Z",
    "confirmed_at": "2026-09-26T12:00:01.000Z"
  }],
  "replayed": false
}
```

Servidor aplica limites: até sete datas distintas no envelope, 500 itens e 512 KiB (bytes UTF-8 do JSON recebido). Contagem inclui cada snapshot, cada atividade e cada activity_set inclusive vazio; DTO não pode duplicar tipo/data/ID. Snapshots completos podem ser divididos entre batches, mas um snapshot de dia/métrica ou conjunto diário de atividades não pode ser truncado. Conjunto que excede limite retorna payload_limit_exceeded, preserva remoto e fecha run partial/failed pelas regras abaixo; esse conjunto está explicitamente fora da capacidade v1, sem delegar nova decisão arquitetural a HOM-26/27. Não aumentar limite nem inventar staging nesta implementação.

<a id="activity-payload"></a>

Activity_sets usa `{local_date,read_complete,read_at,items[]}`, com read_complete=true e read_at UTC. Item é `{hc_record_id,origin_package,source_last_modified_at,exercise_type,start_at,end_at}`; hc_record_id não vazio até 256 caracteres, origin_package até 255, tipo inteiro >= 0, instantes válidos/end>start. Configuração/fuso/scope/epoch vêm do envelope; servidor calcula start_local_date, duração em segundos, UUID remoto e classificação verified. Todos os items iniciam na local_date declarada e origem escolhida; conjunto vazio é confirmação no_data, não permissão negada. Source_last_modified_at é obrigatório quando API informa, caso contrário null; não define precedência de upload. Fingerprint de day state usa itens normalizados ordenados por (start_at,hc_record_id), disponibilidade, data/fuso/versões e verification_state/reasons; exclui UUID remoto/read_at/timestamps administrativos.

Mover hc_record_id existente entre datas exige conjuntos completos da data antiga e nova no MESMO envelope; o servidor valida antes de modificar (activity_move_requires_old_set se faltar). Adapter agrupa datas conectadas por movimentos antes de dividir batches; primeiro valida todos os sets, depois aplica remoções/upserts/contagens com FKs diferidas. Não remover sessão de conjunto não confirmado como efeito colateral do upsert de outro dia. Se componente de datas ultrapassa sete datas/500 itens/512 KiB ou não cabe no período do run de até 90 datas, v1 retorna payload_limit_exceeded, preserva remoto e relata partial/failed; não divide movimento em commits inconsistentes. Deletion de um dia sem movimento continua conjunto completo normal. Tokens/índice retêm intenção até correção suportada ou classificação unverified por impedimento comprovado.

Contadores fechados: accepted_items é número de snapshots + sets + itens de atividades, inclusive set vazio. Changed_items conta linhas de diário, day states e atividades cujo conteúdo/classificação mudou; deleted_activities conta remoções separadamente (não soma em changed_items). Coach invalidado, recibos, confirmed_targets e timestamps de rechecagem não entram nesses números. Uploaded_items de run é soma accepted_items de batches únicos; committed_batches conta recibos únicos; targets confirmados são pares tipo/data únicos, não essa soma. Revision sobe uma vez quando changed_items>0 ou deleted_activities>0. Mark/config/register têm contadores próprios, sem incrementar upload; configuração real também sobe revision mesmo sem linhas de saúde.

Semântica atômica:

- Se há recibo para batch/hash, retornar resultado original com `replayed=true`, sem efeito novo, mesmo que a revision base já tenha mudado. Conta/ID/hash devem corresponder. Não aplicar um ACK de writer antigo ao cache da nova sessão.
- Mesmo ID com outro hash: batch_conflict. Sem recibo, epoch/scope/instalação divergente: writer_conflict; lease expirado/token trocado/ocupado: lease_conflict; base revision diferente: revision_conflict; configuração/mapping/política divergente: config_conflict; formato/versão/payload incorretos: invalid_contract. Novo run após mudança de configuração é obrigatório. Replay de recibo não estende lease nem autoriza novo upload.
- Validar limites, datas, unidades, método por tipo, flags/read_complete e proprietário das FKs; todos os alvos pertencem ao plano imutável do run e ao period_start/end do envelope, subconjunto não vazio de até sete datas do período do run. Available/no_data são os únicos estados aceitos. No_data exige value/observed_at null, origins=[], sample_count 0 ou null; available exige valor válido e origem conforme preferência/agregação. Snapshot usa fuso/versões do envelope; fronteiras são calculadas pelo banco com o fuso, não aceitas como intervalos arbitrários. Primeiro efeito exige read_at de cada snapshot/set de até sete dias e no máximo cinco minutos no futuro; timestamps normalizados ao milissegundo (truncar submilissegundo no adapter), finite/precisão conforme schema. Hoje provisório deve estar true; data passada com leitura do dia já fechado false. Impedimento/incompleto vai em date_results, nunca no conjunto de substituição.
- Sob lock de sync state, substituir diário por chave canônica; para activities, upsert IDs e remover ausentes do conjunto completo pela data de início, incluindo scope anterior no intervalo confirmado. Opcionais desligados sem leitura não geram deletion set.
- Emitir revision, superseder gerações ativas cujo input de duas semanas intersecta alterações, limpar ponteiros, persistir recibo/confirmed_targets e incrementar contadores uma vez. Invalidação e publicação seguem [limite semanal](database-schema.md#weekly-publication) e [fronteira de escrita](database-schema.md#write-boundary). Erro em qualquer validação/operação faz rollback do batch inteiro; falta de RLS/grant é falha, nunca motivo para usar admin key.

O lease serializa o escritor, a revision impede sobrescrita obsoleta e o recibo resolve ACK perdido. Nenhum mecanismo isolado fornece os três comportamentos.

## 6. Exclusões, mudanças e recuperação de histórico

Janela recente e auditoria relêem valores; se dado apagado não existe mais, `no_data` substitui o valor anterior ou lista completa remove atividade. Revogação de permissão não autoriza esse apagamento. Não deletar “tudo que não veio” de páginas parciais, tipo negado ou período inacessível.

Changes API é complemento para localizar atualizações/exclusões fora da janela. Obter token por tipo antes do backfill; alterações que ocorrem durante leitura são consumidas depois. Mapear `DeletionChange` pelo índice local, pois evento de exclusão contém ID, não intervalo/tipo completo. Reprocessar datas antigas e novas quando registro troca de intervalo; não apenas a nova data. Consumir páginas até fim, guardar datas afetadas e próximo token em transação Room; avançar token remoto lógico de ingestão somente após dados/checkpoint confirmados ou intenção de releitura durável. Deixar pendência durável é essencial para não perder exclusão em crash.

Tokens não usados expiram após 30 dias; a [orientação de sync oficial](https://developer.android.com/health-and-fitness/health-connect/sync-data) recomenda recuperar por releitura/deduplicação. Em token expirado/inválido, reinstalação ou índice perdido: reservar token novo, reler todo histórico acessível (até 90 dias autorizados), reconciliar conjuntos completos e drenar mudanças posteriores. Se ID de exclusão desconhecido não puder ser localizado, registrar lacuna e acionar releitura ampla, sem deletar indiscriminadamente.

Histórico fora do alcance não pode ser reconciliado com garantia. Preservar projeções anteriores com verification_state=unverified_history e flag derivada nas leituras; aplicar [regra objetiva de degradação/promoção](#history-verification), impedir comparação silenciosa e explicar limitação no diagnóstico. Sete dias sozinhos não corrigem exclusões antigas; mesmo auditoria de 30 depende de acesso. Não há garantia de consistência de dados que a plataforma não permite reler.

Troca de writer/store: novo epoch e namespace; descartar envelopes antigos, refazer backfill acessível; substituição completa por data evita misturar stores no intervalo confirmado. Não juntar total de passos de dois aparelhos. Alterar fuso/método/origem: incrementar versão, bloquear fila incompatível, recalcular intervalo acessível; reclassificar datas antigas que não puderem ser recalculadas.

<a id="history-verification"></a>

### Classificação objetiva de verificação

Verification_state é ortogonal a availability. Verified significa releitura completa e commit sob contexto vigente, não promessa de que produtor terminou exportação. Unverified_history preserva exatamente valor/ausência/IDs/intervalos/fuso/versões originais, porém impede uso quantitativo pelo coach e comparações; read_at/observed_at/last_verified_at não são atualizados para fingir releitura. A lista verification_reasons é união ordenada sem duplicatas de history_restricted, permission_denied, source_reset, source_policy_changed, timezone_changed, mapping_changed, change_tracking_lost; verified exige lista vazia. A flag unverified_history nas respostas é derivada desse estado.

Degradar projeção existente quando (a) plataforma confirma data fora do alcance autorizado ou permissão do tipo revogada; (b) writer/store/configuração/método mudou e projeção não foi refeita; (c) token/índice de changes foi perdido/expirou ou exclusão desconhecida impossibilita reconciliar. No caso (a), mark_history_unverified_v1 recebe ranges exatos por tipo/motivo; o app percorre datas remotas existentes pelo get_daily_metrics/get_activities, em chunks de até 90 datas. Permission_denied abrange todo histórico persistido desse tipo; history_restricted abrange somente datas comprovadamente inacessíveis. No caso (b), register/update config reclassifica automaticamente todas as projeções dos tipos afetados, incluindo hoje; no caso (c), marcar todo histórico persistido do tipo e então refazer o alcance acessível. Nenhuma dessas operações cria no_data em uma data ausente. Indisponibilidade transitória, rede, timeout e quota só tornam leitura stale/read_error; não bastam para degradar verificação.

Mark_history altera apenas classificação, motivos, verification_changed_at, hash/revision e invalidação de coach; exige writer/lease/config/base revision vigentes, mas NÃO read_complete nem novos valores. Mesmo alvo/motivo sem mudança é no-op e não sobe revision. Reclassificação automática também é uma única transação/revision com a alteração de contexto; metadados de origem antiga permanecem. Cache offline guarda intenção durável de marcar; não inventa alteração remota antes do ACK.

Promover somente por commit de snapshot/conjunto completo em contexto atual, todos os registros/páginas consumidos, disponibilidade available ou no_data e read_complete=true. Servidor substitui integralmente dados, fixa verified/[], atualiza last_verified_at e remove motivos anteriores. Dia vazio confirmado promove tombstone diário ou activity_day_state no_data e remove atividades anteriores. Snapshot parcial/erro/negação não promove nem apaga. Histórico inacessível continua unverified indefinidamente até nova permissão + releitura, sem prazo automático; consultas preservam fuso antigo separado do fuso solicitado. Atividades e sua linha diária recebem a mesma classificação na mesma transação; somente ver uma sessão isolada em Changes não promove conjunto diário.

## 7. Falhas, retry e concorrência

| Condição | Ação | Estado/efeito |
| --- | --- | --- |
| Sem rede / 429 / 5xx / timeout | Retry exponencial a partir de 30 s; respeitar Retry-After e restrições WorkManager | Outbox persiste; consultar recibo se commit pode ter ocorrido |
| Sessão expirada / 401 | Renovar uma vez; se falhar, aguardar login | auth_required; blocked sem confirmações, partial com confirmações; sem loop ou upload com outro usuário |
| 403 / permissão da métrica negada | Não fazer retry cego; orientar grant/configuração | Preserve histórico; diagnosticar por camada |
| Página Health Connect interrompida / quota | Retry apenas falha transitória com backoff; reler dia/tipo | Não subir snapshot parcial |
| Falha contratual / 422 | Parar batch e registrar código sanitizado | Corrigir implementação/versão; não retry infinito |
| Lease em uso | Aguardar expiração/liberação e retomar | Não iniciar segundo escritor paralelo |
| Revision conflict | Consultar recibo primeiro; se não confirmado, reler config/origem com nova base e novo batch | Não trocar somente revision de envelope obsoleto |
| Writer/versão mudou | Invalidar fila antiga e reconstruir leitura | Writer inativo não volta a escrever automaticamente |
| Request com ACK perdido | Repetir exatamente ID/hash/envelope ou consultar recibo | Mesmos dados/revision/contadores, sem duplicação |
| App encerrado após commit antes de ACK local | Retomar por outbox e recibo | Corrigir cache/checkpoint sem novo efeito remoto |
| Lease expirou durante leitura/offline | Recuperar lease; conferir recibos/revision e reler partes não confirmadas | Batches já confirmados permanecem; outros são reconstruídos |
| Finish run sem resposta | Consultar run; finalizar idempotentemente | Não apagar último sucesso ou duplicar contadores |

Backoff de WorkManager é inexato; configuração e comportamento seguem [Define work requests](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work). Após cinco tentativas consecutivas de upload sem êxito, marcar falha visível; execução futura/manual continua podendo retomar após resolver condição. Logs sanitizados guardam contagem e próximo retry, não payload de saúde.

Outbox com mais de sete dias exige nova leitura/novo batch, não replay cego. Recibos por 90 dias permitem ACK tardio dentro do prazo suportado. Não remover recibo enquanto houver run recuperável associado ou referência necessária sem aplicar regra de expiração do contrato.

## 8. Diagnóstico para HOM-31

Dados locais aparecem mesmo quando Supabase não responde. App combina runs remotos confirmados e tentativa local, distinguindo:

- último início, última conclusão e último sucesso remoto;
- trigger, run ID, período solicitado, datas confirmadas e fuso;
- estado do provedor, features e permissões background/history por tipo;
- origem efetivamente observada, última medição, disponibilidade e cobertura de cada métrica;
- records lidos (quando disponíveis), snapshots enviados/alterados, atividades removidas e batches confirmados;
- fila pendente, tentativas, próxima execução pretendida e deferimento pelo SO;
- erro por camada: `source_visibility`, `health_connect`, `normalization`, `local_store`, `auth`, `network`, `supabase_contract`, `supabase_commit`;
- código sanitizado, sem SQL, token, dados de saúde ou texto do insight em log.

Sem dado novo em Health Connect, pode-se indicar que a origem não publicou no período; isso não prova falha interna Garmin/Health Sync. Dado presente com falha de leitura aponta camada Health Connect; leitura completa com outbox pendente aponta app/rede/auth; RPC negado/erro de commit aponta integração Supabase. Botão manual chama o mesmo pipeline e exibe pendência/conclusão real. Última execução bem-sucedida sem registros não pode fabricar valor zero.

## 9. Cenários de aceite futuro de HOM-28

| Cenário | Resultado exigido |
| --- | --- |
| Reenviar batch confirmado dez vezes | Uma linha por dia/métrica e mesmo recibo; contadores não multiplicam |
| Dado Garmin/Health Sync chega atrasado no dia anterior | Próxima reconciliação substitui agregado e incrementa revision se conteúdo mudou |
| Excluir todos os registros de dia antes com valor | Releitura completa resulta `no_data/null`, sem conservar número antigo |
| Excluir treino ou movê-lo para outro dia | Remover do conjunto antigo e persistir no novo sem duplicação |
| Permissão negada/revogada ou página incompleta | Sem deletion set/zero fabricado; partial com confirmações, blocked sem confirmações diante de impedimento, failed sem confirmações diante de erro de página |
| Dois produtores com intervalos sobrepostos | Valor conforme política de origem/dedupe, sem soma cega |
| Periódico/manual simultâneos e processos reiniciados | Serialização/lease; conflito claro, sem sobrescrita fora de ordem |
| Matar app antes/depois do commit e perder resposta | Outbox/recibo recuperam efeito e checkpoint; nunca supor sucesso |
| Novo writer / fuso / origem durante fila offline | Envelope antigo rejeitado; reler antes de escrever com nova configuração |
| Changes token expirado e exclusão desconhecida | Releitura acessível; lacuna explícita para histórico não verificável |
| Payload inválido ou acima do limite | Rollback completo; nenhum truncamento declarado como sucesso |
| Intervalo cruza meia-noite ou dia de 23/25h | Resultado segue mapping, fronteiras e fuso persistidos |
| Correção de dado já usado pelo coach | Geração afetada superseded atomicamente; app não apresenta insight obsoleto como atual |
| Upload funciona mas finish falha | Dados confirmados continuam; run recuperável, último sucesso sem falsificação |

Esses são testes de integração necessários nas issues de execução, não testes criados nesta etapa documental. HOM-25 termina com estratégia verificável e riscos delimitados, sem workers, banco ou features implementados.

<a id="auxiliary-contracts"></a>

## 10. Catálogo normativo das operações auxiliares v1

Tipos comuns: UUID em string canônica com hífens; bigint JSON inteiro seguro (0..2^53−1); versões > 0 salvo expectativas iniciais iguais a 0; data ISO, instante UTC com milissegundos; período start inclusivo/end exclusivo. Data_type é steps, sleep_duration, resting_heart_rate, active_energy, total_energy, distance, weight, hrv_rmssd ou exercise_sessions. Metric no diário exclui exercise_sessions. Toda request object de mutação contém contract_version=1 e operation_id UUID criado/persistido no Android antes do envio; begin usa também run_id, commit usa batch_id em vez de operation_id. Finish não aceita campo status livre. Leituras não exigem operation_id. Todas as operações rejeitam user_id e campos desconhecidos.

Mutação auxiliar com request object tem issued_at UTC; first execution admite até sete dias de idade e até cinco minutos no futuro, usando relógio do servidor, limitando replay de fila depois da retenção. Recibo existente de mesma identidade/hash é retornado antes da checagem de idade/contexto, por até 90 dias. Hora do cliente não determina precedência/autorização. Cliente com relógio inválido usa computed_at para ajustar metadado da nova intenção, sem alterar relógio do SO nem payload de operation_id já enviado. Após sete dias sem recibo, reler contexto e usar nova operação. Recibo guarda kind/hash/resposta sem segredo; collision kind/hash retorna operation_conflict. Todas as respostas de domínio JSON (sync/leituras/coach/Telegram) incluem contract_version, computed_at e replayed (false em leitura); erro do gateway pode ter formato nativo. Respostas replayadas preservam horários originais. SHA-256/JCS do request integral, sem campo de hash externo. Mark_insight/consume e geração têm idempotência própria documentada, não usam operation_receipts.

Contexto W é DTO com installation_id (writer ativo), source_scope_id, writer_epoch, data_revision, lease_run_id, lease_token e lease_expires_at nullable, profile:P. P contém analysis_timezone, config_version, source_policy_version, mapping_version, hrv_enabled, activities_enabled, source_preferences[] {data_type,mode,origin_package,policy_version}. Cadastro/get/begin/renew/config/diagnostics retornam esse DTO no campo context; demais campos da resposta estão descritos em cada operação. Cópia em Room é cache; get_sync_context é autoridade depois de replay/reconexão. No início get retorna writer_registered=false/context=null; após cadastro true/context:W. Todas as preferências existem mesmo para opcionais desligados.

`api.get_sync_context_v1()` não recebe parâmetros e retorna writer_registered/context, além dos campos comuns de resposta. Exige sessão permanente do proprietário, mas permite qualquer aparelho da conta; não cria perfil, adquire lease nem altera timestamps. Antes do primeiro cadastro retorna false/null (exceção ao profile_required das demais leituras); depois retorna true/W. Lease vencido permanece identificado no contexto para recuperação, sem renovação automática; sua validade é comparada a computed_at do servidor.

### Cadastro e namespace de Health Connect

`api.register_writer_v1(request)` exige installation_id, replace_current boolean, reset_source_scope boolean, expected_writer_epoch, expected_config_version e initial_timezone (IANA, usado só na criação; depois deve ser null). Primeiro cadastro exige expectativas 0/0, replace_current=false e reset=false; cria perfil (config/policy/mapping=1), writer_epoch=1, data_revision=0 e UUID source_scope_id aleatório no servidor. Retorna W e writer_registered=true. Mesmo installation/contexto, replace/reset false: no-op, devolve o mesmo scope/epoch. Installation diferente exige replace_current=true, expectativas atuais e confirmação explícita do usuário; mesmo installation após reset detectado exige reset_source_scope=true/replace=false. Nova instalação ou reset incrementa epoch uma vez, cria novo source_scope_id, fecha run anterior, invalida lease e degrada todo dataset existente com source_reset; revision sobe uma vez se houver mudança de conteúdo/classificação. Expectativas divergentes conflitam; nunca aceitar scope fornecido pelo cliente.

Source_scope_id é namespace lógico emitido por usuário/store ativo, não ID nativo universal do Health Connect nem credencial. Aparelho salva installation UUID fora de backup na primeira execução; índice/cache/tokens guardam scope devolvido. Scope persiste entre runs/logout/login da mesma instalação se store não mudou; mudança de origem/fuso só altera configuração, nunca scope. Reinstalação/limpeza do provedor/troca de store ou impossibilidade de demonstrar continuidade exigem reset explícito; perda apenas de token/índice com store conhecido usa change_tracking_lost e mantém scope. Offline anterior ao primeiro register pode guardar candidatos locais sem scope, mas não produz envelope válido. Novo scope só é aplicado a dados após releitura completa; histórico preservado mantém scope antigo/qualidade unverified. Get/begin/renew/register sempre devolvem scope, evitando inventar UUID no Android.

### Alteração de configuração

`api.update_analysis_config_v1(request)` exige installation_id, writer_epoch, expected_config_version, analysis_timezone (configuração inteira), source_preferences[] de todos os nove tipos, hrv_enabled e activities_enabled. Tipos/policies seguem [mapping](health-connect-mapping.md); policy_version não é enviado, o banco calcula. Somente writer ativo altera. Validar IANA/pacotes/modos, lock e comparação de versão; idempotente pela operation_id. Retorna W, affected_data_types[], reprocess_required boolean. Mudança real sobe config_version; alteração de preferências/opcionais sobe também source_policy_version global. Baseline v1 conservadora: qualquer alteração efetiva invalida todas as projeções/tipos, inclusive histórico de opcionais desligados, pois config_version é global; affected_data_types contém os nove tipos. Motivo timezone_changed se fuso mudou, source_policy_changed se preferência/opcional mudou (união se ambos). Fecha run vigente partial com confirmações ou blocked sem, reason=config_changed; zera lease e invalida envelopes antigos. Reclassifica histórico, limpa publicações e incrementa revision uma vez, mesmo sem linhas porque configuração faz parte do input. Fuso não relabela datas antigas: fuso/versões originais ficam até substituição completa. Sem alteração, não fecha run nem muda versões/revision. Mapping v1 não configurável pelo cliente; futura mudança administrativa segue a mesma invalidação global.

### Abrir, renovar e retomar run

`api.begin_sync_v1(request)` exige run_id, installation_id, source_scope_id, writer_epoch, expected_config_version, trigger e period_start/end (1–90 datas; start<=hoje, end<=amanhã exclusivo no fuso do perfil). Plano imutável é todas as datas pelos sete tipos iniciais mais opcionais habilitados no begin; permissão não reduz plano. Run novo registra contexto/expected_data_types e server started_at/last_attempt_at; retorna context:W, run e confirmed_targets[]. Mesmo run/contexto/plano com lease válido devolve token existente sem estender. Lease de outro run válido conflita. Para running com lease expirado e sem sucessor, nova operation_id com mesmo plano readquire lease de 15 minutos/token novo; consultar recibos e reler alvos não confirmados. Run terminal nunca reabre: run_closed; novo ciclo usa run_id novo. Se outro run expired é substituído, fechar primeiro como partial com confirmações ou failed sem, reason=lease_expired, sem mudar last_success.

`api.renew_sync_lease_v1(request)` exige run_id, installation_id, source_scope_id, writer_epoch, config_version e lease_token; somente contexto ativo, run running e token não expirado. Estende até agora+15 minutos; devolve W/run_id. Nova renovação usa nova operation_id; replay da mesma retorna expiry original, não estende indefinidamente. Expirado retorna lease_conflict, exigindo begin/releitura; config/writer divergente retorna respectivo conflito. Token em cada batch impede worker de lease antigo escrever após retomada, mesmo com run_id/epoch iguais. Retry de recibo confirmado não exige lease vigente, mas novo efeito sempre exige.

### Consultar recuperação e diagnóstico

`api.get_sync_receipt_v1(batch_id,payload_hash)` exige UUID/hash SHA-256; retorna found boolean, receipt ou null, computed_at. Receipt contém run_id/batch_id, hash, scope/epoch/config/lease de origem, committed_revision, accepted_items/changed_items/deleted_activities, committed_at e confirmed_targets[] {data_type,local_date,availability,read_at,confirmed_at}; não devolve payload de saúde. Batch inexistente/outro proprietário/hash errado produz o mesmo found=false, sem contar/remover nada. ACK perdido: consultar; found=false permite repetir envelope exato dentro do prazo suportado, nunca alterar só base_revision/token do envelope. Found=true permite reconstruir checkpoint, não reutilizar contexto antigo no novo writer.

`api.get_sync_run_v1(run_id)` retorna found/run ou found=false/run=null; run traz plano/contexto, status, started_at/finished_at, terminal_reason, lease_active boolean, lease_expires_at, confirmed_targets[], metric_results[] e contadores remotos. Leitura de lease expirado devolve status=running/lease_active=false e interruption_code=lease_expired, sem concluir automaticamente. Consulta não retoma nem renova. Runs retidos 90 dias; fora desse prazo found=false. Resumo de run em list/diagnostics é projeção de run_id, trigger, requested_start/end, expected_data_types, status, started_at, finished_at, terminal_reason, committed_batches, uploaded_items, changed_items e deleted_activities. Não contém lease_token nem payload; detailed run expõe token só no contexto próprio de recuperação. Pending local não é linha running remota sem begin aceito.

`api.list_sync_runs_v1(cursor=null,limit=20)` retorna items[] de resumos de run, next_cursor e data_revision; máximo 100, ordem (started_at,run_id) desc, cursor pelo padrão de [architecture](architecture.md). `api.get_sync_diagnostics_v1()` retorna context:W, last_attempt_at, last_success_at, last_success_run_id, last_completed_period_start/end, recent_runs[] (20 resumos), classificação/cobertura por tipo e interruption_code do lease atual; não exige aparelho writer para leitura própria. Get_sync_run consulta detalhes/targets de até 90×9 sem paginação. Falhas sem rede permanecem locais até integração voltar.

### Marcar histórico e concluir run

`api.mark_history_unverified_v1(request)` exige run_id, installation_id, source_scope_id, writer_epoch, lease_token, config_version, base_revision e targets[] {data_type,period_start,period_end,reason}. Até 90 datas distintas por request e nove tipos, ranges disjuntos por tipo; apenas history_restricted/permission_denied/change_tracking_lost recebidos do adapter são aceitos. Contexto deve ser atual, mas tipo/range histórico pode estar fora do plano recente do run. Outros motivos são gerados somente por cadastro/config/migration administrativa. Aplicar [classificação](#history-verification) só em linhas existentes e day states/atividades; devolver committed_revision, changed_targets, computed_at/replayed. Não conta como snapshot confirmado, uploaded_items ou success. Repeated target/reason sem mudança é no-op; depois de mudança atualizar base_revision antes do batch seguinte.

`api.finish_sync_v1(request)` exige run_id, installation_id, source_scope_id, writer_epoch, config_version, lease_token, termination=completed|user_cancelled|blocked|technical_failure e metric_results[] para todos os tipos/datas esperados. Resultado por tipo usa date_results[] {local_date,availability,read_complete,upload_state,error_stage,error_code}, origins[], records_read nullable, source_latest_observed_at nullable, background_feature_available/background_permission_granted/history_permission_granted boolean. Upload_state=confirmed|pending|failed|not_attempted separa leitura de confirmação: available/no_data pode ter upload pendente/falho; confirmed sem fato remoto correspondente é rejeitado (unconfirmed_target). Onde há confirmed_target, availability/read_complete devem coincidir e upload_state=confirmed; contadores/completed_dates derivam do servidor. Resultados impedidos têm read_complete=false/upload_state=not_attempted. Finish aceita lease expirado se último token/contexto corresponder, sem liberar lease de sucessor. Grava status/finished_at/finish_payload_hash atomicamente; retorna run, last_success_at, last_success_run_id e replayed. Mesmo hash é no-op; terminal automático devolve estado sem reabertura. Outra tentativa de editar finish aceito conflita. Cancelamento manual usa essa operação, sem RPC extra.

<a id="run-status"></a>

## 11. Semântica uniforme de execução e último sucesso

O servidor deriva status, nunca confia em success enviado pelo Android. C é número de pares (data_type,data) em confirmed_targets do run; E é número de pares do plano imutável, sempre > 0. Confirmação completa available ou no_data conta, mesmo se não alterou valor/revision; marcação histórica, cache offline ou request enviado não contam. Permissão negada/restrição histórica/unsupported/source_ambiguous/background não autorizado são impedimentos; read_error/quota esgotada/contrato inválido/upload esgotado são falhas técnicas. Retomada pode sanar resultado e concluir sem manter erro antigo como impedimento.

| Regra em ordem de precedência | Estado terminal | Last_success_at |
| --- | --- | --- |
| Cancelamento explícito do usuário, qualquer C | cancelled | Preservar |
| Termination completed e C=E, sem alvos pendentes nem fila do run não confirmada | success | Agora do servidor no finish; last_success_run_id e período do run também avançam |
| 0<C<E ou abortamento técnico/impedimento com C>0 | partial | Preservar |
| C=0 e impedimento exige ação/consentimento/contexto | blocked | Preservar |
| C=0 e falha técnica, ou termination completed com alvos sem resultado confirmado | failed | Preservar |

Completed com C=E exige resultados compatíveis com confirmed_targets, sem pendência; só então success. C=E com termination technical_failure é partial terminal; só novo ciclo success pode avançar last_success, não existe edição/reabertura de finish aceito. Fila local consulta recibos antes de terminar: available/no_data sem ACK é upload_state=pending/failed e não confirmação. Hoje provisório confirmado até read_at conta para sync, não para semana fechada. Success não significa sete métricas com valores, mas plano inteiro lido/confirmado (no_data mantém null). Partial pode ter todo subconjunto acessível processado e uma permissão negada; E nunca diminui silenciosamente.

Sem login/rede o app usa estado local pending/blocked/auth_required/failed conforme causa; não cria run remoto nem last_success fictício. 401 após refresh falho é blocked se C=0 e partial se já confirmou algo; ao reconectar fecha pelo contexto autorizado ou consulta terminal automático. Begin/renew/upload/no-op/mark_history/replay de finish não avançam last_success. Diagnóstico usa último finished_at mesmo de partial/blocked e mostra separadamente último success. Logout impede worker antigo de finalizar com a sessão de outra conta. Reconfiguração/troca fecha run anterior partial se C>0, blocked se C=0; replay de seus recibos continua legível pelo proprietário, mas não altera status/sucesso.

Exemplos de aceite documental: sete tipos × sete datas = E=49; C=49 com duas métricas no_data em todos os dias e termination completed é success; C=42 com peso negado é partial; C=0 com todas as permissões negadas é blocked; C=0 com página quebrada é failed; um dia de treino sem sessões confirmado também conta; HRV/treinos desligados não entram em E. Last_success só muda no primeiro caso (ou qualquer outro success completo), nunca por degradar/promover histórico fora do plano.
