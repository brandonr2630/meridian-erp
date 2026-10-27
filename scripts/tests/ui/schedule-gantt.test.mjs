// Tests for the Phase A custom per-job Gantt (index.html, SCHEDULE GANTT RENDERER block). Run: node --test scripts/tests/ui/schedule-gantt.test.mjs
// index.html is one big inline script, so the code under test is sliced out of it (the shared SCHEDULE COMPUTE block it builds on plus
// the renderer block) and run in a node:vm context against a tiny fake DOM. UI_SRC lets the mutation check point at a mutated copy.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const cStart = html.indexOf("// ── SCHEDULE COMPUTE (shared) ──");
const gStart = html.indexOf("// ── SCHEDULE GANTT RENDERER ──");
const gEnd = html.indexOf("// ── END SCHEDULE GANTT RENDERER ──");
assert.ok(cStart > 0 && gStart > cStart && gEnd > gStart, "could not slice the code under test");
const code = html.slice(cStart, gStart);
const gBlock = html.slice(gStart, gEnd);

// ---------- fake DOM: createElement / createElementNS / setAttribute / appendChild / textContent; innerHTML records and rejects ----------
function makeDom() {
  const innerHTMLWrites = [];
  const byId = {};
  class Node {
    constructor(tag, ns) { this.tagName = tag; this.ns = ns || "html"; this.children = []; this.attrs = {}; this.listeners = {}; this.style = {}; this.className = ""; this.scrollLeft = 0; this.scrollTop = 0; this.clientWidth = 1000; this.parent = null; this.checked = false; this.type = ""; this.value = ""; }
    setAttribute(k, v) { this.attrs[k] = String(v); }
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    appendChild(c) { c.parent = this; this.children.push(c); return c; }
    get firstChild() { return this.children[0] ?? null; }
    removeChild(c) { this.children = this.children.filter((x) => x !== c); return c; }
    set textContent(v) { this.children = []; if (v !== "" && v != null) this.children.push({ isText: true, text: String(v) }); }
    get textContent() { return this.children.map((c) => (c.isText ? c.text : c.textContent)).join(""); }
    set innerHTML(v) { innerHTMLWrites.push(String(v)); throw new Error("innerHTML must not be used by the Gantt renderer: " + v); }
    get innerHTML() { return ""; }
    addEventListener(t, f) { (this.listeners[t] ??= []).push(f); }
    fire(t, ev) { (this.listeners[t] || []).forEach((f) => f(ev || {})); }
  }
  const document = {
    createElement: (t) => new Node(t), createElementNS: (ns, t) => new Node(t, ns), createTextNode: (t) => ({ isText: true, text: String(t) }),
    getElementById: (id) => byId[id] ?? null, querySelector: () => null,
  };
  const reg = (id, node) => { node.attrs.id = id; byId[id] = node; return node; };
  return { document, Node, byId, reg, innerHTMLWrites };
}
function* walk(n) { yield n; for (const c of n.children || []) if (!c.isText) yield* walk(c); }
const find = (n, f) => [...walk(n)].filter(f);
const hasClass = (n, c) => (n.className || n.attrs?.class || "").split(/\s+/).includes(c);

function load() {
  const dom = makeDom();
  const host = dom.reg("jc-sched-chart", new dom.Node("div"));
  const zoom = dom.reg("jc-sched-zoom", new dom.Node("select")); zoom.value = "Day";
  // frozen clock: 2026-10-20 23:30 in Trinidad (UTC-4) is already 2026-10-21 in UTC, which is exactly where a UTC date would be wrong
  class FakeDate { getFullYear() { return 2026; } getMonth() { return 9; } getDate() { return 20; } getUTCFullYear() { return 2026; } getUTCMonth() { return 9; } getUTCDate() { return 21; } toISOString() { return "2026-10-21T03:30:00.000Z"; } }
  const ctx = { document: dom.document, console: { warn() {}, log() {} }, window: { innerWidth: 1400 }, performance, Date: FakeDate };
  vm.createContext(ctx);
  const names = ["jcSchedDay", "jcSchedYmd", "jcSchedCompute", "jcGanttLayout", "jcGanttDraw", "jcGanttToday", "jcGanttJobCtx", "jcRenderJobGantt", "jcGanttDay"];
  const wrapped = `(function(){ let jcTasks=[], jcSchedPhases, jcSchedLinks, jcCurrentJobId=null, jcDashData=[];\n${code}\n${gBlock}\n` +
    `return { ${names.join(", ")}, jcGanttCollapsed, ZOOM: JC_GANTT_ZOOM,\n` +
    `set(o){ if('tasks' in o) jcTasks=o.tasks; if('phases' in o) jcSchedPhases=o.phases; if('links' in o) jcSchedLinks=o.links; if('job' in o) jcCurrentJobId=o.job; if('dash' in o) jcDashData=o.dash; if('showAll' in o) jcGanttShowAll=o.showAll; },\n` +
    `state(){ return { showAll: jcGanttShowAll, jobId: jcGanttJobId }; } }; })()`;
  const api = vm.runInContext(wrapped, ctx);
  return { api, dom, host, zoom };
}
const { api: A } = load();
const D = (s) => A.jcSchedDay(s);
const plain = (x) => JSON.parse(JSON.stringify(x));

// ---------- fixture ----------
const TODAY = "2026-10-20";
function base() {
  const phases = [{ id: "p2", name: "Install", colour: "#112233", sort_order: 2 }, { id: "p1", name: "Fabrication", colour: null, sort_order: 1 }];
  const a = { id: "a", task_name: "Cut plate", start_date: "2026-10-10", end_date: "2026-10-19", progress: 50, phase_id: "p1", baseline_start: "2026-10-10", baseline_end: "2026-10-17", baseline_locked_at: "2026-10-01T00:00:00Z" };
  const b = { id: "b", task_name: "Weld frame", start_date: "2026-10-20", end_date: "2026-10-25", progress: 0, phase_id: "p1", baseline_start: "2026-10-18", baseline_end: "2026-10-23" };
  const m = { id: "m", task_name: "Hand-over", start_date: "2026-10-30", end_date: "2026-10-30", progress: 0, phase_id: "p2", is_milestone: true };
  const u = { id: "u", task_name: "Site survey", start_date: null, end_date: null, progress: 0, phase_id: "p2" };
  const l = { id: "l", task_name: "Paperwork", start_date: "2026-10-12", end_date: "2026-10-14", progress: 100 };
  const tasks = [a, b, m, u, l];
  const links = [{ task_id: "b", predecessor_id: "a", lag_days: 0 }, { task_id: "m", predecessor_id: "b", lag_days: 0 }, { task_id: "l", predecessor_id: "a", lag_days: 0 }];
  return { tasks, phases, links };
}
function model(o = {}) {
  const f = base(), job = { due_date: "2026-11-05", status: "In Progress" };
  const compute = A.jcSchedCompute({ tasks: f.tasks, links: f.links, phases: f.phases, job, today: TODAY });
  return { ...f, compute, today: TODAY, pxPerDay: 28, collapsed: new Set(), ...o };
}
const lay = (o, opts) => plain(A.jcGanttLayout(model(o), opts));
const row = (L, id) => L.rows.find((r) => r.id === id);

// ================= pure layout =================
test("rows: phases in sort_order, tasks under their phase, implicit Unphased group last, each row 28 px apart", () => {
  const L = lay();
  assert.deepEqual(L.rows.map((r) => r.id), ["p1", "a", "b", "p2", "m", "u", "__unphased__", "l"]);
  assert.deepEqual(L.rows.map((r) => r.kind), ["phase", "task", "task", "phase", "milestone", "task", "phase", "task"]);
  L.rows.forEach((r, i) => { assert.equal(r.y, i * 28); assert.equal(r.h, 28); });
  assert.equal(L.height, 8 * 28);
  assert.equal(row(L, "__unphased__").label, "Unphased");
  assert.equal(row(L, "p1").label, "Fabrication");
  assert.equal(row(L, "p1").colour, "#5B9BD5", "null colour falls back to the default palette");
  assert.equal(row(L, "p2").colour, "#112233");
});
test("no Unphased header when every task has a phase; a task with an unknown phase_id lands in Unphased", () => {
  const f = base(); f.tasks.pop();
  const L = plain(A.jcGanttLayout({ ...f, today: TODAY, pxPerDay: 28 }));
  assert.ok(!L.rows.some((r) => r.id === "__unphased__"));
  const L2 = plain(A.jcGanttLayout({ tasks: [{ id: "x", task_name: "X", start_date: "2026-10-10", end_date: "2026-10-12", phase_id: "gone" }], phases: f.phases, today: TODAY, pxPerDay: 28 }));
  assert.ok(L2.rows.some((r) => r.id === "__unphased__") && L2.rows.some((r) => r.id === "x"));
});
test("positions at Day / Week / Month zoom (28 / 8 / 3 px per day)", () => {
  // the range starts 2 days before the earliest date (10-10): minDay = 10-08
  for (const [px, label] of [[28, "Day"], [8, "Week"], [3, "Month"]]) {
    const L = lay({ pxPerDay: px });
    assert.equal(L.minDate, "2026-10-08");
    const a = row(L, "a");
    assert.equal(a.bar.x, 2 * px, label);
    assert.equal(a.bar.width, 10 * px);
    assert.equal(a.bar.progressWidth, 10 * px * 0.5);
    assert.equal(a.ghost.x, 2 * px);
    assert.equal(a.ghost.width, 8 * px);
    assert.equal(row(L, "b").bar.x, 12 * px);
    assert.equal(L.today.x, 12.5 * px, "TODAY is the middle of today's day cell");
    assert.equal(L.width, (L.maxDay - L.minDay + 1) * px);
  }
  assert.equal(A.ZOOM.Day, 28); assert.equal(A.ZOOM.Week, 8); assert.equal(A.ZOOM.Month, 3);
});
test("TODAY x follows today, and is absent when today is outside a pinned range", () => {
  assert.equal(lay({ today: "2026-10-08" }).today.x, 70, "range grows to include today, with 2 days of padding");
  assert.equal(lay({ today: "2026-10-10" }).today.x, 2.5 * 28);
  assert.equal(lay({ today: "2026-10-21" }).today.x, 13.5 * 28);
  assert.equal(lay({}, { rangeStart: "2026-11-01", rangeEnd: "2026-11-30" }).today, null);
});
test("ghost bar shows the baseline, the actual bar the current dates (after a slip they differ); ghost is 4 px lower and thinner", () => {
  const L = lay(), a = row(L, "a"), b = row(L, "b");
  assert.equal(a.bar.width, 280); assert.equal(a.ghost.width, 224);
  assert.equal(b.bar.x, 336); assert.equal(b.ghost.x, 280, "b baseline starts 10-18, current starts 10-20");
  assert.equal(b.ghost.width, 6 * 28);
  assert.equal(b.ghost.y, b.bar.y + 4);
  assert.ok(b.ghost.height < b.bar.height);
  assert.ok(a.bar.y >= a.y && a.bar.y + a.bar.height <= a.y + 28, "bar sits inside its row");
});
test("tasks without a baseline get no ghost; tooltip says 'Added after baseline' only when the job has a baseline", () => {
  const L = lay(), c = row(L, "l");
  assert.equal(c.ghost, null);
  assert.ok(c.tip.lines.includes("Added after baseline"));
  assert.ok(!row(L, "a").tip.lines.includes("Added after baseline"));
  const f = base(); f.tasks.forEach((t) => { delete t.baseline_locked_at; delete t.baseline_start; delete t.baseline_end; });
  const L2 = plain(A.jcGanttLayout({ ...f, today: TODAY, pxPerDay: 28 }));
  assert.equal(L2.hasBaseline, false);
  assert.ok(!row(L2, "l").tip.lines.some((s) => /baseline/i.test(s)));
});
test("tooltip carries name, dates, baseline dates, slip days, progress, assignee, critical", () => {
  const f = base(); f.tasks[0].assignee = "Kim";
  const compute = A.jcSchedCompute({ ...f, job: {}, today: TODAY });
  const L = plain(A.jcGanttLayout({ ...f, compute: { ...compute, crit: ["a"] }, today: TODAY, pxPerDay: 28 }));
  const tip = row(L, "a").tip;
  assert.equal(tip.title, "Cut plate");
  assert.ok(tip.lines.includes("Dates: 2026-10-10 → 2026-10-19 (10 d)"));
  assert.ok(tip.lines.includes("Baseline: 2026-10-10 → 2026-10-17"));
  assert.ok(tip.lines.includes("Slip: +2 d late"));
  assert.ok(tip.lines.includes("Progress: 50%"));
  assert.ok(tip.lines.includes("Assignee: Kim"));
  assert.ok(tip.lines.includes("On the critical path"));
  assert.ok(row(L, "b").tip.lines.includes("Slip: +2 d late"));
});
test("slip wording: early and on baseline", () => {
  const f = { tasks: [{ id: "e", task_name: "E", start_date: "2026-10-10", end_date: "2026-10-12", baseline_start: "2026-10-10", baseline_end: "2026-10-14" },
    { id: "o", task_name: "O", start_date: "2026-10-10", end_date: "2026-10-12", baseline_start: "2026-10-10", baseline_end: "2026-10-12" }], phases: [], today: TODAY };
  const L = plain(A.jcGanttLayout(f));
  assert.ok(row(L, "e").tip.lines.includes("Slip: 2 d early"));
  assert.ok(row(L, "o").tip.lines.includes("Slip: on baseline"));
});
test("progress label sits inside the bar when it is wide enough, to the right when not", () => {
  const wide = row(lay(), "a").pctLabel, narrow = row(lay({ pxPerDay: 3 }), "a").pctLabel;
  assert.equal(wide.inside, true); assert.equal(wide.text, "50%"); assert.equal(wide.anchor, "middle");
  assert.equal(wide.x, 56 + 140);
  assert.equal(narrow.inside, false); assert.equal(narrow.anchor, "start");
  assert.equal(narrow.x, 6 + 30 + 5);
});
test("milestones: diamond at end_date centre; filled only at 100%; red outline when past today and incomplete", () => {
  const ms = (id, end, progress) => ({ id, task_name: "M" + id, start_date: end, end_date: end, progress, is_milestone: true });
  const tasks = [ms("future", "2026-10-30", 0), ms("late", "2026-10-15", 0), ms("done", "2026-10-15", 100), ms("todayms", "2026-10-20", 0)];
  const L = plain(A.jcGanttLayout({ tasks, phases: [], compute: null, today: TODAY, pxPerDay: 28 }));
  const d = (id) => row(L, id).diamond;
  assert.equal(d("future").filled, false); assert.equal(d("future").fill, "none"); assert.equal(d("future").pastDue, false);
  assert.notEqual(d("future").stroke, "#E05C5C");
  assert.equal(d("late").pastDue, true); assert.equal(d("late").stroke, "#E05C5C"); assert.equal(d("late").fill, "none");
  assert.equal(d("done").filled, true); assert.equal(d("done").pastDue, false); assert.notEqual(d("done").fill, "none");
  assert.equal(d("todayms").pastDue, false, "due today is not past due yet");
  assert.equal(d("future").cx, (D("2026-10-30") - L.minDay) * 28 + 14);
  assert.equal(d("future").cy, row(L, "future").y + 14);
  assert.equal(d("future").label.x, d("future").cx + d("future").r + 6, "label to the right");
  assert.equal(row(L, "future").bar, null);
  assert.equal(row(L, "done").pctText, "Done"); assert.equal(row(L, "future").pctText, "—");
});
test("collapsed phases hide their task rows and shift the y of everything below (Set or array)", () => {
  const open = lay(), shut = lay({ collapsed: new Set(["p1"]) }), arr = lay({ collapsed: ["p1"] });
  assert.deepEqual(shut.rows.map((r) => r.id), ["p1", "p2", "m", "u", "__unphased__", "l"]);
  assert.equal(row(shut, "p1").collapsed, true); assert.equal(row(open, "p1").collapsed, false);
  assert.equal(row(shut, "p2").y, 28); assert.equal(row(open, "p2").y, 3 * 28);
  assert.equal(row(shut, "l").y, 5 * 28);
  assert.equal(shut.height, 6 * 28);
  assert.deepEqual(arr.rows.map((r) => r.id), shut.rows.map((r) => r.id));
  const all = lay({ collapsed: new Set(["p1", "p2", "__unphased__"]) });
  assert.deepEqual(all.rows.map((r) => r.id), ["p1", "p2", "__unphased__"]);
  assert.equal(row(shut, "p1").taskCount, 2, "header still reports its tasks while collapsed");
  assert.ok(row(shut, "p1").pct != null && row(shut, "p1").bar, "rollup bar stays on a collapsed header");
});
test("collapsing drops connectors to hidden rows", () => {
  assert.equal(lay({}, { showAll: true }).connectors.length, 3);
  assert.equal(lay({ collapsed: new Set(["p1"]) }, { showAll: true }).connectors.length, 0, "a and b are hidden, l links only to a, m only to b");
});
test("undated tasks: no bar, row marked unscheduled; a task with only one date is unscheduled too", () => {
  const L = lay(), u = row(L, "u");
  assert.equal(u.bar, null); assert.equal(u.ghost, null); assert.equal(u.scheduled, false); assert.equal(u.unscheduled, true);
  assert.ok(u.tip.lines[0].startsWith("Unscheduled"));
  const one = plain(A.jcGanttLayout({ tasks: [{ id: "h", task_name: "H", start_date: "2026-10-10", end_date: null }], phases: [], today: TODAY }));
  assert.equal(row(one, "h").bar, null); assert.equal(row(one, "h").unscheduled, true);
});
test("phase header: derived span, weighted % from jcSchedCompute, thin rollup bar", () => {
  const L = lay(), p1 = row(L, "p1");
  assert.equal(p1.start, "2026-10-10"); assert.equal(p1.end, "2026-10-25");
  assert.equal(p1.spanText, "10 Oct – 25 Oct");
  // weights: a = 10 days @50, b = 6 days @0 => 500/16 = 31.25 -> 31
  assert.equal(p1.pctText, "31%");
  assert.ok(Math.abs(p1.pct - 31.25) < 1e-9);
  assert.equal(p1.bar.x, 56); assert.equal(p1.bar.width, 16 * 28); assert.equal(p1.bar.height, 6);
  assert.ok(Math.abs(p1.bar.progressWidth - 16 * 28 * 0.3125) < 1e-9);
  assert.equal(row(L, "p2").start, "2026-10-30", "undated tasks do not stretch the span");
  assert.equal(row(lay({ compute: null }), "p1").pctText, "—", "no compute result: no invented percentage");
});
test("a phase spanning two years labels the years", () => {
  const f = { tasks: [{ id: "x", task_name: "X", start_date: "2026-12-20", end_date: "2027-01-10", phase_id: "p" }], phases: [{ id: "p", name: "P", sort_order: 1 }], today: TODAY };
  assert.equal(row(plain(A.jcGanttLayout(f)), "p").spanText, "20 Dec 2026 – 10 Jan 2027");
});
test("critical colouring comes from the live compute result, not the cached column", () => {
  const f = base();
  f.tasks[1].is_critical = false; f.tasks[0].is_critical = true;     // stale cache says a is critical, b is not
  const L = plain(A.jcGanttLayout({ ...f, compute: { crit: ["b"], phaseRollups: [] }, today: TODAY, pxPerDay: 28 }));
  assert.equal(L.critSource, "compute");
  assert.equal(row(L, "b").critical, true); assert.equal(row(L, "b").bar.colour, "#E05C5C"); assert.equal(row(L, "b").bar.critical, true);
  assert.equal(row(L, "a").critical, false); assert.equal(row(L, "a").bar.colour, "#5B9BD5", "non-critical uses the phase colour");
});
test("when compute failed (null / error object) the cached is_critical column is used", () => {
  const f = base(); f.tasks[0].is_critical = true;
  const L = plain(A.jcGanttLayout({ ...f, compute: null, today: TODAY, pxPerDay: 28 }));
  assert.equal(L.critSource, "cache");
  assert.equal(row(L, "a").critical, true); assert.equal(row(L, "b").critical, false);
  assert.equal(plain(A.jcGanttLayout({ ...f, compute: { error: true }, today: TODAY, pxPerDay: 28 })).critSource, "cache");
});
test("connectors: only critical links by default, every link with showAll; paths run finish -> start", () => {
  const f = base(), compute = { crit: ["a", "b"], phaseRollups: [] };
  const mk = (showAll) => plain(A.jcGanttLayout({ ...f, compute, today: TODAY, pxPerDay: 28 }, { showAll }));
  const def = mk(false), all = mk(true);
  assert.equal(def.connectors.length, 1);
  assert.equal(def.connectors[0].from, "a"); assert.equal(def.connectors[0].to, "b"); assert.equal(def.connectors[0].critical, true);
  assert.equal(all.connectors.length, 3);
  assert.equal(all.connectors.filter((c) => c.critical).length, 1);
  // a finishes at x 56+280 = 336 on row 1 (mid y 42); b starts at 336 too (touching), so the route goes round
  const c = def.connectors[0], rb = row(def, "b");
  assert.ok(c.d.startsWith("M336 42H342V56H330V"), c.d);
  assert.ok(c.d.endsWith("V" + (rb.y + 14) + "H" + rb.bar.x), c.d);
  // with the successor well to the right the route is a simple elbow
  const f2 = { tasks: [{ id: "p", task_name: "P", start_date: "2026-10-10", end_date: "2026-10-11" }, { id: "q", task_name: "Q", start_date: "2026-10-20", end_date: "2026-10-22" }], phases: [], links: [{ task_id: "q", predecessor_id: "p" }], compute: { crit: ["p", "q"] }, today: TODAY, pxPerDay: 28 };
  const e = plain(A.jcGanttLayout(f2)).connectors[0];
  assert.equal(e.d, "M112 42H118V70H336");
  assert.ok(e.head.startsWith("336,70 "));
  const only = plain(A.jcGanttLayout({ ...f2, compute: { crit: ["p"] } })).connectors;
  assert.equal(only.length, 0, "a link needs BOTH ends critical to count as critical");
});
test("connectors by link type (A2): SS start->start, FF finish->finish, SF start->finish; missing or unknown type is FS", () => {
  // p: x 56..112 on the row with mid y 42; q: x 336..420 on the row with mid y 70
  const mk = (type) => ({ tasks: [{ id: "p", task_name: "P", start_date: "2026-10-10", end_date: "2026-10-11" }, { id: "q", task_name: "Q", start_date: "2026-10-20", end_date: "2026-10-22" }], phases: [],
    links: [{ task_id: "q", predecessor_id: "p", link_type: type }], compute: { crit: ["p", "q"] }, today: TODAY, pxPerDay: 28 });
  const one = (type) => plain(A.jcGanttLayout(mk(type))).connectors[0];
  const fs = one("FS"), ss = one("SS"), ff = one("FF"), sf = one("SF");
  assert.deepEqual([fs.type, fs.d, fs.head], ["FS", "M112 42H118V70H336", "336,70 331,67 331,73"]);
  assert.deepEqual([ss.type, ss.d, ss.head], ["SS", "M56 42H50V70H336", "336,70 331,67 331,73"]);                         // leaves p's start to the left, arrives at q's start
  assert.deepEqual([ff.type, ff.d, ff.head], ["FF", "M112 42H426V70H420", "420,70 425,67 425,73"]);                      // arrives at q's finish from the right, head points left
  assert.deepEqual([sf.type, sf.d, sf.head], ["SF", "M56 42H50V56H426V70H420", "420,70 425,67 425,73"]);                 // would double back: detours through the gap between the rows
  for (const t of [undefined, null, "", "XX", "fs"]) { const c = one(t); assert.deepEqual([c.type, c.d], ["FS", fs.d]); }
  // upward arrows: SF from a lower row to an upper one runs straight back (no detour); an FS that would double back detours ABOVE the lower row
  const upSF = plain(A.jcGanttLayout({ ...mk("SF"), links: [{ task_id: "p", predecessor_id: "q", link_type: "SF" }] })).connectors[0];
  assert.equal(upSF.d, "M336 70H330V42H112");
  assert.equal(upSF.head, "112,42 117,39 117,45");
  const upFS = plain(A.jcGanttLayout({ ...mk("FS"), links: [{ task_id: "p", predecessor_id: "q", link_type: "FS" }] })).connectors[0];
  assert.equal(upFS.d, "M420 70H426V56H50V42H56");
  // the same pair with different types draws both; the same pair and type draws once
  const both = plain(A.jcGanttLayout({ ...mk("FS"), links: [{ task_id: "q", predecessor_id: "p", link_type: "FS" }, { task_id: "q", predecessor_id: "p", link_type: "SS" }, { task_id: "q", predecessor_id: "p", link_type: "SS" }] })).connectors;
  assert.deepEqual(both.map((c) => c.type), ["FS", "SS"]);
});
test("connectors attach at the diamond edge; bad links (duplicate, self, unknown, undated, null) are skipped", () => {
  const f = { tasks: [{ id: "p", task_name: "P", start_date: "2026-10-10", end_date: "2026-10-11" }, { id: "ms", task_name: "M", start_date: "2026-10-20", end_date: "2026-10-20", is_milestone: true },
    { id: "und", task_name: "U" }], phases: [], today: TODAY, pxPerDay: 28,
    links: [{ task_id: "ms", predecessor_id: "p" }, { task_id: "ms", predecessor_id: "p" }, { task_id: "p", predecessor_id: "p" }, { task_id: "ms", predecessor_id: "nope" }, { task_id: "und", predecessor_id: "p" }, null, { task_id: null, predecessor_id: "p" }] };
  const L = plain(A.jcGanttLayout(f, { showAll: true }));
  assert.equal(L.connectors.length, 1);
  const dm = row(L, "ms").diamond;
  assert.ok(L.connectors[0].d.endsWith("H" + (dm.cx - dm.r)));
});
test("axis ticks: month band always; days at 28 px, Mondays at 8 px, none at 3 px", () => {
  const day = lay({ pxPerDay: 28 }), week = lay({ pxPerDay: 8 }), month = lay({ pxPerDay: 3 });
  assert.equal(day.ticks.filter((t) => t.kind === "day").length, day.maxDay - day.minDay + 1);
  assert.ok(day.ticks.some((t) => t.kind === "day" && t.weekend));
  const mondays = week.ticks.filter((t) => t.kind === "week");
  assert.ok(mondays.length > 0);
  assert.ok(mondays.every((t) => (((week.minDay + t.x / 8) % 7) + 7 + 4) % 7 === 1), "week ticks fall on Mondays");
  assert.equal(month.ticks.filter((t) => t.kind !== "month").length, 0);
  for (const L of [day, week, month]) assert.ok(L.ticks.some((t) => t.kind === "month" && t.label));
  const oct = day.ticks.find((t) => t.kind === "month");
  assert.equal(oct.x, 0); assert.equal(oct.line, false, "partial first month has no separator");
  assert.equal(oct.label, "Oct 2026");
  const reps = day.ticks.filter((t) => t.kind === "monthlbl");
  assert.ok(reps.length > 0 && reps.every((t) => t.label && t.x > 0), "month name repeats so it is readable wherever the pane is scrolled");
  assert.equal(month.ticks.filter((t) => t.kind === "monthlbl").length, 0);
  assert.equal(day.ticks.find((t) => t.kind === "day").label, "8");
  const wk = (iso) => day.ticks.find((t) => t.kind === "day" && t.x === (D(iso) - day.minDay) * 28).weekend;
  assert.deepEqual([wk("2026-10-09"), wk("2026-10-10"), wk("2026-10-11"), wk("2026-10-12")], [false, true, true, false], "Fri Sat Sun Mon");
});
test("tasks outside a pinned visible range: omitted when wholly outside, clipped when straddling", () => {
  const L = lay({}, { rangeStart: "2026-10-18", rangeEnd: "2026-10-22" });
  assert.equal(L.minDate, "2026-10-18");
  assert.equal(row(L, "l").outside, "left"); assert.equal(row(L, "l").bar, null);
  assert.equal(row(L, "m").outside, "right"); assert.equal(row(L, "m").diamond, null);
  const a = row(L, "a");           // 10-10..10-19 straddles the left edge
  assert.equal(a.outside, null); assert.equal(a.bar.x, 0); assert.equal(a.bar.width, 2 * 28); assert.equal(a.bar.clipL, true);
  assert.equal(L.width, 5 * 28);
  for (const r of L.rows) if (r.bar) assert.ok(r.bar.x >= 0 && r.bar.x + r.bar.width <= L.width + 3);
});
test("empty job: no rows, no throw, sane width", () => {
  for (const m of [undefined, null, {}, { tasks: [] }, { tasks: null, phases: null, links: null, today: "garbage" }]) {
    const L = plain(A.jcGanttLayout(m));
    assert.equal(L.empty, true); assert.equal(L.rows.length, 0); assert.equal(L.height, 0);
    assert.ok(Number.isFinite(L.width) && L.width > 0);
  }
  const L = lay({ tasks: [], phases: [], links: [], compute: null });
  assert.equal(L.rows.length, 0); assert.ok(L.today, "TODAY still has a position on an empty chart");
});
test("adversarial data never produces NaN / negative widths: NaN progress, end before start, 0-day, junk dates, 3000-day spans", () => {
  const tasks = [
    { id: "nan", task_name: "Nan-prog", start_date: "2026-10-10", end_date: "2026-10-12", progress: "abc" },
    { id: "neg", task_name: "Neg", start_date: "2026-10-10", end_date: "2026-10-12", progress: -50 },
    { id: "big", task_name: "Big", start_date: "2026-10-10", end_date: "2026-10-12", progress: 900 },
    { id: "rev", task_name: "Rev", start_date: "2026-10-20", end_date: "2026-10-12", progress: 10 },
    { id: "zero", task_name: "Zero", start_date: "2026-10-12", end_date: "2026-10-12", progress: 10 },
    { id: "old", task_name: "Old", start_date: "0202-10-12", end_date: "0202-10-20" },
    { id: "far", task_name: "Far", start_date: "9999-01-01", end_date: "9999-02-01" },
    { id: "junk", task_name: "Junk", start_date: "not-a-date", end_date: "2026-13-45" },
    { id: "long", task_name: "x".repeat(5000), start_date: "2026-10-12", end_date: "2026-10-13" },
    { id: "span", task_name: "Span", start_date: "2020-01-01", end_date: "2028-03-26" },
    { id: "bl", task_name: "BL", start_date: "2026-10-12", end_date: "2026-10-13", baseline_start: "2026-10-20", baseline_end: "2026-10-10" },
    { task_name: "no id" }, null, undefined, 7,
  ];
  const L = plain(A.jcGanttLayout({ tasks, phases: [{ id: "p", name: null }, null, { name: "no id" }], links: [{ task_id: "rev", predecessor_id: "nan" }], today: TODAY, pxPerDay: 28 }, { showAll: true }));
  assert.equal(JSON.stringify(L).includes("NaN"), false);
  const nulls = []; (function scan(o, path) { if (o && typeof o === "object") for (const k in o) scan(o[k], path + "." + k); else if (typeof o === "number" && !Number.isFinite(o)) nulls.push(path); })(L, "L");
  assert.deepEqual(nulls, []);
  for (const r of L.rows) { if (r.bar) assert.ok(r.bar.width >= 0 && r.bar.progressWidth >= 0 && r.bar.progressWidth <= r.bar.width, r.id); if (r.ghost) assert.ok(r.ghost.width >= 0); }
  assert.equal(row(L, "nan").progress, 0); assert.equal(row(L, "neg").progress, 0); assert.equal(row(L, "big").progress, 100);
  assert.equal(row(L, "rev").badRange, true); assert.equal(row(L, "rev").bar.width, 9 * 28, "reversed dates draw the span between them"); assert.ok(row(L, "rev").tip.lines.some((s) => /end is before start/.test(s)));
  assert.equal(row(L, "zero").bar.width, 28, "a 0-day task (start = end) is one day wide");
  for (const id of ["old", "far", "junk"]) assert.equal(row(L, id).unscheduled, true, id);
  assert.ok(row(L, "bl").ghost.width > 0, "reversed baseline is swapped, not negative");
  assert.equal(row(L, "long").label.length, 5000, "row label keeps the full name (the UI ellipsises it); only SVG labels are truncated");
  assert.ok(row(L, "span").bar.width > 2000 * 28);
  assert.ok(L.width < 1e6);
});
test("SVG milestone labels are truncated; full name stays in the tooltip", () => {
  const f = { tasks: [{ id: "m", task_name: "M".repeat(200), start_date: "2026-10-12", end_date: "2026-10-12", is_milestone: true }], phases: [], today: TODAY };
  const r = row(plain(A.jcGanttLayout(f)), "m");
  assert.equal(r.diamond.label.text.length, 40); assert.ok(r.diamond.label.text.endsWith("…")); assert.equal(r.tip.title.length, 200);
});
test("phase order follows sort_order (ties keep input order); unnamed phase gets a placeholder", () => {
  const f = { tasks: [], phases: [{ id: "c", name: "C", sort_order: 5 }, { id: "a", name: "  ", sort_order: 1 }, { id: "b", name: "B", sort_order: 1 }], today: TODAY };
  const L = plain(A.jcGanttLayout(f));
  assert.deepEqual(L.rows.map((r) => r.id), ["a", "b", "c"]);
  assert.equal(row(L, "a").label, "(unnamed phase)");
});
test("a 200-task job lays out in under 100 ms", () => {
  const phases = Array.from({ length: 10 }, (_, i) => ({ id: "p" + i, name: "Phase " + i, sort_order: i }));
  const tasks = [], links = [];
  for (let i = 0; i < 200; i++) {
    const s = D("2026-06-01") + i, id = "t" + i;
    tasks.push({ id, task_name: "Task " + i, phase_id: "p" + (i % 10), start_date: A.jcSchedYmd(s), end_date: A.jcSchedYmd(s + 5 + (i % 7)), progress: i % 101, baseline_start: A.jcSchedYmd(s - 1), baseline_end: A.jcSchedYmd(s + 4), is_milestone: i % 25 === 0 });
    if (i) links.push({ task_id: id, predecessor_id: "t" + (i - 1), lag_days: 0 });
  }
  const compute = A.jcSchedCompute({ tasks, links, phases, job: { due_date: "2027-02-01" }, today: TODAY });
  let best = Infinity, L;
  for (let k = 0; k < 5; k++) { const t0 = performance.now(); L = A.jcGanttLayout({ tasks, phases, links, compute, today: TODAY, pxPerDay: 28 }, { showAll: true }); best = Math.min(best, performance.now() - t0); }
  assert.ok(best < 100, `layout took ${best.toFixed(1)} ms`);
  assert.equal(L.rows.length, 210);
  assert.ok(L.connectors.length > 100);
});
test("jcGanttToday is the LOCAL date (not the UTC date): 23:30 on the 20th in UTC-4 is still the 20th", () => {
  assert.equal(A.jcGanttToday(), "2026-10-20");
});

// ================= DOM drawer =================
const XSS = "<img src=x onerror=alert(1)>";
function draw(o = {}, ui = {}) {
  const e = load();
  const L = e.api.jcGanttLayout({ ...model({ compute: { crit: [], phaseRollups: [] } }), ...o });
  e.api.jcGanttDraw(e.host, L, ui);
  return { ...e, L };
}
test("drawer: left rows and svg rows share the 28 px height and count; sticky axis + body svg widths agree", () => {
  const { host, L } = draw();
  const lrows = find(host, (n) => hasClass(n, "gt-lrow")), grows = find(host, (n) => hasClass(n, "gt-row"));
  assert.equal(lrows.length, L.rows.length); assert.equal(grows.length, L.rows.length);
  assert.ok(lrows.every((r) => r.style.height === "28px"));
  const body = find(host, (n) => n.tagName === "svg" && hasClass(n, "gt-body"))[0], axis = find(host, (n) => n.tagName === "svg" && hasClass(n, "gt-axis"))[0];
  assert.equal(body.attrs.height, String(L.rows.length * 28)); assert.equal(body.attrs.width, axis.attrs.width);
  assert.ok(find(host, (n) => n.ns && n.ns.includes("svg")).length > 20, "svg nodes use createElementNS");
  const hits = find(host, (n) => hasClass(n, "gt-hit"));
  assert.ok(hits.every((h, i) => h.attrs.y === String(i * 28) && h.attrs.height === "28"));
});
test("drawer: bars, ghost, progress, diamond (outline) and 'unscheduled' are drawn from the layout", () => {
  const { host } = draw();
  const g = (id) => find(host, (n) => hasClass(n, "gt-row") && n.attrs["data-id"] === id)[0];
  const a = g("a");
  assert.equal(find(a, (n) => hasClass(n, "gt-ghost")).length, 1);
  assert.equal(find(a, (n) => hasClass(n, "gt-bar")).length, 1);
  assert.equal(find(a, (n) => hasClass(n, "gt-prog"))[0].attrs.width, "140");
  assert.equal(find(a, (n) => hasClass(n, "gt-pct")).map((n) => n.textContent)[0], "50%");
  assert.equal(find(g("l"), (n) => hasClass(n, "gt-ghost")).length, 0);
  const ms = find(g("m"), (n) => hasClass(n, "gt-ms"))[0];
  assert.equal(ms.tagName, "polygon"); assert.equal(ms.attrs.fill, "none"); assert.equal(ms.attrs.stroke, "#112233");
  assert.equal(find(g("u"), (n) => hasClass(n, "gt-unsched"))[0].textContent, "unscheduled");
  assert.equal(find(g("u"), (n) => hasClass(n, "gt-bar")).length, 0);
});
test("drawer: critical bar gets the red fill and amber edge; connectors only for critical links by default", () => {
  const f = base(), compute = { crit: ["a", "b"], phaseRollups: [] };
  const e = load(), mk = (showAll) => { e.api.jcGanttDraw(e.host, e.api.jcGanttLayout({ ...f, compute, today: TODAY, pxPerDay: 28 }, { showAll }), { showAll }); return e.host; };
  let h = mk(false);
  assert.equal(find(h, (n) => hasClass(n, "gt-link")).length, 1);
  const rowB = find(h, (n) => hasClass(n, "gt-row") && n.attrs["data-id"] === "b")[0];
  const b = find(rowB, (n) => hasClass(n, "gt-bar"))[0];
  assert.equal(b.attrs.fill, "#E05C5C"); assert.equal(b.attrs.stroke, "#E8A020");
  h = mk(true);
  assert.equal(find(h, (n) => hasClass(n, "gt-link")).length, 3);
});
test("drawer: the TODAY line is the last thing in the body svg (above the bars) and the flag is in the axis", () => {
  const { host } = draw();
  const body = find(host, (n) => n.tagName === "svg" && hasClass(n, "gt-body"))[0];
  const last = body.children[body.children.length - 1];
  assert.ok(hasClass(last, "gt-today-ln")); assert.equal(last.attrs.x1, "350");
  assert.deepEqual(find(host, (n) => hasClass(n, "gt-today-tx")).map((n) => n.textContent), ["TODAY"]);
});
test("drawer: chevron toggles via callback with aria state; checkbox reports the dependency toggle", () => {
  const calls = [], tog = [];
  const { host } = draw({ collapsed: new Set(["p2"]) }, { onToggle: (k) => calls.push(k), onToggleAll: (v) => tog.push(v), showAll: true });
  const chev = find(host, (n) => hasClass(n, "gt-chev"));
  assert.deepEqual(chev.map((c) => c.attrs["aria-expanded"]), ["true", "false", "true"]);
  assert.deepEqual(chev.map((c) => c.textContent), ["▾", "▸", "▾"]);
  chev[1].fire("click"); assert.deepEqual(calls, ["p2"]);
  const cb = find(host, (n) => n.tagName === "input")[0];
  assert.equal(cb.checked, true); cb.checked = false; cb.fire("change"); assert.deepEqual(tog, [false]);
});
test("drawer: hover shows a tooltip with the row details and hides it on leave", () => {
  const { host } = draw();
  const g = find(host, (n) => hasClass(n, "gt-row") && n.attrs["data-id"] === "b")[0], tip = find(host, (n) => hasClass(n, "gt-tip"))[0];
  assert.equal(tip.style.display, "none");
  g.fire("mouseenter", { clientX: 100, clientY: 50 });
  assert.equal(tip.style.display, "block"); assert.equal(tip.style.left, "114px");
  assert.match(tip.textContent, /Weld frame/); assert.match(tip.textContent, /Slip: \+2 d late/);
  g.fire("mouseleave"); assert.equal(tip.style.display, "none");
});
test("XSS: markup in task / phase / assignee names is only ever text or attribute values, never HTML", () => {
  const f = { phases: [{ id: "p", name: XSS, colour: "red;}</style><script>alert(1)</script>", sort_order: 1 }],
    tasks: [{ id: "t1", task_name: XSS, assignee: XSS, phase_id: "p", start_date: "2026-10-10", end_date: "2026-10-20", progress: 40 },
      { id: "t2", task_name: XSS, assignee: XSS, phase_id: "p", start_date: "2026-10-22", end_date: "2026-10-22", is_milestone: true },
      { id: "t3", task_name: XSS, assignee: XSS }, { id: XSS, task_name: "ID", start_date: "2026-10-10", end_date: "2026-10-12" }],
    links: [{ task_id: "t2", predecessor_id: "t1" }] };
  const e = load();
  const L = e.api.jcGanttLayout({ ...f, compute: null, today: TODAY, pxPerDay: 28 }, { showAll: true });
  e.api.jcGanttDraw(e.host, L, { showAll: true });
  assert.deepEqual(e.dom.innerHTMLWrites, [], "innerHTML was never assigned");
  const all = [...walk(e.host)];
  assert.ok(!all.some((n) => ["img", "script", "style"].includes(n.tagName)), "no element was created from user markup");
  assert.ok(!all.some((n) => Object.keys(n.attrs).some((k) => /^on/i.test(k))), "no event-handler attributes");
  const texts = all.flatMap((n) => (n.children || []).filter((c) => c.isText).map((c) => c.text));
  assert.ok(texts.some((t) => t === XSS), "the raw string is present as a text node");
  assert.ok(find(e.host, (n) => n.tagName === "polygon" || n.tagName === "rect").every((n) => !/[<>;]/.test(n.attrs.fill || "")), "a hostile colour never reaches a fill");
  assert.ok(all.some((n) => n.attrs["data-id"] === XSS), "ids are attribute values only");
});
test("static: the renderer block never assigns innerHTML / outerHTML / insertAdjacentHTML, never uses the UTC date, has no library", () => {
  assert.ok(!/\.(innerHTML|outerHTML)\s*=/.test(gBlock));
  assert.ok(!/insertAdjacentHTML|document\.write|eval\(|new Function/.test(gBlock));
  assert.ok(!/toISOString/.test(gBlock));
  assert.ok(!/new Gantt|jcLoadGanttLib|import\(|<script/.test(gBlock));
});
test("static: jcRenderSchedGantt only calls jcRenderJobGantt; the portfolio Gantt and the frappe loader are untouched", () => {
  const fn = html.match(/async function jcRenderSchedGantt\(\) \{[\s\S]*?\n\}\n/)[0];
  assert.match(fn, /jcRenderJobGantt\(\);/);
  assert.ok(!/new Gantt|jcLoadGanttLib|innerHTML/.test(fn));
  assert.match(html, /function jcLoadGanttLib\(\)/);
  assert.match(html, /jcGanttInstance = new Gantt\('#jc-gantt-svg'/);
  assert.match(html, /id="jc-sched-zoom" onchange="jcRenderSchedGantt\(\)"/);
  assert.match(html, /\/\* schedule-gantt:begin \*\/[\s\S]*\/\* schedule-gantt:end \*\//);
});

// ================= entry point =================
function open(extra = {}) {
  const e = load(), f = base();
  e.api.set({ tasks: f.tasks, phases: f.phases, links: f.links, job: "job-1", ...extra });
  return e;
}
const bodyW = (e) => +find(e.host, (n) => n.tagName === "svg" && hasClass(n, "gt-body"))[0].attrs.width;
test("entry: jcRenderJobGantt renders into #jc-sched-chart and honours the zoom select (28 / 8 / 3 px per day)", () => {
  const e = open();
  e.api.jcRenderJobGantt();
  assert.ok(find(e.host, (n) => hasClass(n, "gt-body")).length, "chart drawn");
  const wDay = bodyW(e);
  e.zoom.value = "Month"; e.api.jcRenderJobGantt(); const wMonth = bodyW(e);
  e.zoom.value = "Week"; e.api.jcRenderJobGantt(); const wWeek = bodyW(e);
  // right padding leaves >= 240 px for a milestone label: 9 days at 28 px, 30 at 8 px, 80 at 3 px
  const dataDays = wDay / 28 - 9;
  assert.ok(Number.isInteger(dataDays));
  assert.equal(wWeek, (dataDays + 30) * 8); assert.equal(wMonth, (dataDays + 80) * 3);
});
test("entry: collapse state survives redraws, scroll position is kept, and both reset when the job changes", () => {
  const e = open();
  e.api.jcRenderJobGantt();
  const chev = () => find(e.host, (n) => hasClass(n, "gt-chev"));
  const wrap = () => find(e.host, (n) => hasClass(n, "gt-wrap"))[0];
  const rows = () => find(e.host, (n) => hasClass(n, "gt-row")).length;
  const total = rows();
  wrap().scrollLeft = 77; wrap().scrollTop = 12;
  chev()[0].fire("click");                       // collapse the first phase
  assert.equal(rows(), total - 2);
  assert.equal(wrap().scrollLeft, 77); assert.equal(wrap().scrollTop, 12);
  assert.ok(e.api.jcGanttCollapsed.has("p1"));
  e.api.jcRenderJobGantt(); assert.equal(rows(), total - 2, "still collapsed after another render");
  e.api.set({ job: "job-2" }); e.api.jcRenderJobGantt();
  assert.equal(rows(), total, "a different job starts expanded");
  assert.equal(e.api.jcGanttCollapsed.size, 0);
});
test("entry: the dependency toggle redraws with all links", () => {
  const e = open();
  e.api.jcRenderJobGantt();
  const links = () => find(e.host, (n) => hasClass(n, "gt-link")).length;
  const before = links();
  const cb = find(e.host, (n) => n.tagName === "input")[0]; cb.checked = true; cb.fire("change");
  assert.equal(e.api.state().showAll, true);
  assert.ok(links() > before, `${before} -> ${links()}`);
  assert.equal(find(e.host, (n) => n.tagName === "input")[0].checked, true, "checkbox keeps its state after the redraw");
});
test("entry: TODAY is scrolled into view on first open (and left alone on later redraws)", () => {
  const e = load();
  const d0 = e.api.jcSchedDay(e.api.jcGanttToday()), ymd = (n) => e.api.jcSchedYmd(n);
  e.api.set({ job: "j", tasks: [{ id: "x", task_name: "X", start_date: ymd(d0 - 60), end_date: ymd(d0 - 50) }, { id: "y", task_name: "Y", start_date: ymd(d0 + 1), end_date: ymd(d0 + 3) }] });
  e.api.jcRenderJobGantt();
  const w = find(e.host, (n) => hasClass(n, "gt-wrap"))[0];
  assert.ok(w.scrollLeft > 500, `scrollLeft ${w.scrollLeft}`);
  const first = w.scrollLeft; w.scrollLeft = 123; e.api.jcRenderJobGantt();
  assert.notEqual(first, 123);
  assert.equal(find(e.host, (n) => hasClass(n, "gt-wrap"))[0].scrollLeft, 123);
});
test("entry: never throws; garbage state, a throwing state and a missing host all end quietly", () => {
  for (const tasks of [null, undefined, 5, {}, "x", [null, undefined, 3, {}]]) {
    const e = open({ tasks }); assert.doesNotThrow(() => e.api.jcRenderJobGantt());
  }
  const e = open({ tasks: new Proxy([], { get() { throw new Error("boom"); } }) });
  assert.doesNotThrow(() => e.api.jcRenderJobGantt());
  assert.match(e.host.textContent, /could not be drawn/);
  const e2 = load(); delete e2.dom.byId["jc-sched-chart"]; assert.doesNotThrow(() => e2.api.jcRenderJobGantt());
  const e3 = open({ tasks: [] }); e3.host.textContent = "stale"; e3.api.jcRenderJobGantt(); assert.equal(e3.host.textContent, "", "no tasks: chart cleared");
});
test("entry: the legacy depends_on column becomes a link when no job_task_links rows exist", () => {
  const tasks = [{ id: "p", task_name: "P", start_date: "2026-10-10", end_date: "2026-10-11" }, { id: "q", task_name: "Q", start_date: "2026-10-20", end_date: "2026-10-22", depends_on: "p" }];
  const e = open({ tasks, phases: undefined, links: undefined, showAll: true });
  e.api.jcRenderJobGantt();
  assert.equal(find(e.host, (n) => hasClass(n, "gt-link")).length, 1);
});
test("jcGanttJobCtx reads the live form, falls back to the dashboard row", () => {
  const e = load();
  e.dom.reg("jc-f-due-date", new e.dom.Node("input")).value = "2026-12-01";
  e.dom.document.querySelector = () => ({ textContent: " In Progress " });
  assert.deepEqual(plain(e.api.jcGanttJobCtx()), { due_date: "2026-12-01", status: "In Progress" });
  const f = load(); f.api.set({ job: "j9", dash: [{ id: "j9", due_date: "2026-11-11", status: "On Hold" }] });
  assert.deepEqual(plain(f.api.jcGanttJobCtx()), { due_date: "2026-11-11", status: "On Hold" });
});
