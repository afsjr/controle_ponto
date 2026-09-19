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

## 6. Pendências

- 🔴 Frontend ainda não migrado para as RPCs (T018/T020/T021): ações em `actions.md`.
- 🔴 Definir/armazenar credenciais do Supabase (config local).
- 🔴 Política de retenção e base legal LGPD (feature `persistencia-lgpd`).

---

Gerado por reversa-coding em 2026-09-18.
