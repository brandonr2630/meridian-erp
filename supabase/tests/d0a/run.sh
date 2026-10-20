#!/usr/bin/env bash
# Runs the D0a migration against a throwaway Postgres 17 container seeded with a stub of the live schema.
# Usage: bash supabase/tests/d0a/run.sh   (needs Docker running; uses postgres:17-alpine)
set -euo pipefail
cd "$(dirname "$0")"
MIG="../../migrations/202610200900_d0a_staff_only_storage.sql"
DOWN="../../rollbacks/202610200900_d0a_down.sql"
C=d0a-test-pg
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 60); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
run() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
step() { echo "== $1"; }
apply() { out=$(run < "$1" 2>&1) || { echo "$out" | grep -E "ERROR|FAIL" | head -5; echo "FAILED applying $1"; exit 1; }; }
# assertion files raise on the first mismatch; report PASS count, or the failing assertion
assert() { out=$(run < "$1" 2>&1) || { echo "$out" | grep -E "ERROR|FAIL" | head -5; echo "FAILED: $1"; exit 1; }; echo "   PASS count: $(echo "$out" | grep -c 'NOTICE:  PASS')"; }
step "stub live schema";               apply 00_stub_schema.sql
step "BEFORE: holes exist";            assert 10_before.sql
step "apply D0a";                      apply "$MIG"
step "apply D0a again (idempotent)";   apply "$MIG"
step "AFTER: hardened";                assert 20_after.sql
step "rollback";                       apply "$DOWN"
step "AFTER rollback: original state"; assert 30_rollback.sql
step "re-apply D0a after rollback";    apply "$MIG"
step "AFTER again";                    assert 20_after.sql
echo "ALL D0a TESTS PASSED"
