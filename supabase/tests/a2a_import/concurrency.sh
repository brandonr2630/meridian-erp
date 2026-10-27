#!/usr/bin/env bash
# True two-session test for the row locks of import_job_schedule(replace) (review finding L5; the single-file assert style cannot run two sessions).
# Usage: bash supabase/tests/a2a_import/concurrency.sh [mutated-migration.sql]
#   Session B (a UI editor) updates one task and keeps its transaction open for 4 s. Session A (an approver) starts 1 s later, with the
#   based_on it read BEFORE B committed, and runs replace on the same job.
#   Expected with the row locks: A BLOCKS on B's row (waited >= 2000 ms), then its stale check sees B's committed edit and refuses
#   ('schedule changed since preview'); the schedule is untouched and B's edit (progress 77) survives.
#   Without the locks A passes the stale check on the old snapshot, waits only at the DELETE, then replaces the schedule and B's edit is
#   gone without trace: the script then exits 1 (and prints MUTANT CAUGHT, exit 0, when given a mutated migration).
# Success token (normal mode): "CONCURRENCY OK"
set -uo pipefail
MUT="${1:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/supabase/tests/a2a_import"
MIG="${MUT:-$(ls "$ROOT"/supabase/migrations/*_a2a_import.sql | head -1)}"
C="a2a-impconc-$$"
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
apply "$T/10_stub_extra.sql"
apply "$MIG"
apply "$T/concurrency_seed.sql"

OA="$(mktemp)"; OB="$(mktemp)"
psqlx < "$T/concurrency_b.sql" > "$OB" 2>&1 &
PB=$!
sleep 1
psqlx < "$T/concurrency_a.sql" > "$OA" 2>&1 &
PA=$!
wait "$PA"; wait "$PB"
echo "--- session A (import, replace)"; cat "$OA"
echo "--- session B (UI edit)"; cat "$OB"

RA="$(grep -o 'A result .*' "$OA" | head -1 | cut -c10-)"
WA="$(grep -o 'A waited_ms [0-9]*' "$OA" | awk '{print $3}')"
STATE="$(psqlx -c "SELECT (SELECT count(*) FROM job_phases WHERE job_id='b1000000-0000-0000-0000-0000000000d0') || '/' || (SELECT count(*) FROM job_tasks WHERE job_id='b1000000-0000-0000-0000-0000000000d0') || '/' || (SELECT progress FROM job_tasks WHERE task_name='B1' AND job_id='b1000000-0000-0000-0000-0000000000d0')" 2>&1 </dev/null)"
echo "A=[$RA] A_waited_ms=$WA state(phases/tasks/B1 progress)=$STATE"

if [ "$RA" = "schedule changed since preview" ] && [ "${WA:-0}" -ge 2000 ] && [ "$STATE" = "1/2/77" ]; then
  [ -n "$MUT" ] && { echo "MUTANT SURVIVED"; exit 1; }
  echo "CONCURRENCY OK"; exit 0
fi
[ -n "$MUT" ] && { echo "MUTANT CAUGHT"; exit 0; }
echo "CONCURRENCY FAILED"; exit 1
