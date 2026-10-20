// Tests for the shared Schedule v2 compute block. Run: node --test scripts/tests/schedule/compute.test.mjs
// The block between "// ── SCHEDULE COMPUTE (shared) ──" and "// ── END SCHEDULE COMPUTE ──" is sliced out of index.html
// and evaluated in a vm context that holds nothing but a Date that throws (the block must be pure). UI_SRC lets the
// mutation check (mutate.mjs) point at a mutated copy of index.html. Expected values live in fixture.json, derived by hand.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const BEGIN = "// ── SCHEDULE COMPUTE (shared) ──", END = "// ── END SCHEDULE COMPUTE ──";
const a = html.indexOf(BEGIN), b = html.indexOf(END);
assert.ok(a > 0 && b > a, "compute block markers not found in " + SRC);
const block = html.slice(a, b + END.length);
const fixture = JSON.parse(readFileSync(join(here, "fixture.json"), "utf8"));

// Date that throws on any use: the pure functions must never read the clock or build dates.
const NoDate = function () { throw new Error("Date used inside compute block"); };
for (const k of ["now", "UTC", "parse"]) NoDate[k] = () => { throw new Error("Date." + k + " used inside compute block"); };
function load() {
  const ctx = { Date: NoDate };
  vm.createContext(ctx);
  // trusted: sliced from this repo's own index.html
  return vm.runInContext(`(function(){\n${block}\nreturn { jcTaskWeight, jcPlannedPct, jcSchedCompute, jcSchedDay, jcSchedYmd,
    JC_SCHED_LATE_DAYS, JC_SCHED_GAP_PTS, JC_SCHED_LABELS };\n})()`, ctx);
}
const M = load();
const plain = (o) => JSON.parse(JSON.stringify(o));           // strip cross-realm prototypes so deepStrictEqual works
const run = (input) => plain(M.jcSchedCompute(input));

function toInput(c) {
  return {
    tasks: c.tasks.map((t) => ({ id: t.key, sort_order: t.sort_order, start_date: t.start_date, end_date: t.end_date, progress: t.progress,
      is_milestone: t.is_milestone, weight: t.weight, baseline_start: t.baseline_start, baseline_end: t.baseline_end, phase_id: null })),
    links: c.links.map((l) => ({ task_id: l.task, predecessor_id: l.pred, lag_days: l.lag })),
    phases: [], job: { status: c.job.status, due_date: c.job.due_date, baselineLocked: c.baselineLocked }, today: c.today,
  };
}

// ---------- shared fixture ----------
test("fixture has at least 30 cases with unique names and the exact contract keys", () => {
  assert.ok(fixture.cases.length >= 30);
  assert.equal(new Set(fixture.cases.map((c) => c.name)).size, fixture.cases.length);
  for (const c of fixture.cases) {
    assert.deepEqual(Object.keys(c).sort(), ["baselineLocked", "expect", "job", "links", "name", "notes", "tasks", "today"]);
    assert.deepEqual(Object.keys(c.expect).sort(), ["forecastEnd", "overall", "overallDisplay", "plannedDisplay", "plannedToday", "slipDays", "status"]);
    assert.ok(c.notes.length > 40, "hand derivation missing in " + c.name);
  }
});
for (const c of fixture.cases) {
  test("fixture: " + c.name, () => {
    const r = run(toInput(c)), e = c.expect;
    assert.deepEqual({ overall: r.overall, overallDisplay: r.overallDisplay, plannedToday: r.plannedToday, plannedDisplay: r.plannedDisplay,
      forecastEnd: r.forecastEnd, status: r.status, slipDays: r.slipDays }, e);
    assert.deepEqual(r.warnings, []);
  });
}

// ---------- critical path (hand derived, see the fixture notes of the same cases) ----------
const caseByName = (n) => fixture.cases.find((c) => c.name.startsWith(n));
const critOf = (n) => run(toInput(caseByName(n))).crit.slice().sort();
test("critical sets and slack", () => {
  assert.deepEqual(critOf("diamond"), ["A", "C", "D"]);                       // B has 4 days of slack
  assert.deepEqual(critOf("single chain"), ["B", "C"]);                       // A is started and ahead: slack 4
  assert.deepEqual(critOf("due date earlier than forecast"), ["A", "B"]);
  assert.deepEqual(critOf("due date later than forecast"), ["A", "B"]);       // min-slack path, C is not
  assert.deepEqual(critOf("due_date sets the deadline"), ["X", "Y"]);
  assert.deepEqual(critOf("same jobs without due_date"), ["Y"]);
  assert.deepEqual(critOf("overdue NON-critical"), ["T"]);
  assert.deepEqual(critOf("all complete, no due"), []);                       // done tasks are never critical
  assert.deepEqual(run(toInput(caseByName("diamond"))).slackByTask, { A: 0, B: 4, C: 0, D: 0 });
  assert.equal(run(toInput(caseByName("single chain"))).slackByTask.A, 4);
  assert.deepEqual(run(toInput(caseByName("all complete, no due"))).slackByTask, {});
  assert.deepEqual(run(toInput(caseByName("due date later than forecast"))).slackByTask, { A: 13, B: 13, C: 17 });
  assert.deepEqual(run(toInput(caseByName("due date earlier than forecast"))).slackByTask, { A: -3, B: -3 });
});

// ---------- helpers ----------
test("jcTaskWeight mirrors SQL job_task_weight", () => {
  const w = M.jcTaskWeight;
  assert.equal(w(true, 50, "2026-03-04", "2026-03-04"), 0);                   // milestone always 0, even with a weight
  assert.equal(w(true, null, null, null), 0);
  assert.equal(w(false, null, "2026-03-01", "2026-03-10"), 10);               // NULL weight = duration
  assert.equal(w(false, undefined, "2026-03-01", "2026-03-01"), 1);           // same day = 1
  assert.equal(w(false, null, null, null), 1);                                // undated = 1
  assert.equal(w(false, null, "2026-03-01", null), 1);                        // half dated = 1
  assert.equal(w(false, 8, "2026-03-01", "2026-03-02"), 8);                   // explicit wins
  assert.equal(w(false, 0, "2026-03-01", "2026-03-10"), 0);                   // explicit 0 stays 0
  assert.equal(w(false, 7.25, null, null), 7.25);                             // unrounded
  assert.equal(w(false, "3.5", null, null), 3.5);                             // numeric string from PostgREST
  assert.equal(w(false, NaN, "2026-03-01", "2026-03-03"), 3);                 // junk weight = NULL
  assert.equal(w(false, null, "2026-03-10", "2026-03-01"), 1);                // never below 1
  assert.equal(w(false, null, "2026-02-27", "2026-03-02"), 4);                // month boundary 27,28,1,2
});
test("jcPlannedPct mirrors SQL job_task_planned_pct (unrounded, clamped, baseline fallback)", () => {
  const p = M.jcPlannedPct;
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", "2026-03-06"), 60);
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", "2026-02-20"), 0);   // clamp low
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", "2026-03-01"), 10);  // first day counts
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", "2026-03-10"), 100);
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", "2026-04-20"), 100); // clamp high
  assert.equal(p("2026-03-01", "2026-03-04", "2026-03-01", "2026-03-30", "2026-03-02"), 50);   // baseline wins over current
  assert.equal(p("2026-03-01", null, "2026-03-01", "2026-03-04", "2026-03-02"), 50);           // end falls back per column
  assert.equal(p(null, "2026-03-04", "2026-03-01", "2026-03-30", "2026-03-02"), 50);           // start falls back per column
  assert.equal(p(null, null, null, null, "2026-03-02"), 0);                   // no dates
  assert.equal(p("2026-03-01", null, null, null, "2026-03-02"), 0);           // only one side available
  assert.equal(p(null, null, "2026-03-05", "2026-03-01", "2026-03-05"), 100);  // end<start: dur floors at 1
  const x = p(null, null, "2026-03-01", "2026-03-03", "2026-03-01");
  assert.ok(Math.abs(x - 100 / 3) < 1e-12 && x !== 33.33, "must stay unrounded");
  assert.equal(p(null, null, "2026-03-01", "2026-03-10", null), 0);           // junk "on" = 0, no throw
});
test("day helpers: exact calendar arithmetic with no Date", () => {
  const d = M.jcSchedDay, y = M.jcSchedYmd;
  assert.equal(d("2026-03-01") - d("2026-02-28"), 1);
  assert.equal(d("2028-03-01") - d("2028-02-28"), 2);                         // leap year
  assert.equal(d("2026-11-02") - d("2026-11-01"), 1);                         // DST change days in the US/EU
  assert.equal(d("2026-03-29") - d("2026-03-28"), 1);
  assert.equal(d("2027-01-01") - d("2026-01-01"), 365);
  assert.equal(d("1970-01-01"), 0);
  for (let n = d("1999-12-25"); n < d("2001-03-05"); n += 1) assert.equal(d(y(n)), n);
  assert.equal(y(d("2028-02-29")), "2028-02-29");
  assert.equal(y(d("2026-03-08") + 30), "2026-04-07");
  assert.equal(d("2026-03-01T10:00:00Z"), d("2026-03-01"));                   // timestamps tolerated
  for (const bad of [null, undefined, "", "x", "2026-13-01", "2026-00-10", "2026-03-00"]) assert.equal(d(bad), null);
  assert.equal(y(null), null);
});

// ---------- structure rules ----------
test("determinism: same input twice, input not mutated, clock never touched", () => {
  const input = toInput(caseByName("diamond"));
  const deepFreeze = (o) => { if (o && typeof o === "object" && !Object.isFrozen(o)) { Object.freeze(o); Object.values(o).forEach(deepFreeze); } return o; };
  const snapshot = JSON.stringify(input);
  deepFreeze(input);                                                          // a write to the input would throw or be lost
  const r1 = run(input), r2 = run(input);
  assert.deepEqual(r1, r2);
  assert.equal(JSON.stringify(input), snapshot);
  for (const cs of fixture.cases) assert.deepEqual(run(toInput(cs)), run(toInput(cs)));
});
test("a dependency cycle never throws: warnings:['cycle'] and a finished result", () => {
  const mk = (id, s, e) => ({ id, start_date: s, end_date: e, progress: 0, is_milestone: false });
  const input = { tasks: [mk("a", "2026-03-01", "2026-03-03"), mk("b", "2026-03-04", "2026-03-06"), mk("c", "2026-03-07", "2026-03-09")],
    links: [{ task_id: "b", predecessor_id: "a", lag_days: 0 }, { task_id: "c", predecessor_id: "b", lag_days: 0 }, { task_id: "a", predecessor_id: "c", lag_days: 0 }],
    phases: [], job: { status: "In Progress", due_date: "2026-03-20" }, today: "2026-03-01" };
  const r = run(input);
  assert.deepEqual(r.warnings, ["cycle"]);
  assert.ok(Object.values(plain(M.JC_SCHED_LABELS)).includes(r.status));
  assert.ok(typeof r.overall === "number" && Number.isFinite(r.overall));
  const self = run({ ...input, links: [{ task_id: "a", predecessor_id: "a", lag_days: 2 }] });   // self-link
  assert.deepEqual(self.warnings, ["cycle"]);
  const flat = run({ tasks: [{ id: "m1", start_date: "2026-03-01", end_date: "2026-03-01", progress: 0, is_milestone: true }, { id: "m2", start_date: "2026-03-01", end_date: "2026-03-01", progress: 0, is_milestone: true }],
    links: [{ task_id: "m1", predecessor_id: "m2", lag_days: 0 }, { task_id: "m2", predecessor_id: "m1", lag_days: 0 }], job: {}, today: "2026-03-01" });
  assert.deepEqual(flat.warnings, []);                                        // zero-length cycle: nothing ever moves, terminates quietly
  assert.equal(flat.forecastEnd, "2026-03-01");
});
test("index.html carries exactly ONE compute implementation", () => {
  assert.equal(html.split("function jcSchedCompute").length - 1, 1);
  assert.equal(html.split("function jcTaskWeight").length - 1, 1);
  assert.equal(html.split("function jcPlannedPct").length - 1, 1);
  assert.equal(html.split(BEGIN).length - 1, 1);
  assert.equal(html.split(END).length - 1, 1);
  const gap = html.indexOf("async function jcLoadTasks()") - html.indexOf(END);
  assert.ok(gap > 0, "block must sit above jcLoadTasks (other leaves add their own delimited blocks between the two)");
  assert.ok(!/function (jcSchedCompute|jcTaskWeight|jcPlannedPct)/.test(html.slice(html.indexOf(END) + END.length, html.indexOf("async function jcLoadTasks()"))), "no second compute implementation below the block");
  assert.ok(block.split("\n").length < 400);
});
test("block is DOM-free and clock-free", () => {
  const code = block.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
  for (const bad of ["document.", "window.", "fetch(", "new Date", "Date.", "localStorage", "sb(", "await "]) assert.ok(!code.includes(bad), bad);
});
test("mirrored constants and labels equal the SQL source of truth", () => {
  assert.equal(M.JC_SCHED_LATE_DAYS, 5);
  assert.equal(M.JC_SCHED_GAP_PTS, 10);
  assert.deepEqual(Object.values(plain(M.JC_SCHED_LABELS)).sort(), ["At risk", "Complete", "Late", "On hold", "On track"]);
  const spec = readFileSync(join(root, "docs", "specs", "project-portal", "phase-a-schedule-v2.md"), "utf8");
  assert.equal(+/k_late_days\s+constant integer := (\d+)/.exec(spec)[1], 5);
  assert.equal(+/k_gap_pts\s+constant integer := (\d+)/.exec(spec)[1], 10);
  for (const l of ["On track", "At risk", "Late", "Complete", "On hold"]) assert.ok(spec.includes("'" + l + "'"), l);
  assert.ok(block.includes("keep equal to SQL job_schedule_status"));
});

// ---------- adversarial inputs ----------
const t0 = (o) => ({ id: "t", start_date: "2026-03-01", end_date: "2026-03-05", progress: 0, is_milestone: false, ...o });
const job0 = { status: "In Progress", due_date: null };
test("empty and missing arrays, junk values: no throw, sane output", () => {
  const e = run({ today: "2026-03-01" });
  assert.deepEqual([e.overall, e.plannedToday, e.forecastEnd, e.slipDays, e.status, e.crit, e.warnings], [0, 0, null, null, "On track", [], []]);
  assert.throws(() => M.jcSchedCompute({ tasks: [], today: undefined }), /today/);
  const r = run({ tasks: [t0({ progress: null }), t0({ id: "u", progress: undefined, start_date: undefined, end_date: null }), t0({ id: "n", progress: NaN })], links: null, phases: null, job: job0, today: "2026-03-02" });
  assert.equal(r.overall, 0);
  assert.ok(Number.isFinite(r.plannedToday));
  const zero = run({ tasks: [t0({ weight: 0, progress: 50 })], job: job0, today: "2026-03-02" });
  assert.deepEqual([zero.overall, zero.plannedToday], [0, 0]);                // explicit weight 0 = excluded, SUM(w)=0
});
test("links to unknown tasks (other jobs) are ignored, null lag counts as 0, tasks absent from links schedule normally", () => {
  const base = { tasks: [t0({ id: "a" }), t0({ id: "b", start_date: "2026-03-06", end_date: "2026-03-08" })], job: job0, today: "2026-03-01" };
  const r0 = run({ ...base, links: [] });
  const r1 = run({ ...base, links: [{ task_id: "b", predecessor_id: "zzz-other-job", lag_days: 3 }, { task_id: "nope", predecessor_id: "a", lag_days: 0 }, null, {}] });
  assert.deepEqual(r1, r0);
  assert.equal(r0.forecastEnd, "2026-03-06");                                 // a ef 03-06, b ef 03-01+3 = 03-04
  const r2 = run({ ...base, links: [{ task_id: "b", predecessor_id: "a", lag_days: null }] });
  assert.equal(r2.forecastEnd, "2026-03-09");                                 // a ef 03-06 -> b es 03-06, ef 03-09
});
test("junk entries (null task, task without id, empty link) cannot crash or create phantom links", () => {
  const r = run({ tasks: [null, { start_date: "2026-03-01", end_date: "2026-03-03", progress: 0 }, t0({ id: "k" })], links: [{}, { task_id: "k" }, { predecessor_id: "k" }, undefined],
    phases: [{ id: "p" }], job: job0, today: "2026-03-01" });
  assert.deepEqual(r.warnings, []);
  assert.equal(r.forecastEnd, "2026-03-06");
  assert.equal(r.phaseRollups.at(-1).taskCount, 3);                           // loose bucket holds all three, null one included
});
test("progress 0 / 100 / mid, and a started task with only an end date", () => {
  const r = run({ tasks: [t0({ id: "x", progress: 100 }), t0({ id: "y", progress: 50, start_date: null, end_date: "2026-03-05" })], job: job0, today: "2026-03-02" });
  assert.equal(r.overall, 91.67);                                             // w5 p100, w1 p50 (half dated => dur 1): 550/6
  assert.equal(r.overallDisplay, 92);
  assert.equal(r.forecastEnd, "2026-03-05");                                  // x done ef 03-05; y not scheduled (one date only)
});
test("phase rollups use the same formula per phase, with a loose bucket for unphased tasks", () => {
  const tasks = [t0({ id: "a", phase_id: "p1", progress: 100 }), t0({ id: "b", phase_id: "p2", progress: 0, start_date: "2026-03-06", end_date: "2026-03-10" }), t0({ id: "c", phase_id: null, progress: 50 })];
  const r = run({ tasks, phases: [{ id: "p2", sort_order: 20 }, { id: "p1", sort_order: 10 }, { id: "p3", sort_order: 30 }], job: job0, today: "2026-03-03" });
  assert.deepEqual(r.phaseRollups.map((p) => p.phase_id), ["p1", "p2", "p3", null]);   // by sort_order, loose last
  assert.deepEqual(r.phaseRollups.map((p) => [p.overall, p.plannedToday, p.taskCount]), [[100, 60, 1], [0, 0, 1], [0, 0, 0], [50, 60, 1]]);
  assert.deepEqual([r.phaseRollups[1].start, r.phaseRollups[1].end], ["2026-03-06", "2026-03-10"]);
  assert.equal(r.phaseRollups[0].overallDisplay, 100);
  assert.equal(r.overall, 50);                                                // (500+0+250)/15
});
test("200-task job computes in well under 100 ms", () => {
  const tasks = [], links = [];
  const day = (n) => "2026-" + String(3 + Math.floor((n - 1) / 28)).padStart(2, "0") + "-" + String(((n - 1) % 28) + 1).padStart(2, "0");
  for (let i = 0; i < 200; i++) {
    const s = 1 + (i % 25);
    tasks.push({ id: "t" + i, start_date: day(s + i), end_date: day(s + i + 3), progress: i % 4 === 0 ? 100 : (i * 7) % 90, is_milestone: i % 50 === 49, weight: null, phase_id: "p" + (i % 5) });
    if (i > 0) links.push({ task_id: "t" + i, predecessor_id: "t" + (i - 1), lag_days: i % 3 });
    if (i > 10) links.push({ task_id: "t" + i, predecessor_id: "t" + (i - 10), lag_days: 0 });
  }
  const input = { tasks, links, phases: [0, 1, 2, 3, 4].map((k) => ({ id: "p" + k, sort_order: k })), job: { status: "In Progress", due_date: "2026-12-31" }, today: "2026-04-01" };
  M.jcSchedCompute(input);                                                    // warm up
  const t = performance.now(); const r = M.jcSchedCompute(input); const ms = performance.now() - t;
  assert.ok(ms < 100, "took " + ms + " ms");
  assert.deepEqual(plain(r.warnings), []);
});
