#!/usr/bin/env bash
# A2a combined check: all four A2 migrations together on ONE throwaway Postgres 17 (Docker), in prod order, then the shared
# schedule fixture against the real stack, then every rollback in reverse (twice, idempotent), then re-apply.
# The per-family suites test each migration alone; this proves they coexist (parent guard + import, status + schema, ...).
# Usage: bash supabase/tests/a2a_all/run.sh        Success token: "A2A COMBINED STACK PASSED"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
C="a2a-all-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
apply() { local out; out=$(docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q < "$1" 2>&1) || { echo "$out" | grep -E "ERROR|DETAIL" | head -5; echo "FAILED applying $1"; exit 1; }; }
MIGS="202610210600_phase_a_sql 202610271000_a2a_schema 202610271100_a2a_status 202610271200_a2a_export 202610271300_a2a_import"
echo "== base"; apply "$ROOT/supabase/tests/d0a/00_stub_schema.sql"; apply "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql"
apply "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql"
# the import family stub adds fixtures the RPC tests need; the combined run only needs the schema, so it is not applied here
echo "== apply all (twice)"; for m in $MIGS; do apply "$ROOT/supabase/migrations/$m.sql"; done; for m in $MIGS; do apply "$ROOT/supabase/migrations/$m.sql"; done
echo "== shared fixture on the full stack"
node "$ROOT/scripts/tests/schedule/sql-fixture-runner.mjs" --container "$C" --fixture "$ROOT/scripts/tests/schedule/fixture.json"
echo "== rollbacks in reverse, twice"
for pass in 1 2; do for m in 202610271300_a2a_import 202610271200_a2a_export 202610271100_a2a_status 202610271000_a2a_schema; do apply "$ROOT/supabase/rollbacks/${m}_down.sql"; done; done
echo "== re-apply after rollback"; for m in 202610271000_a2a_schema 202610271100_a2a_status 202610271200_a2a_export 202610271300_a2a_import; do apply "$ROOT/supabase/migrations/$m.sql"; done
echo "== functions present"
docker exec -i "$C" psql -U postgres -At -c "select string_agg(proname, ',' order by proname) from pg_proc where proname in ('job_schedule_status','prepare_schedule_export','import_job_schedule','schedule_export_core')"
echo "A2A COMBINED STACK PASSED"
