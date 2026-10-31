#!/usr/bin/env bash
# True two-session concurrency test for the r3d M2 guards (job_task_links_hierarchy_guard / job_tasks_parent_link_guard).
# A single-file assertion run cannot show that two concurrent writes of one job are serialised, so this runs two psql sessions.
# Usage: bash supabase/tests/a2a_schema/concurrency.sh [mutated-migration.sql]
#   Scenario 1  A: INSERT link (X after Y), holds its transaction 4 s.   B (1 s later): re-parent Y under X.
#   Scenario 2  A: re-parent Y under X, holds 4 s.                        B (1 s later): INSERT link (X after Y).
#   With the shared per-job advisory lock B BLOCKS until A commits (waited >= 2000 ms), then sees A's row and is refused
#   (scenario 1: A2L02, scenario 2: A2L01), so the final state never holds a link between a task and its own parent.
#   Without the lock B does not wait and both writes commit (final state: the forbidden pair) -> with a mutant the script exits 1.
#   With a mutant argument: exit 0 = MUTANT CAUGHT, exit 1 = MUTANT SURVIVED.
# Success token (normal mode): "CONCURRENCY OK"
set -uo pipefail
MUT="${1:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/supabase/tests/a2a_schema"
MIG="${MUT:-$(ls "$ROOT"/supabase/migrations/*_a2a_schema.sql | head -1)}"
C="a2a-sconc-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
psqlx() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=0 -qAt "$@"; }
apply() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q < "$1" >/dev/null || { echo "FAILED applying $1"; exit 2; }; }
apply "$ROOT/supabase/tests/d0a/00_stub_schema.sql"
apply "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql"
apply "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql"
apply "$ROOT/supabase/migrations/202610210600_phase_a_sql.sql"
apply "$MIG"
apply "$T/concurrency_seed.sql"

run_pair() {   # $1 = scenario number
  local OA OB; OA="$(mktemp)"; OB="$(mktemp)"
  psqlx < "$T/concurrency_${1}_a.sql" > "$OA" 2>&1 &
  local PA=$!
  sleep 1
  psqlx < "$T/concurrency_${1}_b.sql" > "$OB" 2>&1 &
  local PB=$!
  wait "$PA"; wait "$PB"
  echo "--- scenario $1 session A"; cat "$OA"
  echo "--- scenario $1 session B"; cat "$OB"
  R_A="$(grep -o 'A result .*' "$OA" | head -1)"; R_B="$(grep -o 'B result .*' "$OB" | head -1)"
  W_B="$(grep -o 'B waited_ms [0-9]*' "$OB" | awk '{print $3}')"
  rm -f "$OA" "$OB"
}
related() {    # is there a link between task and its own parent in job c1?  prints t/f
  psqlx -c "SELECT EXISTS (SELECT 1 FROM job_task_links l JOIN job_tasks t ON t.id = l.task_id AND t.parent_task_id = l.predecessor_id
                           UNION ALL SELECT 1 FROM job_task_links l JOIN job_tasks t ON t.id = l.predecessor_id AND t.parent_task_id = l.task_id)" </dev/null
}

ok=1
run_pair 1; S1_A="$R_A"; S1_B="$R_B"; S1_W="${W_B:-0}"; S1_REL="$(related)"
psqlx -c "DELETE FROM job_task_links; UPDATE job_tasks SET parent_task_id = NULL" </dev/null >/dev/null
run_pair 2; S2_A="$R_A"; S2_B="$R_B"; S2_W="${W_B:-0}"; S2_REL="$(related)"
echo "scenario 1: A=[$S1_A] B=[$S1_B] B_waited_ms=$S1_W forbidden_pair_stored=$S1_REL"
echo "scenario 2: A=[$S2_A] B=[$S2_B] B_waited_ms=$S2_W forbidden_pair_stored=$S2_REL"
[ "$S1_A" = "A result ok" ] && [ "$S1_B" = "B result A2L02" ] && [ "$S1_W" -ge 2000 ] && [ "$S1_REL" = "f" ] || ok=0
[ "$S2_A" = "A result ok" ] && [ "$S2_B" = "B result A2L01" ] && [ "$S2_W" -ge 2000 ] && [ "$S2_REL" = "f" ] || ok=0

if [ "$ok" = "1" ]; then
  [ -n "$MUT" ] && { echo "MUTANT SURVIVED"; exit 1; }
  echo "CONCURRENCY OK"; exit 0
fi
[ -n "$MUT" ] && { echo "MUTANT CAUGHT"; exit 0; }
echo "CONCURRENCY FAILED"; exit 1
