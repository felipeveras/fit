# HOM-26: banco pessoal

O projeto Supabase dedicado é `shape` (`bvyohalmpwfijfhoxnxc`), na região `sa-east-1`.
O schema exposto pela Data API é apenas `api`. O Android usa Supabase Auth e a chave
publicável; não há servidor intermediário nem chave administrativa no app.

## Modelo após a migration de simplificação

- `api.daily_metrics`: uma linha por `(user_id, local_date, metric)`. Uma leitura
  completa sem registros grava `availability='no_data'` e `value=null`.
- `api.activities`: uma linha por `(user_id, origin_package, hc_record_id)`.
- `api.insights`: até três slots por conta e semana, escritos pelo Hermes e lidos
  pelo Android.
- `integration.service_user_bindings`: associação administrativa entre o login SQL
  do Hermes e uma conta Auth. O login herda apenas `hermes_coach`.

O Android faz upsert de métricas pela chave `(user_id,local_date,metric)` e de
atividades pela chave `(user_id,origin_package,hc_record_id)`. Reenviar a mesma
leitura não duplica linhas. Quando uma atividade desaparece da origem, o app apaga
a linha correspondente. O banco não interpreta permissão negada como `no_data`.

RLS e `FORCE ROW LEVEL SECURITY` protegem as três tabelas `api`. A conta Android
só lê e grava suas métricas e atividades, e só lê seus insights. O Hermes lê os
dados da conta vinculada e grava apenas os insights dessa conta. Sem binding ativo,
suas consultas retornam zero linhas. Não conceder `hermes_coach` ao Android.

## Histórico e aplicação

As doze migrations anteriores continuam no histórico porque já haviam sido
aplicadas ao projeto. `20260928122524_simplify_personal_health_data.sql` trocou
esse modelo por um único conjunto de tabelas; a migration abortaria se houvesse
qualquer linha de negócio nos schemas anteriores. As tabelas estavam vazias, e
as duas contas Auth foram preservadas. A migration
`20260928122722_grant_hermes_binding_read.sql` restaurou o grant de leitura do
próprio binding Hermes, ainda limitado por RLS.

As duas migrations constam do histórico remoto em 28/09/2026. Grants, RLS e
`FORCE RLS` foram conferidos no catálogo. Testes transacionais com roles e claims
simulados confirmaram que reenvios de métrica/atividade mantêm uma linha, B não
lê/altera dados de A, Hermes sem binding não resolve usuário e Hermes vinculado
não escreve insights de B. Os testes foram revertidos; as tabelas continuam vazias.

## Teste de Auth e integração com Hermes

O teste de login deve usar duas contas Auth reais, A e B, sem compartilhar senhas
ou tokens. No app ou em um cliente local com a chave publicável, entrar como A,
gravar uma métrica de teste e reenviá-la; deve existir uma linha. Entrar como B:
a linha de A não deve aparecer e B não deve conseguir alterá-la. Sem login, a
tabela não deve estar acessível. Por fim, A apaga a linha de teste. Isso valida
o caminho real Auth → Data API → RLS, ainda não coberto pelos testes SQL com
claims simulados.

O Hermes não deve usar o MCP administrativo do Supabase como integração do app.
Quando for integrado, usará uma conexão Postgres com um login exclusivo que herda
`hermes_coach`, associado à conta Auth em `integration.service_user_bindings`.
Se o Hermes só aceitar MCP, uma ponte MCP própria poderá usar esse mesmo login
e expor apenas as operações necessárias.
Nenhum login ou binding permanente foi criado; uma conexão Hermes real ainda
precisa ser testada.

Os ajustes administrativos de Auth e backup ficam para outra versão, conforme
decisão de 28/09/2026. O advisor de segurança não retornou alerta crítico; há
um `WARN` para proteção de senhas vazadas desabilitada, também adiado.
