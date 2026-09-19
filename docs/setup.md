# Setup — Controle de Ponto (CSM)

Guia para colocar o projeto no ar. Passo a passo, do banco ao deploy.

## 1. Credenciais do Supabase

No painel: **Project Settings → API**. Copie:
- **Project URL**
- **Publishable key** (pública, própria para o frontend) — no formato `sb_publishable_...`

> A `secret`/`service_role` key é **secreta** e nunca vai para o frontend.

## 2. Preparar o banco (SQL Editor do Supabase)

1. Cole e execute **`infra/supabase/apply_all.sql`** (tabelas + funções). Idempotente.
2. *(dev)* Cole e execute **`infra/supabase/migrations/0003_seed.sql`** (dados de teste, senha `ponto123`).
3. Confira (deve retornar 9 linhas):

```sql
select proname from pg_proc where proname in
('login','registrar_ponto','registros_hoje','acompanhamento_periodo',
 'registros_funcionario_periodo','perfil_atual','admin_atualizar_perfil',
 'excluir_registro','escopo_funcionarios');
```

## 3. Configurar o app (`index.html`)

Preencha `window.PONTO_CONFIG` (perto do fim do arquivo):

```html
<script>
  window.PONTO_CONFIG = {
    url: "https://SEU-PROJETO.supabase.co",
    anonKey: "SUA-PUBLISHABLE-KEY",
    timezone: "America/Sao_Paulo"
  };
</script>
```

Com `url`/`anonKey` vazios, o app roda em **modo local (demo)**, sem servidor.

## 4. Rodar localmente

Sirva por HTTP (não abra via `file://`):

```
python3 -m http.server 8080
```

Abra `http://localhost:8080`.

## 5. Testar

- **Registrar ponto (terminal):** matrícula `218406` / senha `ponto123` → **Entrada** → confirmação com nome e horário. Repita escolhendo **Saída**.
- **Acompanhamento:** `305671` / `ponto123` (Coordenação → perfil `rh`) → painel com totais e pendências.
- Se aparecer "sem permissão", ajuste o perfil:
  `update public.funcionarios set perfil='rh' where matricula='305671';`

## 6. Deploy na Vercel

1. Commite `.vercelignore` (exclui `infra/`, `scripts/`, `docs/` do site).
2. Importe o repositório no Vercel: framework **Other**, **sem build**, diretório raiz.
3. A publishable key fica no `index.html` — é pública; a proteção é RLS + funções `security definer`.

## 7. Testes (TDD)

Local (sobe um Postgres efêmero, aplica migrations e roda as suítes):

```
bash scripts/test-db.sh
```

Os testes também rodam no SQL Editor do Supabase (SQL puro, com `rollback`):

- `infra/supabase/tests/acompanhamento_rh_test.sql`
- `infra/supabase/tests/perfis_permissoes_test.sql`

## 8. Perfis e permissões

| Perfil | Vê | Corrige | Exclui |
|--------|----|---------|--------|
| trabalhador | só os próprios registros | não | não |
| coordenador | subordinados da sua área | desvios da área | não |
| rh | coordenação e abaixo | coordenação e abaixo | não |
| diretoria | todos | todos | **sim (soft delete)** |

Toda alteração é auditada em `auditoria` com `entidade`, `antes`, `depois`, autor e data/hora.

## 9. Segurança / LGPD

- Publishable/anon key = pública; `service_role` = secreta (só em scripts locais, ex. `scripts/migracao.js`).
- `CREDENCIAIS.local.md` fica **fora do Git**.
- Senhas são gravadas com hash bcrypt (`pgcrypto`).

## 10. Problemas comuns

| Sintoma | Causa | Solução |
|---------|-------|---------|
| App em modo local | `PONTO_CONFIG` vazio | preencher `url`/`anonKey` |
| `function gen_salt(...) does not exist` | falta o pgcrypto | rodar `0001_init.sql` (cria em `schema extensions`) |
| `sem_permissao` no painel | usuário sem perfil | `admin_atualizar_perfil` ou SQL |
| Módulo do Supabase não carrega | aberto via `file://` | servir por HTTP |

---

Gerado pela pipeline Reversa em 2026-09-19.
