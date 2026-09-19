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
