-- 0003_seed.sql
-- Funcionários de teste. Senha padrão dos exemplos: "ponto123".
-- Rode apenas em ambiente de desenvolvimento.

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('218406', 'Ana Beatriz Lima',      'Professora',  'ponto123'),
      ('491827', 'Carlos Eduardo Souza',  'Assistente',  'ponto123'),
      ('735102', 'Juliana Martins',       'Estagiaria',  'ponto123'),
      ('864319', 'Rafael Oliveira',       'Assistente',  'ponto123'),
      ('305671', 'Beatriz Almeida',       'Coordenacao', 'ponto123'),
      ('999999', 'Teste Terminal',        'Ambiente de teste', 'ponto123')
    ) as t(matricula, nome, funcao, senha)
  loop
    if not exists (select 1 from public.funcionarios where matricula = r.matricula) then
      perform public.criar_funcionario(r.matricula, r.nome, r.funcao, r.senha);
    end if;
  end loop;
end $$;
