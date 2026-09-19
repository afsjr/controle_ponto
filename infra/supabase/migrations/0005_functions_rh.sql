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
