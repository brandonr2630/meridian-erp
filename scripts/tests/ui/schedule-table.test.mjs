// Tests for the Schedule v2 task table + data layer (Phase A, staff UI). Run: node --test scripts/tests/ui/schedule-table.test.mjs
// index.html is one inline script, so the code under test (the shared compute block, the SCHEDULE TASK TABLE block and the
// jcLoadTasks..jcDeleteTask functions that follow it) is sliced out and run in a vm against a fake DOM and an in-memory fake
// Supabase that records every request. UI_SRC points the suite at a mutated copy (see schedule-table-mutate.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const sliceBetween = (a, b) => { const i = html.indexOf(a), j = html.indexOf(b, i); assert.ok(i >= 0 && j > i, `cannot slice ${a}`); return html.slice(i, j); };
const computeBlock = sliceBetween("// ── SCHEDULE COMPUTE (shared) ──", "// ── END SCHEDULE COMPUTE ──");
const tableStart = html.indexOf("// ── SCHEDULE TASK TABLE ──");
const delStart = html.indexOf("async function jcDeleteTask(id) {");
const tableBlock = html.slice(tableStart, html.indexOf("\n}\n", delStart) + 3);
const escSrc = html.match(/function escHTML\(s\) \{[\s\S]*?\n\}\n/)[0];
assert.ok(tableStart > 0 && delStart > tableStart, "could not slice the code under test");

const NAMES = ["jcLoadTasks", "jcRenderTasks", "jcTaskSet", "jcAddTask", "jcDeleteTask", "jcSetPredecessors", "jcPredChange", "jcPredToggle", "jcApplyPhaseTemplate",
  "jcAddPhase", "jcPhaseRename", "jcPhaseMove", "jcPhaseVisible", "jcDeletePhase", "jcAddFromCatalogue", "jcSchedSyncCritical", "jcSchedEnsureCatalogue",
  "jcSchedPhaseForCategory", "JC_PHASE_TEMPLATES"];
const addDays = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
const plain = (x) => JSON.parse(JSON.stringify(x));
const tick = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

const task = (id, o = {}) => ({ id, company_id: "c1", job_id: "j1", sort_order: 0, task_name: id, start_date: "2026-03-02", end_date: "2026-03-06", progress: 0,
  assignee: null, depends_on: null, phase_id: null, is_milestone: false, is_critical: false, weight: null, client_visible: false, ...o });

function env({ canWrite = true, canApprove = true, tasks = [], phases = [], links = [], missing = false, catalogue, jobType = "", confirm = true,
  postError, srcTransform, due = "", noKpi = false } = {}) {
  const log = { calls: [], toasts: [], order: [] };
  const db = { job_tasks: tasks.map((t) => ({ ...t })), job_phases: phases.map((p) => ({ ...p })), job_task_links: links.map((l) => ({ ...l })) };
  let nid = 1;
  const rec = (fn, table, extra) => log.calls.push({ fn, table, ...extra });
  const nodes = {};
  const node = (id) => (nodes[id] ??= { id, innerHTML: "", textContent: "", value: "", style: {}, _c: new Set(),
    classList: { toggle: (c, on) => (on ? nodes[id]._c.add(c) : nodes[id]._c.delete(c)), contains: (c) => nodes[id]._c.has(c), add: (c) => nodes[id]._c.add(c), remove: (c) => nodes[id]._c.delete(c) } });
  node("jc-f-job-type").value = jobType; node("jc-f-due-date").value = due;
  const listeners = [];
  const document = { getElementById: (id) => node(id), addEventListener: (t, f) => listeners.push([t, f]) };
  const srv = {
    patchHook: null, patchError: null, whereError: false, deleteError: null,
    sbGet: async (table, q) => { rec("get", table, { q });
      if (missing && (table === "job_phases" || table === "job_task_links")) throw new Error(`Could not find the table 'public.${table}' in the schema cache`);
      if (table === "config_tasks") { if (catalogue === "error") throw new Error("boom"); return catalogue ?? []; }
      return db[table].map((r) => ({ ...r })); },
    sbPost: async (table, body) => { rec("post", table, { body: structuredClone(body) });
      if (postError && table === postError.table) throw new Error(postError.msg);
      const arr = (Array.isArray(body) ? body : [body]).map((b) => ({ id: `${table}-${nid++}`, ...b }));
      db[table].push(...arr.map((r) => ({ ...r }))); return arr; },
    sbPatchChecked: async (table, id, body) => { rec("patchChecked", table, { id, body: structuredClone(body) });
      if (srv.patchError) throw new Error(srv.patchError);
      if (srv.patchHook) await srv.patchHook(table, id, body);
      const row = db[table].find((r) => r.id === id); if (!row) throw new Error("The change was not saved");
      const wording = "task_name" in body || "name" in body;
      Object.assign(row, body); if (wording && row.client_visible && !("client_visible" in body)) row.client_visible = false;   // job_visibility_guard
      return [{ ...row }]; },
    sbPatchWhere: async (table, where, body) => { rec("patchWhere", table, { where, body: structuredClone(body) }); if (srv.whereError) throw new Error("x"); return null; },
    sbDelete: async (table, id) => { rec("delete", table, { id }); db[table] = db[table].filter((r) => r.id !== id); return null; },
    sbDeleteWhere: async (table, where) => { rec("deleteWhere", table, { where });
      if (srv.deleteError) throw new Error(srv.deleteError);
      const m = where.match(/^id=(eq|in)\.\(?([^)]*)\)?$/); const ids = m ? m[2].split(",") : []; db[table] = db[table].filter((r) => !ids.includes(r.id)); return null; },
  };
  const ctx = { document, currentCompany: { id: "c1" }, jcConfig: { tasks: ["Fallback task"] },
    can: (a) => (a === "ops:work-orders:write" ? canWrite : a === "ops:work-orders:approve" ? canApprove : false),
    showToast: (m, t) => log.toasts.push([m, t]), showConfirm: async (m) => { log.confirm = m; return confirm; },
    jcRenderSchedGantt: () => log.order.push("gantt"),
    sbGet: (...a) => srv.sbGet(...a), sbPost: (...a) => srv.sbPost(...a), sbPatchChecked: (...a) => srv.sbPatchChecked(...a),
    sbPatchWhere: (...a) => srv.sbPatchWhere(...a), sbDelete: (...a) => srv.sbDelete(...a), sbDeleteWhere: (...a) => srv.sbDeleteWhere(...a), console };
  if (!noKpi) ctx.jcRenderSchedKpis = () => log.order.push("kpi");
  vm.createContext(ctx);
  const tb = srcTransform ? srcTransform(tableBlock) : tableBlock;
  const getters = ["jcTasks", "jcSchedPhases", "jcSchedLinks", "jcSchedV2", "jcSchedNotice", "jcPredOpen", "jcSchedCatalogue", "jcCurrentJobId"]
    .map((n) => `get ${n}(){return ${n}}, set ${n}(v){${n}=v}`).join(",");
  const code = `(function(){ let jcTasks=[], jcSchedPhases=[], jcSchedLinks=[], jcCurrentJobId='j1';
    const jcCanEditTasks = () => can('ops:work-orders:write'); const jcIsReadOnlyRole = () => !can('ops:work-orders:write');
    ${escSrc}\n${computeBlock}\n${tb}\nreturn { ${NAMES.join(", ")}, ${getters} }; })()`;
  const api = vm.runInContext(code, ctx);
  return { api, db, log, nodes, node, srv, listeners, body: () => nodes["jc-sched-body"].innerHTML, bar: () => nodes["jc-sched-phasebar"].innerHTML,
    writes: () => log.calls.filter((c) => ["post", "patchChecked", "delete", "deleteWhere"].includes(c.fn)),   // the is_critical cache writes (patchWhere) are asserted separately
    allWrites: () => log.calls.filter((c) => ["post", "patchChecked", "patchWhere", "delete", "deleteWhere"].includes(c.fn)) };
}
const P = (id, name, so, o = {}) => ({ id, company_id: "c1", job_id: "j1", sort_order: so, name, client_visible: false, ...o });
const L = (id, task_id, predecessor_id) => ({ id, company_id: "c1", job_id: "j1", task_id, predecessor_id, lag_days: 0 });
const base = () => ({ tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2 }), task("t3", { sort_order: 3 })], phases: [P("p1", "Assess", 10), P("p2", "Design", 20), P("p3", "Make", 30)] });
const loaded = async (o = {}) => { const e = env({ ...base(), ...o }); await e.api.jcLoadTasks(); await tick(); e.log.calls.length = 0; e.log.order.length = 0; e.log.toasts.length = 0; return e; };

// ---------- load ----------
test("load: tasks, phases and links are fetched for the job; v2 on; table not in v1 mode; hooks KPI then Gantt", async () => {
  const e = env({ ...base(), links: [L("l1", "t2", "t1")] });
  await e.api.jcLoadTasks(); await tick();
  const gets = e.log.calls.filter((c) => c.fn === "get").map((c) => `${c.table}?${c.q}`);
  assert.ok(gets.includes("job_tasks?job_id=eq.j1&order=sort_order.asc,created_at.asc"));
  assert.ok(gets.some((g) => g.startsWith("job_phases?job_id=eq.j1&order=sort_order.asc")));
  assert.ok(gets.some((g) => g.startsWith("job_task_links?job_id=eq.j1")));
  assert.equal(e.api.jcSchedV2, true); assert.equal(e.api.jcTasks.length, 3); assert.equal(e.api.jcSchedPhases.length, 3); assert.equal(e.api.jcSchedLinks.length, 1);
  assert.equal(e.nodes["jc-sched-table"]._c.has("jc-sched-v1"), false); assert.equal(e.nodes["jc-sched-notice"].style.display, "none");
  assert.deepEqual(e.log.order.slice(0, 2), ["kpi", "gantt"]);
  assert.match(e.body(), /Unphased/); assert.match(e.body(), /Design/);
});
test("load: missing job_phases / job_task_links degrade to v1 (no throw, notice, single depends_on select, no phase UI, no writes)", async () => {
  const e = env({ ...base(), missing: true, catalogue: [{ task_name: "X", category: "Welding" }] });
  await e.api.jcLoadTasks(); await tick();
  assert.equal(e.api.jcSchedV2, false); assert.equal(e.api.jcTasks.length, 3); assert.equal(e.api.jcSchedPhases.length, 0); assert.equal(e.api.jcSchedLinks.length, 0);
  assert.equal(e.nodes["jc-sched-table"]._c.has("jc-sched-v1"), true);
  assert.match(e.nodes["jc-sched-notice"].textContent, /basic schedule/); assert.equal(e.nodes["jc-sched-notice"].style.display, "");
  assert.match(e.body(), /jcTaskSet\('t1','depends_on',this\.value\)/); assert.doesNotMatch(e.body(), /phase_id|is_milestone|jc-pred|client_visible/);
  assert.equal(e.bar(), ""); assert.equal(e.writes().length, 0, "no critical-cache or other writes without the migration");
  assert.ok(!e.log.calls.some((c) => c.table === "config_tasks"));
  assert.ok(e.log.order.includes("kpi") && e.log.order.includes("gantt"));
});
test("load: a failing task fetch toasts, leaves an empty table and does not throw", async () => {
  const e = env({ ...base() }); e.srv.sbGet = async (t) => { if (t === "job_tasks") throw new Error("down"); return []; };
  await e.api.jcLoadTasks(); await tick();
  assert.equal(e.api.jcTasks.length, 0); assert.ok(e.log.toasts.some(([m]) => /Could not load tasks: down/.test(m)));
  assert.doesNotMatch(e.nodes["jc-sched-notice"].textContent, /basic schedule/);
});
test("load: with no saved job the table says so and nothing is fetched", async () => {
  const e = env({ ...base() }); e.api.jcCurrentJobId = null; await e.api.jcLoadTasks();
  assert.match(e.body(), /Save the job to start planning tasks/); assert.equal(e.log.calls.length, 0);
});
test("load: an older, slower load never overwrites a newer one", async () => {
  const e = env({ ...base() }); let first = true;
  const orig = e.srv.sbGet;
  e.srv.sbGet = async (t, q) => { if (t === "job_tasks" && first) { first = false; await tick(20); return [task("old")]; } return orig(t, q); };
  const a = e.api.jcLoadTasks(); const b = e.api.jcLoadTasks(); await Promise.all([a, b]); await tick();
  assert.deepEqual(plain(e.api.jcTasks.map((t) => t.id)), ["t1", "t2", "t3"]);
});

// ---------- critical cache ----------
const critJob = (cached) => ({ tasks: [
  task("A", { sort_order: 1, start_date: addDays(0), end_date: addDays(9), is_critical: cached.A }),
  task("B", { sort_order: 2, start_date: addDays(10), end_date: addDays(14), is_critical: cached.B }),
  task("C", { sort_order: 3, start_date: addDays(0), end_date: addDays(2), is_critical: cached.C })], phases: [], links: [L("l1", "B", "A")] });
test("critical cache: only rows that differ are patched, one call per flag value, no updated_at", async () => {
  const e = env(critJob({ A: false, B: true, C: true }));
  await e.api.jcLoadTasks(); await tick();
  const w = e.log.calls.filter((c) => c.fn === "patchWhere");
  assert.equal(w.length, 2);
  assert.deepEqual(w[0], { fn: "patchWhere", table: "job_tasks", where: "job_id=eq.j1&id=in.(A)", body: { is_critical: true } });
  assert.deepEqual(w[1], { fn: "patchWhere", table: "job_tasks", where: "job_id=eq.j1&id=in.(C)", body: { is_critical: false } });
  assert.deepEqual(plain(e.api.jcTasks.map((t) => t.is_critical)), [true, true, false]);
  e.log.calls.length = 0; await e.api.jcSchedSyncCritical(); assert.equal(e.log.calls.filter((c) => c.fn === "patchWhere").length, 0, "already in sync: nothing to write, no loop");
});
test("critical cache: several differing rows are batched into ONE call per flag", async () => {
  const e = env(critJob({ A: false, B: false, C: true }));
  await e.api.jcLoadTasks(); await tick();
  const w = e.log.calls.filter((c) => c.fn === "patchWhere");
  assert.equal(w.length, 2); assert.equal(w[0].where, "job_id=eq.j1&id=in.(A,B)"); assert.deepEqual(w[0].body, { is_critical: true });
});
test("critical cache: nothing for a read-only role", async () => {
  const e = env({ ...critJob({ A: false, B: false, C: true }), canWrite: false });
  await e.api.jcLoadTasks(); await tick(); await e.api.jcSchedSyncCritical();
  assert.equal(e.log.calls.filter((c) => c.fn === "patchWhere").length, 0);
});
test("critical cache: a failing write is silent and not retried by itself", async () => {
  const e = env(critJob({ A: false, B: true, C: true })); e.srv.whereError = true;
  await e.api.jcLoadTasks(); await tick(20);
  assert.equal(e.log.calls.filter((c) => c.fn === "patchWhere").length, 2); assert.equal(e.log.toasts.length, 0);
  assert.equal(e.api.jcTasks[0].is_critical, false, "local cache untouched when the write failed");
});
test("critical cache: an edit re-syncs it (stretching C past A's chain makes C critical)", async () => {
  const e = env(critJob({ A: true, B: true, C: false })); await e.api.jcLoadTasks(); await tick(); e.log.calls.length = 0;
  await e.api.jcTaskSet("C", "end_date", addDays(30)); await tick();
  const w = e.log.calls.filter((c) => c.fn === "patchWhere");
  assert.ok(w.some((c) => c.where === "job_id=eq.j1&id=in.(C)" && c.body.is_critical === true), JSON.stringify(w));
});

// ---------- predecessors ----------
test("predecessors: adding one POSTs exactly the new link and mirrors it into depends_on", async () => {
  const e = await loaded();
  await e.api.jcPredChange("t3", "t1", true);
  const w = e.writes();
  assert.deepEqual(w[0], { fn: "post", table: "job_task_links", body: [{ company_id: "c1", job_id: "j1", task_id: "t3", predecessor_id: "t1" }] });
  assert.deepEqual(w[1], { fn: "patchChecked", table: "job_tasks", id: "t3", body: { depends_on: "t1" } });
  assert.equal(w.filter((c) => c.fn === "deleteWhere").length, 0);
  assert.equal(e.api.jcSchedLinks.length, 1); assert.equal(e.api.jcTasks[2].depends_on, "t1");
});
test("predecessors: the FIRST predecessor stays mirrored; removing it promotes the next; removing the last clears depends_on", async () => {
  const e = await loaded({ links: [L("l1", "t3", "t1"), L("l2", "t3", "t2")], tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2 }), task("t3", { sort_order: 3, depends_on: "t1" })] });
  await e.api.jcPredChange("t3", "t2", false);
  assert.deepEqual(e.writes().map((c) => [c.fn, c.where]), [["deleteWhere", "id=in.(l2)"]], "removing a non-first predecessor does not touch depends_on");
  e.log.calls.length = 0;
  await e.api.jcPredChange("t3", "t1", false);
  assert.deepEqual(e.writes().map((c) => c.fn), ["deleteWhere", "patchChecked"]); assert.deepEqual(e.writes()[1].body, { depends_on: null });
  e.log.calls.length = 0;
  await e.api.jcPredChange("t3", "t2", true); await e.api.jcPredChange("t3", "t1", true);   // t2 first, then t1 appended
  assert.equal(e.api.jcTasks[2].depends_on, "t2");
  await e.api.jcPredChange("t3", "t2", false);
  assert.equal(e.api.jcTasks[2].depends_on, "t1", "removing the first promotes the next in order");
});
test("predecessors: selecting what is already selected / deselecting nothing writes nothing", async () => {
  const e = await loaded({ links: [L("l1", "t2", "t1")], tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2, depends_on: "t1" }), task("t3", { sort_order: 3 })] });
  await e.api.jcPredChange("t2", "t1", true); await e.api.jcPredChange("t2", "t3", false);
  assert.equal(e.writes().length, 0);
});
test("predecessors: a multi-select replace is one POST then one DELETE (adds first), then the depends_on mirror", async () => {
  const e = await loaded({ links: [L("l1", "t3", "t1")], tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2 }), task("t3", { sort_order: 3, depends_on: "t1" })] });
  await e.api.jcSetPredecessors("t3", ["t2"]);
  assert.deepEqual(e.writes().map((c) => c.fn), ["post", "deleteWhere", "patchChecked"]);
  assert.equal(e.writes()[1].where, "id=in.(l1)"); assert.deepEqual(e.writes()[2].body, { depends_on: "t2" });
});
test("predecessors: a loop is refused client-side with a toast and no request", async () => {
  const e = await loaded({ links: [L("l1", "t2", "t1")], tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2, depends_on: "t1" }), task("t3", { sort_order: 3 })] });
  await e.api.jcPredChange("t1", "t2", true);
  assert.equal(e.writes().length, 0); assert.match(e.log.toasts[0][0], /circular/);
  await e.api.jcSetPredecessors("t1", ["t1"]); assert.equal(e.writes().length, 0, "self link never sent");
});
test("predecessors: the DB cycle trigger error shows a clear toast and reverts the UI and local state", async () => {
  const e = await loaded({ postError: { table: "job_task_links", msg: "dependency cycle: a cannot depend on b" } });
  await e.api.jcPredChange("t3", "t1", true);
  assert.equal(e.log.toasts.length, 1); assert.match(e.log.toasts[0][0], /circular dependency/); assert.equal(e.log.toasts[0][1], "warn");
  assert.equal(e.api.jcSchedLinks.length, 0); assert.equal(e.api.jcTasks[2].depends_on, null);
  assert.equal(e.writes().filter((c) => c.fn !== "post").length, 0, "nothing else was written after the refused POST");
  assert.ok(!e.log.calls.some((c) => c.fn === "get"), "no reload needed: nothing was written");
});
test("predecessors: a non-cycle server error toasts and reloads from the server", async () => {
  const e = await loaded({ postError: { table: "job_task_links", msg: "boom" } });
  await e.api.jcPredChange("t3", "t1", true); await tick();
  assert.match(e.log.toasts[0][0], /Failed to save predecessors: boom/);
  assert.ok(e.log.calls.some((c) => c.fn === "get" && c.table === "job_tasks"), "reloaded");
});
test("predecessors: the dropdown lists the other tasks, shows the selected names, opens/closes, closes on an outside click", async () => {
  const e = await loaded({ links: [L("l1", "t3", "t1")] });
  e.api.jcPredToggle("t3", { getBoundingClientRect: () => ({ bottom: 100.4, left: 50.6 }) });
  assert.match(e.body(), /class="jc-pred-menu" style="top:100px;left:51px"/);
  const menu = e.body().match(/<div class="jc-pred-menu"[\s\S]*?<\/div>/)[0];
  assert.equal((menu.match(/<label>/g) || []).length, 2); assert.doesNotMatch(menu, /jcPredChange\('t3','t3'/); assert.match(menu, /checked onchange="jcPredChange\('t3','t1'/);
  assert.match(e.body(), /<button type="button" class="jc-pred-btn" title="t1"/);
  const click = e.listeners.find(([t]) => t === "click")[1];
  click({ target: { closest: () => ({}) } }); assert.equal(e.api.jcPredOpen, "t3");
  click({ target: { closest: () => null } }); assert.equal(e.api.jcPredOpen, null); assert.doesNotMatch(e.body(), /jc-pred-menu"/);
  e.api.jcPredToggle("t3", null); e.api.jcPredToggle("t3", null); assert.equal(e.api.jcPredOpen, null, "second click toggles it shut");
});
test("predecessors: v2 'depends_on' edits are routed to the links, never PATCHed alone", async () => {
  const e = await loaded();
  await e.api.jcTaskSet("t2", "depends_on", "t1");
  assert.deepEqual(e.writes().map((c) => c.fn), ["post", "patchChecked"]);
});
test("adversarial: a task deleted while the dropdown is open; links pointing to deleted tasks", async () => {
  const e = await loaded({ links: [L("l1", "t3", "t2"), L("lg", "t3", "ghost")], tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2 }), task("t3", { sort_order: 3, depends_on: "t2" })] });
  assert.doesNotMatch(e.body(), /ghost|undefined/); assert.match(e.body(), /title="t2" onclick="jcPredToggle\('t3'/, "only the live predecessor is listed"); e.api.jcPredToggle("t3", null);
  await e.api.jcDeleteTask("t2");
  assert.deepEqual(plain(e.api.jcSchedLinks.map((l) => l.id)), ["lg"], "links to the deleted task are dropped locally (the DB cascades)");
  assert.equal(e.api.jcTasks.find((t) => t.id === "t3").depends_on, null);
  e.log.calls.length = 0;
  await e.api.jcPredChange("t3", "t2", true);   // stale checkbox of the deleted task
  assert.equal(e.writes().length, 0); assert.doesNotMatch(e.body(), /jcPredChange\('t3','t2'/);
  await e.api.jcSetPredecessors("t3", []); assert.equal(e.writes().length, 0, "the dangling ghost link is not counted as a selection");
});

// ---------- milestone / weight ----------
test("milestone: checking it collapses to one day and disables the weight field; unchecking only clears the flag", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 1, start_date: "2026-03-02", end_date: "2026-03-06", weight: 8 })] });
  await e.api.jcTaskSet("t1", "is_milestone", true);
  assert.deepEqual(e.writes()[0].body, { is_milestone: true, end_date: "2026-03-02" });
  assert.match(e.body(), /type="number" disabled placeholder="n\/a"/); assert.doesNotMatch(e.body(), /jcTaskSet\('t1','weight'/);
  e.log.calls.length = 0; await e.api.jcTaskSet("t1", "is_milestone", false);
  assert.deepEqual(e.writes()[0].body, { is_milestone: false }); assert.match(e.body(), /jcTaskSet\('t1','weight'/);
});
test("milestone: with only an end date the start is set; editing either date of a milestone moves the other", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 1, start_date: null, end_date: "2026-03-06" }), task("t2", { sort_order: 2, is_milestone: true, start_date: "2026-03-02", end_date: "2026-03-02" })] });
  await e.api.jcTaskSet("t1", "is_milestone", "true"); assert.deepEqual(e.writes()[0].body, { is_milestone: true, start_date: "2026-03-06" });
  e.log.calls.length = 0; await e.api.jcTaskSet("t2", "start_date", "2026-04-01"); assert.deepEqual(e.writes()[0].body, { start_date: "2026-04-01", end_date: "2026-04-01" });
  e.log.calls.length = 0; await e.api.jcTaskSet("t2", "start_date", "2026-02-01"); assert.deepEqual(e.writes()[0].body, { start_date: "2026-02-01", end_date: "2026-02-01" }, "moving a milestone earlier drags the end too");
  e.log.calls.length = 0; await e.api.jcTaskSet("t2", "end_date", "2026-04-09"); assert.deepEqual(e.writes()[0].body, { end_date: "2026-04-09", start_date: "2026-04-09" });
  assert.equal(e.log.toasts.length, 0);
});
test("weight: empty is NULL, a number is stored (2 dp), an explicit 0 is kept; invalid input is refused", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 1, weight: 3 })] });
  await e.api.jcTaskSet("t1", "weight", ""); assert.deepEqual(e.writes().at(-1).body, { weight: null });
  await e.api.jcTaskSet("t1", "weight", "7.456"); assert.deepEqual(e.writes().at(-1).body, { weight: 7.46 });
  await e.api.jcTaskSet("t1", "weight", "0"); assert.deepEqual(e.writes().at(-1).body, { weight: 0 }); assert.match(e.body(), /step="any" value="0"/);
  const n = e.writes().length;
  for (const bad of ["-1", "abc", "1000000"]) await e.api.jcTaskSet("t1", "weight", bad);
  assert.equal(e.writes().length, n); assert.equal(e.log.toasts.length, 3);
});
test("weight: the placeholder shows the effective (duration) weight, the value stays empty for NULL", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 1, start_date: "2026-03-02", end_date: "2026-03-11" }), task("t2", { sort_order: 2, start_date: null, end_date: null })] });
  const rows = e.body().split("<tr>");
  assert.match(rows[1], /value="" placeholder="10"/); assert.match(rows[2], /value="" placeholder="1"/);
});

// ---------- phase select ----------
test("phase select: lists the job's phases plus Unphased; changing it PATCHes phase_id (null for Unphased); unknown ids become null", async () => {
  const e = await loaded();
  assert.match(e.body().split("<tr>")[1], /<option value="">— Unphased<\/option><option value="p1">Assess<\/option><option value="p2">Design<\/option><option value="p3">Make<\/option>/);
  await e.api.jcTaskSet("t1", "phase_id", "p2"); assert.deepEqual(e.writes().at(-1).body, { phase_id: "p2" });
  await e.api.jcTaskSet("t1", "phase_id", ""); assert.deepEqual(e.writes().at(-1).body, { phase_id: null });
  await e.api.jcTaskSet("t1", "phase_id", "nope"); assert.deepEqual(e.writes().at(-1).body, { phase_id: null });
});

// ---------- publishing ----------
test("publish: without approve the toggle is disabled with a tooltip; unpublishing a visible row is still possible", async () => {
  const e = await loaded({ canApprove: false, tasks: [task("t1", { sort_order: 1 }), task("t2", { sort_order: 2, client_visible: true })] });
  const rows = e.body().split("<tr>");
  assert.match(rows[1], /class="jc-vis" disabled title="Publishing to the client needs approval permission/);
  assert.match(rows[2], /class="jc-vis" checked title="Visible to client"/);
  await e.api.jcTaskSet("t1", "client_visible", true); assert.equal(e.writes().length, 0); assert.match(e.log.toasts[0][0], /approval permission/);
  await e.api.jcTaskSet("t2", "client_visible", false); assert.deepEqual(e.writes()[0].body, { client_visible: false });
});
test("publish: with approve the toggle works; read-only roles get no toggle at all", async () => {
  const e = await loaded(); await e.api.jcTaskSet("t1", "client_visible", true);
  assert.deepEqual(e.writes()[0], { fn: "patchChecked", table: "job_tasks", id: "t1", body: { client_visible: true } }); assert.equal(e.api.jcTasks[0].client_visible, true);
  const r = await loaded({ canWrite: false }); assert.doesNotMatch(r.body(), /jc-vis/);
});
test("publish: a wording edit that the server auto-unpublishes shows the re-publish badge; republishing clears it; date edits do not", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 1, client_visible: true })] });
  await e.api.jcTaskSet("t1", "start_date", "2026-03-03"); assert.equal(e.api.jcTasks[0].client_visible, true); assert.doesNotMatch(e.body(), /Unpublished by edit/);
  await e.api.jcTaskSet("t1", "task_name", "Renamed");
  assert.equal(e.api.jcTasks[0].client_visible, false); assert.match(e.body(), /Unpublished by edit: re-publish/); assert.ok(e.log.toasts.some(([m]) => /Unpublished by edit/.test(m)));
  await e.api.jcTaskSet("t1", "client_visible", true); assert.doesNotMatch(e.body(), /Unpublished by edit/);
});

// ---------- phases ----------
test("template: the default five phases are created with ONE array POST, sort_order 10..50, company_id/job_id", async () => {
  const e = await loaded({ phases: [] });
  assert.match(e.bar(), /Apply template/);
  await e.api.jcApplyPhaseTemplate();
  assert.deepEqual(e.writes(), [{ fn: "post", table: "job_phases", body: ["Assess", "Design", "Make", "Install", "Commission"].map((name, i) => ({ company_id: "c1", job_id: "j1", sort_order: (i + 1) * 10, name })) }]);
  assert.equal(e.api.jcSchedPhases.length, 5); assert.doesNotMatch(e.bar(), /Apply template/);
});
test("template: only for jobs without phases, and a double click creates them once", async () => {
  const e = await loaded(); await e.api.jcApplyPhaseTemplate(); assert.equal(e.writes().length, 0);
  const f = await loaded({ phases: [] }); await Promise.all([f.api.jcApplyPhaseTemplate(), f.api.jcApplyPhaseTemplate()]);
  assert.equal(f.writes().filter((c) => c.fn === "post").length, 1);
});
test("template: a job_type match uses its list, an unknown type or Object.prototype keys fall back to the default", async () => {
  const tx = (b) => { const o = b.replace("byJobType: Object.freeze({})", "byJobType: Object.freeze({ Fabrication: ['Assess','Make'] })"); assert.notEqual(o, b); return o; };
  const e = env({ ...base(), phases: [], jobType: "Fabrication", srcTransform: tx }); await e.api.jcLoadTasks(); await tick(); e.log.calls.length = 0;
  await e.api.jcApplyPhaseTemplate(); assert.deepEqual(e.writes()[0].body.map((r) => [r.name, r.sort_order]), [["Assess", 10], ["Make", 20]]);
  const f = env({ ...base(), phases: [], jobType: "constructor", srcTransform: tx }); await f.api.jcLoadTasks(); await tick(); f.log.calls.length = 0;
  await f.api.jcApplyPhaseTemplate(); assert.equal(f.writes()[0].body.length, 5);
});
test("template constant: versioned, default five, empty byJobType, the spec's category map", () => {
  const T = env().api.JC_PHASE_TEMPLATES;
  assert.equal(T.version, 1); assert.deepEqual([...T.default], ["Assess", "Design", "Make", "Install", "Commission"]); assert.deepEqual({ ...T.byJobType }, {});
  assert.deepEqual({ ...T.categoryToPhase }, { Engineering: "Design", "Mechanical Engineering": "Design", Machining: "Make", Metalwork: "Make", Welding: "Make", Coatings: "Make",
    "Mechanical Fitting": "Install", "Electrical Motor": "Install", Inspection: "Commission", HSE: "Assess" });
});
test("add phase: appended 10 after the highest sort_order", async () => {
  const e = await loaded(); await e.api.jcAddPhase();
  assert.deepEqual(e.writes()[0].body, { company_id: "c1", job_id: "j1", sort_order: 40, name: "New phase" }); assert.equal(e.api.jcSchedPhases.length, 4);
});
test("rename: trimmed and PATCHed; empty is refused; a published phase auto-unpublished by the server gets the badge", async () => {
  const e = await loaded({ phases: [P("p1", "Assess", 10, { client_visible: true })] });
  await e.api.jcPhaseRename("p1", "   "); assert.equal(e.writes().length, 0); assert.match(e.log.toasts[0][0], /needs a name/);
  await e.api.jcPhaseRename("p1", "  Survey  "); assert.deepEqual(e.writes()[0].body, { name: "Survey" });
  assert.match(e.bar(), /Unpublished by edit: re-publish/); assert.match(e.bar(), /value="Survey"/);
  await e.api.jcPhaseVisible("p1", true); assert.doesNotMatch(e.bar(), /Unpublished by edit/);
});
test("phase publish toggle is gated on approve like the task one", async () => {
  const e = await loaded({ canApprove: false }); assert.match(e.bar(), /class="jc-vis" disabled/);
  await e.api.jcPhaseVisible("p1", true); assert.equal(e.writes().length, 0);
});
test("reorder: swaps and rewrites sort_order with gaps of 10, PATCHing only changed rows; edges are no-ops", async () => {
  const e = await loaded(); await e.api.jcPhaseMove("p3", -1);
  assert.deepEqual(e.writes().map((c) => [c.id, c.body.sort_order]), [["p3", 20], ["p2", 30]]);
  assert.deepEqual(plain(e.api.jcSchedPhases.map((p) => [p.id, p.sort_order])), [["p1", 10], ["p3", 20], ["p2", 30]]);
  e.log.calls.length = 0; await e.api.jcPhaseMove("p1", -1); await e.api.jcPhaseMove("p2", 1); assert.equal(e.writes().length, 0);
  const g = await loaded({ phases: [P("p1", "A", 5), P("p2", "B", 7), P("p3", "C", 100)] }); await g.api.jcPhaseMove("p1", 1);
  assert.deepEqual(plain(g.api.jcSchedPhases.map((p) => [p.id, p.sort_order])), [["p2", 10], ["p1", 20], ["p3", 30]]);
});
test("delete phase: asks first, then deletes; its tasks fall to Unphased locally", async () => {
  const e = await loaded({ confirm: false, tasks: [task("t1", { sort_order: 1, phase_id: "p2" }), task("t2", { sort_order: 2, phase_id: "p2" })] });
  await e.api.jcDeletePhase("p2"); assert.equal(e.writes().length, 0); assert.match(e.log.confirm, /Its 2 tasks will become Unphased/);
  const f = await loaded({ tasks: [task("t1", { sort_order: 1, phase_id: "p2" })] }); await f.api.jcDeletePhase("p2");
  assert.deepEqual(f.writes(), [{ fn: "deleteWhere", table: "job_phases", where: "id=eq.p2" }]); assert.equal(f.api.jcTasks[0].phase_id, null); assert.equal(f.api.jcSchedPhases.length, 2);
});

// ---------- add task ----------
test("add task: carries company_id/job_id, sort_order after the last, and the phase of the row above; no timestamps or baseline", async () => {
  const e = await loaded({ tasks: [task("t1", { sort_order: 4, phase_id: "p2", end_date: "2026-03-06" })] });
  await e.api.jcAddTask();
  assert.deepEqual(e.writes()[0].body, { job_id: "j1", company_id: "c1", sort_order: 5, task_name: "", start_date: "2026-03-06", end_date: "2026-03-06", progress: 0, phase_id: "p2" });
  assert.equal(e.api.jcTasks.length, 2);
});
test("add task: v1 mode never sends phase_id; a double click inserts once; no saved job => warning", async () => {
  const v1 = env({ ...base(), missing: true }); await v1.api.jcLoadTasks(); v1.log.calls.length = 0; await v1.api.jcAddTask();
  assert.ok(!("phase_id" in v1.writes()[0].body));
  const e = await loaded(); await Promise.all([e.api.jcAddTask(), e.api.jcAddTask()]); assert.equal(e.writes().filter((c) => c.fn === "post").length, 1);
  e.api.jcCurrentJobId = null; e.log.calls.length = 0; await e.api.jcAddTask(); assert.equal(e.writes().length, 0); assert.match(e.log.toasts.at(-1)[0], /Save the job/);
});
test("add task: an empty task list gets sort_order 0 and no phase", async () => {
  const e = await loaded({ tasks: [] }); await e.api.jcAddTask();
  assert.equal(e.writes()[0].body.sort_order, 0); assert.equal(e.writes()[0].body.phase_id, null);
});

// ---------- catalogue ----------
const CAT = [{ task_name: "Turn shaft", category: "Machining" }, { task_name: "Mystery", category: "Weird" }, { task_name: "Proto", category: "constructor" }, { task_name: "NoCat", category: null }, { task_name: "Inspect", category: "Inspection" }];
test("catalogue: a picked task goes to categoryToPhase[category] by phase name; unmapped, prototype keys and a missing phase give Unphased", async () => {
  const e = await loaded({ catalogue: CAT, phases: [P("p1", "Assess", 10), P("pm", "make", 20)] }); await e.api.jcSchedEnsureCatalogue();
  await e.api.jcAddFromCatalogue("0"); assert.deepEqual([e.writes()[0].body.task_name, e.writes()[0].body.phase_id], ["Turn shaft", "pm"], "case-insensitive name match");
  for (const [i, name] of [[1, "Mystery"], [2, "Proto"], [3, "NoCat"], [4, "Inspect"]]) {
    e.log.calls.length = 0; await e.api.jcAddFromCatalogue(String(i));
    assert.deepEqual([e.writes()[0].body.task_name, e.writes()[0].body.phase_id], [name, null], name);
  }
});
test("catalogue: the picker shows the target phase and flags unmapped categories", async () => {
  const e = await loaded({ catalogue: CAT }); await e.api.jcSchedEnsureCatalogue();
  assert.match(e.bar(), /Turn shaft → Make/); assert.match(e.bar(), /Mystery ⚠ unmapped category \(Weird\)/); assert.match(e.bar(), /NoCat ⚠ unmapped category</);
  assert.match(e.bar(), /Inspect → Unphased/, "mapped but the job has no Commission phase");
});
test("catalogue: if config_tasks cannot be read the plain task names are offered; read-only roles never load it", async () => {
  const e = await loaded({ catalogue: "error" }); await e.api.jcSchedEnsureCatalogue(); assert.match(e.bar(), /Fallback task ⚠ unmapped/);
  const r = await loaded({ canWrite: false, catalogue: CAT }); await r.api.jcSchedEnsureCatalogue(); assert.ok(!r.log.calls.some((c) => c.table === "config_tasks"));
});

// ---------- read-only ----------
test("read-only role: every control is disabled or absent, and every handler is a no-op", async () => {
  const e = await loaded({ canWrite: false, links: [L("l1", "t2", "t1")], catalogue: CAT });
  e.api.jcPredToggle("t2", null);
  const controls = [...(e.body() + e.bar()).matchAll(/<(input|select)\b[^>]*>/g)].map((m) => m[0]);
  assert.ok(controls.length > 10); assert.deepEqual(controls.filter((c) => !/ disabled/.test(c)), [], "all inputs/selects disabled");
  assert.doesNotMatch(e.body(), /btn-del/); assert.doesNotMatch(e.bar(), /<button|Apply template|\+ Add phase|<select/);
  assert.match(e.body(), /jc-pred-btn/, "predecessor names remain readable");
  const api = e.api;
  await api.jcTaskSet("t1", "task_name", "x"); await api.jcAddTask(); await api.jcDeleteTask("t1"); await api.jcPredChange("t1", "t2", true); await api.jcSetPredecessors("t1", ["t2"]);
  await api.jcAddPhase(); await api.jcApplyPhaseTemplate(); await api.jcPhaseRename("p1", "y"); await api.jcPhaseMove("p1", 1); await api.jcDeletePhase("p1"); await api.jcPhaseVisible("p1", true);
  await api.jcAddFromCatalogue("0"); await api.jcPhaseRename("p1", "");
  assert.equal(e.writes().length, 0); assert.equal(e.log.toasts.length, 0, "no toast either: the handlers return before doing anything");
});
test("writer with approve sees the controls enabled", async () => {
  const e = await loaded({ links: [L("l1", "t2", "t1")] });
  assert.ok(!/<(input|select)\b[^>]* disabled/.test(e.body())); assert.match(e.bar(), /\+ Add phase/);
});

// ---------- escaping ----------
test("XSS: task, assignee, phase and catalogue strings are escaped everywhere they are rendered", async () => {
  const evil = `"><img src=x onerror=alert(1)>`;
  const e = await loaded({ catalogue: [{ task_name: evil, category: evil }], tasks: [task("t1", { sort_order: 1, task_name: evil, assignee: evil, phase_id: "p1" }), task("t2", { sort_order: 2, task_name: "<script>x</script>" })],
    phases: [P("p1", evil, 10)], links: [L("l1", "t2", "t1")] });
  await e.api.jcSchedEnsureCatalogue(); e.api.jcPredToggle("t2", null);
  for (const h of [e.body(), e.bar()]) { assert.doesNotMatch(h, /<img/); assert.doesNotMatch(h, /<script/); }
  assert.match(e.body(), /&lt;img src=x onerror=alert\(1\)&gt;/);
});

// ---------- cross-cutting ----------
test("no request body anywhere contains updated_at, created_at or baseline_* columns", async () => {
  const e = await loaded({ catalogue: CAT, phases: [] });
  await e.api.jcApplyPhaseTemplate(); await e.api.jcAddPhase(); await e.api.jcSchedEnsureCatalogue(); await e.api.jcAddFromCatalogue("0"); await e.api.jcAddTask();
  const id = e.api.jcTasks[0].id;
  await e.api.jcTaskSet(id, "task_name", "n"); await e.api.jcTaskSet(id, "start_date", "2026-05-01"); await e.api.jcTaskSet(id, "is_milestone", true); await e.api.jcTaskSet(id, "weight", "4");
  await e.api.jcTaskSet(id, "progress", "50"); await e.api.jcTaskSet(id, "client_visible", true); await e.api.jcTaskSet(id, "phase_id", e.api.jcSchedPhases[0].id);
  await e.api.jcPredChange(e.api.jcTasks[1].id, id, true); await e.api.jcPhaseRename(e.api.jcSchedPhases[0].id, "R"); await e.api.jcPhaseMove(e.api.jcSchedPhases[1].id, -1);
  await e.api.jcSchedSyncCritical(); await e.api.jcDeleteTask(id); await tick();
  const w = e.allWrites(); assert.ok(w.length > 12);
  for (const c of w) {
    for (const b of [].concat(c.body ?? [])) for (const k of Object.keys(b)) assert.doesNotMatch(k, /^(updated_at|created_at|baseline_)/, `${c.fn} ${c.table} sent ${k}`);
    assert.doesNotMatch(JSON.stringify(c), /updated_at|created_at|baseline_/);
  }
});
test("hooks: every successful edit calls KPI then Gantt (stubs), in that order", async () => {
  const e = await loaded();
  for (const [f, v] of [["progress", "40"], ["assignee", "Ann"], ["start_date", "2026-03-03"], ["weight", "3"], ["is_milestone", true]]) {
    e.log.order.length = 0; await e.api.jcTaskSet("t1", f, v); await tick();
    assert.deepEqual(e.log.order.slice(0, 2), ["kpi", "gantt"], f);
  }
  e.log.order.length = 0; await e.api.jcPredChange("t2", "t1", true); assert.deepEqual(e.log.order.slice(0, 2), ["kpi", "gantt"]);
  e.log.order.length = 0; await e.api.jcAddTask(); assert.deepEqual(e.log.order.slice(0, 2), ["kpi", "gantt"]);
  e.log.order.length = 0; await e.api.jcDeleteTask("t3"); assert.deepEqual(e.log.order.slice(0, 2), ["kpi", "gantt"]);
});
test("hooks: a missing KPI renderer (other leaf not merged yet) is tolerated; the Gantt hook still fires", async () => {
  const e = env({ ...base(), noKpi: true }); await e.api.jcLoadTasks(); await tick(); await e.api.jcTaskSet("t1", "progress", "10");
  assert.ok(e.log.order.length > 0 && e.log.order.every((x) => x === "gantt"));
});
test("rapid edits to one task are applied strictly in the order made, even when an earlier PATCH is slower", async () => {
  const e = await loaded(); const order = [];
  e.srv.patchHook = async (t, id, body) => { order.push(body.progress); if (body.progress === 10) await tick(15); };
  const a = e.api.jcTaskSet("t1", "progress", "10"); const b = e.api.jcTaskSet("t1", "progress", "90"); await Promise.all([a, b]);
  assert.deepEqual(order, [10, 90]); assert.equal(e.api.jcTasks[0].progress, 90);
});
test("v1 behaviours still hold: end before start refused, start past end drags the end, progress clamped, task_name trimmed, v1 loop check", async () => {
  const e = await loaded({ missing: true });
  await e.api.jcTaskSet("t1", "end_date", "2026-03-01"); assert.equal(e.writes().length, 0); assert.match(e.log.toasts[0][0], /End date cannot be before start/);
  await e.api.jcTaskSet("t1", "start_date", "2026-03-20"); assert.deepEqual(e.writes()[0].body, { start_date: "2026-03-20", end_date: "2026-03-20" });
  await e.api.jcTaskSet("t1", "progress", "250"); assert.deepEqual(e.writes().at(-1).body, { progress: 100 });
  await e.api.jcTaskSet("t1", "task_name", "  hi  "); assert.deepEqual(e.writes().at(-1).body, { task_name: "hi" });
  await e.api.jcTaskSet("t2", "depends_on", "t1"); assert.deepEqual(e.writes().at(-1).body, { depends_on: "t1" });
  e.log.toasts.length = 0; await e.api.jcTaskSet("t1", "depends_on", "t2"); assert.match(e.log.toasts[0][0], /circular/);
  const n = e.writes().length; await e.api.jcTaskSet("t1", "client_visible", true); await e.api.jcTaskSet("t1", "weight", "3"); assert.equal(e.writes().length, n, "v2-only columns are never sent in v1 mode");
  await tick(); assert.equal(e.log.calls.filter((c) => c.fn === "patchWhere").length, 0, "no is_critical cache writes without the migration");
});
test("delete task: asks first; v2 links to it are dropped locally; a double click deletes once", async () => {
  const e = await loaded({ confirm: false }); await e.api.jcDeleteTask("t1"); assert.equal(e.writes().length, 0);
  const f = await loaded({ links: [L("l1", "t2", "t1")] }); await Promise.all([f.api.jcDeleteTask("t1"), f.api.jcDeleteTask("t1")]);
  assert.equal(f.writes().filter((c) => c.fn === "delete").length, 1); assert.equal(f.api.jcSchedLinks.length, 0);
});
test("performance: 200 tasks with links render and sync well inside the budget", async () => {
  const tasks = Array.from({ length: 200 }, (_, i) => task("x" + i, { sort_order: i, start_date: addDays(i % 40), end_date: addDays((i % 40) + 3), phase_id: "p" + ((i % 3) + 1) }));
  const links = Array.from({ length: 199 }, (_, i) => L("k" + i, "x" + (i + 1), "x" + i));
  const e = env({ tasks, links, phases: base().phases }); await e.api.jcLoadTasks(); await tick(10);
  e.api.jcPredToggle("x100", null);
  const t0 = performance.now(); for (let i = 0; i < 5; i++) e.api.jcRenderTasks(); const per = (performance.now() - t0) / 5;
  assert.ok(per < 100, `render took ${per.toFixed(1)} ms`);
  assert.ok(e.log.calls.filter((c) => c.fn === "patchWhere").length <= 2);
});

// ---------- static pins ----------
test("static: markers, globals, markup, css, and the updated_at opt-out are in place", () => {
  const once = (s) => assert.equal(html.split(s).length - 1, 1, s);
  once("// ── SCHEDULE TASK TABLE ──"); once("// ── END SCHEDULE TASK TABLE ──"); once("/* schedule-table:begin */"); once("/* schedule-table:end */");
  assert.ok(html.includes("let jcTasks = [];\nlet jcSchedPhases = [];"), "globals declared right after jcTasks");
  assert.ok(/let jcSchedLinks = \[\];/.test(html));
  assert.ok(html.indexOf("// ── END SCHEDULE COMPUTE ──") < tableStart && tableStart < html.indexOf("async function jcLoadTasks()"));
  assert.match(html, /const NO_UPDATED_AT = new Set\(\['job_tasks','job_phases','job_task_links'/);
  for (const th of [">Phase<", ">Milestone<", ">Weight<", ">Predecessors<", ">Client<", ">Assignee<", ">% Done<"]) assert.ok(html.includes(th), th);
  assert.ok(/id="jc-sched-notice"/.test(html) && /id="jc-sched-phasebar"/.test(html));
  const own = tableBlock.slice(0, tableBlock.indexOf("// ── END SCHEDULE TASK TABLE ──")).replace(/\/\/.*$/gm, "");   // code only, comments stripped
  assert.doesNotMatch(own, /baseline_|updated_at|created_at/, "the block never mentions the guarded columns");
});
