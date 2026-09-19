-- perfis_permissoes_test.sql
-- Testes da feature 003. SQL puro (sem comandos do psql), roda no Supabase SQL Editor
-- e no runner local (scripts/test-db.sh). Isolado por transação com rollback.
-- No Supabase, cole o arquivo inteiro e execute (uma vez).

begin;

create or replace function pg_temp.assert_true(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FALHOU: %', p_msg;
  end if;
end;
$$;

do $$
declare
  v_dir uuid; v_rh uuid; v_coord uuid; v_sub uuid; v_out uuid;
  v_dir_token uuid; v_rh_token uuid; v_coord_token uuid; v_sub_token uuid;
  v_n int; v_r json; v_reg uuid; v_ok boolean;
begin
  -- ---------------------------------------------------------------- setup
  v_dir := public.criar_funcionario('DIR001', 'Diretora Teste', 'Diretoria', 'dirsenha');
  update public.funcionarios set perfil = 'diretoria', area = 'Administracao' where id = v_dir;

  v_rh := public.criar_funcionario('RH0002', 'RH Teste', 'Recursos Humanos', 'rhsenha');
  update public.funcionarios set perfil = 'rh', area = 'Administracao' where id = v_rh;

  v_coord := public.criar_funcionario('COORD01', 'Coordenador Teste', 'Coordenacao', 'coordsenha');
  update public.funcionarios set perfil = 'coordenador', area = 'Fundamental' where id = v_coord;

  v_sub := public.criar_funcionario('SUB0001', 'Subordinado Teste', 'Assistente', 'subsenha');
  update public.funcionarios set perfil = 'trabalhador', area = 'Fundamental', coordenador_id = v_coord where id = v_sub;

  v_out := public.criar_funcionario('OUT0001', 'Outra Area Teste', 'Assistente', 'outsenha');
  update public.funcionarios set perfil = 'trabalhador', area = 'Infantil' where id = v_out;

  v_dir_token := (public.login('DIR001', 'dirsenha') ->> 'token')::uuid;
  v_rh_token := (public.login('RH0002', 'rhsenha') ->> 'token')::uuid;
  v_coord_token := (public.login('COORD01', 'coordsenha') ->> 'token')::uuid;
  v_sub_token := (public.login('SUB0001', 'subsenha') ->> 'token')::uuid;

  -- ---------------------------------------------------------------- T004: escopo
  select count(*) into v_n from public.escopo_funcionarios(v_sub);
  perform pg_temp.assert_true(v_n = 1, 'trabalhador deve ver apenas a si, veio ' || v_n);

  select count(*) into v_n from public.escopo_funcionarios(v_coord);
  perform pg_temp.assert_true(v_n = 2, 'coordenador deve ver a si + 1 subordinado, veio ' || v_n);

  perform pg_temp.assert_true(
    exists (select 1 from public.escopo_funcionarios(v_rh) e where e.funcionario_id = v_sub)
    and not exists (select 1 from public.escopo_funcionarios(v_rh) e where e.funcionario_id = v_dir),
    'RH deve incluir trabalhadores/coordenadores e excluir a diretoria');

  perform pg_temp.assert_true(
    exists (select 1 from public.escopo_funcionarios(v_dir) e where e.funcionario_id = v_rh),
    'diretoria deve incluir o RH');

  v_r := public.perfil_atual(v_coord_token);
  perform pg_temp.assert_true((v_r ->> 'perfil') = 'coordenador', 'perfil_atual = coordenador');
  perform pg_temp.assert_true((v_r ->> 'quantidade_escopo')::int = 2, 'escopo do coordenador = 2');

  -- detalhe fora do escopo
  v_ok := false;
  begin
    perform public.registros_funcionario_periodo(v_coord_token, v_out, public.hoje_sp(), public.hoje_sp());
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'coordenador nao pode ver funcionario de outra area');

  v_r := public.registros_funcionario_periodo(v_coord_token, v_sub, public.hoje_sp(), public.hoje_sp());
  perform pg_temp.assert_true((v_r -> 'funcionario' ->> 'nome') = 'Subordinado Teste', 'coordenador ve seu subordinado');

  -- ---------------------------------------------------------------- T005: exclusão (soft delete)
  insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem)
    values (v_sub, 'entrada', (public.hoje_sp() + time '08:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste')
    returning id into v_reg;

  v_ok := false;
  begin
    perform public.excluir_registro(v_rh_token, v_reg, 'tentativa rh');
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'RH nao pode excluir');

  v_r := public.excluir_registro(v_dir_token, v_reg, 'duplicidade');
  perform pg_temp.assert_true((v_r ->> 'excluido')::boolean is true, 'diretoria exclui (soft delete)');

  perform pg_temp.assert_true(
    (select excluido from public.registros where id = v_reg) is true,
    'registro marcado como excluido');

  -- ---------------------------------------------------------------- T006: auditoria antes/depois
  select count(*) into v_n from public.auditoria
   where acao = 'exclusao' and entidade = 'registro' and entidade_id = v_reg
     and antes is not null and depois is not null;
  perform pg_temp.assert_true(v_n = 1, 'exclusao deve auditar antes/depois');

  -- ---------------------------------------------------------------- T007: administração
  v_ok := false;
  begin
    perform public.admin_atualizar_perfil(v_rh_token, v_dir, 'trabalhador', 'X', null);
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'RH nao pode alterar a diretoria');

  v_ok := false;
  begin
    perform public.admin_atualizar_perfil(v_sub_token, v_out, 'coordenador', 'Infantil', null);
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'trabalhador nao administra perfis');

  v_ok := false;
  begin
    perform public.admin_atualizar_perfil(v_dir_token, v_coord, 'coordenador', 'Fundamental', v_sub);
  exception when others then
    v_ok := (sqlerrm like '%ciclo_hierarquia%');
  end;
  perform pg_temp.assert_true(v_ok, 'deve recusar ciclo de hierarquia');

  v_ok := false;
  begin
    perform public.admin_atualizar_perfil(v_dir_token, v_out, 'gerente', 'Infantil', null);
  exception when others then
    v_ok := (sqlerrm like '%perfil_invalido%');
  end;
  perform pg_temp.assert_true(v_ok, 'deve recusar perfil invalido');

  v_r := public.admin_atualizar_perfil(v_rh_token, v_sub, 'coordenador', 'Fundamental', v_coord);
  perform pg_temp.assert_true((v_r ->> 'perfil') = 'coordenador', 'RH atualiza subordinado para coordenador');

  select count(*) into v_n from public.auditoria
   where acao = 'perfil_atualizado' and entidade = 'funcionario' and entidade_id = v_sub
     and antes is not null and depois is not null;
  perform pg_temp.assert_true(v_n = 1, 'admin deve auditar perfil_atualizado com antes/depois');
end $$;

select 'TODOS OS TESTES PASSARAM' as resultado;

rollback;
