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
