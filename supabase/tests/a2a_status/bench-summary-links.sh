#!/usr/bin/env bash
# Perf harness (r3, summary links): times job_schedule_status on the reviewer's payload: summary S with K leaf kids chained against
# their direction (kid g after kid g+1, FS) and K FS links from K outside tasks into S (default K=300: 601 tasks / 599 links).
# Variants (informational): "nest" = nested summaries N deep; "cyc" = the reviewer payload plus a link from a kid to its own summary
# (hierarchy-induced cycle: passes do not settle, so the pass loop runs to its n+2 cut-off, exactly as the JS engine does).
# Usage: bash supabase/tests/a2a_status/bench-summary-links.sh [migration.sql] [K]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIG="${1:-$ROOT/supabase/migrations/202610271100_a2a_status.sql}"
K="${2:-300}"
C="d0c-benchs-$$"
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
CO=c1000000-0000-0000-0000-000000000001
uid() { echo "('e0000000-0000-0000-0000-' || lpad(($1)::text, 12, '0'))::uuid"; }
run >/dev/null <<SQL
INSERT INTO jobs (id, company_id, job_no, status) SELECT ('b7000000-0000-0000-0000-00000000000' || g)::uuid, '$CO', 'BS-' || g, 'Open' FROM generate_series(1, 3) g;
SET session_replication_role = replica;   -- timing fixture: skip triggers (link-cycle check, caps)
-- job 1 = reviewer payload: S=1, kids 2..K+1 (parent S), outsiders 1001..1000+K
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, parent_task_id)
SELECT $(uid g), '$CO', 'b7000000-0000-0000-0000-000000000001', g, 'T' || g, DATE '2026-03-01', DATE '2026-03-03',
       CASE WHEN g BETWEEN 2 AND $K + 1 THEN $(uid 1) END
  FROM (SELECT g FROM generate_series(1, $K + 1) g UNION ALL SELECT 1000 + g FROM generate_series(1, $K) g) s(g);
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
SELECT '$CO', 'b7000000-0000-0000-0000-000000000001', $(uid g), $(uid "g + 1"), 0, 'FS' FROM generate_series(2, $K) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
SELECT '$CO', 'b7000000-0000-0000-0000-000000000001', $(uid 1), $(uid "1000 + g"), 0, 'FS' FROM generate_series(1, $K) g;
-- job 2 = nested summaries 1 > 2 > 3 ... > 2K, one leaf under the deepest, FS chain between every pair of summaries' leaves skipped
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, parent_task_id)
SELECT $(uid "10000 + g"), '$CO', 'b7000000-0000-0000-0000-000000000002', g, 'N' || g, DATE '2026-03-01', DATE '2026-03-03',
       CASE WHEN g > 1 THEN $(uid "10000 + g - 1") END FROM generate_series(1, 2 * $K) g;
-- job 3 = job 1 plus a link from kid 2 to its own summary (cycle through the hierarchy)
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, parent_task_id)
SELECT $(uid "20000 + g"), '$CO', 'b7000000-0000-0000-0000-000000000003', g, 'T' || g, DATE '2026-03-01', DATE '2026-03-03',
       CASE WHEN g BETWEEN 2 AND $K + 1 THEN $(uid 20001) END
  FROM (SELECT g FROM generate_series(1, $K + 1) g UNION ALL SELECT 1000 + g FROM generate_series(1, $K) g) s(g);
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
SELECT '$CO', 'b7000000-0000-0000-0000-000000000003', $(uid "20000 + g"), $(uid "20000 + g + 1"), 0, 'FS' FROM generate_series(2, $K) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
SELECT '$CO', 'b7000000-0000-0000-0000-000000000003', $(uid 20001), $(uid "20000 + 1000 + g"), 0, 'FS' FROM generate_series(1, $K) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
VALUES ('$CO', 'b7000000-0000-0000-0000-000000000003', $(uid 20001), $(uid 20002), 0, 'FS');
ANALYZE;
SQL
echo "migration: $MIG  K=$K"
for v in 1 2 3; do
  label=$([ $v = 1 ] && echo "reviewer payload (tasks $((2*K+1)), links $((2*K-1)))" || { [ $v = 2 ] && echo "nest $((2*K)) deep" || echo "cyclic variant (kid -> own summary)"; })
  echo "-- $label"
  for k in 1 2 3; do
    run -At <<SQL | grep -E "Time:|\|" | tr '\n' ' '
\timing on
SELECT status, forecast_end, slip_days FROM job_schedule_status('b7000000-0000-0000-0000-00000000000$v', DATE '2026-03-01');
SQL
    echo
  done
done
# r3d M2: the one-link repro (a link joining the summary and one of its own kids) is refused at the INSERT now, so it can no longer be stored
echo "-- repro: INSERT job_task_links(task = summary, predecessor = its own kid) with the triggers on"
run -At <<SQL
DO \$\$ BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
  VALUES ('$CO', 'b7000000-0000-0000-0000-000000000001', $(uid 1), $(uid 2), 0, 'FS');
  RAISE NOTICE 'REPRO NOT REFUSED';
EXCEPTION WHEN SQLSTATE 'A2L01' THEN RAISE NOTICE 'REPRO REFUSED with A2L01';
END \$\$;
SQL
