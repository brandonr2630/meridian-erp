#!/usr/bin/env bash
# Runs the shared schedule fixture against SQL (job_schedule_status + job_task_weight/job_task_planned_pct) on a throwaway
# Postgres 17 (Docker): D0a stub, phase_a_sql family stub, the Phase A migration, then scripts/tests/schedule/sql-fixture-runner.mjs.
# Usage:  bash supabase/tests/phase_a_sql/run-fixture.sh [fixture.json]
#   default fixture: scripts/tests/schedule/fixture.json (the shared one); a tiny self-made sample lives next to this script
#   (fixture-sample.json) and is used when the shared file is absent.
# Success token: "SQL FIXTURE PASSED n/n cases"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FX="${1:-}"
if [ -z "$FX" ]; then
  if [ -f "$ROOT/scripts/tests/schedule/fixture.json" ]; then FX="$ROOT/scripts/tests/schedule/fixture.json"; else FX="$ROOT/supabase/tests/phase_a_sql/fixture-sample.json"; fi
fi
C="phase-a-fixture-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
for f in "$ROOT/supabase/tests/d0a/00_stub_schema.sql" "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql" \
         "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql" "$ROOT"/supabase/migrations/*_phase_a_sql.sql; do
  out=$(docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q < "$f" 2>&1) || { echo "$out" | grep -E "ERROR|DETAIL" | head -5; echo "FAILED applying $f"; exit 1; }
done
echo "fixture: $FX"
node "$ROOT/scripts/tests/schedule/sql-fixture-runner.mjs" --container "$C" --fixture "$FX"
