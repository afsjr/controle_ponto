-- registro_ponto_test.sql
-- Testes pgTAP das regras de registro-ponto.
-- Requer a extensão pgtap: create extension if not exists pgtap;
-- Rodar em ambiente de teste com as migrations aplicadas.
-- IMPORTANTE: ainda NÃO executado (sem projeto Supabase). Guardado para aplicação futura.

begin;
select plan(12);

-- Setup: funcionário de teste com senha conhecida
select public.criar_funcionario('T00001', 'Teste Unit', 'QA', 'segredo') as func_id \gset

-- T010/T015: login válido emite token
select is(
  (public.login('T00001', 'segredo') ->> 'token') is not null,
  true,
  'login válido retorna token'
);

-- Login inválido
select throws_ok(
  $$ select public.login('T00001', 'errada') $$,
  'P0001', 'credenciais_invalidas',
  'senha incorreta é recusada'
);

-- Matrícula inexistente
select throws_ok(
  $$ select public.login('NAOEXISTE', 'segredo') $$,
  'P0001', 'credenciais_invalidas',
  'matrícula inexistente é recusada'
);

-- Token inválido
select throws_ok(
  format($$ select public.registrar_ponto(%L, 'entrada') $$, gen_random_uuid()),
  'P0001', 'nao_autenticado',
  'token inválido é recusado'
);

-- Happy path: entrada
select lives_ok(
  format($$ select public.registrar_ponto(%L, 'entrada', 'teste') $$,
         (public.login('T00001','segredo') ->> 'token')),
  'entrada registrada com token válido'
);

-- RN-02: entrada dupla
select throws_ok(
  format($$ select public.registrar_ponto(%L, 'entrada', 'teste') $$,
         (public.login('T00001','segredo') ->> 'token')),
  'P0001', 'entrada_ja_aberta',
  'entrada com entrada aberta é recusada (BR-02)'
);

-- Saída fecha o intervalo
select lives_ok(
  format($$ select public.registrar_ponto(%L, 'saida', 'teste') $$,
         (public.login('T00001','segredo') ->> 'token')),
  'saída registrada após entrada'
);

-- RN-03: saída sem entrada
select throws_ok(
  format($$ select public.registrar_ponto(%L, 'saida', 'teste') $$,
         (public.login('T00001','segredo') ->> 'token')),
  'P0001', 'sem_entrada_aberta',
  'saída sem entrada é recusada (BR-03)'
);

-- Tipo inválido
select throws_ok(
  format($$ select public.registrar_ponto(%L, 'banana', 'teste') $$,
         (public.login('T00001','segredo') ->> 'token')),
  'P0001', 'tipo_invalido',
  'tipo diferente de entrada/saida é recusado'
);

-- Idempotência (mesmo request_id não cria dois registros)
select is(
  (select count(*)::int from public.registros
    where funcionario_id = (select id from public.funcionarios where matricula = 'T00001')),
  2,
  'após entrada e saída existem exatamente 2 registros'
);

-- Estado derivado
select is(
  public.estado_do_dia((select id from public.funcionarios where matricula = 'T00001')),
  'saida',
  'estado derivado é o último registro do dia'
);

-- hoje_sp no fuso de Brasília
select is(
  public.hoje_sp(),
  (now() at time zone 'America/Sao_Paulo')::date,
  'hoje_sp usa America/Sao_Paulo'
);

select * from finish();
rollback;
