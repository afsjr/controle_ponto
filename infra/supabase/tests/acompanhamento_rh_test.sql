-- acompanhamento_rh_test.sql
-- Testes executáveis da feature 002 (TDD). SQL puro, sem extensão: roda no runner
-- local (scripts/test-db.sh) e também no SQL Editor do Supabase.
-- Isolado por transação com rollback.

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
select public.criar_funcionario('RH0001', 'RH Teste', 'Coordenacao', 'rhsenha') as rh_id \gset
update public.funcionarios set is_rh = true, perfil = 'rh' where matricula = 'RH0001';

select public.criar_funcionario('EST001', 'Estagiaria Teste', 'Estagiaria', 'estsenha') as est_id \gset
update public.funcionarios set jornada_minutos = 240 where matricula = 'EST001';

select public.criar_funcionario('EST002', 'Pendente Teste', 'Estagiaria', 'pendsenha') as est2_id \gset

select (public.login('RH0001', 'rhsenha') ->> 'token') as rh_token \gset
select (public.login('EST001', 'estsenha') ->> 'token') as est_token \gset

-- Disponibiliza os valores para uso dentro de blocos DO (dollar-quoted).
select
  set_config('test.rh_token',  :'rh_token',  false),
  set_config('test.est_token', :'est_token', false),
  set_config('test.est_id',    :'est_id',    false),
  set_config('test.est2_id',   :'est2_id',   false);

-- EST001: 08:00-12:00 e 13:00-17:00 (refeição de 1h entre os pares)
insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem) values
  (:'est_id'::uuid, 'entrada', (public.hoje_sp() + time '08:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
  (:'est_id'::uuid, 'saida',   (public.hoje_sp() + time '12:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
  (:'est_id'::uuid, 'entrada', (public.hoje_sp() + time '13:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste'),
  (:'est_id'::uuid, 'saida',   (public.hoje_sp() + time '17:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste');

-- EST002: apenas entrada hoje (dia incompleto)
insert into public.registros(funcionario_id, tipo, timestamp_utc, timezone, origem) values
  (:'est2_id'::uuid, 'entrada', (public.hoje_sp() + time '09:00') at time zone 'America/Sao_Paulo', 'America/Sao_Paulo', 'teste');

-- ------------------------------------------------- T004 (evoluído pela 003): escopo
-- Com perfis (feature 003), o painel é escopado ao ator: trabalhador vê apenas a si.
do $$ declare r json; begin
  r := public.acompanhamento_periodo(current_setting('test.est_token')::uuid,
                                     public.hoje_sp(), public.hoje_sp(), null);
  perform pg_temp.assert_true(json_array_length(r) = 1, 'trabalhador deve ver apenas a si no painel');
  perform pg_temp.assert_true((r->0->>'matricula') = 'EST001', 'trabalhador ve o proprio registro');
end $$;

-- ---------------------------------------------------------------- T005/T009/T010: agregação
do $$
declare
  r json;
  e json;
  total int;
  desvio int;
  pend json;
begin
  r := public.acompanhamento_periodo(current_setting('test.rh_token')::uuid,
                                     public.hoje_sp(),
                                     public.hoje_sp(), null);

  select value into e from json_array_elements(r) where value->>'matricula' = 'EST001';
  perform pg_temp.assert_true(e is not null, 'EST001 presente no painel');

  total := (e->>'total_minutos')::int;
  perform pg_temp.assert_true(total = 480, 'total deve ser 480 min (refeicao excluida), veio ' || total);

  perform pg_temp.assert_true((e->>'jornada_minutos')::int = 240, 'jornada da estagiaria = 240');
  desvio := (e->>'desvio_minutos')::int;
  perform pg_temp.assert_true(desvio = 240, 'desvio = 480 - 240 = 240, veio ' || desvio);
  perform pg_temp.assert_true((e->>'presenca') = 'saida', 'presenca derivada = saida');

  pend := e->'dias_pendentes';
  perform pg_temp.assert_true(json_array_length(pend) = 0, 'dia completo nao deve ter pendencia');
end $$;

-- ---------------------------------------------------------------- T009: pendência (dia incompleto)
do $$
declare
  r json;
  e json;
  hoje date := public.hoje_sp();
  dow int := extract(isodow from hoje);
  n int;
begin
  r := public.acompanhamento_periodo(current_setting('test.rh_token')::uuid, hoje, hoje, null);
  select value into e from json_array_elements(r) where value->>'matricula' = 'EST002';
  perform pg_temp.assert_true(e is not null, 'EST002 presente no painel');
  perform pg_temp.assert_true((e->>'total_minutos')::int = 0, 'EST002 sem par completo = 0 min');
  perform pg_temp.assert_true((e->>'presenca') = 'entrada', 'EST002 em atividade');
  n := json_array_length(e->'dias_pendentes');
  if dow between 1 and 5 then
    perform pg_temp.assert_true(n = 1, 'dia util incompleto deve ter 1 pendencia');
  else
    perform pg_temp.assert_true(n = 0, 'fim de semana nao conta pendencia');
  end if;
end $$;

-- ---------------------------------------------------------------- T006: período inválido
do $$ declare ok boolean := false; begin
  begin
    perform public.acompanhamento_periodo(current_setting('test.rh_token')::uuid,
                                           public.hoje_sp(), public.hoje_sp() - 1, null);
  exception when others then
    ok := (sqlerrm like '%periodo_invalido%');
  end;
  perform pg_temp.assert_true(ok, 'periodo com fim antes do inicio deve falhar');
end $$;

-- ---------------------------------------------------------------- T013: detalhe
do $$
declare r json;
begin
  r := public.registros_funcionario_periodo(current_setting('test.rh_token')::uuid,
                                            current_setting('test.est_id')::uuid,
                                            public.hoje_sp(), public.hoje_sp());
  perform pg_temp.assert_true(json_array_length(r->'registros') = 4, 'detalhe deve listar 4 registros');
  perform pg_temp.assert_true((r->'funcionario'->>'nome') = 'Estagiaria Teste', 'detalhe traz o funcionario');
end $$;

-- ---------------------------------------------------------------- filtro por função
do $$
declare r json;
begin
  r := public.acompanhamento_periodo(current_setting('test.rh_token')::uuid,
                                     public.hoje_sp(), public.hoje_sp(), 'Inexistente');
  perform pg_temp.assert_true(json_array_length(r) = 0, 'filtro por funcao inexistente deve ser vazio');
end $$;

select 'TODOS OS TESTES PASSARAM' as resultado;

rollback;
