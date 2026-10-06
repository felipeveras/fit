# Migração Flutter — GitHub #19

## Referência e limite desta entrega

Referência Kotlin: `c0148fa`, merge da automação diária (#7). O Android original
continua em `app/`, sem alterações. O Flutter fica em `app_flutter/`.
Não há cutover: dados Garmin/Health Sync e envio Telegram ainda precisam de
validação no aparelho do proprietário. Treinos (#20) e hábitos (#21) agora estão integrados ao Flutter.
O serviço Coach permanece uma entrega separada (#11).

Inventário real: sete métricas, permissões de dados/histórico/background,
rechecagem ao retomar, paginação, seleção de origem, janela conservadora do
primeiro consentimento, resumo manual Telegram e WorkManager diário. Não há
dashboard novo, Coach ou banco estruturado implementados no Kotlin deste commit.
A captura [Kotlin no emulador](migration/kotlin-reference.png) registra a referência
atual; o emulador não tem dados de produtores.

## Contrato de saúde

Canal `com.homefelipev.healthcoach/health`, versão 1. Cada chamada inclui
`version: 1` e cada resposta inclui `version: 1`. Operações:

| Método | Argumentos adicionais | Resposta |
| --- | --- | --- |
| getAvailability | nenhum | provider |
| getPermissions | nenhum | granted, required, history, background |
| requestPermissions | kind: data ou history | estado atualizado das permissões |
| openHealthSettings | nenhum | opened |
| getToday | nenhum | days, timezone, snapshots |
| getPeriod | days: 7, 30 ou 90 | days, timezone, snapshots |

Datas locais ISO, instantes UTC ISO, sete tipos em snake_case iguais aos enums
Kotlin. Cada snapshot conserva unidade, disponibilidade, valor nullable,
intervalo, origem, contagem, completude, provisoriedade, método, flags de qualidade
e versões do mapeamento. O período inclui hoje e N−1 datas anteriores no fuso do
aparelho. Não soma peso/FC/sono entre dias: entrega snapshots diários para que
consumidores escolham explicitamente a agregação adequada.

Erros do canal: `invalid_arguments`, `unsupported_version`, `provider_unavailable`,
`permission_request_in_progress`, `health_connect_error`, `bridge_detached`.
Erros por métrica permanecem no DTO: `permission_denied`, `history_restricted`,
`unsupported`, `read_error`, `source_ambiguous`, `no_data`. Nenhum vira zero.
Cancelamento do host encerra chamadas pendentes. A UI só conhece HealthRepository;
MethodChannel fica na implementação de infraestrutura.

O bridge preserva os sete arquivos em `data/healthconnect` do app original.
Não adiciona FC instantânea ou sessões de exercício sem contrato e testes: nesta
fundação o escopo de paridade é exatamente o das sete métricas existentes.

## Dados e preferências

Health Connect continua sendo a fonte de verdade de saúde; snapshots ficam
somente em memória. A base única `app_fit.db` (SQLite/sqflite) usa `user_version`
e migrations incrementais. As versões 2 a 4 acrescentam o schema da issue #20:
biblioteca de exercícios, rotinas e dias agendados, sessões, séries, timer
recuperável, metas de prescrição copiadas para cada sessão, histórico de PRs,
outbox de eventos com retry, medidas e metadados de fotos. O módulo mantém os
dados detalhados de força no armazenamento local. Preferências Telegram e último envio ficam em
SharedPreferences. Não há conta, backend ou dependência de IA.

Para coexistência, o APK Flutter usa `com.homefelipev.healthcoach.flutter`.
Isso permite instalar ambos, com consentimentos e preferências independentes.
Não importa automaticamente permissões ou credenciais do app original. A troca
do applicationId e migração de preferências exigem uma decisão no cutover.

## Origem e licenças

O bridge deriva do próprio repositório, referência `c0148fa`; não incorpora código
nem assets do GymMane ou Streak. O catálogo inicial da issue #20 contém nomes e
instruções próprios, sem código nem arte upstream. O GymMane publica seu código
sob GPL-3.0 com termo adicional de atribuição; qualquer adaptação futura deve
preservar os notices e o crédito "Based on GymMane by InlitX". Os ícones são
Material Icons fornecidos pelo Flutter; o ícone do launcher vem do próprio app
Kotlin. Sobre/Créditos informa isso; incorporar upstream futuramente exige
registrar arquivos, revisão de licença e notices correspondentes. Esta entrega
não declara uma licença nova para todo o repositório.

## Validação em aparelho real antes do cutover

- Provider ausente, instalado sem permissão, concessão e revogação ao retomar.
- Dados parciais e múltiplas origens: conferir ausência e origem ambígua.
- Hoje, 7/30/90 dias; sem histórico ampliado, cobertura limitada explícita.
- Garmin → Health Sync → Health Connect → dashboard Flutter.
- Atualizar, fechar/reabrir; preferências preservadas.
- Enviar Telegram com/sem tópico, sem rede e token inválido.
- Manter automação Kotlin até decidir e validar a migração de background.

## Evidências desta entrega (06/10/2026)

- `flutter analyze`: sem issues; formatação verificada sem alterações.
- `flutter test`: 14 testes aprovados (DTO/canal, estados, dashboard, Telegram e SQLite/preferências).
- `:app:testDebugUnitTest`: 36 testes aprovados, incluindo 35 regressões do leitor preservado.
- `:app:lintDebug`: aprovado, sem erros; há avisos de dependências/recursos do template.
  No Windows, `tool/lint-android.ps1` corrige o escape dos caminhos locais que o
  Flutter gera e atualiza o relatório. Nenhuma regra de lint foi desativada.
- `flutter build apk --debug`: APK gerado e instalado no emulador API 36, ao lado do Kotlin.
- Dashboard inicial, solicitação de consentimento pelo launcher nativo, retorno
  ao dashboard após concessão, navegação para configurações e reinício verificados.
- Revogação de passos reconhecida como `permission_denied` no dashboard; permissão
  restaurada após o teste. As permissões do app Kotlin não foram alteradas.
- Hoje e períodos 7/30/90 consultados no emulador. O período de 90 dias mostra
  aviso de histórico limitado sem a permissão ampliada. O emulador não tem
  Garmin/Health Sync; as métricas vazias permanecem sem valor. O aggregate do SDK
  retornou calorias totais, exibidas sem substituir as demais ausências por zero.
- Capturas: [sem permissão](migration/flutter-no-permission.png),
  [consentimento](migration/flutter-permission-request.png),
  [dashboard](migration/flutter-dashboard.png),
  [90 dias](migration/flutter-period-90.png),
  [configurações](migration/flutter-settings.png).
- CI configurada para reproduzir checks em Linux; ainda não executada no GitHub.
  Aparelho real, dados de produtores e entrega Telegram real continuam pendentes.

## Evidências do módulo de treinos (#20, 06/10/2026)

- Catálogo pesquisável e exercícios personalizados; CRUD e duplicação de
  rotinas com ordem, prescrição, superset e dias agendados.
- Sessão ativa persistida com registro/edição/exclusão de séries, RPE/RIR,
  timer recuperável, conclusão/cancelamento e resumo compartilhável. Conclusão
  válida grava evento idempotente para consumidores do domínio.
- Histórico, PRs, 1RM estimado, volume, duração, grupos musculares, frequência,
  meta semanal, streak, heatmap, medidas e fotos de progresso implementados.
- Antes destas quatro correções, `dart format` não indicou mudanças,
  `flutter analyze` não encontrou issues e `flutter test` aprovou 27 testes.
- Regressões para timer/UI, retry/replay de eventos, snapshot de prescrição e
  histórico de PRs foram adicionadas nesta correção; permanecem para validação
  centralizada e não foram executadas neste worktree.
- `flutter build apk --debug`: APK gerado. A primeira tentativa ficou sem espaço
  no volume do workspace; a compilação concluída usou o volume com espaço livre.
  Flutter avisou sobre versões futuras do Gradle, AGP e Kotlin.
- Fluxos do módulo ainda não foram exercitados manualmente em aparelho/emulador;
  o APK não foi instalado nesta validação.
- Na migração v4, o histórico de PRs é reconstruído cronologicamente a partir
  das séries concluídas já armazenadas; a tabela de melhores atuais continua
  preservada separadamente.
- Workout publica `WorkoutDomainEvent` de forma durável após conclusão válida.
  O `id` do evento é a chave de idempotência; o sink assíncrono só confirma após
  persistência no consumidor. Sem consumidor conectado, ou após falha, o evento
  permanece pendente para replay/retry. Na entrega integrada,
  `WorkoutHabitConsumer` conecta esse outbox ao `HabitRepository` no bootstrap;
  a confirmação aguarda a transação SQLite de hábitos.

## Composição integrada #19/#20/#21

O banco único `app_fit.db` está na versão 5: preserva metadados (v1),
treinos (v2), timers/outbox (v3) e prescrições/histórico de PRs/retries (v4),
e acrescenta hábitos (v5). O dashboard oferece treinos, aba de hábitos e
Morning Brief. A importação de exercícios usa o bridge opcional, permissão
independente de passos, uma origem selecionada e cobertura diária explícita.
Falhas de leitura, permissão ou histórico não viram faltas artificiais.

A validação central desta composição deve registrar resultados e SHA final;
esta seção não declara os checks concluídos. O proprietário ainda não
validou os dados reais e Telegram no aparelho físico. Essa pendência mantém
a #19 aberta e impede tratar a migração como cutover de produção.
Veja [contrato de hábitos](habit-tracker-flutter.md) e
[checklist físico](flutter-device-validation.md).

Referência técnica: [canais de plataforma Flutter](https://docs.flutter.dev/platform-integration/platform-channels).
