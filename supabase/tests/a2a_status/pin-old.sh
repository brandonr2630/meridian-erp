#!/usr/bin/env bash
# Writes pinned-old.json: what the PRE-CHANGE job_schedule_status returns for the pinned r3 cases (see gen-cases.mjs).
# Usage: node gen-cases.mjs --dump-pinned && bash supabase/tests/a2a_status/pin-old.sh [git-ref or migration file of the pre-change body, default HEAD] [cases.json] [out.json]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; REF="${1:-HEAD}"; CASES="${2:-$ROOT/supabase/tests/a2a_status/pinned-cases.json}"; OUT="${3:-$ROOT/supabase/tests/a2a_status/pinned-old.json}"; T="$ROOT/supabase/tests/a2a_status"
C="d0c-pin-$$"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x postgres:17-alpine >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 90); do n=$(docker logs "$C" 2>&1 | grep -c "ready to accept connections" || true); [ "$n" -ge 2 ] && break; sleep 1; done
run() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
for f in "$ROOT/supabase/tests/d0a/00_stub_schema.sql" "$ROOT/supabase/migrations/202610200900_d0a_staff_only_storage.sql" \
         "$ROOT/supabase/tests/phase_a_sql/10_stub_extra.sql" "$ROOT"/supabase/migrations/*_phase_a_sql.sql "$ROOT/supabase/migrations/202610271000_a2a_schema.sql"; do
  run < "$f" >/dev/null 2>&1 || { echo "FAILED applying $f"; exit 1; }
done
if [ -f "$REF" ]; then run < "$REF" >/dev/null; else git -C "$ROOT" show "$REF:supabase/migrations/202610271100_a2a_status.sql" | run >/dev/null; fi
node -e '
const fs=require("fs"); const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); const a2=fs.readFileSync(process.argv[2],"utf8");
let o="BEGIN;\nSELECT set_config($$request.jwt.claim.sub$$, $$$$, true);\n";
o+="CREATE FUNCTION pg_temp.st(j text, d date) RETURNS text LANGUAGE sql AS $f$ SELECT count(*)::text || $$:$$ || coalesce(string_agg(status || $$|$$ || coalesce(forecast_end::text, $$null$$) || $$|$$ || coalesce(slip_days::text, $$null$$), $$,$$), $$-$$) FROM job_schedule_status(j::uuid, d) $f$;\n";
o+=a2+"\n";
for(const c of d) o+="SELECT $n$"+c.name+"$n$ || E\x27\t\x27 || pg_temp.a2run($j$"+c.json+"$j$::jsonb);\n";
o+="ROLLBACK;\n"; fs.writeFileSync(process.argv[3],o);
' "$CASES" "$T/a2run.sql" /tmp/pin-$$.sql
run -At < /tmp/pin-$$.sql | grep -P '	' | node -e '
const l=require("fs").readFileSync(0,"utf8").trim().split("\n"); const m={}; for(const x of l){const i=x.indexOf("\t"); m[x.slice(0,i)]=x.slice(i+1);}
require("fs").writeFileSync(process.argv[1],JSON.stringify(m,null,1)); console.log("pinned",Object.keys(m).length);' "$OUT"
rm -f /tmp/pin-$$.sql
