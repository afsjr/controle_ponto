-- perfis_permissoes_test.sql
-- Testes executáveis da feature 003 (TDD). SQL puro, rode via scripts/test-db.sh
-- ou no SQL Editor do Supabase. Isolado por transação com rollback.

begin;

create or replace function pg_temp.assert_true(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FALHOU: %', p_msg;
  end if;
end;
$$;

-- ---------------------------------------------------------------- setup
select public.criar_funcionario('DIR001', 'Diretora Teste', 'Diretoria', 'dirsenha') as dir_id \gset
update public.funcionarios set perfil = 'diretoria', area = 'Administracao' where matricula = 'DIR001';

select public.criar_funcionario('RH0002', 'RH Teste', 'Recursos Humanos', 'rhsenha') as rh_id \gset
update public.funcionarios set perfil = 'rh', area = 'Administracao' where matricula = 'RH0002';

select public.criar_funcionario('COORD01', 'Coordenador Teste', 'Coordenacao', 'coordsenha') as coord_id \gset
update public.funcionarios set perfil = 'coordenador', area = 'Fundamental' where matricula = 'COORD01';

select public.criar_funcionario('SUB0001', 'Subordinado Teste', 'Assistente', 'subsenha') as sub_id \gset
update public.funcionarios set perfil = 'trabalhador', area = 'Fundamental', coordenador_id = :'coord_id'::uuid where matricula = 'SUB0001';

select public.criar_funcionario('OUT0001', 'Outra Area Teste', 'Assistente', 'outsenha') as out_id \gset
update public.funcionarios set perfil = 'trabalhador', area = 'Infantil' where matricula = 'OUT0001';

select (public.login('DIR001', 'dirsenha') ->> 'token') as dir_token \gset
select (public.login('RH0002', 'rhsenha') ->> 'token') as rh_token \gset
select (public.login('COORD01', 'coordsenha') ->> 'token') as coord_token \gset
select (public.login('SUB0001', 'subsenha') ->> 'token') as sub_token \gset

select
  set_config('test.dir_token', :'dir_token', false),
  set_config('test.rh_token', :'rh_token', false),
  set_config('test.coord_token', :'coord_token', false),
  set_config('test.sub_token', :'sub_token', false),
  set_config('test.dir_id', :'dir_id', false),
  set_config('test.rh_id', :'rh_id', false),
  set_config('test.coord_id', :'coord_id', false),
  set_config('test.sub_id', :'sub_id', false),
  set_config('test.out_id', :'out_id', false);

-- ---------------------------------------------------------------- T004: escopo
do $$
declare n int;
begin
  select count(*) into n from public.escopo_funcionarios(current_setting('test.sub_id')::uuid);
  perform pg_temp.assert_true(n = 1, 'trabalhador deve ver apenas a si, veio ' || n);

  select count(*) into n from public.escopo_funcionarios(current_setting('test.coord_id')::uuid);
  perform pg_temp.assert_true(n = 2, 'coordenador deve ver a si + 1 subordinado, veio ' || n);

  select count(*) into n from public.escopo_funcionarios(current_setting('test.rh_id')::uuid);
  perform pg_temp.assert_true(n = 3, 'RH deve ver trabalhadores + coordenadores, veio ' || n);

  select count(*) into n from public.escopo_funcionarios(current_setting('test.dir_id')::uuid);
  perform pg_temp.assert_true(n = 5, 'diretoria deve ver todos, veio ' || n);
end $$;

-- perfil_atual
do $$
declare r json;
begin
  r := public.perfil_atual(current_setting('test.coord_token')::uuid);
  perform pg_temp.assert_true((r->>'perfil') = 'coordenador', 'perfil_atual = coordenador');
  perform pg_temp.assert_true((r->>'quantidade_escopo')::int = 2, 'escopo do coordenador = 2');
end $$;

-- ---------------------------------------------------------------- T004: detalhe fora do escopo
do $$ declare ok boolean := false; begin
  begin
    perform public.registros_funcionario_periodo(
      current_setting('test.coord_token')::uuid,
      current_setting('test.out_id')::uuid,
      public.hoje_sp(), public.hoje_sp());
  exception when others then
    ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(ok, 'coordenador nao pode ver funcionario de outra area');
end $$;

do $$ declare r json; begin
  r := public.registros_funcionario_periodo(
    current_setting('test.coord_token')::uuid,
    current_setting('test.sub_id')::uuid,
    public.hoje_sp(), public.hoje_sp());
  perform pg_temp.assert_true((r->'funcionario'->>'nome') = 'Subordinado Teste', 'coordenador ve seu subordinado');
end $$;

-- ---------------------------------------------------------------- T005: exclusão (soft delete, só diretoria)
insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem)
values (:'sub_id'::uuid, 'entrada', (public.hoje_sp() + time '08:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste')
returning id as reg_id \gset
select set_config('test.reg_id', :'reg_id', false);

do $$ declare ok boolean := false; begin
  begin
    perform public.excluir_registro(current_setting('test.rh_token')::uuid, current_setting('test.reg_id')::uuid, 'tentativa rh');
  exception when others then
    ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(ok, 'RH nao pode excluir');
end $$;

do $$
declare r json;
declare v_excluido boolean;
begin
  r := public.excluir_registro(current_setting('test.dir_token')::uuid, current_setting('test.reg_id')::uuid, 'duplicidade');
  perform pg_temp.assert_true((r->>'excluido')::boolean is true, 'diretoria exclui (soft delete)');
  select excluido into v_excluido from public.registros where id = current_setting('test.reg_id')::uuid;
  perform pg_temp.assert_true(v_excluido is true, 'registro marcado como excluido');
end $$;

-- ---------------------------------------------------------------- T006: auditoria antes/depois
do $$
declare n int;
begin
  select count(*) into n from public.auditoria
   where acao = 'exclusao' and entidade = 'registro'
     and entidade_id = current_setting('test.reg_id')::uuid
     and antes is not null and depois is not null;
  perform pg_temp.assert_true(n = 1, 'exclusao deve auditar antes/depois');
end $$;

-- ---------------------------------------------------------------- T007: administração
-- RH não pode alterar a diretoria
do $$ declare ok boolean := false; begin
  begin
    perform public.admin_atualizar_perfil(
      current_setting('test.rh_token')::uuid,
      current_setting('test.dir_id')::uuid,
      'trabalhador', 'X', null);
  exception when others then
    ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(ok, 'RH nao pode alterar a diretoria');
end $$;

-- Trabalhador não pode administrar
do $$ declare ok boolean := false; begin
  begin
    perform public.admin_atualizar_perfil(
      current_setting('test.sub_token')::uuid,
      current_setting('test.out_id')::uuid,
      'coordenador', 'Infantil', null);
  exception when others then
    ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(ok, 'trabalhador nao administra perfis');
end $$;

-- Ciclo de hierarquia: coordenador não pode ser subordinado do próprio subordinado
do $$ declare ok boolean := false; begin
  begin
    perform public.admin_atualizar_perfil(
      current_setting('test.dir_token')::uuid,
      current_setting('test.coord_id')::uuid,
      'coordenador', 'Fundamental', current_setting('test.sub_id')::uuid);
  exception when others then
    ok := (sqlerrm like '%ciclo_hierarquia%');
  end;
  perform pg_temp.assert_true(ok, 'deve recusar ciclo de hierarquia');
end $$;

-- Perfil inválido
do $$ declare ok boolean := false; begin
  begin
    perform public.admin_atualizar_perfil(
      current_setting('test.dir_token')::uuid,
      current_setting('test.out_id')::uuid,
      'gerente', 'Infantil', null);
  exception when others then
    ok := (sqlerrm like '%perfil_invalido%');
  end;
  perform pg_temp.assert_true(ok, 'deve recusar perfil invalido');
end $$;

-- RH pode atualizar coordenação para baixo, com auditoria
do $$
declare r json;
declare n int;
begin
  r := public.admin_atualizar_perfil(
    current_setting('test.rh_token')::uuid,
    current_setting('test.sub_id')::uuid,
    'coordenador', 'Fundamental', current_setting('test.coord_id')::uuid);
  perform pg_temp.assert_true((r->>'perfil') = 'coordenador', 'RH atualiza subordinado para coordenador');

  select count(*) into n from public.auditoria
   where acao = 'perfil_atualizado' and entidade = 'funcionario'
     and entidade_id = current_setting('test.sub_id')::uuid
     and antes is not null and depois is not null;
  perform pg_temp.assert_true(n = 1, 'admin deve auditar perfil_atualizado com antes/depois');
end $$;

select 'TODOS OS TESTES PASSARAM' as resultado;

rollback;
