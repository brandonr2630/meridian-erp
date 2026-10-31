#!/usr/bin/env bash
# Cost of the link / re-parent guards (r4 M1): the same statements against the schema migration of a git ref (default HEAD = before the value-flow
# check) and against the working tree. Tables are ANALYZEd after the tasks are loaded (a database with statistics). Times are wall clock in ms.
#   A  attach 4999 kids to a summary that has 1000 links into it, ONE statement (re-parent guard per row)
#   B  insert 3000 chain links, ONE statement, in the direction that is cheap for the Phase A walk (kid g after kid g+1, ascending)
#   C  the same 2999 links in the reverse insertion order (the walk of the link-cycle trigger sees the whole chain every time)
#   D  1000 links from fresh outsiders into a summary with 1000 kids (every insert would have to look below the summary)
#   E  the reviewer's indirect loop is refused: Y after S (accepted), the last kid after Y (A2L03), with the time of each
# Usage: bash supabase/tests/a2a_status/bench-guard-cost.sh [old-ref (default HEAD)]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; REF="${1:-HEAD}"
CO=c1000000-0000-0000-0000-000000000001
run_one() {   # $1 = label, $2 = schema migration file
  local C="d0c-bgc-$$-$RANDOM"
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
  for i in $(seq 1 90); do n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true); [ "$n" -ge 2 ] && break; sleep 1; done
  local run="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -q"
  for f in "$ROOT/supabase/tests/d0a/00_stub_schema.sql" "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql" \
           "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql" "$ROOT"/supabase/migrations/*_phase_a_sql.sql "$2"; do
    $run < "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; docker rm -f "$C" >/dev/null; exit 1; }
  done
  echo "== $1"
  $run -At 2>&1 <<SQL | grep -E "NOTICE:  [A-E] |ERROR" | sed 's/NOTICE:  //'
CREATE FUNCTION pg_temp.u(j int, g int) RETURNS uuid LANGUAGE sql IMMUTABLE AS \$f\$ SELECT ('e7000000-0000-000' || j || '-0000-' || lpad(g::text, 12, '0'))::uuid \$f\$;
INSERT INTO jobs (id, company_id, job_no, status) SELECT ('b7100000-0000-0000-0000-00000000000' || g)::uuid, '$CO', 'GC-' || g, 'Open' FROM generate_series(1, 5) g;
SET session_replication_role = replica;
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  SELECT pg_temp.u(j, g), '$CO', ('b7100000-0000-0000-0000-00000000000' || j)::uuid, g, 'T' || g FROM generate_series(1, 5) j, generate_series(1, 6000) g;
SET session_replication_role = origin;
ANALYZE job_tasks;
-- A: job 1: S = task 1 with links from outsiders 5001..6000; attach kids 2..5000
SET session_replication_role = replica;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
  SELECT '$CO', 'b7100000-0000-0000-0000-000000000001', pg_temp.u(1, 1), pg_temp.u(1, g) FROM generate_series(5001, 6000) g;
SET session_replication_role = origin;
ANALYZE job_task_links;
DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  UPDATE job_tasks SET parent_task_id = pg_temp.u(1, 1) WHERE job_id = 'b7100000-0000-0000-0000-000000000001' AND sort_order BETWEEN 2 AND 5000;
  RAISE NOTICE 'A attach 4999 kids to S (1000 links into S): % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END \$\$;
-- B: job 2, 2999 links ascending in one statement
DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
    SELECT '$CO', 'b7100000-0000-0000-0000-000000000002', pg_temp.u(2, g), pg_temp.u(2, g + 1) FROM generate_series(1, ${BN:-2999}) g;
  RAISE NOTICE 'B ${BN:-2999} chain links, ascending, one statement: % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END \$\$;
-- C: job 3, the same chain inserted in the reverse order
DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
    SELECT '$CO', 'b7100000-0000-0000-0000-000000000003', pg_temp.u(3, g), pg_temp.u(3, g + 1) FROM generate_series(2999, 1, -1) g;
  RAISE NOTICE 'C 2999 chain links, descending order, one statement: % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END \$\$;
-- D: job 4: summary S = task 1 with kids 2..1001 (planted), then 1000 links from fresh outsiders 3001..4000 into S (one statement)
SET session_replication_role = replica;
UPDATE job_tasks SET parent_task_id = pg_temp.u(4, 1) WHERE job_id = 'b7100000-0000-0000-0000-000000000004' AND sort_order BETWEEN 2 AND 1001;
SET session_replication_role = origin;
DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
    SELECT '$CO', 'b7100000-0000-0000-0000-000000000004', pg_temp.u(4, 1), pg_temp.u(4, g) FROM generate_series(3001, 4000) g;
  RAISE NOTICE 'D 1000 links into a summary with 1000 kids, one statement: % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END \$\$;
-- E: job 5: S = task 1 with kids 2..1001; Y = task 3001
SET session_replication_role = replica;
UPDATE job_tasks SET parent_task_id = pg_temp.u(5, 1) WHERE job_id = 'b7100000-0000-0000-0000-000000000005' AND sort_order BETWEEN 2 AND 1001;
SET session_replication_role = origin;
DO \$\$ DECLARE t0 timestamptz := clock_timestamp(); r text; BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES ('$CO', 'b7100000-0000-0000-0000-000000000005', pg_temp.u(5, 3001), pg_temp.u(5, 1));
  RAISE NOTICE 'E Y after S accepted: % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp();
  BEGIN
    INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES ('$CO', 'b7100000-0000-0000-0000-000000000005', pg_temp.u(5, 1001), pg_temp.u(5, 3001));
    r := 'ACCEPTED (the loop is stored)';
  EXCEPTION WHEN OTHERS THEN r := 'refused ' || SQLSTATE;
  END;
  RAISE NOTICE 'E last kid after Y: % in % ms', r, round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END \$\$;
SQL
  docker rm -f "$C" >/dev/null
}
OLD="$(mktemp)"; git -C "$ROOT" show "$REF:supabase/migrations/202610271000_a2a_schema.sql" > "$OLD"
run_one "before ($REF)" "$OLD"
run_one "after (working tree)" "$ROOT/supabase/migrations/202610271000_a2a_schema.sql"
