#!/usr/bin/env bash
# True two-session test for the export numbering UPDATEs (r4 M2, rule X26: a uid never lands on a row of ANOTHER job).
# Usage: bash supabase/tests/a2a_export/concurrency_move.sh [mutated-migration.sql]
# The numbering UPDATE of schedule_export_core matched rows by id only. A writer that moves a row without a uid to job B while the export of job A
# waits for that row's lock made the export stamp A's uid onto the row now in job B (and a DBA / import that numbered the row in between was
# overwritten). With the predicates job_id / company_id / msp_uid IS NULL the UPDATE re-checks the row after the lock wait and skips it.
#   S1  task: W moves a uid-less task A -> B and holds 3 s; the export of A (1 s later) waits, then must skip it.   S2  the same for a phase.
#   S3  task, other order: the export of A numbers everything and holds 3 s; W's move (1 s later) waits, then is refused (A2U01: numbered row).  S4 phase.
#   S5  a DBA session sets msp_uid = 99 on a task of A and holds 3 s; the export waits, then must leave 99 alone.                                  S6 phase.
#   S7  (r5 M-A) a PHASE is inserted (sort_order 0) while the export, which already counted its uid-less rows, waits for the uid counter held by a
#       third session: the numbering must be capped at the counted rows (no uid shared by a phase and a task; the surplus row stays un-numbered).
#   S8  the same with a TASK. Both then check that a second export numbers the leftover row without a duplicate.
# Success token (normal mode): "CONCURRENCY MOVE OK". With a mutant argument: exit 0 = MUTANT CAUGHT, exit 1 = MUTANT SURVIVED.
set -uo pipefail
MUT="${1:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/supabase/tests/a2a_export"
MIG="${MUT:-$(ls "$ROOT"/supabase/migrations/*_a2a_export.sql | head -1)}"
C="a2a-mconc-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
psqlx() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=0 -qAt "$@"; }
apply() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q < "$1" >/dev/null 2>&1 || { echo "FAILED applying $1"; exit 2; }; }
apply "$ROOT/supabase/tests/d0a/00_stub_schema.sql"
apply "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql"
while IFS= read -r f || [ -n "$f" ]; do
  f="${f%$'\r'}"; case "$f" in ""|"#"*) continue;; esac
  apply "$ROOT/$f"
done < "$T/requires.txt"
apply "$MIG"

CO=c1000000-0000-0000-0000-000000000001
JB=b1000000-0000-0000-0000-0000000000f0                       # the destination job
ja() { echo "b1000000-0000-0000-0000-0000000000a$1"; }        # job of scenario $1
tk() { echo "f1000000-0000-0000-0000-0000000000a$1"; }        # the task that is moved / locked in scenario $1 (its first task)
ph() { echo "f2000000-0000-0000-0000-0000000000a$1"; }        # the phase that is moved / locked in scenario $1 (its first phase)
SEED="$(mktemp)"
printf "INSERT INTO jobs (id, company_id, job_no, status) VALUES ('%s','%s','WO-MVB','Open');\n" "$JB" "$CO" > "$SEED"
for s in 1 2 3 4 5 6; do
  printf "INSERT INTO jobs (id, company_id, job_no, status) VALUES ('%s','%s','WO-MV%s','Open');\n" "$(ja $s)" "$CO" "$s" >> "$SEED"
  printf "INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES ('%s','%s','%s',1,'P1'),(gen_random_uuid(),'%s','%s',2,'P2'),(gen_random_uuid(),'%s','%s',3,'P3');\n" "$(ph $s)" "$CO" "$(ja $s)" "$CO" "$(ja $s)" "$CO" "$(ja $s)" >> "$SEED"
  printf "INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES ('%s','%s','%s',1,'T1'),(gen_random_uuid(),'%s','%s',2,'T2'),(gen_random_uuid(),'%s','%s',3,'T3');\n" "$(tk $s)" "$CO" "$(ja $s)" "$CO" "$(ja $s)" "$CO" "$(ja $s)" >> "$SEED"
done
for s in 7 8; do
  printf "INSERT INTO jobs (id, company_id, job_no, status) VALUES ('%s','%s','WO-MV%s','Open');\n" "$(ja $s)" "$CO" "$s" >> "$SEED"
  printf "INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES (gen_random_uuid(),'%s','%s',1,'P1'),(gen_random_uuid(),'%s','%s',2,'P2');\n" "$CO" "$(ja $s)" "$CO" "$(ja $s)" >> "$SEED"
  printf "INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES (gen_random_uuid(),'%s','%s',1,'T1'),(gen_random_uuid(),'%s','%s',2,'T2');\n" "$CO" "$(ja $s)" "$CO" "$(ja $s)" >> "$SEED"
  printf "INSERT INTO job_schedule_uid_counter (job_id, last_uid) VALUES ('%s', 0);\n" "$(ja $s)" >> "$SEED"
done
psqlx < "$SEED" >/dev/null

WRITER="SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true); SET LOCAL ROLE authenticated;"
mv_sql() {      # $1 = table, $2 = row id: the moving writer (API role) holds its transaction 3 s
  printf "BEGIN;\n%s\nDO \$\$ BEGIN UPDATE %s SET job_id = '%s' WHERE id = '%s'; RAISE NOTICE 'W result ok'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'W result %%', SQLSTATE; END \$\$;\nSELECT pg_sleep(3);\nCOMMIT;\n" "$WRITER" "$1" "$JB" "$2"; }
exp_sql() {     # $1 = job, $2 = hold seconds
  printf "BEGIN;\n%s\nSELECT 'E result ' || prepare_schedule_export('%s');\nSELECT pg_sleep(%s);\nCOMMIT;\n" "$WRITER" "$1" "$2"; }
dba_sql() {     # $1 = table, $2 = row id: a DBA session (owner, not an API role) numbers a row by hand and holds 3 s
  printf "BEGIN;\nUPDATE %s SET msp_uid = 99 WHERE id = '%s';\nSELECT pg_sleep(3);\nCOMMIT;\n" "$1" "$2"; }
pair() {        # $1 = scenario, $2 = first-session sql, $3 = second-session sql (starts 1 s later); outputs go to $OA / $OB
  OA="$(mktemp)"; OB="$(mktemp)"
  printf '%s' "$2" | psqlx > "$OA" 2>&1 &
  local PA=$!
  sleep 1
  printf '%s' "$3" | psqlx > "$OB" 2>&1 &
  local PB=$!
  wait "$PA"; wait "$PB"
}
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1: got '$2' expected '$3'"; FAIL=1; fi; }
q() { psqlx -c "$1" </dev/null; }
dups() { q "SELECT count(*) - count(DISTINCT u) FROM (SELECT msp_uid u FROM job_phases WHERE job_id IN ('$1','$JB') AND msp_uid IS NOT NULL UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id IN ('$1','$JB') AND msp_uid IS NOT NULL) s"; }

echo "S1 task moves away while the export of its job waits for the row"
pair 1 "$(mv_sql job_tasks "$(tk 1)")" "$(exp_sql "$(ja 1)" 0)"
RE="$(grep -o 'E result [0-9]*' "$OB" | awk '{print $3}')"; cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S1 export assigned (3 phases + 2 tasks)" "$RE" "5"
check "S1 the moved task sits in job B without a uid" "$(q "SELECT job_id = '$JB' AND msp_uid IS NULL FROM job_tasks WHERE id = '$(tk 1)'")" "t"
check "S1 job A keeps 5 distinct uids" "$(q "SELECT count(DISTINCT msp_uid) FROM (SELECT msp_uid FROM job_phases WHERE job_id = '$(ja 1)' UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id = '$(ja 1)') s")" "5"

echo "S2 phase moves away while the export of its job waits for the row"
pair 2 "$(mv_sql job_phases "$(ph 2)")" "$(exp_sql "$(ja 2)" 0)"
RE="$(grep -o 'E result [0-9]*' "$OB" | awk '{print $3}')"; cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S2 export assigned (2 phases + 3 tasks)" "$RE" "5"
check "S2 the moved phase sits in job B without a uid" "$(q "SELECT job_id = '$JB' AND msp_uid IS NULL FROM job_phases WHERE id = '$(ph 2)'")" "t"

echo "S3 the export numbers a task first, the move waits and is refused"
pair 3 "$(exp_sql "$(ja 3)" 3)" "$(mv_sql job_tasks "$(tk 3)")"
cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S3 the move was refused A2U01" "$(grep -o 'W result [A-Z0-9]*' "$OB" | awk '{print $3}')" "A2U01"
check "S3 the task stayed in job A with its uid" "$(q "SELECT job_id = '$(ja 3)' AND msp_uid IS NOT NULL FROM job_tasks WHERE id = '$(tk 3)'")" "t"

echo "S4 the export numbers a phase first, the move waits and is refused"
pair 4 "$(exp_sql "$(ja 4)" 3)" "$(mv_sql job_phases "$(ph 4)")"
cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S4 the move was refused A2U01" "$(grep -o 'W result [A-Z0-9]*' "$OB" | awk '{print $3}')" "A2U01"
check "S4 the phase stayed in job A with its uid" "$(q "SELECT job_id = '$(ja 4)' AND msp_uid IS NOT NULL FROM job_phases WHERE id = '$(ph 4)'")" "t"

echo "S5 a DBA numbers a task (uid 99) while the export waits for the row"
pair 5 "$(dba_sql job_tasks "$(tk 5)")" "$(exp_sql "$(ja 5)" 0)"
RE="$(grep -o 'E result [0-9]*' "$OB" | awk '{print $3}')"; cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S5 export assigned (3 phases + 2 tasks)" "$RE" "5"
check "S5 the DBA's uid 99 is still there" "$(q "SELECT msp_uid FROM job_tasks WHERE id = '$(tk 5)'")" "99"
check "S5 no uid used twice in the job" "$(dups "$(ja 5)")" "0"

echo "S6 a DBA numbers a phase (uid 99) while the export waits for the row"
pair 6 "$(dba_sql job_phases "$(ph 6)")" "$(exp_sql "$(ja 6)" 0)"
RE="$(grep -o 'E result [0-9]*' "$OB" | awk '{print $3}')"; cat "$OA" "$OB" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S6 export assigned (2 phases + 3 tasks)" "$RE" "5"
check "S6 the DBA's uid 99 is still there" "$(q "SELECT msp_uid FROM job_phases WHERE id = '$(ph 6)'")" "99"
check "S6 no uid used twice in the job" "$(dups "$(ja 6)")" "0"

# S7/S8 (r5 M-A): three sessions. B holds the uid counter row, so export A (which has already counted its uid-less rows) pauses inside
# sched_next_uids; C then inserts a row with sort_order 0 into the job; B commits; A resumes and numbers.
three() {       # $1 = job, $2 = insert statement for C
  OA="$(mktemp)"; OB="$(mktemp)"; OC="$(mktemp)"
  printf "BEGIN;\nSELECT last_uid FROM job_schedule_uid_counter WHERE job_id = '%s' FOR UPDATE;\nSELECT pg_sleep(4);\nCOMMIT;\n" "$1" | psqlx > "$OB" 2>&1 &
  local PB=$!
  sleep 1
  printf '%s' "$(exp_sql "$1" 0)" | psqlx > "$OA" 2>&1 &
  local PA=$!
  sleep 1.5
  printf '%s\n' "$2" | psqlx > "$OC" 2>&1
  wait "$PA"; wait "$PB"
}
uids() { q "SELECT string_agg(u::text, ',' ORDER BY u) FROM (SELECT msp_uid u FROM job_phases WHERE job_id = '$1' AND msp_uid IS NOT NULL UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id = '$1' AND msp_uid IS NOT NULL) s"; }
again() { printf '%s' "$(exp_sql "$1" 0)" | psqlx 2>&1 | grep -o 'E result [0-9]*' | awk '{print $3}'; }   # a second export, same job

echo "S7 a phase is inserted while the export waits for the uid counter"
three "$(ja 7)" "INSERT INTO job_phases (company_id, job_id, sort_order, name) VALUES ('$CO','$(ja 7)',0,'PNEW');"
RE="$(grep -o 'E result [0-9]*' "$OA" | awk '{print $3}')"; cat "$OA" "$OC" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S7 export assigned only the 2 phases + 2 tasks it counted" "$RE" "4"
check "S7 no uid used twice in the job" "$(dups "$(ja 7)")" "0"
check "S7 exactly one phase is left without a uid" "$(q "SELECT count(*) FROM job_phases WHERE job_id = '$(ja 7)' AND msp_uid IS NULL")" "1"
check "S7 uids handed out are 1..4" "$(uids "$(ja 7)")" "1,2,3,4"
check "S7 the next export numbers the leftover phase" "$(again "$(ja 7)")" "1"
check "S7 after it: five distinct uids" "$(uids "$(ja 7)")" "1,2,3,4,5"

echo "S8 a task is inserted while the export waits for the uid counter"
three "$(ja 8)" "INSERT INTO job_tasks (company_id, job_id, sort_order, task_name) VALUES ('$CO','$(ja 8)',0,'TNEW');"
RE="$(grep -o 'E result [0-9]*' "$OA" | awk '{print $3}')"; cat "$OA" "$OC" | grep -E "result|ERROR" | tr '\n' ' '; echo
check "S8 export assigned only the 2 phases + 2 tasks it counted" "$RE" "4"
check "S8 no uid used twice in the job" "$(dups "$(ja 8)")" "0"
check "S8 exactly one task is left without a uid" "$(q "SELECT count(*) FROM job_tasks WHERE job_id = '$(ja 8)' AND msp_uid IS NULL")" "1"
check "S8 uids handed out are 1..4" "$(uids "$(ja 8)")" "1,2,3,4"
check "S8 the next export numbers the leftover task" "$(again "$(ja 8)")" "1"

if [ "$FAIL" = 0 ]; then
  [ -n "$MUT" ] && { echo "MUTANT SURVIVED"; exit 1; }
  echo "CONCURRENCY MOVE OK"; exit 0
fi
[ -n "$MUT" ] && { echo "MUTANT CAUGHT"; exit 0; }
echo "CONCURRENCY MOVE FAILED"; exit 1
