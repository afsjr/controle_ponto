#!/usr/bin/env bash
# test-db.sh — TDD local: sobe um Postgres efêmero, aplica as migrations e roda os testes.
# Uso: bash scripts/test-db.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/ponto-pg-test-$$"
DATA="$TMP/data"
SOCK="$TMP/sock"
PORT="${PGTEST_PORT:-55432}"

mkdir -p "$SOCK"

cleanup() {
  pg_ctl -D "$DATA" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> initdb"
initdb -D "$DATA" -A trust -U postgres --no-sync >/dev/null

echo "==> start postgres (porta $PORT, socket $SOCK)"
pg_ctl -D "$DATA" -o "-p $PORT -k $SOCK -c listen_addresses=''" -l "$TMP/log" start >/dev/null
export PGHOST="$SOCK" PGPORT="$PORT" PGUSER=postgres

createdb ponto_test

echo "==> roles do Supabase (anon, authenticated)"
psql -d ponto_test -v ON_ERROR_STOP=1 -q -c "create role anon nologin; create role authenticated nologin;"

for f in \
  infra/supabase/migrations/0001_init.sql \
  infra/supabase/migrations/0002_functions.sql \
  infra/supabase/migrations/0004_rh.sql \
  infra/supabase/migrations/0005_functions_rh.sql \
  infra/supabase/migrations/0006_perfis.sql \
  infra/supabase/migrations/0007_functions_perfis.sql
do
  echo "==> aplicando $f"
  psql -d ponto_test -v ON_ERROR_STOP=1 -q -f "$ROOT/$f"
done

for t in \
  infra/supabase/tests/acompanhamento_rh_test.sql \
  infra/supabase/tests/perfis_permissoes_test.sql
do
  echo "==> rodando $t"
  psql -d ponto_test -v ON_ERROR_STOP=1 -f "$ROOT/$t"
done

echo "==> OK"
