# Ponto Claro

MVP de um sistema de controle de jornada com registro numérico e trilha de auditoria.

## Executar

Abra `index.html` em um navegador. Os dados ficam persistidos no `localStorage` do navegador.

Para testar o terminal de ponto, use um dos códigos demonstrativos:

- Ana Beatriz Lima: `218406`
- Carlos Eduardo Souza: `491827`
- Juliana Martins: `735102`
- Rafael Oliveira: `864319`
- Beatriz Almeida: `305671`
- Teste Terminal (fluxo livre): `999999`

## Regras implementadas

- O sistema alterna automaticamente entre entrada e saída para cada trabalhador.
- Registros originais nunca são apagados ou sobrescritos.
- Uma correção cria um novo evento vinculado ao registro original e exige justificativa.
- O dashboard mostra presença, horas acumuladas, média, alertas e atividade recente.
- A jornada padrão é de 8 horas, com tolerância de 30 minutos para desvios.

## Próximos passos para produção

Este MVP mantém os dados localmente para facilitar validação da experiência. Em produção, a camada de persistência deve ser substituída por uma API autenticada com banco de dados append-only, controle de permissões, sincronização de relógio no servidor e exportação dos eventos para auditoria.
