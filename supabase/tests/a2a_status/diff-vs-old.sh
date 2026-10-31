#!/usr/bin/env bash
# Differential regression (r3 summary): runs the pre-change job_schedule_status (git HEAD of the migration, loaded as
# job_schedule_status_old) next to the working-tree one on seeded random graphs (flat, hierarchies, reversed chains, hierarchy cycles,
# every link type, negative lags, undated / done / milestone tasks). Exit 0 and "DIFFTEST compared ... 0 differences" = identical.
# Usage: bash supabase/tests/a2a_status/diff-vs-old.sh [N jobs per mode (default 150)] [old-ref (default HEAD)]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
N="${1:-150}"; REF="${2:-HEAD}"
MIG="$ROOT/supabase/migrations/202610271100_a2a_status.sql"
C="d0c-diff-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
run() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
for f in "$ROOT/supabase/tests/d0a/00_stub_schema.sql" "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql" \
         "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql" "$ROOT"/supabase/migrations/*_phase_a_sql.sql \
         "$ROOT/supabase/migrations/202610271000_a2a_schema.sql" "$MIG"; do
  run < "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; exit 1; }
done
git -C "$ROOT" show "$REF:supabase/migrations/202610271100_a2a_status.sql" | sed 's/job_schedule_status/job_schedule_status_old/g' | run >/dev/null
sed "s/:N/$N/" "$ROOT/supabase/tests/a2a_status/diff-vs-old.sql" | run 2>&1 | grep -E "DIFF|ERROR|FAILED" || true
