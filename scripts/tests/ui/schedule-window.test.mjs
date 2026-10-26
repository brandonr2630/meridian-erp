// Tests for the A2a schedule window (index.html, SCHEDULE WINDOW block). Run: node --test scripts/tests/ui/schedule-window.test.mjs
// index.html is one big inline script, so the code under test is sliced out of it and run in a node:vm context against a small fake DOM
// that records innerHTML (so escaping can be asserted). The compute block and schedule-msp.js are the real ones; the Gantt renderer is
// stubbed here because it has its own tests. UI_SRC lets the mutation check point at a mutated copy of index.html.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const codecSrc = readFileSync(join(root, "schedule-msp.js"), "utf8");
const fx = (f) => readFileSync(join(root, "scripts", "tests", "schedule", "mspdi", f), "utf8");
const slice = (a, b) => { const i = html.indexOf(a), j = html.indexOf(b, i); assert.ok(i > 0 && j > i, "marker not found: " + a); return html.slice(i, j); };
const compute = slice("// ── SCHEDULE COMPUTE (shared) ──", "// ── END SCHEDULE COMPUTE ──");
const kpiHelpers = slice("const JC_KPI_MON", "function jcKpiState");
const escSrc = slice("function escHTML(s) {", "\n}\n") + "\n}\n";
const winBlock = slice("// ── SCHEDULE WINDOW ──", "// ── END SCHEDULE WINDOW ──");

const JOB = "0a1b2c3d-0000-4000-8000-000000000999";
const plain = (o) => JSON.parse(JSON.stringify(o));

function makeEl(id) {
  return { id, _html: "", textContent: "", style: {}, disabled: false, value: "", children: [], listeners: {}, clicked: 0,
    set innerHTML(v) { this._html = String(v); }, get innerHTML() { return this._html; },
    querySelectorAll() { return []; }, addEventListener(t, f) { (this.listeners[t] ??= []).push(f); }, click() { this.clicked++; }, appendChild(c) { this.children.push(c); }, remove() {} };
}
function load({ perms = ["ops:work-orders:read"], data = {} } = {}) {
  const els = {}, toasts = [], downloads = [], anchors = [], opened = [], gantt = { layout: [], draw: [] };
  const getEl = (id) => (els[id] ??= makeEl(id));
  for (const id of ["sw-title", "sw-sub", "sw-msg", "sw-main", "sw-export", "sw-import", "sw-notice", "sw-kpis", "sw-table", "sw-detail", "sw-gantt", "sw-import-panel", "sw-file"]) getEl(id);
  class FakeDate { getFullYear() { return 2026; } getMonth() { return 2; } getDate() { return 2; } }
  const calls = [];
  const ctx = {
    document: { getElementById: (id) => els[id] ?? null, createElement: (t) => { const a = makeEl(t); anchors.push(a); return a; }, body: makeEl("body") },
    window: { open: (...a) => opened.push(a) }, location: { pathname: "/index.html" }, Date: FakeDate, console: { warn() {}, log() {} },
    can: (p) => perms.includes(p), showToast: (m, t) => toasts.push([m, t]),
    sbGet: async (table, q) => { calls.push([table, q]); const h = data[table]; if (h instanceof Error) throw h; return typeof h === "function" ? h(q) : h; },
    jcGanttToday: () => "2026-03-02", JC_GANTT_ZOOM: { Day: 28, Week: 8, Month: 3 }, JC_GANTT_LEFT_W: 320,
    jcGanttLayout: (m) => { gantt.layout.push(m); return { today: null, empty: false }; }, jcGanttDraw: (el, layout, ui) => { gantt.draw.push({ el, layout, ui }); return { wrap: null }; },
    URL: { createObjectURL: (b) => { downloads.push(b); return "blob:x"; }, revokeObjectURL() {} }, Blob: class { constructor(parts, o) { this.parts = parts; this.type = o && o.type; } },
    setTimeout: (f) => 0, encodeURIComponent,
  };
  vm.createContext(ctx);
  const src = `(function(){\n${escSrc}\n${compute}\n${kpiHelpers}\n${codecSrc}\n${winBlock}\n` +
    `return { schedWin, schedWinJobIdFromHash, schedWinOpen, schedWinPredText, schedWinRows, schedWinBuildModel, schedWinFileName, loadScheduleWindow, schedWinRender,\n` +
    `  schedWinExport, schedWinImportFile, schedWinImportSummary, schedWinImportClose, schedWinSetZoom, schedWinRenderGantt, MspCodec, SCHED_WIN_MARKER, SCHED_WIN_NOTICE, escHTML,\n` +
    `  setJob(id) { _schedWinJobId = id; } };\n})()`;
  const api = vm.runInContext(src, ctx);   // trusted: sliced from this repo's own files
  return { api, els, toasts, downloads, anchors, opened, gantt, calls };
}
const uuid = (n) => "0a1b2c3d-0000-4000-8000-" + String(n).padStart(12, "0");
const task = (n, over = {}) => ({ id: uuid(n), task_name: "T" + n, sort_order: n * 10, start_date: "2026-03-09", end_date: "2026-03-12", progress: 0, is_milestone: false, phase_id: null, ...over });
const rows = (r) => r.map((x) => (x.kind === "phase" ? "P:" + x.phase.name : "T:" + x.task.task_name + (x.depth ? "@" + x.depth : "")));

// ---------- pure helpers ----------
test("job id from the hash: only #/schedule/<uuid>", () => {
  const { api } = load();
  const f = api.schedWinJobIdFromHash;
  assert.equal(f("#/schedule/" + JOB), JOB);
  assert.equal(f("schedule/" + JOB), JOB);
  assert.equal(f("#schedule/" + JOB), JOB);
  assert.equal(f("#/schedule/" + JOB.toUpperCase()), JOB);               // lower-cased
  for (const bad of ["#/schedule", "#/schedule/", "#/schedule/123", "#/work-orders/" + JOB, "#/schedule/" + JOB + "x", "#/schedule/'; drop", "", null, undefined, 42, "#/schedule/%00"]) assert.equal(f(bad), null, String(bad));
  assert.equal(f("#/schedule/" + JOB + "/extra"), JOB);                  // trailing segments are ignored, not trusted
});
test("opening the window: a new tab with only the job id in the address; a toast when the job is unsaved", () => {
  const { api, opened, toasts } = load();
  api.schedWinOpen(JOB);
  assert.deepEqual(plain(opened), [["/index.html#/schedule/" + JOB, "_blank", "noopener"]]);
  api.schedWinOpen(null);
  assert.equal(opened.length, 1);
  assert.equal(toasts.length, 1);
});
test("rows: phases in order with their tasks, unphased last, indent from parent_task_id", () => {
  const { api } = load();
  const phases = [{ id: "p2", name: "Reassembly", sort_order: 20 }, { id: "p1", name: "Teardown", sort_order: 10 }];
  const tasks = [task(1, { phase_id: "p1" }), task(2, { phase_id: "p2" }), task(3, { phase_id: "p1", parent_task_id: uuid(1) }), task(4), task(5, { phase_id: "gone" }),
    task(6, { phase_id: "p1", parent_task_id: uuid(3) })];
  assert.deepEqual(plain(rows(api.schedWinRows(tasks, phases))), ["P:Teardown", "T:T1", "T:T3@1", "T:T6@2", "P:Reassembly", "T:T2", "P:Unphased", "T:T4", "T:T5"]);
  assert.deepEqual(plain(rows(api.schedWinRows([task(1), task(2)], []))), ["T:T1", "T:T2"]);   // no phases: no "Unphased" header
  assert.deepEqual(plain(api.schedWinRows(null, null)), []);
  const cyc = [task(1, { parent_task_id: uuid(2) }), task(2, { parent_task_id: uuid(1) })];
  assert.equal(api.schedWinRows(cyc, []).length, 2);                      // a parent cycle does not hang
});
test("predecessor text: type, signed lag, truncation, missing predecessors skipped", () => {
  const { api } = load();
  const ts = [task(1, { task_name: "Inspect" }), task(2), task(3, { task_name: "x".repeat(40) })], byId = new Map(ts.map((t) => [t.id, t]));
  const links = [{ task_id: uuid(2), predecessor_id: uuid(1), lag_days: 2 }, { task_id: uuid(2), predecessor_id: uuid(3), lag_days: -1, link_type: "SS" },
    { task_id: uuid(2), predecessor_id: "missing", lag_days: 0 }, { task_id: uuid(2), predecessor_id: uuid(1), link_type: "XX", lag_days: 0 }, { task_id: uuid(1), predecessor_id: uuid(2) }];
  assert.equal(api.schedWinPredText(ts[1], links, byId), "Inspect FS+2d, " + "x".repeat(27) + "… SS-1d, Inspect FS");
  assert.equal(api.schedWinPredText(ts[0], links, byId), "T2 FS");
  assert.equal(api.schedWinPredText(ts[2], links, byId), "");
});
test("file name is safe", () => {
  const { api } = load();
  assert.equal(api.schedWinFileName({ job_no: "Q2-0142" }), "WO-Q2-0142-schedule.xml");
  assert.equal(api.schedWinFileName({ job_no: "../../etc/passwd\\x:" }), "WO-.._.._etc_passwd_x_-schedule.xml");
  assert.equal(api.schedWinFileName(null), "WO-schedule-schedule.xml");
  assert.ok(api.schedWinFileName({ job_no: "a".repeat(200) }).length < 70);
});

// ---------- export model ----------
const phases = [{ id: "p1", name: "Teardown", sort_order: 10 }, { id: "p2", name: "Reassembly", sort_order: 20 }];
const tasks = [
  task(1, { phase_id: "p1", task_name: "Inspect <motor>", start_date: "2026-03-02", end_date: "2026-03-04", progress: 100, is_critical: true, baseline_start: "2026-03-02", baseline_end: "2026-03-03" }),
  task(2, { phase_id: "p1", task_name: "Remove bearings", start_date: "2026-03-05", end_date: "2026-03-10", progress: 40 }),
  task(3, { phase_id: "p2", task_name: "Fit", start_date: "2026-03-11", end_date: "2026-03-13" }),
  task(4, { task_name: "Delivery", start_date: "2026-03-16", end_date: "2026-03-16", is_milestone: true }),
];
const links = [{ task_id: uuid(2), predecessor_id: uuid(1), lag_days: 1 }, { task_id: uuid(3), predecessor_id: uuid(2), lag_days: 0, link_type: "SS" },
  { task_id: uuid(4), predecessor_id: uuid(3), lag_days: -2, link_type: "FF" }, { task_id: uuid(4), predecessor_id: "gone", lag_days: 0 }, { task_id: uuid(3), predecessor_id: uuid(3), lag_days: 0 }];
test("export model: temporary UIDs from 1,000,001, phases first; unknown and self links skipped; builds and parses back", () => {
  const { api } = load();
  const m = plain(api.schedWinBuildModel({ id: JOB, job_no: "Q2-0142", description: "Motor repair" }, tasks, phases, links));
  assert.deepEqual(m.phases.map((p) => p.uid), [1000001, 1000002]);
  assert.deepEqual(m.tasks.map((t) => t.uid), [1000003, 1000004, 1000005, 1000006]);
  assert.deepEqual(m.project, { id: JOB, name: "Q2-0142", title: "Q2-0142 Motor repair" });
  assert.deepEqual(m.tasks[1].links, [{ pred_uid: 1000003, link_type: "FS", lag_days: 1 }]);
  assert.deepEqual(m.tasks[2].links, [{ pred_uid: 1000004, link_type: "SS", lag_days: 0 }]);   // the self link is gone
  assert.deepEqual(m.tasks[3].links, [{ pred_uid: 1000005, link_type: "FF", lag_days: -2 }]);  // the link to an unknown task is gone
  assert.equal(m.tasks[3].phase_uid, null);
  assert.equal(m.tasks[0].is_critical, true);
  const xml = api.MspCodec.build(m, { notice: api.SCHED_WIN_NOTICE, manager: api.SCHED_WIN_MARKER });
  const back = plain(api.MspCodec.toPayload(api.MspCodec.parse(xml)));
  assert.equal(back.tasks.length, 4);
  assert.deepEqual(back.tasks.map((t) => t.name), ["Inspect <motor>", "Remove bearings", "Fit", "Delivery"]);
  assert.deepEqual(back.tasks.find((t) => t.name === "Delivery").links.map((l) => [l.link_type, l.lag_days]), [["FF", -2]]);
  assert.equal(api.MspCodec.parse(xml).project.uid, JOB);
  assert.equal(api.MspCodec.parse(xml).project.manager, api.SCHED_WIN_MARKER);
});
test("export model: fractional lags are rounded to whole days", () => {
  const { api } = load();
  const ts = [task(1), task(2), task(3)];
  const m = plain(api.schedWinBuildModel({ id: JOB }, ts, [], [{ task_id: uuid(2), predecessor_id: uuid(1), lag_days: 1.6 }, { task_id: uuid(3), predecessor_id: uuid(1), lag_days: "-1.4" }]));
  assert.deepEqual([m.tasks[1].links[0].lag_days, m.tasks[2].links[0].lag_days], [2, -1]);
});
test("export model: a task with only a name or no dates still builds", () => {
  const { api } = load();
  const m = api.schedWinBuildModel({ id: JOB }, [{ id: "a", task_name: "", progress: "x" }], null, null);
  assert.equal(plain(m).tasks[0].name, "(unnamed)");
  assert.doesNotThrow(() => api.MspCodec.build(m));
});

// ---------- loading ----------
const okData = () => ({ jobs: [{ id: JOB, job_no: "Q2-0142", description: "Motor repair", status: "In Progress", due_date: null, company_id: "c1" }], job_tasks: tasks, job_phases: phases, job_task_links: links });
test("load: queries by job id, fills the state, computes and renders", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB);
  await t.api.loadScheduleWindow();
  const w = t.api.schedWin;
  assert.equal(w.error, "");
  assert.equal(w.tasks.length, 4);
  assert.equal(w.v2, true);
  assert.ok(w.compute && typeof w.compute.status === "string");
  assert.deepEqual(t.calls.map((c) => c[0]).sort(), ["job_phases", "job_task_links", "job_tasks", "jobs"]);
  assert.ok(t.calls.every((c) => c[1].includes(JOB)));
  assert.ok(t.calls.find((c) => c[0] === "jobs")[1].includes("select=id,job_no,description,status,due_date,company_id"), "no commercial job columns are requested");
  assert.equal(t.els["sw-title"].textContent, "Schedule · Q2-0142");
  assert.equal(t.els["sw-main"].style.display, "");
  assert.equal(t.els["sw-export"].disabled, false);
  assert.ok(t.els["sw-table"].innerHTML.includes("Remove bearings"));
  assert.ok(t.els["sw-table"].innerHTML.includes("FS+1d"));
  assert.ok(t.els["sw-table"].innerHTML.includes("SS"));
  assert.ok(t.els["sw-kpis"].innerHTML.includes("Overall progress"));
  assert.ok(t.els["sw-table"].innerHTML.includes('>0%</td>'), "a task at 0% reads 0%, not an empty cell");
  assert.ok(/>0 d<\/td>/.test(t.els["sw-table"].innerHTML) || /sw-nw">-?\d+ d<\/td>/.test(t.els["sw-table"].innerHTML), "slack is shown with its unit");
  assert.equal(t.gantt.layout.length, 1);
  assert.equal(t.gantt.layout[0].pxPerDay, 28);
  assert.equal(t.gantt.layout[0].tasks.length, 4);
  assert.equal(t.els["sw-notice"].style.display, "none");
});
test("load: before the schedule upgrade the single depends_on parent is used and a notice shows", async () => {
  const d = okData(); d.job_phases = new Error("relation does not exist"); d.job_tasks = [task(1), task(2, { depends_on: uuid(1) })];
  const t = load({ data: d });
  t.api.setJob(JOB);
  await t.api.loadScheduleWindow();
  assert.equal(t.api.schedWin.v2, false);
  assert.deepEqual(plain(t.api.schedWin.links), [{ task_id: uuid(2), predecessor_id: uuid(1), lag_days: 0 }]);
  assert.deepEqual(plain(t.api.schedWin.phases), []);
  assert.notEqual(t.els["sw-notice"].style.display, "none");
  assert.ok(t.els["sw-notice"].textContent.includes("not applied"));
});
test("load: failures show a message and never the table", async () => {
  const check = async (setup, text, perms) => {
    const t = load({ perms, data: setup });
    t.api.setJob(setup && setup.__id !== undefined ? setup.__id : JOB);
    await t.api.loadScheduleWindow();
    assert.ok(t.api.schedWin.error.includes(text), t.api.schedWin.error);
    assert.equal(t.els["sw-msg"].style.display, "");
    assert.equal(t.els["sw-main"].style.display, "none");
    assert.equal(t.els["sw-export"].disabled, true);
    assert.equal(t.els["sw-import"].disabled, true);
    return t;
  };
  await check({ __id: "not-a-uuid" }, "does not point to a schedule", ["ops:work-orders:read"]);
  await check({ __id: null }, "does not point to a schedule", ["ops:work-orders:read"]);
  const denied = await check(okData(), "do not have access", []);
  assert.equal(denied.calls.length, 0, "no query is sent without the permission");
  await check({ ...okData(), jobs: [] }, "not found", ["ops:work-orders:read"]);
  await check({ ...okData(), jobs: new Error("JWT expired") }, "JWT expired", ["ops:work-orders:read"]);
});
test("load: a newer load supersedes a slower older one", async () => {
  let release, calls = 0; const gate = new Promise((r) => { release = r; });
  const d = okData();
  d.jobs = async () => { calls++; if (calls === 1) { await gate; return [{ id: JOB, job_no: "OLD", description: "", status: "In Progress", due_date: null }]; } return [{ id: JOB, job_no: "NEW", description: "", status: "In Progress", due_date: null }]; };
  const t = load({ data: d });
  t.api.setJob(JOB);
  const p1 = t.api.loadScheduleWindow();          // slow: its job query waits on the gate
  const p2 = t.api.loadScheduleWindow();          // fast: finishes first
  await p2;
  assert.equal(t.api.schedWin.job.job_no, "NEW");
  release(); await p1;
  assert.equal(t.api.schedWin.job.job_no, "NEW", "the late, older response must not overwrite the newer one");
  assert.equal(t.els["sw-title"].textContent, "Schedule · NEW");
});

// ---------- escaping ----------
test("every dynamic string is escaped in the table, details, KPIs and import preview", async () => {
  const evil = '<img src=x onerror=alert(1)>"\'&';
  const d = okData();
  d.job_tasks = [task(1, { phase_id: "p1", task_name: evil, assignee: evil }), task(2, { phase_id: "p1", task_name: "ok" })];
  d.job_phases = [{ id: "p1", name: evil, sort_order: 10 }];
  d.job_task_links = [{ task_id: uuid(2), predecessor_id: uuid(1), lag_days: 1 }];
  d.jobs = [{ id: JOB, job_no: evil, description: evil, status: "In Progress", due_date: null }];
  const t = load({ data: d });
  t.api.setJob(JOB);
  await t.api.loadScheduleWindow();
  t.api.schedWin.selected = uuid(1);
  t.api.schedWinRender();
  for (const id of ["sw-table", "sw-detail", "sw-kpis"]) {
    const h = t.els[id].innerHTML;
    assert.ok(!/<img/i.test(h) && !/onerror=alert\(1\)>/.test(h), id + " has raw markup: " + h.slice(0, 200));
  }
  assert.ok(t.els["sw-table"].innerHTML.includes("&lt;img"));
  assert.ok(t.els["sw-detail"].innerHTML.includes("&lt;img"));
  assert.equal(t.els["sw-title"].textContent, "Schedule · " + evil);       // textContent, not innerHTML
  const hostile = `<?xml version="1.0"?><Project xmlns="http://schemas.microsoft.com/project"><Tasks><Task><UID>1</UID><Name>&lt;img src=x onerror=alert(1)&gt;</Name><OutlineLevel>1</OutlineLevel></Task></Tasks></Project>`;
  await t.api.schedWinImportFile({ name: '<b>f</b>.xml', size: hostile.length, text: async () => hostile });
  const h = t.els["sw-import-panel"].innerHTML;
  assert.ok(!/<img/i.test(h) && !/<b>f/.test(h), h);
  assert.ok(h.includes("&lt;img"));
});

// ---------- export ----------
test("export: builds MS Project XML with the temporary-UID marker and downloads it under a safe name", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  t.api.schedWinExport();
  assert.equal(t.downloads.length, 1);
  const xml = t.downloads[0].parts[0];
  assert.equal(t.downloads[0].type, "application/xml");
  assert.ok(xml.includes("<Manager>meridian-readonly-export</Manager>") && xml.includes("Confidential. Schedule data owned by Q2 Machines."));
  assert.ok(xml.includes("<UID>1000003</UID>") && !xml.includes("<UID>" + uuid(1) + "</UID>"), "temporary task UIDs; real task ids never leave the browser");
  const a = t.anchors.find((x) => x.id === "a");
  assert.equal(a.download, "WO-Q2-0142-schedule.xml");
  assert.equal(a.clicked, 1);
  assert.equal(t.toasts.at(-1)[1], "success");
  const noJob = load();
  noJob.api.schedWinExport();
  assert.equal(noJob.downloads.length, 0);
});

// ---------- import dry run ----------
test("import: a ProjectLibre file is parsed and previewed; Apply is disabled and says why", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  const xml = fx("01-simple-fs.xml");
  await t.api.schedWinImportFile({ name: "01-simple-fs.xml", size: xml.length, text: async () => xml });
  const imp = t.api.schedWin.imp, h = t.els["sw-import-panel"].innerHTML;
  assert.equal(imp.error, "");
  assert.deepEqual(plain(t.api.schedWinImportSummary(imp.payload)), { phases: 1, tasks: 13, summaries: 0, milestones: 2, links: 12, types: { FS: 8, SS: 2, FF: 1, SF: 1 }, resources: 0 });
  assert.ok(h.includes("1 phase · 13 tasks"));
  assert.ok(h.includes("FS 8, SS 2, FF 1, SF 1"));
  assert.ok(h.includes("0 resources") && h.includes("0 summary"), "zero counts are printed, not dropped");
  assert.ok(h.includes("Receive Motor"));
  assert.ok(/<button class="btn btn-primary btn-sm" disabled>Apply import<\/button>/.test(h));
  assert.ok(h.includes("not available yet"));
  assert.ok(h.includes("Not exported from this work order"));
  assert.equal(t.els["sw-import-panel"].style.display, "");
  t.api.schedWinImportClose();
  assert.equal(t.els["sw-import-panel"].style.display, "none");
  assert.equal(t.els["sw-import-panel"].textContent, "");
});
test("import: our own export is recognised only when it has stable IDs (not the temporary-UID marker)", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  const m = t.api.schedWinBuildModel(t.api.schedWin.job, tasks, phases, links);
  const stable = t.api.MspCodec.build(m), temp = t.api.MspCodec.build(m, { manager: t.api.SCHED_WIN_MARKER });
  await t.api.schedWinImportFile({ name: "a.xml", size: stable.length, text: async () => stable });
  assert.ok(t.els["sw-import-panel"].innerHTML.includes("Exported from this work order"));
  await t.api.schedWinImportFile({ name: "b.xml", size: temp.length, text: async () => temp });
  assert.ok(t.els["sw-import-panel"].innerHTML.includes("Not exported from this work order"));
});
test("import: rejected files show the codec's message and no preview", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  const bad = async (name, size, text, msg) => {
    await t.api.schedWinImportFile({ name, size, text: async () => text });
    assert.ok(t.api.schedWin.imp.error.includes(msg), t.api.schedWin.imp.error);
    assert.equal(t.api.schedWin.imp.payload, null);
    assert.ok(t.els["sw-import-panel"].innerHTML.includes("sw-err"));
    assert.ok(!t.els["sw-import-panel"].innerHTML.includes("Apply import"));
  };
  await bad("x.xml", 100, '<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "y">]><Project xmlns="http://schemas.microsoft.com/project"/>', "DOCTYPE");
  await bad("p.pod", 100, "¬í\u0000\u0005", "not XML");
  await bad("big.xml", 6 * 1024 * 1024, "never read", "larger than 5 MB");
  await t.api.schedWinImportFile({ name: "boom.xml", size: 10, text: async () => { throw new Error("disk"); } });
  assert.equal(t.api.schedWin.imp.error, "The file could not be read.");
  await t.api.schedWinImportFile(null);                                     // cancelling the picker changes nothing
  assert.equal(t.api.schedWin.imp.error, "The file could not be read.");
});
test("import: the preview lists at most 200 rows and says how many more there are", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  const rowsXml = Array.from({ length: 250 }, (_, i) => `<Task><UID>${i + 1}</UID><Name>Row ${i + 1}</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-02T08:00:00</Start><Finish>2026-03-02T17:00:00</Finish><Duration>PT8H0M0S</Duration></Task>`).join("");
  const xml = `<?xml version="1.0"?><Project xmlns="http://schemas.microsoft.com/project"><Tasks>${rowsXml}</Tasks></Project>`;
  await t.api.schedWinImportFile({ name: "many.xml", size: xml.length, text: async () => xml });
  const h = t.els["sw-import-panel"].innerHTML;
  assert.equal((h.match(/<tr><td>Task<\/td>/g) || []).length, 200);
  assert.ok(h.includes("and 50 more rows"));
  assert.ok(h.includes("0 phases · 250 tasks"));
});
test("import: a file read that finishes after the preview was replaced is ignored", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  let release; const gate = new Promise((r) => { release = r; });
  const xml = fx("07-synthetic-material.xml");
  const p1 = t.api.schedWinImportFile({ name: "slow.xml", size: 10, text: async () => { await gate; return xml; } });
  await t.api.schedWinImportFile({ name: "fast.xml", size: xml.length, text: async () => xml });
  release(); await p1;
  assert.ok(t.els["sw-import-panel"].innerHTML.includes("fast.xml"));
  assert.ok(t.els["sw-import-panel"].innerHTML.includes("Material resources"), "the synthetic material warning is shown");
});

// ---------- zoom ----------
test("zoom: Week and Month change the pixel scale; anything else falls back to Day", async () => {
  const t = load({ data: okData() });
  t.api.setJob(JOB); await t.api.loadScheduleWindow();
  t.api.schedWinSetZoom("Week"); t.api.schedWinSetZoom("Month");
  assert.equal(t.api.schedWin.zoom, "Month");
  t.api.schedWinSetZoom("nonsense");
  assert.equal(t.api.schedWin.zoom, "Day");
  assert.deepEqual(t.gantt.layout.map((l) => l.pxPerDay), [28, 8, 3, 28]);
});

// ---------- wiring in index.html ----------
test("wiring: route, guard, loader, card button, view markup, script tag", () => {
  assert.ok(html.includes('<script src="schedule-msp.js"></script>'));
  assert.ok(html.indexOf('<script src="schedule-msp.js"></script>') < html.indexOf("// ── SCHEDULE WINDOW ──"), "the codec loads before the code that uses it");
  assert.ok(html.includes("operations: ['work-orders','job-costing','delivery-notes','job-config','schedule']"));
  assert.ok(html.includes("case 'schedule': await loadScheduleWindow(); break;"));
  assert.ok(html.includes("if (view === 'schedule') {   // #/schedule/<job_id>"));
  assert.ok(html.includes("'#/schedule/' + jid"));
  assert.ok(html.includes("'#/' + view + (view === 'schedule' && _schedWinJobId ? '/' + _schedWinJobId : '')"));
  assert.ok(html.includes('id="view-schedule"') && html.includes('onclick="schedWinOpen(jcCurrentJobId)"'));
  for (const id of ["sw-title", "sw-sub", "sw-msg", "sw-main", "sw-notice", "sw-kpis", "sw-table", "sw-detail", "sw-gantt", "sw-import-panel", "sw-file", "sw-export", "sw-import", "sw-zoom"]) assert.ok(html.includes(`id="${id}"`), id);
  assert.ok(/id="sw-import"[^>]*disabled/.test(html) && /id="sw-export"[^>]*disabled/.test(html), "buttons start disabled until a schedule has loaded");
});
test("the window block never talks to the network except through sbGet reads", () => {
  assert.ok(!/\bfetch\s*\(|XMLHttpRequest|sbPost|sbPatch|sbDelete|rpc\//.test(winBlock), "read-only: no writes, no RPC");
  assert.ok(!/localStorage|sessionStorage/.test(winBlock));
  assert.ok(!/requestFullscreen/.test(winBlock));
});
