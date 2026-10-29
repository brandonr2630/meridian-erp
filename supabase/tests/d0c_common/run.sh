#!/usr/bin/env bash
# Shared D0c test runner. Runs one family's migration on a throwaway Postgres 17 (Docker) seeded with the D0a stub of the
# live schema, with the D0a migration already applied (the real starting state), then the family's extra stub and tests.
#
# Usage:  bash supabase/tests/d0c_common/run.sh <family> [mutated-migration.sql]
#   family  = directory name under supabase/tests/ (e.g. d0c_audit). Files in it:
#     10_stub_extra.sql  family-specific stub: real columns/tables/policies/data on top of the D0a stub (may DROP+CREATE tables)
#     15_before.sql      assertions that the legacy holes exist (positive control)         -- run BEFORE the migration
#     20_after.sql       assertions of the new behaviour (role matrix, scoping, atoms)    -- run AFTER the migration
#     30_rollback.sql    assertions after the down script (original state restored)
#   The migration is supabase/migrations/*_<family>.sql and the rollback supabase/rollbacks/*_<family>_down.sql.
#   With a 2nd argument the given file replaces the migration and only 20_after.sql is run: exit 0 = MUTANT CAUGHT (tests failed),
#   exit 1 = MUTANT SURVIVED (tests passed on a broken migration).
# Success token (normal mode): "ALL <FAMILY> TESTS PASSED"
set -euo pipefail
FAM="${1:?family directory name required}"
MUT="${2:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/supabase/tests/$FAM"
BASE="$ROOT/supabase/tests/d0a/00_stub_schema.sql"
D0A="$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql"
MIG="${MUT:-$(ls "$ROOT"/supabase/migrations/*_"$FAM".sql | head -1)}"
DOWN="$(ls "$ROOT"/supabase/rollbacks/*_"$FAM"_down.sql 2>/dev/null | head -1 || true)"
[ -f "$MIG" ] || { echo "no migration found for $FAM"; exit 2; }
C="d0c-$FAM-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do
  n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
run() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
apply() { local out; out=$(run < "$1" 2>&1) || { echo "$out" | grep -E "ERROR|FAIL|DETAIL" | head -6; echo "FAILED applying $1"; return 1; }; }
assert() { local out; out=$(run < "$1" 2>&1) || { echo "$out" | grep -E "ERROR|FAIL" | head -6; echo "FAILED: $1"; return 1; }; echo "   PASS count: $(echo "$out" | grep -c 'NOTICE:  PASS')"; }

# Optional $T/requires.txt: repo-relative files (one per line, # comments ok) applied after D0a and before the family stub.
# Used by families that build on later migrations (e.g. a2a_* needs the Phase A schema).
requires() { [ -f "$T/requires.txt" ] || return 0; local f; while IFS= read -r f || [ -n "$f" ]; do f="${f%$'\r'}"; case "$f" in ""|"#"*) continue;; esac; apply "$ROOT/$f" >/dev/null || return 1; done < "$T/requires.txt"; }

if [ -n "$MUT" ]; then
  apply "$BASE" >/dev/null || exit 2
  apply "$D0A" >/dev/null || exit 2
  requires || exit 2
  [ -f "$T/10_stub_extra.sql" ] && { apply "$T/10_stub_extra.sql" >/dev/null || exit 2; }
  apply "$MIG" >/dev/null 2>&1 || { echo "MUTANT CAUGHT (migration no longer applies)"; exit 0; }
  if run < "$T/20_after.sql" >/dev/null 2>&1; then echo "MUTANT SURVIVED"; exit 1; else echo "MUTANT CAUGHT"; exit 0; fi
fi

echo "== stub live schema + D0a";    apply "$BASE"; apply "$D0A"
echo "== requires";                 requires
[ -f "$T/10_stub_extra.sql" ] && { echo "== family stub"; apply "$T/10_stub_extra.sql"; }
echo "== BEFORE: legacy holes exist"; assert "$T/15_before.sql"
echo "== apply $FAM";                apply "$MIG"
echo "== apply again (idempotent)";  apply "$MIG"
echo "== AFTER: scoped";             assert "$T/20_after.sql"
if [ -n "$DOWN" ]; then
  echo "== rollback";                 apply "$DOWN"
  echo "== AFTER rollback";           assert "$T/30_rollback.sql"
  echo "== re-apply after rollback";  apply "$MIG"
  echo "== AFTER again";              assert "$T/20_after.sql"
fi
echo "ALL $(echo "$FAM" | tr a-z A-Z) TESTS PASSED"
