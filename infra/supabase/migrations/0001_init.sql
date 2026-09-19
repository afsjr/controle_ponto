-- 0001_init.sql
-- Feature: registro-ponto (Reversa forward)
-- SGBD: Supabase (PostgreSQL)
-- Cria as tabelas base do ponto escolar. Idempotente (pode rodar de novo).

-- No Supabase as extensões ficam no schema "extensions".
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Funcionários (autenticação por matrícula + senha com hash)
create table if not exists public.funcionarios (
  id          uuid primary key default gen_random_uuid(),
  matricula   text not null unique,
  nome        text not null,
  funcao      text not null,
  senha_hash  text not null,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  constraint funcionarios_matricula_nao_vazia check (length(btrim(matricula)) > 0)
);

-- Sessões emitidas no login (token opaco; sem Supabase Auth)
create table if not exists public.sessoes (
  token          uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete cascade,
  criado_em      timestamptz not null default now(),
  expira_em      timestamptz not null default (now() + interval '12 hours')
);
create index if not exists idx_sessoes_funcionario on public.sessoes (funcionario_id);

-- Registros de ponto (append-only)
create table if not exists public.registros (
  id             uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references public.funcionarios(id) on delete restrict,
  tipo           text not null,
  timestamp_utc  timestamptz not null default now(),
  timezone       text not null default 'America/Sao_Paulo',
  origem         text,
  request_id     uuid not null default gen_random_uuid(),
  criado_em      timestamptz not null default now(),
  constraint registros_tipo_valido check (tipo in ('entrada', 'saida')),
  constraint registros_request_unico unique (funcionario_id, request_id)
);
create index if not exists idx_registros_func_ts
  on public.registros (funcionario_id, timestamp_utc desc);

-- Trilha de auditoria (LGPD)
create table if not exists public.auditoria (
  id        uuid primary key default gen_random_uuid(),
  acao      text not null,
  autor     text,
  detalhe   jsonb,
  criado_em timestamptz not null default now()
);

-- RLS ligada e sem políticas: o acesso se dá apenas pelas funções security definer.
alter table public.funcionarios enable row level security;
alter table public.sessoes       enable row level security;
alter table public.registros     enable row level security;
alter table public.auditoria     enable row level security;

-- Bloqueia acesso direto às tabelas para os papéis públicos do Supabase.
revoke all on public.funcionarios from anon, authenticated;
revoke all on public.sessoes       from anon, authenticated;
revoke all on public.registros     from anon, authenticated;
revoke all on public.auditoria     from anon, authenticated;
