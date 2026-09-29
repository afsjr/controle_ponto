# Infra — Supabase (registro-ponto)

Feature `001-registro-ponto` · Reversa forward. Artefatos para o **Supabase (PostgreSQL)**.

## Estrutura

```
infra/supabase/
├── README.md                       # este arquivo
├── config.example.json             # modelo de credenciais (URL + anon key)
├── apply_all.sql                   # tudo (0001..0008) em um só script, idempotente
├── migrations/
│   ├── 0001_init.sql               # tabelas, índices, constraints, RLS/revokes
│   ├── 0002_functions.sql          # RPCs: login, registrar_ponto, registros_hoje, etc.
│   ├── 0004_rh.sql                 # painel de acompanhamento (RH)
│   ├── 0005_functions_rh.sql
│   ├── 0006_perfis.sql             # perfis, área/hierarquia, soft delete, auditoria
│   ├── 0007_functions_perfis.sql
│   └── 0008_admin_criar_funcionario.sql  # cadastro de funcionário com senha (bcrypt)
└── tests/
    ├── registro_ponto_test.sql
    ├── acompanhamento_rh_test.sql
    ├── perfis_permissoes_test.sql
    └── admin_criar_funcionario_test.sql
```

## Como aplicar

1. Crie um projeto no Supabase (Região South America / São Paulo é a mais próxima).
2. No **SQL Editor** do projeto, cole e execute **`apply_all.sql`** (tabelas + funções
   + perfis + cadastro). É idempotente, pode reexecutar.
3. Copie `config.example.json` para um local que seu frontend consiga ler e preencha
   `url` e `anonKey` (a anon key é pública, mas ainda assim evite versioná-la).

## Segurança

- As tabelas têm **RLS habilitada e sem políticas**; o acesso é exclusivo pelas funções
  `security definer`. Os papéis `anon`/`authenticated` não têm acesso direto às tabelas.
- Senhas são guardadas com **bcrypt** (`crypt` + `gen_salt('bf')` do `pgcrypto`).
- O token de sessão é opaco (UUID) e expira em 12h (`sessoes.expira_em`).
- `criar_funcionario` (baixo nível) é privada; o cadastro pela UI usa
  `admin_criar_funcionario`, que exige sessão de perfil `rh`/`diretoria`.

## Testes

SQL puro, isolados por `rollback`. No SQL Editor (arquivo inteiro) ou local:

```
bash scripts/test-db.sh
```
