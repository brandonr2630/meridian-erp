// SQL side of the shared schedule fixture (Phase A, X1/X2/X20).
// Consumes scripts/tests/schedule/fixture.json (contract below) against a Postgres that has the Phase A migration applied.
// For each case it seeds a scratch job + tasks + links inside ONE transaction that is rolled back, calls
// job_schedule_status(job_id, today) and computes overall / plannedToday with the same sums over job_task_weight /
// job_task_planned_pct that the migration uses, then compares to `expect` (2 dp value AND the half-up displayed integer).
//
// A2a: `parent` (a task key) is written to job_tasks.parent_task_id and `type` (FS|SS|FF|SF, default FS) to job_task_links.link_type;
// both columns come from supabase/migrations/202610271000_a2a_schema.sql. Overall / planned sums EXCLUDE summary rows (tasks that have
// children), mirroring the X1 amendment and the SQL function.
//
// Usage:  node scripts/tests/schedule/sql-fixture-runner.mjs --container <docker container> [--fixture file.json] [--company <uuid>]
//   or    bash supabase/tests/phase_a_sql/run-fixture.sh [fixture.json]     (starts its own throwaway container)
// Prints "SQL FIXTURE PASSED n/n cases" on success; exits 1 and prints every mismatch otherwise.
//
// Contract: { "cases": [ { name, today, job: {status, due_date}, baselineLocked, tasks: [ {key, sort_order, start_date, end_date,
//   progress, is_milestone, weight, baseline_start, baseline_end, parent?} ], links: [ {task, pred, lag, type?} ],
//   expect: { overall, overallDisplay, plannedToday, plannedDisplay, forecastEnd, status, slipDays } } ] }
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : dflt; };
const container = opt("container");
const fixtureFile = opt("fixture", join(here, "fixture.json"));
const company = opt("company", "c1000000-0000-0000-0000-000000000001");
if (!container) { console.error("usage: sql-fixture-runner.mjs --container <name> [--fixture file] [--company uuid]"); process.exit(2); }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
if (!UUID.test(company)) { console.error("bad --company"); process.exit(2); }
const lit = (s) => "'" + String(s).replaceAll("'", "''") + "'";
const date = (d) => { if (d == null) return "NULL"; if (!DATE.test(d)) throw new Error("bad date " + d); return lit(d) + "::date"; };
const num = (n) => { if (n == null) return "NULL"; if (!Number.isFinite(Number(n))) throw new Error("bad number " + n); return String(Number(n)); };
const id = (ci, ti) => `00000000-0000-4000-8000-${String(ci).padStart(6, "0")}${String(ti).padStart(6, "0")}`;

const fixture = JSON.parse(readFileSync(fixtureFile, "utf8"));
if (!Array.isArray(fixture.cases) || fixture.cases.length === 0) { console.error("fixture has no cases"); process.exit(2); }

function caseSql(c, ci) {
  const job = id(ci + 1, 0);
  const keys = new Map(c.tasks.map((t, i) => [t.key, id(ci + 1, i + 1)]));
  const s = [];
  s.push("BEGIN;");
  // baseline columns are guard-protected: seed them as the function owner with the setting on (same as lock_job_baseline)
  s.push("SELECT set_config('app.baseline_rpc', 'on', true);");
  s.push(`INSERT INTO jobs (id, company_id, job_no, status, due_date) VALUES (${lit(job)}, ${lit(company)}, ${lit("FX-" + (ci + 1))}, ${lit(c.job.status)}, ${date(c.job.due_date)});`);
  for (const t of c.tasks) {
    const hasBl = t.baseline_start != null || t.baseline_end != null;
    s.push("INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, is_milestone, weight, baseline_start, baseline_end, baseline_locked_at) VALUES ("
      + [lit(keys.get(t.key)), lit(company), lit(job), num(t.sort_order), lit(t.key), date(t.start_date), date(t.end_date), num(t.progress),
         t.is_milestone ? "true" : "false", num(t.weight), date(t.baseline_start), date(t.baseline_end),
         c.baselineLocked && hasBl ? "now()" : "NULL"].join(", ") + ");");
  }
  for (const t of c.tasks) {
    if (t.parent == null) continue;
    if (!keys.has(t.parent)) throw new Error("parent refers to an unknown task key in case " + c.name);
    s.push(`UPDATE job_tasks SET parent_task_id = ${lit(keys.get(t.parent))} WHERE id = ${lit(keys.get(t.key))};`);
  }
  for (const l of c.links || []) {
    if (!keys.has(l.task) || !keys.has(l.pred)) throw new Error("link refers to an unknown task key in case " + c.name);
    s.push(`INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type) VALUES (${lit(company)}, ${lit(job)}, ${lit(keys.get(l.task))}, ${lit(keys.get(l.pred))}, ${num(l.lag ?? 0)}, ${lit(l.type ?? "FS")});`);
  }
  s.push("SELECT set_config('app.baseline_rpc', 'off', true);");
  const today = date(c.today);
  s.push(`SELECT 'RESULT:' || json_build_object(
    'rows', (SELECT count(*) FROM job_schedule_status(${lit(job)}::uuid, ${today})),
    'status', (SELECT status FROM job_schedule_status(${lit(job)}::uuid, ${today})),
    'forecastEnd', (SELECT forecast_end FROM job_schedule_status(${lit(job)}::uuid, ${today})),
    'slipDays', (SELECT slip_days FROM job_schedule_status(${lit(job)}::uuid, ${today})),
    'overall', a.overall, 'overallDisplay', floor(a.overall + 0.5), 'plannedToday', a.planned, 'plannedDisplay', floor(a.planned + 0.5))::text
  FROM (SELECT COALESCE(ROUND(SUM(w * progress) / NULLIF(SUM(w), 0), 2), 0) AS overall,
               COALESCE(ROUND(SUM(w * job_task_planned_pct(baseline_start, baseline_end, start_date, end_date, ${today})) / NULLIF(SUM(w), 0), 2), 0) AS planned
          FROM (SELECT job_task_weight(is_milestone, weight, start_date, end_date) AS w, progress, baseline_start, baseline_end, start_date, end_date
                  FROM job_tasks WHERE job_id = ${lit(job)}::uuid
                   AND id NOT IN (SELECT parent_task_id FROM job_tasks WHERE job_id = ${lit(job)}::uuid AND parent_task_id IS NOT NULL)) x WHERE w > 0) a;`);
  s.push("ROLLBACK;");
  return s.join("\n");
}

function run(sql) {
  const r = spawnSync("docker", ["exec", "-i", container, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-q"], { input: sql, encoding: "utf8" });
  return { status: r.status, out: (r.stdout || "") + (r.stderr || "") };
}

let passed = 0; const failures = [];
fixture.cases.forEach((c, ci) => {
  let r;
  try { r = run(caseSql(c, ci)); } catch (e) { failures.push(`${c.name}: ${e.message}`); return; }
  const line = r.out.split("\n").find((l) => l.startsWith("RESULT:"));
  if (r.status !== 0 || !line) { failures.push(`${c.name}: SQL error: ${r.out.trim().split("\n").slice(0, 3).join(" | ")}`); return; }
  const got = JSON.parse(line.slice(7)); const e = c.expect; const bad = [];
  if (got.rows !== 1) bad.push(`rows=${got.rows} (want exactly 1)`);
  const cents = (v) => Math.round(Number(v) * 100);
  if (cents(got.overall) !== cents(e.overall)) bad.push(`overall ${got.overall} != ${e.overall}`);
  if (got.overallDisplay !== e.overallDisplay) bad.push(`overallDisplay ${got.overallDisplay} != ${e.overallDisplay}`);
  if (cents(got.plannedToday) !== cents(e.plannedToday)) bad.push(`plannedToday ${got.plannedToday} != ${e.plannedToday}`);
  if (got.plannedDisplay !== e.plannedDisplay) bad.push(`plannedDisplay ${got.plannedDisplay} != ${e.plannedDisplay}`);
  if ((got.forecastEnd ?? null) !== (e.forecastEnd ?? null)) bad.push(`forecastEnd ${got.forecastEnd} != ${e.forecastEnd}`);
  if (got.status !== e.status) bad.push(`status ${got.status} != ${e.status}`);
  if ((got.slipDays ?? null) !== (e.slipDays ?? null)) bad.push(`slipDays ${got.slipDays} != ${e.slipDays}`);
  if (bad.length) failures.push(`${c.name}: ${bad.join("; ")}`); else passed++;
});
if (failures.length) {
  console.error(`SQL FIXTURE FAILED ${passed}/${fixture.cases.length} cases`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`SQL FIXTURE PASSED ${passed}/${fixture.cases.length} cases`);
