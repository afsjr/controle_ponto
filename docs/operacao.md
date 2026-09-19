# Operação — registro-ponto

Feature `001-registro-ponto` · Reversa forward. Documentação curta de operação e teste.

## 1. Visão geral

O registro de ponto passou a ter backend no **Supabase (PostgreSQL)**. O frontend
(estático) fala com o Supabase por **RPCs**; as tabelas não são acessadas diretamente.

```
Frontend (index.html/app.js)  --RPC-->  Supabase (Postgres + pgcrypto)
   login / registrar_ponto / registros_hoje
```

## 2. Aplicação no Supabase

1. Criar o projeto (região São Paulo).
2. SQL Editor → rodar `infra/supabase/migrations/0001_init.sql`.
3. SQL Editor → rodar `infra/supabase/migrations/0002_functions.sql`.
4. (Dev) rodar `0003_seed.sql` — cria funcionários de teste com senha `ponto123`.

## 3. RPCs disponíveis

| RPC | Entrada | Saída |
|-----|---------|-------|
| `login` | `matricula`, `senha` | `{ token, funcionario }` |
| `registrar_ponto` | `token`, `tipo` (entrada/saida), `origem`, `request_id` | registro criado |
| `registros_hoje` | `token` | `{ estado, registros, data }` |

Erros retornam mensagens com códigos: `credenciais_invalidas`, `funcionario_inativo`,
`nao_autenticado`, `tipo_invalido`, `entrada_ja_aberta`, `sem_entrada_aberta`.

## 4. Teste da feature (manual, quando o projeto existir)

1. Aplicar as migrations.
2. `select public.login('218406','ponto123');` → deve retornar `token`.
3. `select public.registrar_ponto('<token>', 'entrada', 'manual');` → cria entrada.
4. Repetir a entrada → erro `entrada_ja_aberta`.
5. `select public.registrar_ponto('<token>', 'saida', 'manual');` → fecha o intervalo.
6. `select public.registros_hoje('<token>');` → estado + registros do dia.
7. `select public.hoje_sp();` → data no fuso America/Sao_Paulo.

Testes automatizados: `infra/supabase/tests/registro_ponto_test.sql` (pgTAP) — ainda não
executados por falta de instância.

## 5. Migração de dados locais

`scripts/migracao.js` importa o JSON do `localStorage` (`ponto-claro-v1`) para o Supabase.
Requer `SUPABASE_URL` e `SUPABASE_SERVICE_KEY` (service_role, nunca no frontend):

```
SUPABASE_URL=... SUPABASE_SERVICE_KEY=... node scripts/migracao.js base.json
```

Mapeamento: `code`→`matricula`, `name`→`nome`, `role`→`funcao`; registros com
`timestamp`→`timestamp_utc`. Correções ficam para uma feature futura.

## 6. Painel do RH (feature 002 — acompanhamento-rh)

Aplicar também `infra/supabase/migrations/0004_rh.sql` e `0005_functions_rh.sql`. Eles
adicionam `funcionarios.is_rh` / `jornada_minutos` e as RPCs do painel:

| RPC | Entrada | Saída |
|-----|---------|-------|
| `acompanhamento_periodo` | `token`, `inicio`, `fim`, `funcao` | lista com total, presença, pendências e desvio |
| `registros_funcionario_periodo` | `token`, `funcionario_id`, `inicio`, `fim` | registros do funcionário (somente leitura) |

- Autorização: quem não tem `is_rh` recebe `sem_permissao`.
- Jornada: 240/360 min (estagiárias) e 480 min (demais). Refeição de 1h não é contada.
- No app, a view **Acompanhamento** pede matrícula e senha do RH e exibe o mês corrente.

## 7. Testes (TDD)

Testes executáveis em SQL puro (sem extensão):

```
bash scripts/test-db.sh
```

O runner sobe um Postgres efêmero, aplica as migrations e roda as suítes
`acompanhamento_rh_test.sql` (002) e `perfis_permissoes_test.sql` (003) — cobrindo
agregação, refeição excluída, pendências, escopo por perfil, soft delete, auditoria
antes/depois e administração de perfis. No Supabase, os mesmos arquivos rodam no
SQL Editor (isolados por `rollback`).

## 8. Perfis e permissões (feature 003)

Aplicar `0006_perfis.sql` e `0007_functions_perfis.sql`. Perfis: `trabalhador` (só os
próprios), `coordenador` (sua área via `coordenador_id`), `rh` (coordenação e abaixo),
`diretoria` (todos). `is_rh` migra para `perfil = 'rh'`.

| RPC | Para quem | Efeito |
|-----|-----------|--------|
| `perfil_atual` | todos | perfil + tamanho do escopo |
| `acompanhamento_periodo` | todos (escopado) | totais/pendências do escopo |
| `registros_funcionario_periodo` | escopo | detalhe somente leitura |
| `admin_atualizar_perfil` | diretoria + RH | perfil/área/coordenação (valida ciclo) |
| `excluir_registro` | diretoria | soft delete com auditoria antes/depois |

Exclusão é **lógica** (`excluido = true`); toda alteração registra `entidade`,
`antes`/`depois`, autor e data em `auditoria`.

## 9. Pendências

- 🔴 Definir/armazenar credenciais do Supabase no `index.html` (`window.PONTO_CONFIG`).
- 🔴 UI de administração de perfis (hoje via RPC) e edição de áreas.
- 🔴 Política de retenção e base legal LGPD (feature `persistencia-lgpd`).

---

Gerado por reversa-coding em 2026-09-18 · Atualizado para a feature 002 em 2026-09-19.
