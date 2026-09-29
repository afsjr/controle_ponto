-- admin_criar_funcionario_test.sql
-- Testes da RPC de cadastro de funcionário pela UI (feature 003). SQL puro, isolado
-- por transação com rollback. Roda no Supabase SQL Editor e em scripts/test-db.sh.

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
  v_rh uuid; v_sub uuid;
  v_rh_token uuid; v_sub_token uuid;
  v_r json; v_n int; v_ok boolean;
begin
  -- ---------------------------------------------------------------- setup
  v_rh := public.criar_funcionario('RHCRI1', 'RH Criador', 'Recursos Humanos', 'rhsenha');
  update public.funcionarios set perfil = 'rh', area = 'Administracao' where id = v_rh;

  v_sub := public.criar_funcionario('SUBCRI1', 'Trabalhador Comum', 'Assistente', 'subsenha');
  update public.funcionarios set perfil = 'trabalhador', area = 'Fundamental' where id = v_sub;

  v_rh_token := (public.login('RHCRI1', 'rhsenha') ->> 'token')::uuid;
  v_sub_token := (public.login('SUBCRI1', 'subsenha') ->> 'token')::uuid;

  -- ---------------------------------------------------------------- cadastro feliz
  v_r := public.admin_criar_funcionario(v_rh_token, 'NOVO01', 'Nova Pessoa', 'Assistente', 'novasenha');
  perform pg_temp.assert_true((v_r ->> 'matricula') = 'NOVO01', 'RPC deve retornar a matricula criada');
  perform pg_temp.assert_true((v_r ->> 'perfil') = 'trabalhador', 'perfil padrao deve ser trabalhador');

  -- senha foi hasheada e o login funciona
  v_ok := (public.login('NOVO01', 'novasenha') -> 'funcionario' ->> 'nome') = 'Nova Pessoa';
  perform pg_temp.assert_true(v_ok, 'login com a senha cadastrada deve funcionar');

  v_ok := false;
  begin
    perform public.login('NOVO01', 'senha-errada');
  exception when others then
    v_ok := (sqlerrm like '%credenciais_invalidas%');
  end;
  perform pg_temp.assert_true(v_ok, 'senha errada nao autentica');

  -- auditoria
  select count(*) into v_n from public.auditoria
   where acao = 'funcionario_criado' and entidade = 'funcionario' and depois is not null;
  perform pg_temp.assert_true(v_n = 1, 'cadastro deve gerar auditoria funcionario_criado');

  -- ---------------------------------------------------------------- permissões
  v_ok := false;
  begin
    perform public.admin_criar_funcionario(v_sub_token, 'X00001', 'X', 'Assistente', 'senha123');
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'trabalhador nao pode cadastrar');

  v_ok := false;
  begin
    perform public.admin_criar_funcionario(v_rh_token, 'X00002', 'X', 'Assistente', 'senha123', 'diretoria');
  exception when others then
    v_ok := (sqlerrm like '%sem_permissao%');
  end;
  perform pg_temp.assert_true(v_ok, 'RH nao pode cadastrar diretoria');

  -- ---------------------------------------------------------------- validações
  v_ok := false;
  begin
    perform public.admin_criar_funcionario(v_rh_token, 'NOVO01', 'Duplicada', 'Assistente', 'senha123');
  exception when others then
    v_ok := (sqlerrm like '%matricula_duplicada%');
  end;
  perform pg_temp.assert_true(v_ok, 'matricula duplicada deve ser recusada');

  v_ok := false;
  begin
    perform public.admin_criar_funcionario(v_rh_token, 'FRACA1', 'Senha Curta', 'Assistente', '123');
  exception when others then
    v_ok := (sqlerrm like '%senha_invalida%');
  end;
  perform pg_temp.assert_true(v_ok, 'senha com menos de 6 caracteres deve ser recusada');

  v_ok := false;
  begin
    perform public.admin_criar_funcionario(v_rh_token, '', 'Sem Matricula', 'Assistente', 'senha123');
  exception when others then
    v_ok := (sqlerrm like '%matricula_invalida%');
  end;
  perform pg_temp.assert_true(v_ok, 'matricula vazia deve ser recusada');
end $$;

select 'TODOS OS TESTES PASSARAM' as resultado;

rollback;
