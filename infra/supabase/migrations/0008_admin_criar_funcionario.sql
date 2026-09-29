-- 0008_admin_criar_funcionario.sql
-- Feature: perfis-permissoes (Reversa forward)
-- Cadastro de funcionário pela UI, autorizado por perfil e com senha hasheada (bcrypt).

create or replace function public.admin_criar_funcionario(
  p_token uuid,
  p_matricula text,
  p_nome text,
  p_funcao text,
  p_senha text,
  p_perfil text default 'trabalhador',
  p_area text default null,
  p_coordenador_id uuid default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_ator uuid;
  v_perfil_ator text;
  v_id uuid;
begin
  v_ator := exigir_autorizado(p_token);
  v_perfil_ator := perfil_do_funcionario(v_ator);

  if v_perfil_ator not in ('rh', 'diretoria') then
    perform registrar_auditoria('cadastro_negado', v_ator::text, 'funcionario', null, null, null);
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;

  if p_matricula is null or length(btrim(p_matricula)) = 0 then
    raise exception 'matricula_invalida' using errcode = 'P0001';
  end if;
  if p_nome is null or length(btrim(p_nome)) = 0 then
    raise exception 'nome_invalido' using errcode = 'P0001';
  end if;
  if p_senha is null or length(btrim(p_senha)) < 6 then
    raise exception 'senha_invalida' using errcode = 'P0001';
  end if;
  if p_perfil not in ('trabalhador', 'coordenador', 'rh', 'diretoria') then
    raise exception 'perfil_invalido' using errcode = 'P0001';
  end if;

  -- RH só cria trabalhador/coordenador; diretoria cria qualquer perfil.
  if v_perfil_ator = 'rh' and p_perfil not in ('trabalhador', 'coordenador') then
    raise exception 'sem_permissao' using errcode = 'P0001';
  end if;

  if exists (select 1 from funcionarios where matricula = btrim(p_matricula)) then
    raise exception 'matricula_duplicada' using errcode = 'P0001';
  end if;

  if p_coordenador_id is not null
     and not exists (select 1 from funcionarios where id = p_coordenador_id and not excluido) then
    raise exception 'funcionario_inexistente' using errcode = 'P0001';
  end if;

  insert into funcionarios(matricula, nome, funcao, senha_hash, perfil, area, coordenador_id)
    values (btrim(p_matricula), btrim(p_nome), btrim(p_funcao),
            crypt(p_senha, gen_salt('bf')), p_perfil, p_area, p_coordenador_id)
    returning id into v_id;

  perform registrar_auditoria(
    'funcionario_criado', v_ator::text, 'funcionario', v_id, null,
    jsonb_build_object(
      'matricula', btrim(p_matricula), 'nome', btrim(p_nome), 'funcao', btrim(p_funcao),
      'perfil', p_perfil, 'area', p_area, 'coordenador_id', p_coordenador_id
    )
  );

  return json_build_object(
    'funcionario_id', v_id, 'matricula', btrim(p_matricula),
    'nome', btrim(p_nome), 'perfil', p_perfil
  );
end;
$$;

grant execute on function public.admin_criar_funcionario(uuid, text, text, text, text, text, text, uuid) to anon;
