#!/usr/bin/env bash
# Perf harness (r3): times job_schedule_status on a reversed FS chain of N tasks (default 2000): task i depends on task i+1, so
# the forward/backward passes of a link-order relaxation advance one step per pass. Throwaway Postgres 17 in Docker.
# Usage: bash supabase/tests/a2a_status/bench-reversed-chain.sh [migration.sql] [N]   (default migration: the A2a status file)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MIG="${1:-$ROOT/supabase/migrations/202610271100_a2a_status.sql}"
N="${2:-2000}"
C="d0c-bench-$$"
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
run >/dev/null <<SQL
INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b1000000-0000-0000-0000-0000000b0001', 'c1000000-0000-0000-0000-000000000001', 'BENCH-1', 'Open');
SET session_replication_role = replica;   -- skip triggers (link cycle check etc.): this is a timing fixture
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date)
SELECT ('e0000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, 'c1000000-0000-0000-0000-000000000001',
       'b1000000-0000-0000-0000-0000000b0001', g, 'T' || g, DATE '2026-03-01', DATE '2026-03-03' FROM generate_series(1, $N) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
SELECT 'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000b0001',
       ('e0000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, ('e0000000-0000-0000-0000-' || lpad((g + 1)::text, 12, '0'))::uuid, 0, 'FS'
  FROM generate_series(1, $N - 1) g ORDER BY g;
ANALYZE;
SQL
echo "migration: $MIG  tasks: $N"
for k in 1 2 3; do
  run -At <<SQL
\timing on
SELECT status, forecast_end, slip_days FROM job_schedule_status('b1000000-0000-0000-0000-0000000b0001', DATE '2026-03-01');
SQL
done | grep -E "Time:|\|" 
