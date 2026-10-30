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
// r3 summary perf: shapes that exercise the summary / hierarchy paths of the sweep (acyclic) AND of the pass loop (any hierarchy-induced
// cycle in the job). Expectations come from the JS engine. Every case below is also emitted as a "+cyc" variant (see after).
{
  const D = (d) => "2026-03-" + String(d).padStart(2, "0");
  const types = ["FS", "SS", "FF", "SF"];
  for (const ty of types) {
    // reversed chain inside a summary (kid g after kid g+1), links of type ty INTO the summary from two outsiders (one later, one earlier)
    // and OUT of it to a leaf; the chain is against array order so the pass loop would need several passes.
    const kids = [1, 2, 3, 4, 5].map((g) => T("K" + g, 20 + g, D(9), D(10 + g), { parent: "S" }));
    targeted.push(C(`summary r3 ${ty}: reversed FS chain inside S, two outsiders into S, S out to leaf`, [
      T("S", 10, D(9), D(20)), ...kids, T("O1", 40, D(16), D(20)), T("O2", 41, D(9), D(11)), T("Z", 50, D(9), D(11))],
      [{ task: "K1", pred: "K2", lag: 0, type: "FS" }, { task: "K2", pred: "K3", lag: 1, type: "FS" }, { task: "K3", pred: "K4", lag: 0, type: "FS" },
       { task: "K4", pred: "K5", lag: -1, type: "FS" }, { task: "S", pred: "O1", lag: 2, type: ty }, { task: "S", pred: "O2", lag: 0, type: ty },
       { task: "Z", pred: "S", lag: 1, type: ty }], { today: D(10) }));
    // nested summaries G > P > (L1, L2), a leaf outside, links of type ty into G, into P, out of P and out of G, leaf-to-leaf across
    targeted.push(C(`summary r3 ${ty}: nested G > P, links into and out of both levels`, [
      T("G", 10, D(9), D(25)), T("P", 20, D(9), D(20), { parent: "G" }), T("L1", 30, D(9), D(12), { parent: "P" }), T("L2", 31, D(9), D(14), { parent: "P" }),
      T("L3", 32, D(9), D(11), { parent: "G", progress: 50 }), T("X", 40, D(15), D(18)), T("Y", 41, D(9), D(10)), T("W", 42, D(9), D(12)), T("V", 43, D(20), D(22))],
      [{ task: "G", pred: "X", lag: 1, type: ty }, { task: "P", pred: "Y", lag: 3, type: ty }, { task: "W", pred: "P", lag: 0, type: ty },
       { task: "V", pred: "G", lag: -1, type: ty }, { task: "L2", pred: "L1", lag: 0, type: ty }, { task: "X", pred: "L3", lag: 0, type: ty }], { today: D(10) }));
  }
  targeted.push(C("summary r3: summary into summary, chained S1 > S2 > S3 (FS), each with a leaf", [
    T("S1", 10, D(9), D(12)), T("A1", 11, D(9), D(12), { parent: "S1" }), T("S2", 20, D(9), D(12)), T("A2", 21, D(9), D(12), { parent: "S2" }),
    T("S3", 30, D(9), D(12)), T("A3", 31, D(9), D(12), { parent: "S3" })],
    [{ task: "S2", pred: "S1", lag: 0, type: "FS" }, { task: "S3", pred: "S2", lag: 2, type: "FS" }], { today: D(9) }));
  targeted.push(C("summary r3: leaf of S is the predecessor of a link into its own sibling-less summary parent (non-settling, passes cut off)", [
    T("S", 10, D(9), D(11)), T("A", 20, D(9), D(11), { parent: "S" }), T("B", 21, D(9), D(11), { parent: "S" }), T("O", 30, D(9), D(11))],
    [{ task: "S", pred: "A", lag: 0, type: "FS" }, { task: "B", pred: "O", lag: 0, type: "FS" }], { today: D(9) }));
  targeted.push(C("summary r3: non-settling SS cycle through the hierarchy with a later leaf (ascending-index order inside one link)", [
    T("S", 10, D(9), D(11)), T("A", 20, D(9), D(11), { parent: "S" }), T("B", 21, D(9), D(11), { parent: "S" }), T("C", 22, D(9), D(11), { parent: "S" })],
    [{ task: "S", pred: "B", lag: 1, type: "SS" }], { today: D(9) }));
  targeted.push(C("summary r3: empty-ish job, two undated tasks one child of the other", [T("S", 10, null, null), T("A", 20, null, null, { parent: "S" })], [], { today: D(9) }));
}
// Seeded random graphs (fixed seed, so the file is reproducible): small hierarchies (parents usually earlier, sometimes ANY task = hierarchy
// cycles / links into the own summary), every link type, lags -2..4, started / done / undated / overdue tasks, today past many ends so the
// backward pass decides "late critical". Direct link cycles and duplicate links are skipped (the SQL guards refuse them). JS gives the answer.
{
  let st = 20261029;
  const rnd = () => { st |= 0; st = (st + 0x6d2b79f5) | 0; let t = Math.imul(st ^ (st >>> 15), 1 | st); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const ri = (n) => Math.floor(rnd() * n), D = (d) => "2026-03-" + String(d).padStart(2, "0");
  for (let k = 0; k < 360; k++) {
    const n = 4 + ri(6), keys = Array.from({ length: n }, (_, i) => "R" + i), tasks = [];
    for (let i = 0; i < n; i++) {
      const sd = 1 + ri(14), und = rnd() < 0.08, pr = rnd(), prog = pr < 0.5 ? 0 : pr < 0.75 ? 10 + ri(80) : 100;
      const par = rnd() < 0.55 ? keys[Math.max(0, i - 1 - ri(3))] : undefined;
      tasks.push(T(keys[i], ri(50) * 10 + i, und ? null : D(sd), und ? null : D(sd + ri(8)), { progress: prog, ...(par && par !== keys[i] ? { parent: par } : {}) }));
    }
    const links = [], seenL = new Set(), adj = new Map(keys.map((x) => [x, []]));
    const reach = (a, b) => { const st2 = [a], vis = new Set(); while (st2.length) { const x = st2.pop(); if (x === b) return true; if (vis.has(x)) continue; vis.add(x); st2.push(...adj.get(x)); } return false; };
    for (let l = ri(2 * n); l >= 0; l--) {
      const t = keys[ri(n)], p = keys[ri(n)], key = t + ">" + p;
      const anc = (x) => { const o = new Set(); let c = tasks.find((q2) => q2.key === x); while (c && c.parent && !o.has(c.parent)) { o.add(c.parent); c = tasks.find((q2) => q2.key === c.parent); } return o; };
      if (t === p || seenL.has(key) || reach(t, p) || anc(t).has(p) || anc(p).has(t)) continue;   // ancestor <-> descendant links do not settle: JS and SQL then differ by leaf order (pre-existing, covered by diff-vs-old.sh)
      seenL.add(key); adj.get(p).push(t);   // edge p -> t (t is the successor); a link cycle needs a path t ->* p already
      links.push({ task: t, pred: p, lag: ri(7) - 2, type: ["FS", "SS", "FF", "SF"][ri(4)] });
    }
    targeted.push(C(`random r3 #${k}`, tasks, links, { today: D(10 + ri(20)) }));
  }
  // a done successor keeps its dates: a later predecessor must not move it (and so not the forecast)
  targeted.push(C("done leaf with a later predecessor is not pushed", [T("A", 10, D(9), D(12), { progress: 100 }), T("B", 20, D(16), D(25))], [{ task: "A", pred: "B", lag: 0, type: "FS" }], { today: D(10) }));
  targeted.push(C("done leaf inside a summary with a link into the summary is not pushed", [T("S", 5, D(9), D(12)), T("A", 10, D(9), D(12), { progress: 100, parent: "S" }),
    T("A2", 11, D(9), D(11), { parent: "S" }), T("B", 20, D(16), D(25))], [{ task: "S", pred: "B", lag: 0, type: "FS" }], { today: D(10) }));
}
// PINNED cases (second seeded generator): hierarchies with cycles, links between a task and its ancestor / descendant (non-settling passes,
// ascending-leaf-order effects). JS and the SQL engine differ on those by leaf order (pre-existing), so the expectation here is what the
// PRE-CHANGE SQL function returned (pinned-old.json, written by pin-old.sh against git HEAD~ of the migration): the new body must
// reproduce it exactly. Regenerate the pins only against a pre-change body:  node gen-cases.mjs --dump-pinned && bash pin-old.sh [ref]
const pinnedCases = [];
{
  let st = 77310029;
  const rnd = () => { st |= 0; st = (st + 0x6d2b79f5) | 0; let t = Math.imul(st ^ (st >>> 15), 1 | st); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const ri = (n) => Math.floor(rnd() * n), D = (d) => "2026-03-" + String(d).padStart(2, "0");
  for (let k = 0; k < 220; k++) {
    const n = 3 + ri(7), keys = Array.from({ length: n }, (_, i) => "P" + i), tasks = [];
    for (let i = 0; i < n; i++) {
      const sd = 1 + ri(14), und = rnd() < 0.06, pr = rnd(), prog = pr < 0.5 ? 0 : pr < 0.75 ? 10 + ri(80) : 100;
      const par = rnd() < 0.6 ? (rnd() < 0.8 ? keys[Math.max(0, i - 1 - ri(3))] : keys[ri(n)]) : undefined;
      tasks.push(T(keys[i], ri(50) * 10 + i, und ? null : D(sd), und ? null : D(sd + ri(8)), { progress: prog, ...(par && par !== keys[i] ? { parent: par } : {}) }));
    }
    const links = [], seenL = new Set(), adj = new Map(keys.map((x) => [x, []]));
    const reach = (a, b) => { const st2 = [a], vis = new Set(); while (st2.length) { const x = st2.pop(); if (x === b) return true; if (vis.has(x)) continue; vis.add(x); st2.push(...adj.get(x)); } return false; };
    for (let l = 1 + ri(2 * n); l >= 0; l--) {
      let t = keys[ri(n)], p = keys[ri(n)];
      if (rnd() < 0.4) { const kid = tasks.filter((x) => x.parent).map((x) => x); if (kid.length) { const c = kid[ri(kid.length)]; if (rnd() < 0.5) { t = c.parent; p = c.key; } else { t = c.key; p = c.parent; } } }
      const key = t + ">" + p;
      if (t === p || seenL.has(key) || reach(t, p)) continue;
      seenL.add(key); adj.get(p).push(t);
      links.push({ task: t, pred: p, lag: ri(7) - 2, type: ["FS", "SS", "FF", "SF"][ri(4)] });
    }
    pinnedCases.push(C(`pinned r3 #${k}`, tasks, links, { today: D(10 + ri(20)) }));
  }
}
{
  const D = (d) => "2026-03-" + String(d).padStart(2, "0");
  for (const ty of ["SS", "SF"]) targeted.push(C(`summary r3 backward: ${ty} from a summary predecessor is ignored (an applied bound would make its overdue leaf critical)`, [
    T("S", 5, D(1), D(1)), T("P", 10, D(1), D(8), { progress: 50, parent: "S" }), T("Q", 20, D(12), D(14))],
    [{ task: "Q", pred: "S", lag: ty === "SS" ? 27 : 30, type: ty }], { today: D(12), job: { status: "In Progress", due_date: "2026-03-31" } }));
  for (const ty of ["FS", "FF"]) {
    // nested G > P > L (L overdue, started): a tight bound on P and a loose one on G; L must take the tighter (min), whichever the order of the links
    const mk = (tight, loose, order) => C(`summary r3 backward ${ty}: nested bounds, tight on ${tight}, loose on ${loose} (links ${order})`, [
      T("G", 5, D(1), D(8)), T("P", 6, D(1), D(8), { parent: "G" }), T("L", 10, D(1), D(8), { progress: 50, parent: "P" }), T("R", 30, D(10), D(30)),
      T("Q1", 20, D(12), D(14)), T("Q2", 21, D(12), D(14))],
      [{ task: "Q1", pred: tight, lag: 45, type: ty }, { task: "Q2", pred: loose, lag: 0, type: ty }].sort(() => (order === "rev" ? 1 : 0)).reverse(), { today: D(10) });
    for (const [a, b] of [["P", "G"], ["G", "P"]]) for (const o of ["fwd", "rev"]) targeted.push(mk(a, b, o));
  }
  // several links from one summary predecessor: the tightest bound wins
  targeted.push(C("summary r3 backward: two FS links out of one summary, the tighter one binds its overdue leaf", [
    T("S", 5, D(1), D(8)), T("P", 10, D(1), D(8), { progress: 50, parent: "S" }), T("R", 30, D(10), D(30)), T("Q1", 20, D(12), D(14)), T("Q2", 21, D(12), D(14))],
    [{ task: "Q1", pred: "S", lag: 0, type: "FS" }, { task: "Q2", pred: "S", lag: 45, type: "FS" }], { today: D(10) }));
  targeted.push(C("summary r3 backward: two FS links out of one summary, the tighter one listed first", [
    T("S", 5, D(1), D(8)), T("P", 10, D(1), D(8), { progress: 50, parent: "S" }), T("R", 30, D(10), D(30)), T("Q1", 20, D(12), D(14)), T("Q2", 21, D(12), D(14))],
    [{ task: "Q2", pred: "S", lag: 45, type: "FS" }, { task: "Q1", pred: "S", lag: 0, type: "FS" }], { today: D(10) }));
  // a done leaf with a later predecessor must not be pushed by a link
  // backward cascade inside one link: B is both a leaf of S and the successor of S (JS and SQL differ here by leaf order: pinned to the pre-change SQL below)
  for (const ty of ["FS", "FF"]) for (const lag of [1, 5, 10, 20, 30, 40, 55, 70, 90, 120]) for (const pos of [0, 1, 2]) {
    const ks = ["A", "B", "C"], tk = ks[pos];
    pinnedCases.push(C(`pinned r3 backward cascade ${ty} lag ${lag} succ ${tk}`, [
      T("S", 1, D(1), D(8)), ...ks.map((k, i) => T(k, 10 + i, D(4 + i), D(8 + i), { progress: 50, parent: "S" })), T("R", 30, D(10), D(30))],
      [{ task: tk, pred: "S", lag, type: ty }], { today: D(12) }));
  }
}
// Backward cascade inside one link (a leaf t that is the successor of its own summary p: p's leaves after t see t's lowered bound). 14 cases found by
// a seeded search for inputs on which a variant without the cascade differs from the pre-change body; stored as data, pins from the pre-change body.
for (const c of JSON.parse(readFileSync(join(here, "cascade-cases.json"), "utf8"))) pinnedCases.push(c);
// "+cyc" variants: the same case plus an undated summary Qs with an undated done kid Qk and a link Qs <- Qk (a leaf into its own summary).
// That cycle only exists through the hierarchy, so the whole job takes the pass loop (not the topological sweep); the result must not change.
{
  const withCyc = (c) => ({ ...c, name: c.name + " +cyc", tasks: [...c.tasks, T("Qs", 9990, null, null), T("Qk", 9991, null, null, { parent: "Qs", progress: 100 })],
    links: [...(c.links || []), { task: "Qs", pred: "Qk", lag: 0, type: "FS" }] });
  const base = [...fixture.cases.filter((x) => x.name.startsWith("A2 ")), ...targeted];
  for (const c of base) targeted.push(withCyc(c));
}
const q = (s) => s.replaceAll("'", "''");
const pj = (c) => { const { name, expect, notes, ...rest } = c; return JSON.stringify(rest); };
const line = (c, exp) => `  PERFORM t_expect('${q(c.name)}', pg_temp.a2run($j$${pj(c)}$j$::jsonb), '${exp}');`;

if (process.argv.includes("--dump-pinned")) {
  const pj2 = (c) => { const { name, expect, notes, ...rest } = c; return { name, json: JSON.stringify(rest), today: c.today }; };
  writeFileSync(join(here, "pinned-cases.json"), JSON.stringify(pinnedCases.map(pj2)));
  console.log("wrote pinned-cases.json (" + pinnedCases.length + " cases)"); process.exit(0);
}
const pinnedExp = JSON.parse(readFileSync(join(here, "pinned-old.json"), "utf8"));
const out1 = [], out2 = [];
for (const c of fixture.cases.filter((x) => x.name.startsWith("A2 "))) out1.push(line(c, fmt(c.expect.status, c.expect.forecastEnd, c.expect.slipDays)));
const seen = new Set();
for (const c of targeted) { if (seen.has(c.name)) throw new Error("dup " + c.name); seen.add(c.name); out1.push(line(c, jsExpect(c))); }
for (const c of pinnedCases) { if (pinnedExp[c.name] == null) throw new Error("no pinned value for " + c.name + ": run pin-old.sh"); out1.push(line(c, pinnedExp[c.name])); }
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
