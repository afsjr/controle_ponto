# Infra — Supabase (registro-ponto)

Feature `001-registro-ponto` · Reversa forward. Artefatos para o **Supabase (PostgreSQL)**.

## Estrutura

```
infra/supabase/
├── README.md                      # este arquivo
├── config.example.json            # modelo de credenciais (URL + anon key)
├── migrations/
│   ├── 0001_init.sql              # tabelas, índices, constraints, RLS/revokes
│   ├── 0002_functions.sql         # RPCs: login, registrar_ponto, registros_hoje, etc.
│   └── 0003_seed.sql              # funcionários de teste (senha padrão "ponto123")
└── tests/
    └── registro_ponto_test.sql    # testes pgTAP (ainda NÃO executados)
```

## Como aplicar

1. Crie um projeto no Supabase (Região South America / São Paulo é a mais próxima).
2. No **SQL Editor** do projeto, execute, nesta ordem: `0001_init.sql`, `0002_functions.sql`.
3. Em desenvolvimento, execute também `0003_seed.sql`.
4. Copie `config.example.json` para um local que seu frontend consiga ler e preencha
   `url` e `anonKey` (a anon key é pública, mas ainda assim evite versioná-la).

## Segurança

- As tabelas têm **RLS habilitada e sem políticas**; o acesso é exclusivo pelas funções
  `security definer`. Os papéis `anon`/`authenticated` não têm acesso direto às tabelas.
- Senhas são guardadas com **bcrypt** (`crypt` + `gen_salt('bf')` do `pgcrypto`).
- O token de sessão é opaco (UUID) e expira em 12h (`sessoes.expira_em`).

## Pendências conhecidas

- 🔴 Projeto Supabase ainda não existe; os artefatos **não foram executados**.
- 🔴 Testes pgTAP exigem instância com a extensão `pgtap` e ainda não rodaram.
- 🔴 Frontend (`app.js`) ainda não foi migrado para chamar as RPCs (ações T018/T020/T021).
