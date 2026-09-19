#!/usr/bin/env node
/**
 * migracao.js — importa a base local (localStorage 'ponto-claro-v1') para o Supabase.
 * Feature: registro-ponto (Reversa forward). Ação T019.
 *
 * Uso:
 *   SUPABASE_URL=... SUPABASE_SERVICE_KEY=... node scripts/migracao.js caminho/base.json [senhaInicial]
 *
 * O arquivo de entrada é o JSON exportado de localStorage['ponto-claro-v1']:
 *   { "workers": [...], "records": [...], "corrections": [...] }
 *
 * Requer a service_role key (bypassa RLS). NUNCA use a service_role no frontend.
 */

const fs = require('node:fs');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

async function rpc(fn, body) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`RPC ${fn} falhou: ${res.status} ${await res.text()}`);
  return res.json();
}

async function inserirRegistros(rows) {
  if (rows.length === 0) return;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/registros`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify(rows),
  });
  if (!res.ok) throw new Error(`INSERT registros falhou: ${res.status} ${await res.text()}`);
}

async function main() {
  const [file, senhaInicial = 'ponto123'] = process.argv.slice(2);
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error('Defina SUPABASE_URL e SUPABASE_SERVICE_KEY no ambiente.');
    process.exit(1);
  }
  if (!file) {
    console.error('Informe o caminho do JSON exportado do localStorage.');
    process.exit(1);
  }

  const base = JSON.parse(fs.readFileSync(file, 'utf8'));
  const workers = base.workers || [];
  const records = base.records || [];

  const mapa = new Map(); // workerId antigo -> id novo (uuid)
  for (const w of workers) {
    const id = await rpc('criar_funcionario', {
      p_matricula: String(w.code),
      p_nome: w.name,
      p_funcao: w.role || 'Nao informado',
      p_senha: senhaInicial,
    });
    mapa.set(w.id, id);
    console.log(`funcionario ${w.code} -> ${id}`);
  }

  const linhas = records
    .filter((r) => mapa.has(r.workerId))
    .map((r) => ({
      funcionario_id: mapa.get(r.workerId),
      tipo: r.type === 'in' ? 'entrada' : 'saida',
      timestamp_utc: r.timestamp,
      timezone: 'America/Sao_Paulo',
      origem: r.createdBy || 'migracao-local',
    }));

  await inserirRegistros(linhas);
  console.log(`migrados ${linhas.length} registros de ${workers.length} funcionarios.`);
  console.log('Observacao: correcoes nao fazem parte desta feature e foram ignoradas.');
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
