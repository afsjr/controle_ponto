-- apply_all.sql — aplica todas as migrations de schema/funções (SEM seed).
-- Ordem: 0001 -> 0002 -> 0004 -> 0005 -> 0006 -> 0007
-- Rode no SQL Editor do Supabase. Idempotente (pode reexecutar).
-- Para dados de teste, rode também 0003_seed.sql.


-- ============================================================
-- 0001_init.sql
-- ============================================================
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

-- ============================================================
-- 0002_functions.sql
-- ============================================================
-- 0002_functions.sql
-- Funções de negócio (security definer). O frontend chama apenas estas RPCs.
-- Regras herdadas do legado: _reversa_sdd/domain.md#4.1 (BR-01..BR-07)
-- Timezone: America/Sao_Paulo (RN-09). Timestamps em UTC.

-- Dia corrente no fuso de Brasília
create or replace function public.hoje_sp()
returns date
language sql stable
as $$ select (now() at time zone 'America/Sao_Paulo')::date; $$;

-- Login por matrícula + senha. Retorna token de sessão e dados do funcionário.
create or replace function public.login(p_matricula text, p_senha text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v record;
  v_token uuid;
begin
  if p_matricula is null or p_senha is null then
    raise exception 'dados_invalidos' using errcode = 'P0001';
  end if;

  select * into v from funcionarios where matricula = p_matricula;
  if not found then
    raise exception 'credenciais_invalidas' using errcode = 'P0001';
  end if;
  if not v.ativo then
    raise exception 'funcionario_inativo' using errcode = 'P0001';
  end if;
  if v.senha_hash <> crypt(p_senha, v.senha_hash) then
    insert into auditoria(acao, autor, detalhe)
      values ('login_falho', p_matricula, jsonb_build_object('motivo', 'credenciais_invalidas'));
    raise exception 'credenciais_invalidas' using errcode = 'P0001';
  end if;

  insert into sessoes(funcionario_id) values (v.id) returning sessoes.token into v_token;
  insert into auditoria(acao, autor, detalhe)
    values ('login', v.matricula, jsonb_build_object('funcionario_id', v.id));

  return json_build_object(
    'token', v_token,
    'funcionario', json_build_object(
      'id', v.id, 'matricula', v.matricula, 'nome', v.nome, 'funcao', v.funcao
    )
  );
end;
$$;

-- Resolve o funcionário a partir do token de sessão válido.
create or replace function public.funcionario_por_token(p_token uuid)
returns uuid
language sql stable security definer set search_path = public
as $$
  select funcionario_id from sessoes
   where token = p_token and expira_em > now();
$$;

-- Estado de ponto derivado do último registro do dia (não persistido).
create or replace function public.estado_do_dia(p_funcionario uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select tipo from registros
      where funcionario_id = p_funcionario
        and (timestamp_utc at time zone 'America/Sao_Paulo')::date = hoje_sp()
      order by timestamp_utc desc limit 1),
    'fora'
  );
$$;

-- Registra entrada/saída com regras de sequência + idempotência.
create or replace function public.registrar_ponto(
  p_token uuid,
  p_tipo text,
  p_origem text default null,
  p_request_id uuid default gen_random_uuid()
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_func uuid;
  v_estado text;
  v_id uuid;
  v_ts timestamptz;
  v_tz text;
  v_existente record;
begin
  v_func := funcionario_por_token(p_token);
  if v_func is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;
  if p_tipo not in ('entrada', 'saida') then
    raise exception 'tipo_invalido' using errcode = 'P0001';
  end if;

  -- Idempotência: mesmo request_id devolve o registro já criado (RN-08)
  select * into v_existente from registros
   where funcionario_id = v_func and request_id = p_request_id;
  if found then
    return json_build_object(
      'id', v_existente.id,
      'funcionario_id', v_existente.funcionario_id,
      'tipo', v_existente.tipo,
      'timestamp_utc', v_existente.timestamp_utc,
      'timezone', v_existente.timezone,
      'idempotente', true
    );
  end if;

  v_estado := estado_do_dia(v_func);

  if p_tipo = 'entrada' and v_estado = 'entrada' then
    raise exception 'entrada_ja_aberta' using errcode = 'P0001';        -- BR-02
  end if;
  if p_tipo = 'saida' and v_estado <> 'entrada' then
    raise exception 'sem_entrada_aberta' using errcode = 'P0001';       -- BR-03
  end if;

  insert into registros(funcionario_id, tipo, timezone, origem, request_id)
    values (v_func, p_tipo, 'America/Sao_Paulo', p_origem, p_request_id)
    returning id, timestamp_utc, timezone into v_id, v_ts, v_tz;

  insert into auditoria(acao, autor, detalhe)
    values ('registro', v_func::text, jsonb_build_object('tipo', p_tipo, 'registro_id', v_id));

  return json_build_object(
    'id', v_id,
    'funcionario_id', v_func,
    'tipo', p_tipo,
    'timestamp_utc', v_ts,
    'timezone', v_tz
  );
end;
$$;

-- Registros do dia + estado derivado (detalhe/conferência).
create or replace function public.registros_hoje(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_func uuid;
  v_regs json;
begin
  v_func := funcionario_por_token(p_token);
  if v_func is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;

  select coalesce(
    json_agg(
      json_build_object('id', id, 'tipo', tipo, 'timestamp_utc', timestamp_utc)
      order by timestamp_utc
    ), '[]'::json)
    into v_regs
    from registros
   where funcionario_id = v_func
     and (timestamp_utc at time zone 'America/Sao_Paulo')::date = hoje_sp();

  return json_build_object(
    'funcionario_id', v_func,
    'data', hoje_sp(),
    'timezone', 'America/Sao_Paulo',
    'estado', estado_do_dia(v_func),
    'registros', v_regs
  );
end;
$$;

-- Cadastro de funcionário com senha hasheada (bcrypt via pgcrypto).
create or replace function public.criar_funcionario(
  p_matricula text, p_nome text, p_funcao text, p_senha text
)
returns uuid
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  insert into funcionarios(matricula, nome, funcao, senha_hash)
    values (p_matricula, p_nome, p_funcao, crypt(p_senha, gen_salt('bf')))
    returning id into v_id;
  return v_id;
end;
$$;

-- Permissões: apenas execução das RPCs públicas pelo anon.
revoke all on function public.funcionario_por_token(uuid) from anon, authenticated;
revoke all on function public.estado_do_dia(uuid) from anon, authenticated;
revoke all on function public.criar_funcionario(text, text, text, text) from anon, authenticated;

grant execute on function public.hoje_sp() to anon, authenticated;
grant execute on function public.login(text, text) to anon;
grant execute on function public.registrar_ponto(uuid, text, text, uuid) to anon;
grant execute on function public.registros_hoje(uuid) to anon;

-- ============================================================
-- 0004_rh.sql
-- ============================================================
-- 0004_rh.sql
-- Feature: acompanhamento-rh (Reversa forward)
-- Adiciona papel de RH e jornada esperada por funcionário. Aditivo e idempotente.

alter table public.funcionarios
  add column if not exists is_rh boolean not null default false;

alter table public.funcionarios
  add column if not exists jornada_minutos integer not null default 480;

do $$
begin
  begin
    alter table public.funcionarios
      add constraint funcionarios_jornada_positiva check (jornada_minutos > 0);
  exception
    when duplicate_object then null;   -- constraint já existe
    when duplicate_table then null;
  end;
end $$;

create index if not exists idx_registros_periodo
  on public.registros (date(timestamp_utc at time zone 'America/Sao_Paulo'));

-- Dados de desenvolvimento (idempotente): estagiárias 4h, coordenação vira RH.
-- Observação: estagiárias de 6h devem ser ajustadas individualmente (jornada_minutos = 360).
update public.funcionarios
   set jornada_minutos = 240
 where funcao ilike '%estagi%'
   and jornada_minutos = 480;

update public.funcionarios
   set is_rh = true
 where funcao ilike '%coordena%';

-- ============================================================
-- 0005_functions_rh.sql
-- ============================================================
-- 0005_functions_rh.sql
-- Feature: acompanhamento-rh (Reversa forward)
-- RPCs do painel do RH, com autorização por is_rh. Regras: requirements.md da 002.

-- Um funcionário é RH?
create or replace function public.funcionario_e_rh(p_funcionario uuid)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select coalesce((select is_rh from funcionarios where id = p_funcionario), false);
$$;

-- Autoriza e devolve o funcionário de RH, ou levanta erro.
create or replace function public.exigir_rh(p_token uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions
as $$
declare v_func uuid;
begin
  v_func := funcionario_por_token(p_token);
  if v_func is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;
  if not funcionario_e_rh(v_func) then
    insert into auditoria(acao, autor, detalhe)
      values ('acompanhamento_negado', v_func::text, null);
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;
  return v_func;
end;
$$;

-- Painel: totais, presença, pendências e desvios por funcionário no período.
create or replace function public.acompanhamento_periodo(
  p_token uuid,
  p_inicio date,
  p_fim date,
  p_funcao text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_rh uuid;
  v_result json;
  v_limite_dias int := 92;
begin
  v_rh := exigir_rh(p_token);

  if p_inicio is null or p_fim is null or p_fim < p_inicio then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;
  if (p_fim - p_inicio) > v_limite_dias then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;

  with regs as (
    select
      r.funcionario_id,
      (r.timestamp_utc at time zone 'America/Sao_Paulo')::date as dia,
      r.timestamp_utc,
      r.tipo,
      row_number() over (
        partition by r.funcionario_id, (r.timestamp_utc at time zone 'America/Sao_Paulo')::date
        order by r.timestamp_utc
      ) as rn
    from registros r
    where (r.timestamp_utc at time zone 'America/Sao_Paulo')::date between p_inicio and p_fim
  ),
  contagem_dia as (
    select funcionario_id, dia, count(*)::int as cnt
    from regs
    group by funcionario_id, dia
  ),
  pares as (
    select
      a.funcionario_id,
      a.dia,
      extract(epoch from (b.timestamp_utc - a.timestamp_utc)) / 60.0 as minutos
    from regs a
    join regs b
      on b.funcionario_id = a.funcionario_id
     and b.dia = a.dia
     and b.rn = a.rn + 1
    where a.tipo = 'entrada' and b.tipo = 'saida'
  ),
  totais as (
    select
      funcionario_id,
      coalesce(round(sum(minutos)), 0)::int as total_minutos,
      count(distinct dia)::int as dias_completos
    from pares
    group by funcionario_id
  ),
  dias_uteis as (
    select d::date as dia
    from generate_series(p_inicio, least(p_fim, hoje_sp()), interval '1 day') d
    where extract(isodow from d) between 1 and 5
  ),
  pend as (
    select
      f.id as funcionario_id,
      coalesce(
        array_agg(u.dia order by u.dia) filter (where coalesce(c.cnt, 0) = 0 or coalesce(c.cnt, 0) % 2 = 1),
        '{}'
      ) as dias_pendentes
    from funcionarios f
    cross join dias_uteis u
    left join contagem_dia c on c.funcionario_id = f.id and c.dia = u.dia
    where f.ativo and (p_funcao is null or f.funcao = p_funcao)
    group by f.id
  )
  select coalesce(json_agg(
           json_build_object(
             'funcionario_id', f.id,
             'matricula', f.matricula,
             'nome', f.nome,
             'funcao', f.funcao,
             'jornada_minutos', f.jornada_minutos,
             'total_minutos', coalesce(t.total_minutos, 0),
             'presenca', estado_do_dia(f.id),
             'dias_pendentes', coalesce(pd.dias_pendentes, '{}'),
             'desvio_minutos', coalesce(t.total_minutos, 0) - f.jornada_minutos * coalesce(t.dias_completos, 0)
           ) order by f.nome
         ), '[]'::json)
    into v_result
  from funcionarios f
  left join totais t on t.funcionario_id = f.id
  left join pend pd on pd.funcionario_id = f.id
  where f.ativo and (p_funcao is null or f.funcao = p_funcao);

  insert into auditoria(acao, autor, detalhe)
    values ('acompanhamento_consulta', v_rh::text,
            jsonb_build_object('inicio', p_inicio, 'fim', p_fim, 'funcao', p_funcao));

  return v_result;
end;
$$;

-- Detalhe somente leitura dos registros de um funcionário no período.
create or replace function public.registros_funcionario_periodo(
  p_token uuid,
  p_funcionario_id uuid,
  p_inicio date,
  p_fim date
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_rh uuid;
  v_result json;
begin
  v_rh := exigir_rh(p_token);

  if p_inicio is null or p_fim is null or p_fim < p_inicio then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;

  select json_build_object(
    'funcionario', (
      select json_build_object('id', id, 'nome', nome, 'funcao', funcao)
      from funcionarios where id = p_funcionario_id
    ),
    'registros', coalesce((
      select json_agg(json_build_object('id', id, 'tipo', tipo, 'timestamp_utc', timestamp_utc) order by timestamp_utc)
      from registros
      where funcionario_id = p_funcionario_id
        and (timestamp_utc at time zone 'America/Sao_Paulo')::date between p_inicio and p_fim
    ), '[]'::json)
  ) into v_result;

  insert into auditoria(acao, autor, detalhe)
    values ('acompanhamento_detalhe', v_rh::text,
            jsonb_build_object('funcionario_id', p_funcionario_id));

  return v_result;
end;
$$;

-- Permissões: funções internas ficam privadas; RPCs públicas para o anon.
revoke all on function public.funcionario_e_rh(uuid) from anon, authenticated;
revoke all on function public.exigir_rh(uuid) from anon, authenticated;
grant execute on function public.acompanhamento_periodo(uuid, date, date, text) to anon;
grant execute on function public.registros_funcionario_periodo(uuid, uuid, date, date) to anon;

-- ============================================================
-- 0006_perfis.sql
-- ============================================================
-- 0006_perfis.sql
-- Feature: perfis-permissoes (Reversa forward)
-- Perfis, área/hierarquia, soft delete e auditoria com antes/depois. Aditivo e idempotente.

-- funcionarios: perfil, área, coordenação e soft delete
alter table public.funcionarios
  add column if not exists perfil text not null default 'trabalhador',
  add column if not exists area text,
  add column if not exists coordenador_id uuid references public.funcionarios(id),
  add column if not exists excluido boolean not null default false,
  add column if not exists excluido_em timestamptz,
  add column if not exists excluido_por uuid;

do $$
begin
  begin
    alter table public.funcionarios
      add constraint funcionarios_perfil_valido
      check (perfil in ('trabalhador', 'coordenador', 'rh', 'diretoria'));
  exception
    when duplicate_object then null;
    when duplicate_table then null;
  end;
end $$;

create index if not exists idx_funcionarios_coordenador on public.funcionarios (coordenador_id);
create index if not exists idx_funcionarios_area on public.funcionarios (area);
create index if not exists idx_funcionarios_perfil on public.funcionarios (perfil);

-- registros: soft delete
alter table public.registros
  add column if not exists excluido boolean not null default false,
  add column if not exists excluido_em timestamptz,
  add column if not exists excluido_por uuid;

-- auditoria: o que mudou (antes/depois) por entidade
alter table public.auditoria
  add column if not exists entidade text,
  add column if not exists entidade_id uuid,
  add column if not exists antes jsonb,
  add column if not exists depois jsonb;

-- Migração: is_rh -> perfil 'rh'
update public.funcionarios
   set perfil = 'rh'
 where is_rh = true
   and perfil <> 'rh';

-- Dados de desenvolvimento (idempotente): dá uma área de exemplo à coordenação.
update public.funcionarios
   set area = coalesce(area, 'Administracao')
 where perfil in ('rh', 'diretoria')
   and area is null;

-- ============================================================
-- 0007_functions_perfis.sql
-- ============================================================
-- 0007_functions_perfis.sql
-- Feature: perfis-permissoes (Reversa forward)
-- Autorização por perfil + escopo (área/hierarquia), soft delete e auditoria antes/depois.

-- ---------------------------------------------------------------- helpers

create or replace function public.perfil_do_funcionario(p_id uuid)
returns text
language sql stable security definer set search_path = public, extensions
as $$
  select coalesce((select perfil from funcionarios where id = p_id), 'trabalhador');
$$;

-- Exige sessão válida de funcionário ativo e não excluído.
create or replace function public.exigir_autorizado(p_token uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v uuid;
  v_ok boolean;
begin
  v := funcionario_por_token(p_token);
  if v is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;
  select (not excluido and ativo) into v_ok from funcionarios where id = v;
  if v_ok is not true then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;
  return v;
end;
$$;

-- Escopo visível ao ator, conforme o perfil.
--  trabalhador: {self} | coordenador: {self} + subárvore | rh: trabalhador+coordenador | diretoria: todos
create or replace function public.escopo_funcionarios(p_ator uuid)
returns table (funcionario_id uuid)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
  v_perfil text;
begin
  v_perfil := perfil_do_funcionario(p_ator);

  if v_perfil = 'diretoria' then
    return query select id from funcionarios where not excluido;
  elsif v_perfil = 'rh' then
    return query select id from funcionarios
                  where not excluido and perfil in ('trabalhador', 'coordenador');
  elsif v_perfil = 'coordenador' then
    return query
      with recursive sub as (
        select f.id, 1 as depth
          from funcionarios f
         where f.coordenador_id = p_ator and not f.excluido
        union all
        select f.id, s.depth + 1
          from funcionarios f
          join sub s on f.coordenador_id = s.id
         where not f.excluido and s.depth < 20
      )
      select p_ator
      union
      select id from sub;
  else
    return query select p_ator;
  end if;
end;
$$;

create or replace function public.pode_ver(p_ator uuid, p_alvo uuid)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select exists (select 1 from escopo_funcionarios(p_ator) e where e.funcionario_id = p_alvo);
$$;

create or replace function public.registrar_auditoria(
  p_acao text, p_autor text, p_entidade text, p_entidade_id uuid, p_antes jsonb, p_depois jsonb
)
returns void
language sql security definer set search_path = public, extensions
as $$
  insert into auditoria(acao, autor, entidade, entidade_id, antes, depois)
  values (p_acao, p_autor, p_entidade, p_entidade_id, p_antes, p_depois);
$$;

-- perfil + escopo do ator (para a UI)
create or replace function public.perfil_atual(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v uuid;
  v_row record;
  v_n int;
begin
  v := exigir_autorizado(p_token);
  select * into v_row from funcionarios where id = v;
  select count(*) into v_n from escopo_funcionarios(v);
  return json_build_object(
    'perfil', v_row.perfil,
    'area', v_row.area,
    'quantidade_escopo', v_n
  );
end;
$$;

-- ---------------------------------------------------------------- RPCs de administração

create or replace function public.admin_atualizar_perfil(
  p_token uuid,
  p_funcionario_id uuid,
  p_perfil text,
  p_area text default null,
  p_coordenador_id uuid default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_ator uuid;
  v_perfil_ator text;
  v_alvo_perfil text;
  v_antes jsonb;
  v_depois jsonb;
begin
  v_ator := exigir_autorizado(p_token);
  v_perfil_ator := perfil_do_funcionario(v_ator);

  if p_perfil not in ('trabalhador', 'coordenador', 'rh', 'diretoria') then
    raise exception 'perfil_invalido' using errcode = 'P0001';
  end if;

  select perfil into v_alvo_perfil from funcionarios where id = p_funcionario_id;
  if v_alvo_perfil is null then
    raise exception 'funcionario_inexistente' using errcode = 'P0001';
  end if;

  -- diretoria administra todos; RH administra coordenação para baixo
  if v_perfil_ator = 'diretoria' then
    null;
  elsif v_perfil_ator = 'rh' then
    if v_alvo_perfil not in ('trabalhador', 'coordenador')
       or p_perfil not in ('trabalhador', 'coordenador') then
      perform registrar_auditoria('perfil_negado', v_ator::text, 'funcionario', p_funcionario_id, null, null);
      raise exception 'sem_permissao' using errcode = 'P0001';
    end if;
  else
    perform registrar_auditoria('perfil_negado', v_ator::text, 'funcionario', p_funcionario_id, null, null);
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;

  -- validação de ciclo na hierarquia
  if p_coordenador_id is not null then
    if p_coordenador_id = p_funcionario_id then
      raise exception 'ciclo_hierarquia' using errcode = 'P0001';
    end if;
    if exists (
      with recursive sub as (
        select id from funcionarios where coordenador_id = p_funcionario_id
        union all
        select f.id from funcionarios f join sub s on f.coordenador_id = s.id
      )
      select 1 from sub where id = p_coordenador_id
    ) then
      raise exception 'ciclo_hierarquia' using errcode = 'P0001';
    end if;
  end if;

  select to_jsonb(f) into v_antes from funcionarios f where id = p_funcionario_id;

  update funcionarios
     set perfil = p_perfil, area = p_area, coordenador_id = p_coordenador_id
   where id = p_funcionario_id;

  select to_jsonb(f) into v_depois from funcionarios f where id = p_funcionario_id;

  perform registrar_auditoria('perfil_atualizado', v_ator::text, 'funcionario', p_funcionario_id, v_antes, v_depois);

  return json_build_object('funcionario_id', p_funcionario_id, 'perfil', p_perfil, 'area', p_area);
end;
$$;

-- Exclusão lógica de registro de ponto. Somente diretoria.
create or replace function public.excluir_registro(
  p_token uuid,
  p_registro_id uuid,
  p_motivo text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_ator uuid;
  v_antes jsonb;
  v_depois jsonb;
begin
  v_ator := exigir_autorizado(p_token);

  if perfil_do_funcionario(v_ator) <> 'diretoria' then
    perform registrar_auditoria('exclusao_negada', v_ator::text, 'registro', p_registro_id, null, null);
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;

  select to_jsonb(r) into v_antes from registros r where id = p_registro_id;
  if v_antes is null then
    raise exception 'registro_inexistente' using errcode = 'P0001';
  end if;

  update registros
     set excluido = true, excluido_em = now(), excluido_por = v_ator
   where id = p_registro_id;

  select to_jsonb(r) into v_depois from registros r where id = p_registro_id;

  perform registrar_auditoria(
    'exclusao', v_ator::text, 'registro', p_registro_id, v_antes,
    coalesce(v_depois, '{}'::jsonb) || jsonb_build_object('motivo', p_motivo)
  );

  return json_build_object('registro_id', p_registro_id, 'excluido', true);
end;
$$;

-- ---------------------------------------------------------------- evolução das RPCs do painel

-- estado do dia ignora registros excluídos (soft delete)
create or replace function public.estado_do_dia(p_funcionario uuid)
returns text
language sql stable security definer set search_path = public, extensions
as $$
  select coalesce(
    (select tipo from registros
      where funcionario_id = p_funcionario
        and not excluido
        and (timestamp_utc at time zone 'America/Sao_Paulo')::date = hoje_sp()
      order by timestamp_utc desc limit 1),
    'fora'
  );
$$;

create or replace function public.registros_hoje(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_func uuid;
  v_regs json;
begin
  v_func := funcionario_por_token(p_token);
  if v_func is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;

  select coalesce(
    json_agg(
      json_build_object('id', id, 'tipo', tipo, 'timestamp_utc', timestamp_utc)
      order by timestamp_utc
    ), '[]'::json)
    into v_regs
    from registros
   where funcionario_id = v_func
     and not excluido
     and (timestamp_utc at time zone 'America/Sao_Paulo')::date = hoje_sp();

  return json_build_object(
    'funcionario_id', v_func,
    'data', hoje_sp(),
    'timezone', 'America/Sao_Paulo',
    'estado', estado_do_dia(v_func),
    'registros', v_regs
  );
end;
$$;

-- Painel escopado ao perfil do ator (substitui a exigência de is_rh)
create or replace function public.acompanhamento_periodo(
  p_token uuid, p_inicio date, p_fim date, p_funcao text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_ator uuid;
  v_result json;
  v_limite_dias int := 92;
begin
  v_ator := exigir_autorizado(p_token);

  if p_inicio is null or p_fim is null or p_fim < p_inicio then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;
  if (p_fim - p_inicio) > v_limite_dias then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;

  with regs as (
    select
      r.funcionario_id,
      (r.timestamp_utc at time zone 'America/Sao_Paulo')::date as dia,
      r.timestamp_utc,
      r.tipo,
      row_number() over (
        partition by r.funcionario_id, (r.timestamp_utc at time zone 'America/Sao_Paulo')::date
        order by r.timestamp_utc
      ) as rn
    from registros r
    where not r.excluido
      and (r.timestamp_utc at time zone 'America/Sao_Paulo')::date between p_inicio and p_fim
  ),
  contagem_dia as (
    select funcionario_id, dia, count(*)::int as cnt
    from regs group by funcionario_id, dia
  ),
  pares as (
    select a.funcionario_id, a.dia,
           extract(epoch from (b.timestamp_utc - a.timestamp_utc)) / 60.0 as minutos
    from regs a
    join regs b on b.funcionario_id = a.funcionario_id and b.dia = a.dia and b.rn = a.rn + 1
    where a.tipo = 'entrada' and b.tipo = 'saida'
  ),
  totais as (
    select funcionario_id,
           coalesce(round(sum(minutos)), 0)::int as total_minutos,
           count(distinct dia)::int as dias_completos
    from pares group by funcionario_id
  ),
  dias_uteis as (
    select d::date as dia
    from generate_series(p_inicio, least(p_fim, hoje_sp()), interval '1 day') d
    where extract(isodow from d) between 1 and 5
  ),
  pend as (
    select f.id as funcionario_id,
           coalesce(array_agg(u.dia order by u.dia) filter (where coalesce(c.cnt,0) = 0 or coalesce(c.cnt,0) % 2 = 1), '{}') as dias_pendentes
    from funcionarios f
    cross join dias_uteis u
    left join contagem_dia c on c.funcionario_id = f.id and c.dia = u.dia
    where f.ativo and not f.excluido
      and (p_funcao is null or f.funcao = p_funcao)
      and f.id in (select funcionario_id from escopo_funcionarios(v_ator))
    group by f.id
  )
  select coalesce(json_agg(
           json_build_object(
             'funcionario_id', f.id,
             'matricula', f.matricula,
             'nome', f.nome,
             'funcao', f.funcao,
             'jornada_minutos', f.jornada_minutos,
             'total_minutos', coalesce(t.total_minutos, 0),
             'presenca', estado_do_dia(f.id),
             'dias_pendentes', coalesce(pd.dias_pendentes, '{}'),
             'desvio_minutos', coalesce(t.total_minutos, 0) - f.jornada_minutos * coalesce(t.dias_completos, 0)
           ) order by f.nome
         ), '[]'::json)
    into v_result
  from funcionarios f
  left join totais t on t.funcionario_id = f.id
  left join pend pd on pd.funcionario_id = f.id
  where f.ativo and not f.excluido
    and (p_funcao is null or f.funcao = p_funcao)
    and f.id in (select funcionario_id from escopo_funcionarios(v_ator));

  perform registrar_auditoria('acompanhamento_consulta', v_ator::text, 'consulta', null,
    null, jsonb_build_object('inicio', p_inicio, 'fim', p_fim, 'funcao', p_funcao));

  return v_result;
end;
$$;

-- Detalhe escopado e sem registros excluídos
create or replace function public.registros_funcionario_periodo(
  p_token uuid, p_funcionario_id uuid, p_inicio date, p_fim date
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_ator uuid;
  v_result json;
begin
  v_ator := exigir_autorizado(p_token);

  if not pode_ver(v_ator, p_funcionario_id) then
    perform registrar_auditoria('acesso_negado', v_ator::text, 'funcionario', p_funcionario_id, null, null);
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;

  if p_inicio is null or p_fim is null or p_fim < p_inicio then
    raise exception 'periodo_invalido' using errcode = 'P0001';
  end if;

  select json_build_object(
    'funcionario', (
      select json_build_object('id', id, 'nome', nome, 'funcao', funcao, 'perfil', perfil, 'area', area)
      from funcionarios where id = p_funcionario_id
    ),
    'registros', coalesce((
      select json_agg(json_build_object('id', id, 'tipo', tipo, 'timestamp_utc', timestamp_utc) order by timestamp_utc)
      from registros
      where funcionario_id = p_funcionario_id
        and not excluido
        and (timestamp_utc at time zone 'America/Sao_Paulo')::date between p_inicio and p_fim
    ), '[]'::json)
  ) into v_result;

  perform registrar_auditoria('acompanhamento_detalhe', v_ator::text, 'funcionario', p_funcionario_id, null, null);

  return v_result;
end;
$$;

-- ---------------------------------------------------------------- permissões

revoke all on function public.perfil_do_funcionario(uuid) from anon, authenticated;
revoke all on function public.exigir_autorizado(uuid) from anon, authenticated;
revoke all on function public.escopo_funcionarios(uuid) from anon, authenticated;
revoke all on function public.pode_ver(uuid, uuid) from anon, authenticated;
revoke all on function public.registrar_auditoria(text, text, text, uuid, jsonb, jsonb) from anon, authenticated;

grant execute on function public.perfil_atual(uuid) to anon;
grant execute on function public.admin_atualizar_perfil(uuid, uuid, text, text, uuid) to anon;
grant execute on function public.excluir_registro(uuid, uuid, text) to anon;
