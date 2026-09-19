-- acompanhamento_rh_test.sql
-- Testes da feature 002. SQL puro (sem comandos do psql), roda no Supabase SQL Editor
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
  v_rh uuid; v_est uuid; v_est2 uuid;
  v_rh_token uuid; v_est_token uuid;
  v_r json; v_e json; v_pend json;
  v_total int; v_desvio int; v_n int; v_dow int; v_hoje date;
  v_ok boolean;
begin
  -- ---------------------------------------------------------------- setup
  v_rh := public.criar_funcionario('RH0001', 'RH Teste', 'Coordenacao', 'rhsenha');
  update public.funcionarios set is_rh = true, perfil = 'rh' where id = v_rh;

  v_est := public.criar_funcionario('EST001', 'Estagiaria Teste', 'Estagiaria', 'estsenha');
  update public.funcionarios set jornada_minutos = 240 where id = v_est;

  v_est2 := public.criar_funcionario('EST002', 'Pendente Teste', 'Estagiaria', 'pendsenha');

  v_rh_token := (public.login('RH0001', 'rhsenha') ->> 'token')::uuid;
  v_est_token := (public.login('EST001', 'estsenha') ->> 'token')::uuid;

  -- EST001: 08:00-12:00 e 13:00-17:00 (refeição de 1h entre os pares)
  insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem) values
    (v_est, 'entrada', (public.hoje_sp() + time '08:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
    (v_est, 'saida',   (public.hoje_sp() + time '12:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
    (v_est, 'entrada', (public.hoje_sp() + time '13:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
    (v_est, 'saida',   (public.hoje_sp() + time '17:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste');

  -- EST002: apenas entrada hoje (dia incompleto)
  insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem) values
    (v_est2, 'entrada', (public.hoje_sp() + time '09:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste');

  -- --------------------------------------------- T004 (evoluído pela 003): escopo
  v_r := public.acompanhamento_periodo(v_est_token, public.hoje_sp(), public.hoje_sp(), null);
  perform pg_temp.assert_true(json_array_length(v_r) = 1, 'trabalhador deve ver apenas a si no painel');
  perform pg_temp.assert_true((v_r -> 0 ->> 'matricula') = 'EST001', 'trabalhador ve o proprio registro');

  -- ---------------------------------------------------------------- agregação
  v_r := public.acompanhamento_periodo(v_rh_token, public.hoje_sp(), public.hoje_sp(), null);

  select value into v_e from json_array_elements(v_r) where value ->> 'matricula' = 'EST001';
  perform pg_temp.assert_true(v_e is not null, 'EST001 presente no painel');

  v_total := (v_e ->> 'total_minutos')::int;
  perform pg_temp.assert_true(v_total = 480, 'total deve ser 480 min (refeicao excluida), veio ' || v_total);
  perform pg_temp.assert_true((v_e ->> 'jornada_minutos')::int = 240, 'jornada da estagiaria = 240');

  v_desvio := (v_e ->> 'desvio_minutos')::int;
  perform pg_temp.assert_true(v_desvio = 240, 'desvio = 480 - 240 = 240, veio ' || v_desvio);
  perform pg_temp.assert_true((v_e ->> 'presenca') = 'saida', 'presenca derivada = saida');

  v_pend := v_e -> 'dias_pendentes';
  perform pg_temp.assert_true(json_array_length(v_pend) = 0, 'dia completo nao deve ter pendencia');

  -- ---------------------------------------------------------------- pendência
  v_hoje := public.hoje_sp();
  v_dow := extract(isodow from v_hoje);

  v_r := public.acompanhamento_periodo(v_rh_token, v_hoje, v_hoje, null);
  select value into v_e from json_array_elements(v_r) where value ->> 'matricula' = 'EST002';
  perform pg_temp.assert_true(v_e is not null, 'EST002 presente no painel');
  perform pg_temp.assert_true((v_e ->> 'total_minutos')::int = 0, 'EST002 sem par completo = 0 min');
  perform pg_temp.assert_true((v_e ->> 'presenca') = 'entrada', 'EST002 em atividade');

  v_n := json_array_length(v_e -> 'dias_pendentes');
  if v_dow between 1 and 5 then
    perform pg_temp.assert_true(v_n = 1, 'dia util incompleto deve ter 1 pendencia');
  else
    perform pg_temp.assert_true(v_n = 0, 'fim de semana nao conta pendencia');
  end if;

  -- ---------------------------------------------------------------- período inválido
  v_ok := false;
  begin
    perform public.acompanhamento_periodo(v_rh_token, public.hoje_sp(), public.hoje_sp() - 1, null);
  exception when others then
    v_ok := (sqlerrm like '%periodo_invalido%');
  end;
  perform pg_temp.assert_true(v_ok, 'periodo com fim antes do inicio deve falhar');

  -- ---------------------------------------------------------------- detalhe
  v_r := public.registros_funcionario_periodo(v_rh_token, v_est, public.hoje_sp(), public.hoje_sp());
  perform pg_temp.assert_true(json_array_length(v_r -> 'registros') = 4, 'detalhe deve listar 4 registros');
  perform pg_temp.assert_true((v_r -> 'funcionario' ->> 'nome') = 'Estagiaria Teste', 'detalhe traz o funcionario');

  -- ---------------------------------------------------------------- filtro por função
  v_r := public.acompanhamento_periodo(v_rh_token, public.hoje_sp(), public.hoje_sp(), 'Inexistente');
  perform pg_temp.assert_true(json_array_length(v_r) = 0, 'filtro por funcao inexistente deve ser vazio');
end $$;

select 'TODOS OS TESTES PASSARAM' as resultado;

rollback;
