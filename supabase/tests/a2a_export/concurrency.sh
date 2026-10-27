#!/usr/bin/env bash
# True two-session concurrency test for prepare_schedule_export (the single-file assert style cannot run two sessions).
# Usage: bash supabase/tests/a2a_export/concurrency.sh [mutated-migration.sql]
#   Session A (writer) exports and holds its transaction open 4 s; session B (another writer) starts 1 s later on the same job.
#   Expected with the advisory lock: A assigns 40, B BLOCKS until A commits (waited >= 2000 ms) and then assigns 0; the job ends
#   with 40 distinct uids 1..40 and exactly two audit rows (assigned 40 and 0). Without the lock B does not wait and the
#   numbers collide (B assigns again or errors), so with a mutant the script exits 1 ("MUTANT CAUGHT" is exit 0).
# Success token (normal mode): "CONCURRENCY OK"
set -uo pipefail
MUT="${1:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/supabase/tests/a2a_export"
MIG="${MUT:-$(ls "$ROOT"/supabase/migrations/*_a2a_export.sql | head -1)}"
C="a2a-conc-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
psqlx() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
apply() { psqlx < "$1" >/dev/null || { echo "FAILED applying $1"; exit 2; }; }
apply "$ROOT/supabase/tests/d0a/00_stub_schema.sql"
apply "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql"
while IFS= read -r f || [ -n "$f" ]; do
  f="${f%$'\r'}"; case "$f" in ""|"#"*) continue;; esac
  apply "$ROOT/$f"
done < "$T/requires.txt"
apply "$MIG"
apply "$T/concurrency_seed.sql"

OA="$(mktemp)"; OB="$(mktemp)"
psqlx < "$T/concurrency_a.sql" > "$OA" 2>&1 &
PA=$!
sleep 1
psqlx < "$T/concurrency_b.sql" > "$OB" 2>&1 &
PB=$!
wait "$PA"; wait "$PB"
echo "--- session A"; cat "$OA"
echo "--- session B"; cat "$OB"

RA="$(grep -o 'A result [0-9]*' "$OA" | awk '{print $3}')"
RB="$(grep -o 'B result [0-9]*' "$OB" | awk '{print $3}')"
WB="$(grep -o 'B waited_ms [0-9]*' "$OB" | awk '{print $3}')"
DIST="$(psqlx -c "SELECT count(DISTINCT u) || '/' || count(*) || '/' || min(u) || '/' || max(u) FROM (SELECT msp_uid u FROM job_phases WHERE job_id='b1000000-0000-0000-0000-0000000000c0' UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id='b1000000-0000-0000-0000-0000000000c0') s" 2>&1 </dev/null)"
AUD="$(psqlx -c "SELECT string_agg(metadata->>'assigned', ',' ORDER BY (metadata->>'assigned')::int DESC) FROM job_audit_log WHERE action_type='schedule_exported'" 2>&1 </dev/null)"
echo "A=$RA B=$RB B_waited_ms=$WB uids(distinct/total/min/max)=$DIST audit_assigned=$AUD"

if [ "$RA" = "40" ] && [ "$RB" = "0" ] && [ "${WB:-0}" -ge 2000 ] && [ "$DIST" = "40/40/1/40" ] && [ "$AUD" = "40,0" ]; then
  [ -n "$MUT" ] && { echo "MUTANT SURVIVED"; exit 1; }
  echo "CONCURRENCY OK"; exit 0
fi
[ -n "$MUT" ] && { echo "MUTANT CAUGHT"; exit 0; }
echo "CONCURRENCY FAILED"; exit 1
