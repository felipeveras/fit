# Migração Flutter — GitHub #19

## Referência e limite desta entrega

Referência Kotlin: `c0148fa`, merge da automação diária (#7). O Android original
continua em `app/`, sem alterações. O Flutter fica em `app_flutter/`.
Não há cutover: dados Garmin/Health Sync e envio Telegram ainda precisam de
validação no aparelho do proprietário. Treino, hábitos e Coach são entregas
independentes (#20, #21 e #11).

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
e migrations incrementais. A fundação registra versão e instalação; tabelas de
hábitos, treino e bem-estar serão acrescentadas nas respectivas issues, na mesma
base, sem criar modelos vazios. Preferências Telegram e último envio ficam em
SharedPreferences. Não há conta, backend ou dependência de IA.

Para coexistência, o APK Flutter usa `com.homefelipev.healthcoach.flutter`.
Isso permite instalar ambos, com consentimentos e preferências independentes.
Não importa automaticamente permissões ou credenciais do app original. A troca
do applicationId e migração de preferências exigem uma decisão no cutover.

## Origem e licenças

O bridge deriva do próprio repositório, referência `c0148fa`; não incorpora código
nem assets do GymMane ou Streak. Os ícones são Material Icons fornecidos pelo
Flutter; o ícone do launcher vem do próprio app Kotlin. Sobre/Créditos informa isso; incorporar upstream futuramente exige
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

Referência técnica: [canais de plataforma Flutter](https://docs.flutter.dev/platform-integration/platform-channels).
