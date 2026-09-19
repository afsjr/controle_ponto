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
