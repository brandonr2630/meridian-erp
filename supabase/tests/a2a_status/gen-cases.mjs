// Generates supabase/tests/a2a_status/{20_after,15_before,30_rollback}.sql from the matching *.template.sql (+ a2run.sql helper).
//   node supabase/tests/a2a_status/gen-cases.mjs          (rewrites 20_after.sql; commit both)
//   node supabase/tests/a2a_status/gen-cases.mjs --check   (exit 1 when the committed 20_after.sql is stale)
// Two groups of generated assertions, each one `pg_temp.a2run(<case json>)` compared with 'rows:status|forecast_end|slip_days':
//   1. every "A2 ..." case of the shared fixture (scripts/tests/schedule/fixture.json); the expectation is the fixture's own
//      hand-derived value, so these are SQL-side proofs independent of the JS engine.
//   2. SQL-only targeted cases below (negative lag per link type, 3-level hierarchy, summary rules, parent cycle / self / foreign
//      parent, link into own summary, link types the CHECK would refuse). Their expectation is computed here by the JS engine
//      jcSchedCompute sliced out of index.html (JS is the reference) AND each is pinned by a note saying what it proves; a case whose
//      JS result is not the intended behaviour must be fixed here, not silently accepted.
import { readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const html = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");
const a = html.indexOf("// ── SCHEDULE COMPUTE (shared) ──"), b = html.indexOf("// ── END SCHEDULE COMPUTE ──");
if (a < 0 || b < a) throw new Error("compute block markers not found in index.html");
const ctx = { Date: function () { throw new Error("Date used"); } };
vm.createContext(ctx);
const M = vm.runInContext(`(function(){\n${html.slice(a, b)}\nreturn { jcSchedCompute };\n})()`, ctx);
const fixture = JSON.parse(readFileSync(join(root, "scripts/tests/schedule/fixture.json"), "utf8"));

const OTHER = "@other";   // a parent that lives in ANOTHER job (the template inserts it); JS sees an unknown id
const T = (key, ord, s, e, extra = {}) => ({ key, sort_order: ord, start_date: s, end_date: e, progress: 0, is_milestone: false, weight: null,
  baseline_start: null, baseline_end: null, ...extra });
const C = (name, tasks, links = [], more = {}) => ({ name, today: "2026-03-02", job: { status: "In Progress", due_date: null }, baselineLocked: false, tasks, links, ...more });
const A = T("A", 10, "2026-03-09", "2026-03-13"), B = T("B", 20, "2026-03-09", "2026-03-14");
const neg = (ty) => C(`neg-lag ${ty}: lead of 2 days`, [A, B], [{ task: "B", pred: "A", lag: -2, type: ty }]);
const targeted = [
  neg("FS"), neg("SS"), neg("FF"), neg("SF"),
  C("hier 3 levels: G > P > L1,L2 and G > L3, X after G (FS)", [
    T("G", 10, "2026-03-09", "2026-03-20"), T("P", 20, "2026-03-09", "2026-03-20", { parent: "G" }),
    T("L1", 30, "2026-03-09", "2026-03-10", { parent: "P" }), T("L2", 40, "2026-03-09", "2026-03-13", { parent: "P" }),
    T("L3", 50, "2026-03-09", "2026-03-11", { parent: "G" }), T("X", 60, "2026-03-09", "2026-03-11")], [{ task: "X", pred: "G", lag: 0, type: "FS" }]),
  C("hier 3 levels, children sorted BEFORE their parents (depth order must not depend on sort_order)", [
    T("L1", 10, "2026-03-09", "2026-03-10", { parent: "P" }), T("L2", 20, "2026-03-09", "2026-03-13", { parent: "P" }),
    T("L3", 30, "2026-03-09", "2026-03-11", { parent: "G" }), T("P", 40, "2026-03-09", "2026-03-20", { parent: "G" }),
    T("G", 50, "2026-03-09", "2026-03-20"), T("X", 60, "2026-03-09", "2026-03-11")], [{ task: "X", pred: "G", lag: 0, type: "FS" }]),
  C("hier 3 levels: a link from the middle summary P into leaf Z (SS lag 1) uses P derived start", [
    T("G", 10, "2026-03-09", "2026-03-20"), T("P", 20, "2026-03-09", "2026-03-20", { parent: "G" }),
    T("L1", 30, "2026-03-05", "2026-03-10", { parent: "P", progress: 50 }), T("L2", 40, "2026-03-09", "2026-03-13", { parent: "P" }),
    T("Z", 50, "2026-03-09", "2026-03-11")], [{ task: "Z", pred: "P", lag: 1, type: "SS" }]),
  C("summary is never critical or late: S ended 02-05 unfinished but its leaf is in the future -> On track", [
    T("S", 10, "2026-02-01", "2026-02-05"), T("C1", 20, "2026-03-09", "2026-03-12", { parent: "S" })]),
  C("control: the same task WITHOUT a child, overdue and critical -> Late", [T("S", 10, "2026-02-01", "2026-02-05")]),
  C("summary progress/weight ignored in the gap: leaves 0% against a locked baseline -> At risk even though S says 100%", [
    T("S", 10, "2026-03-01", "2026-03-04", { progress: 100, weight: 50, baseline_start: "2026-03-01", baseline_end: "2026-03-08" }),
    T("C1", 20, "2026-03-01", "2026-03-04", { parent: "S", baseline_start: "2026-03-01", baseline_end: "2026-03-08" }),
    T("C2", 30, "2026-03-01", "2026-03-04", { parent: "S", baseline_start: "2026-03-01", baseline_end: "2026-03-08" })], [],
    { today: "2026-03-04", baselineLocked: true }),
  C("done summary (all leaves done) is a fixed predecessor: X starts today", [
    T("S", 10, "2026-02-01", "2026-02-20"), T("C1", 20, "2026-02-01", "2026-02-10", { parent: "S", progress: 100 }),
    T("C2", 30, "2026-02-11", "2026-02-20", { parent: "S", progress: 100 }), T("X", 40, "2026-03-09", "2026-03-11")], [{ task: "X", pred: "S", lag: 0, type: "FS" }]),
  C("FF into a summary is ignored (summary-link-approx); SS into it binds its leaves", [
    T("P", 10, "2026-03-09", "2026-03-13"), T("S", 20, "2026-03-09", "2026-03-09"), T("L1", 30, "2026-03-09", "2026-03-09", { parent: "S" }),
    T("Q", 40, "2026-03-09", "2026-03-11"), T("S2", 50, "2026-03-09", "2026-03-14"), T("L2", 60, "2026-03-09", "2026-03-14", { parent: "S2" })],
    [{ task: "S", pred: "P", lag: 4, type: "FF" }, { task: "S2", pred: "Q", lag: 2, type: "SS" }]),
  C("SF into a summary is ignored; SS and SF FROM a summary predecessor use its derived span", [
    T("S", 10, "2026-03-09", "2026-03-13"), T("L1", 20, "2026-03-09", "2026-03-13", { parent: "S" }), T("L2", 30, "2026-03-09", "2026-03-10", { parent: "S" }),
    T("Y", 40, "2026-03-09", "2026-03-11"), T("W", 50, "2026-03-09", "2026-03-11"), T("V", 60, "2026-03-09", "2026-03-20")],
    [{ task: "Y", pred: "S", lag: 1, type: "SS" }, { task: "W", pred: "S", lag: 0, type: "SF" }, { task: "S", pred: "V", lag: 0, type: "SF" }]),
  C("parent 2-cycle A<->B with leaf C under A: the closing edge is cut, nothing loops", [
    T("A", 10, "2026-03-09", "2026-03-13", { parent: "B" }), T("B", 20, "2026-03-09", "2026-03-11", { parent: "A" }), T("C", 30, "2026-03-09", "2026-03-12", { parent: "A" })]),
  C("parent 3-cycle A>B>C>A plus a link out of the cycle", [
    T("A", 10, "2026-03-09", "2026-03-13", { parent: "C" }), T("B", 20, "2026-03-09", "2026-03-11", { parent: "A" }),
    T("C", 30, "2026-03-09", "2026-03-12", { parent: "B" }), T("Z", 40, "2026-03-09", "2026-03-10")], [{ task: "Z", pred: "A", lag: 0, type: "FS" }]),
  C("a task that is its own parent stays a leaf", [T("A", 10, "2026-03-09", "2026-03-13", { parent: "A" })]),
  C("a parent that sits in another job is ignored (task stays a leaf)", [T("A", 10, "2026-03-09", "2026-03-13", { parent: OTHER }), T("B", 20, "2026-03-09", "2026-03-11")]),
  C("a link from a leaf to its own summary does not raise: one row, passes stop", [
    T("S", 10, "2026-03-09", "2026-03-13"), T("C1", 20, "2026-03-09", "2026-03-12", { parent: "S" })], [{ task: "S", pred: "C1", lag: 0, type: "FS" }]),
  // M2: a cycle made by the hierarchy (a link between a summary and its own leaf) keeps the stored link order, like JS; the follower chain N<-M<-L is
  // listed BEFORE the closing link, so visiting the links in rank order instead would let N see L's value of the same pass and end somewhere else
  C("cycle: a leaf linked to its own summary, with a follower chain: the stored link order decides what the passes leave", [
    T("S", 10, "2026-03-09", "2026-03-13"), T("L", 20, "2026-03-09", "2026-03-12", { parent: "S" }), T("M", 30, "2026-03-09", "2026-03-11"), T("N", 40, "2026-03-09", "2026-03-10")],
    [{ task: "N", pred: "M", lag: 0, type: "FS" }, { task: "M", pred: "L", lag: 0, type: "FS" }, { task: "S", pred: "L", lag: 0, type: "FS" }]),
  C("cycle: a summary linked to its own leaf, with a follower chain: the stored link order decides what the passes leave", [
    T("S", 10, "2026-03-09", "2026-03-13"), T("L", 20, "2026-03-09", "2026-03-12", { parent: "S" }), T("M", 30, "2026-03-09", "2026-03-11"), T("N", 40, "2026-03-09", "2026-03-10")],
    [{ task: "N", pred: "M", lag: 0, type: "FS" }, { task: "M", pred: "L", lag: 0, type: "FS" }, { task: "L", pred: "S", lag: 0, type: "FS" }]),
  // M2: a chain U1->...->U6 that FEEDS the cycle is stored backwards. Visited in stored order its push reaches L on pass 6, visited by rank on pass 1;
  // the cycle keeps growing until the pass cap, so the two orders leave different values (the engine must keep the stored order, like JS)
  C("cycle: a chain feeding a leaf that is linked to its own summary, stored backwards", [
    ...[1, 2, 3, 4, 5, 6].map((k) => T("U" + k, k * 10, "2026-03-09", "2026-03-19")),
    T("S", 70, "2026-03-09", "2026-03-13"), T("L", 80, "2026-03-09", "2026-03-12", { parent: "S" })],
    [...[6, 5, 4, 3, 2].map((k) => ({ task: "U" + k, pred: "U" + (k - 1), lag: 0, type: "FS" })), { task: "L", pred: "U6", lag: 0, type: "FS" }, { task: "S", pred: "L", lag: 0, type: "FS" }]),
  C("undated summary with dated leaves takes its span from the leaves", [
    T("S", 10, null, null), T("C1", 20, "2026-03-09", "2026-03-12", { parent: "S" }), T("C2", 30, "2026-03-10", "2026-03-16", { parent: "S" }), T("X", 40, "2026-03-09", "2026-03-10")],
    [{ task: "X", pred: "S", lag: 0, type: "FS" }]),
  C("dated summary over undated leaves: the leaves are unscheduled, the summary adds nothing", [
    T("S", 10, "2026-03-09", "2026-03-13"), T("C1", 20, null, null, { parent: "S" }), T("X", 30, "2026-03-09", "2026-03-10")], [{ task: "X", pred: "S", lag: 0, type: "FS" }]),
];
// link types the CHECK constraint refuses: run after the test drops the constraint; every one must behave as FS
const unchecked = ["ZZ", "ss", "FS ", "XX"].map((ty) => C(`unknown link_type '${ty}' behaves as FS`, [A, B], [{ task: "B", pred: "A", lag: 2, type: ty }]));
const fsRef = C("reference for the unknown-type cases: the same link as FS", [A, B], [{ task: "B", pred: "A", lag: 2, type: "FS" }]);

const toInput = (c) => ({
  tasks: c.tasks.map((t) => ({ id: t.key, sort_order: t.sort_order, start_date: t.start_date, end_date: t.end_date, progress: t.progress, is_milestone: t.is_milestone,
    weight: t.weight, baseline_start: t.baseline_start, baseline_end: t.baseline_end, phase_id: null, parent_task_id: t.parent == null ? null : t.parent === OTHER ? "other-job-task" : t.parent })),
  links: c.links.map((l) => ({ task_id: l.task, predecessor_id: l.pred, lag_days: l.lag, link_type: l.type })),
  phases: [], job: { status: c.job.status, due_date: c.job.due_date, baselineLocked: c.baselineLocked }, today: c.today });
const run = (c) => JSON.parse(JSON.stringify(M.jcSchedCompute(toInput(c))));
const fmt = (st, fe, slip) => `1:${st}|${fe ?? "null"}|${slip ?? "null"}`;
const jsExpect = (c) => { const r = run(c); return fmt(r.status, r.forecastEnd, r.slipDays); };
// Backward-pass probes: for each link type, the lag at which a started, overdue predecessor P flips from critical (At risk) to
// non-critical (On track), found with the JS engine; both sides of the boundary are asserted, for a plain predecessor and for P
// inside a summary S (backward FS/FF apply to the leaves of a summary predecessor, SS/SF are ignored). Any mutation of a backward
// formula by even one day moves one of the two sides.
const probeCase = (ty, lag, sum) => C(`probe ${sum ? "summary " : ""}${ty} lag ${lag}: overdue predecessor critical or not`, [
  ...(sum ? [T("S", 5, "2026-03-01", "2026-03-08")] : []),
  T("P", 10, "2026-03-01", "2026-03-08", { progress: 50, ...(sum ? { parent: "S" } : {}) }), T("Q", 20, "2026-03-12", "2026-03-14"), T("R", 30, "2026-03-10", "2026-03-30")],
  [{ task: "Q", pred: sum ? "S" : "P", lag, type: ty }], { today: "2026-03-10" });
for (const ty of ["FS", "SS", "FF", "SF"]) {
  let edge = null;
  for (let lag = -40; lag < 40 && edge == null; lag++) if (jsExpect(probeCase(ty, lag, false)) !== jsExpect(probeCase(ty, lag + 1, false))) edge = lag;
  if (edge == null) throw new Error("no boundary found for probe " + ty);
  for (const lag of [edge, edge + 1]) { targeted.push(probeCase(ty, lag, false)); targeted.push(probeCase(ty, lag, true)); }
}
const q = (s) => s.replaceAll("'", "''");
const pj = (c) => { const { name, expect, notes, ...rest } = c; return JSON.stringify(rest); };
const line = (c, exp) => `  PERFORM t_expect('${q(c.name)}', pg_temp.a2run($j$${pj(c)}$j$::jsonb), '${exp}');`;

const out1 = [], out2 = [];
for (const c of fixture.cases.filter((x) => x.name.startsWith("A2 "))) out1.push(line(c, fmt(c.expect.status, c.expect.forecastEnd, c.expect.slipDays)));
const seen = new Set();
for (const c of targeted) { if (seen.has(c.name)) throw new Error("dup " + c.name); seen.add(c.name); out1.push(line(c, jsExpect(c))); }
const ref = jsExpect(fsRef);
out2.push(line(fsRef, ref));
for (const c of unchecked) { const e = jsExpect(c); if (e !== ref) throw new Error("JS disagrees for " + c.name); out2.push(line(c, ref)); }

// What the Phase A body returns (forecast_end) for the A2 fixture cases that need link types / hierarchy: pinned in 15_before and 30_rollback.
const LEGACY = {
  "A2 SS link with lag 2": "2026-03-15", "A2 FF link with lag 0": "2026-03-10", "A2 SF link that does not bind": "2026-03-09",
  "A2 SF link that pushes the successor": "2026-03-11", "A2 mixed link types into one successor take the latest": "2026-03-14",
  "A2 SS on a started predecessor": "2026-03-10", "A2 hierarchy: a summary row carries no weight and no progress": "2026-03-20" };
const old = fixture.cases.filter((x) => LEGACY[x.name]).map((c) =>
  `  PERFORM t_expect('${q(c.name)} (Phase A forecast_end)', split_part(pg_temp.a2run($j$${pj(c)}$j$::jsonb), '|', 2), '${LEGACY[c.name]}');`);
if (old.length !== 7) throw new Error("expected 7 legacy-pinned fixture cases, got " + old.length);
const NL = String.fromCharCode(10), CRLF = String.fromCharCode(13, 10);
const lf = (s) => s.split(CRLF).join(NL);
const phaseA = lf(readFileSync(join(root, "supabase/migrations/202610210600_phase_a_sql.sql"), "utf8"));
const fa = phaseA.indexOf("CREATE OR REPLACE FUNCTION job_schedule_status(");
const ba = phaseA.indexOf("AS $$" + NL, fa) + 5, bb = phaseA.indexOf("$$;", ba);
const md5 = createHash("md5").update(phaseA.slice(ba, bb)).digest("hex");
const rd = (f) => lf(readFileSync(join(here, f), "utf8"));
const a2run = rd("a2run.sql");
const outs = {
  "20_after.sql": rd("20_after.template.sql").replace("-- @@A2RUN@@" + NL, () => a2run).replace("-- @@CASES@@", () => out1.join(NL)).replace("-- @@UNCHECKED@@", () => out2.join(NL)),
  "15_before.sql": rd("15_before.template.sql").replace("-- @@A2RUN@@" + NL, () => a2run).replace("-- @@OLD@@", () => old.join(NL)),
  "30_rollback.sql": rd("30_rollback.template.sql").replace("-- @@A2RUN@@" + NL, () => a2run).replace("-- @@OLD@@", () => old.join(NL)).replace("@@PHASEA_MD5@@", md5),
};
const check = process.argv.includes("--check");
let stale = false;
for (const [f, body] of Object.entries(outs)) {
  if (/-- @@[A-Z0-9]+@@|'@@PHASEA/.test(body)) throw new Error("unfilled marker in " + f);
  const target = join(here, f);
  if (check) {
    let cur = ""; try { cur = lf(readFileSync(target, "utf8")); } catch {}
    if (cur !== body) { console.error(f + " is stale: run node supabase/tests/a2a_status/gen-cases.mjs"); stale = true; }
  } else writeFileSync(target, body);
}
if (check) { if (stale) process.exit(1); console.log("generated files are up to date"); }
else console.log(`wrote 20_after.sql (${out1.length} cases + ${out2.length} unchecked-type cases), 15_before.sql, 30_rollback.sql; Phase A body md5 ${md5}`);
