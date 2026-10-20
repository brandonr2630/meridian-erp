// Tests for the Phase A KPI strip + baseline lock UI. Run: node --test scripts/tests/ui/schedule-kpi.test.mjs
// Like work-orders-readonly.test.mjs, the code under test is sliced out of index.html (the SCHEDULE KPI block, the real
// SCHEDULE COMPUTE block and escHTML) and run in a vm against a tiny fake DOM. UI_SRC points the run at a mutated copy.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const slice = (a, b) => html.slice(html.indexOf(a), html.indexOf(b) + b.length);
const KPI = slice("// ── SCHEDULE KPI ──", "// ── END SCHEDULE KPI ──");
const COMPUTE = slice("// ── SCHEDULE COMPUTE (shared) ──", "// ── END SCHEDULE COMPUTE ──");
const ESC = html.match(/function escHTML\(s\) \{[\s\S]*?\n\}\n/)[0];
assert.ok(KPI.length > 500 && COMPUTE.length > 500 && ESC, "could not slice the code under test");

const NOW = "2026-10-20T12:00:00";   // fixed local 'today' for every test
const JOB = "11111111-1111-1111-1111-111111111111";

function env({ perms = ["ops:work-orders:approve", "ops:work-orders:write"], readOnly = false, jobId = JOB, status = "In Progress", due = "2026-11-30",
  tasks = [], phases, links, declareGlobals = true, confirm = true, sbImpl, auditRows = [{ username: "Ann Lee" }], noContainer = false, noLoad = false, now = NOW } = {}) {
  const log = { toasts: [], sb: [], sbGet: [], confirms: [], loads: 0 };
  const box = { innerHTML: "", textContent: "" };
  const reason = { value: "", focus() { log.focused = true; } };
  const nodes = { "jc-sched-kpis": noContainer ? null : box, "jc-job-no-display": { textContent: "WO-0042" }, "jc-f-due-date": { value: due || "" } };
  const document = { getElementById: (id) => (id === "jc-kpi-reason" ? (box.innerHTML.includes('id="jc-kpi-reason"') ? reason : null) : nodes[id] ?? null),
    querySelector: () => (status == null ? null : { textContent: status }) };
  class FakeDate extends Date { constructor(...a) { super(...(a.length ? a : [now])); } }
  const ctx = { document, Date: FakeDate, Promise, console,
    can: (p) => perms.includes(p), jcIsReadOnlyRole: () => readOnly,
    showToast: (m, t) => log.toasts.push(t === undefined ? [m] : [m, t]),
    showConfirm: async (...a) => { log.confirms.push(a); return confirm; },
    sb: sbImpl ? (...a) => { log.sb.push(plain(a)); return sbImpl(...a); } : async (...a) => { log.sb.push(plain(a)); return null; },
    sbGet: async (...a) => { log.sbGet.push(plain(a)); if (auditRows instanceof Error) throw auditRows; return auditRows; } };
  const decl = declareGlobals ? "let jcTasks = __t.tasks, jcSchedPhases = __t.phases, jcSchedLinks = __t.links, jcCurrentJobId = __t.jobId;" : "";
  const loader = noLoad ? "" : "async function jcLoadTasks(){ __log.loads++; jcRenderSchedKpis(); }";
  ctx.__t = { tasks, phases, links, jobId }; ctx.__log = log;
  const names = ["jcRenderSchedKpis", "jcSchedJobCtx", "jcSchedToday", "jcKpiLockClick", "jcKpiConfirmRebaseline", "jcKpiCancel", "jcKpiReasonInput", "jcKpiFmtDate", "jcRpc"];
  // trusted code sliced from this repo's own index.html, run in a vm holding only the fake globals above
  const code = `(function(){ ${decl}\n${ESC}\n${COMPUTE}\n${loader}\n${KPI}\nreturn { ${names.join(", ")} }; })()`;
  vm.createContext(ctx);
  const api = vm.runInContext(code, ctx);
  return { api, box, reason, log, ctx };
}
const plain = (x) => JSON.parse(JSON.stringify(x));   // realm-neutral copy so deepStrictEqual compares structure
const flush = () => new Promise((r) => setTimeout(r, 0));
const text = (h) => h.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");
const LOCKED = "2026-10-02T09:30:00+00:00";
const task = (o = {}) => ({ id: "t" + Math.random().toString(36).slice(2, 7), task_name: "T", start_date: "2026-10-15", end_date: "2026-10-24", progress: 60,
  baseline_start: "2026-10-15", baseline_end: "2026-10-24", baseline_locked_at: LOCKED, ...o });

// ---------- tiles ----------
test("on track: 60% done, 60% planned, green pill, forecast line with delta against the due date", () => {
  const e = env({ tasks: [task()] }); e.api.jcRenderSchedKpis();
  const t = text(e.box.innerHTML);
  assert.match(t, /Overall progress 60%/); assert.match(t, /planned 60% today/);
  assert.match(e.box.innerHTML, /jc-kpi2-pill ok">On track</);
  assert.match(t, /Handover forecast \d\d \w{3} · due 30 Nov \(−\d+ d\)/);
  assert.doesNotMatch(t, /No baseline/);
  assert.match(e.box.innerHTML, /class="jc-kpi2-fill" style="width:60%"/); assert.match(e.box.innerHTML, /jc-kpi2-plan" style="left:60%"/);
});
test("at risk: far behind plan gives the amber pill", () => {
  const e = env({ tasks: [task({ progress: 10 })] }); e.api.jcRenderSchedKpis();
  assert.match(e.box.innerHTML, /jc-kpi2-pill warn">At risk</);
});
test("late: overdue critical task gives the red pill", () => {
  const e = env({ tasks: [task({ start_date: "2026-10-01", end_date: "2026-10-10", baseline_start: "2026-10-01", baseline_end: "2026-10-10", progress: 50 })] });
  e.api.jcRenderSchedKpis(); assert.match(e.box.innerHTML, /jc-kpi2-pill bad">Late</);
});
test("complete / on hold come from the job status; on hold greys the forecast", () => {
  const c = env({ tasks: [task({ progress: 100 })], status: "Completed" }); c.api.jcRenderSchedKpis();
  assert.match(c.box.innerHTML, /jc-kpi2-pill done">Complete</);
  const h = env({ tasks: [task()], status: "On Hold" }); h.api.jcRenderSchedKpis();
  assert.match(h.box.innerHTML, /jc-kpi2-pill hold">On hold</); assert.match(h.box.innerHTML, /jc-kpi2-sub jc-kpi2-grey">Handover forecast/);
  assert.match(h.box.innerHTML, /jc-kpi2 jc-kpi2-dim/);
});
test("no baseline: the tile says so and the status falls back to the due-date rule", () => {
  const e = env({ tasks: [task({ baseline_start: null, baseline_end: null, baseline_locked_at: null })], due: "2026-10-10" }); e.api.jcRenderSchedKpis();
  assert.match(text(e.box.innerHTML), /No baseline/); assert.doesNotMatch(e.box.innerHTML, /jc-kpi-caption/);
  assert.match(e.box.innerHTML, /jc-kpi2-pill (warn|bad)"/);   // forecast is past the (earlier) due date
});
test("no tasks: 0%, 'No tasks yet', 'Not scheduled'; unscheduled tasks also read 'Not scheduled'", () => {
  const e = env({ tasks: [] }); e.api.jcRenderSchedKpis();
  const t = text(e.box.innerHTML); assert.match(t, /0%/); assert.match(t, /No tasks yet/); assert.match(t, /Not scheduled/);
  assert.doesNotMatch(e.box.innerHTML, /jc-kpi2-plan/);
  const u = env({ tasks: [{ id: "a", task_name: "x", progress: 0 }] }); u.api.jcRenderSchedKpis(); assert.match(text(u.box.innerHTML), /Not scheduled/);
});
test("date format is 'dd Mon', with the year only when it is not the current year", () => {
  const e = env({ tasks: [task()], due: "2027-03-10" }); e.api.jcRenderSchedKpis();
  assert.match(text(e.box.innerHTML), /due 10 Mar 2027/);
  assert.equal(e.api.jcKpiFmtDate("2026-03-05"), "05 Mar"); assert.equal(e.api.jcKpiFmtDate("garbage"), ""); assert.equal(e.api.jcKpiFmtDate(null), "");
  assert.equal(e.api.jcSchedToday(), "2026-10-20");
});
test("forecast after the due date shows +N d; no due date says so", () => {
  const e = env({ tasks: [task({ progress: 0 })], due: "2026-10-20" }); e.api.jcRenderSchedKpis();
  assert.match(text(e.box.innerHTML), /due 20 Oct \(\+\d+ d\)/);
  const n = env({ tasks: [task()], due: null }); n.api.jcRenderSchedKpis(); assert.match(text(n.box.innerHTML), /no due date/);
});

// ---------- escaping ----------
test("XSS strings in the audit name, status and due date are never interpreted as HTML", async () => {
  const evil = "<img src=x onerror=alert(1)>";
  const e = env({ tasks: [task({ task_name: evil })], auditRows: [{ username: evil }], status: evil, due: evil });
  e.api.jcRenderSchedKpis(); await flush();
  assert.ok(!e.box.innerHTML.includes("<img"), e.box.innerHTML);
  assert.match(e.box.innerHTML, /&lt;img src=x onerror=alert\(1\)&gt;/);   // the name is shown as text
});
test("a hostile reason text in the re-baseline form is escaped when re-rendered", async () => {
  const e = env({ tasks: [task()] }); await e.api.jcKpiLockClick();
  e.api.jcKpiReasonInput('"><img src=x onerror=1>'); e.api.jcRenderSchedKpis();
  assert.ok(!e.box.innerHTML.includes("<img"), e.box.innerHTML);
});

// ---------- caption + audit ----------
test("caption shows the latest lock date and the audit name; the audit lookup is one query and cached", async () => {
  const e = env({ tasks: [task({ baseline_locked_at: "2026-09-01T00:00:00Z" }), task()] });
  e.api.jcRenderSchedKpis(); await flush();
  assert.match(text(e.box.innerHTML), /Baseline locked 02 Oct by Ann Lee/);
  e.api.jcRenderSchedKpis(); e.api.jcRenderSchedKpis(); await flush();
  assert.equal(e.log.sbGet.length, 1);
  const burst = env({ tasks: [task()] }); for (let i = 0; i < 3; i++) burst.api.jcRenderSchedKpis(); await flush();
  assert.equal(burst.log.sbGet.length, 1, "renders while the lookup is in flight must not refetch");
  assert.deepEqual(e.log.sbGet[0], ["job_audit_log", `job_id=eq.${JOB}&action_type=in.(baseline_locked,baseline_reset)&order=created_at.desc&limit=1`]);
});
test("audit lookup failure or empty result: caption without a name; no baseline: no lookup", async () => {
  const f = env({ tasks: [task()], auditRows: new Error("boom") }); f.api.jcRenderSchedKpis(); await flush();
  assert.match(text(f.box.innerHTML), /Baseline locked 02 Oct/); assert.doesNotMatch(f.box.innerHTML, / by /);
  const n = env({ tasks: [task({ baseline_locked_at: null })] }); n.api.jcRenderSchedKpis(); await flush();
  assert.equal(n.log.sbGet.length, 0);
});

// ---------- button visibility ----------
const btn = (e) => /id="jc-kpi-lock"[^>]*>([^<]*)</.exec(e.box.innerHTML)?.[1] ?? null;
test("button matrix", () => {
  const show = (o) => { const e = env({ tasks: [task({ baseline_locked_at: null })], ...o }); e.api.jcRenderSchedKpis(); return btn(e); };
  assert.equal(show({}), "Lock baseline");
  assert.equal(show({ perms: ["ops:work-orders:write"] }), null);               // no approve
  assert.equal(show({ perms: [] }), null);
  assert.equal(show({ readOnly: true }), null);                                  // read-only role never sees it
  assert.equal(show({ jobId: null }), null);                                     // unsaved job
  assert.equal(show({ tasks: [] }), null);                                       // no tasks
  assert.equal(show({ tasks: [{ id: "u", progress: 0 }] }), null);               // no dated task
  assert.equal(show({ tasks: [task({ baseline_locked_at: null, end_date: null })] }), null);
  const e = env({ tasks: [task()] }); e.api.jcRenderSchedKpis(); assert.equal(btn(e), "Re-baseline");
});

// ---------- lock flow ----------
test("first lock: confirm dialog, then exactly one RPC with the exact body, toast, tasks reloaded", async () => {
  const e = env({ tasks: [task({ baseline_locked_at: null })] }); e.api.jcRenderSchedKpis();
  await e.api.jcKpiLockClick();
  assert.equal(e.log.confirms.length, 1);
  assert.equal(e.log.sb.length, 1);
  assert.deepEqual(e.log.sb[0], ["rpc/lock_job_baseline", { method: "POST", body: { p_job_id: JOB, p_reason: null } }]);
  assert.deepEqual(e.log.toasts, [["Baseline locked."]]); assert.equal(e.log.loads, 1);
});
test("first lock cancelled in the dialog: no RPC", async () => {
  const e = env({ tasks: [task({ baseline_locked_at: null })], confirm: false }); await e.api.jcKpiLockClick();
  assert.equal(e.log.sb.length, 0); assert.equal(e.log.loads, 0);
});
test("re-baseline opens the reason form (no dialog, no RPC); empty or blank reason blocks the call", async () => {
  const e = env({ tasks: [task()] }); await e.api.jcKpiLockClick();
  assert.equal(e.log.confirms.length, 0); assert.equal(e.log.sb.length, 0);
  assert.match(e.box.innerHTML, /id="jc-kpi-reason"/); assert.equal(e.log.focused, true);
  await e.api.jcKpiConfirmRebaseline(); e.reason.value = "   "; await e.api.jcKpiConfirmRebaseline();
  assert.equal(e.log.sb.length, 0); assert.equal(e.log.toasts.length, 2); assert.match(e.log.toasts[0][0], /reason is required/i);
});
test("re-baseline with a reason: one RPC with the trimmed reason, form closed, tasks reloaded", async () => {
  const e = env({ tasks: [task()] }); await e.api.jcKpiLockClick();
  e.reason.value = "  Client moved the handover  "; await e.api.jcKpiConfirmRebaseline();
  assert.deepEqual(e.log.sb, [["rpc/lock_job_baseline", { method: "POST", body: { p_job_id: JOB, p_reason: "Client moved the handover" } }]]);
  assert.equal(e.log.loads, 1); assert.deepEqual(e.log.toasts, [["Baseline reset."]]);
  assert.doesNotMatch(e.box.innerHTML, /jc-kpi-reason/);
});
test("cancel closes the reason form and sends nothing", async () => {
  const e = env({ tasks: [task()] }); await e.api.jcKpiLockClick(); e.api.jcKpiCancel();
  assert.doesNotMatch(e.box.innerHTML, /jc-kpi-reason/); assert.equal(e.log.sb.length, 0);
});
test("the typed reason survives a re-render while the form is open", async () => {
  const e = env({ tasks: [task()] }); await e.api.jcKpiLockClick();
  e.api.jcKpiReasonInput("half typed"); e.api.jcRenderSchedKpis(); assert.match(e.box.innerHTML, />half typed<\/textarea>/);
});
test("permission is re-checked in the handlers (a stale button cannot lock)", async () => {
  for (const o of [{ perms: ["ops:work-orders:write"] }, { readOnly: true }]) {
    const e = env({ tasks: [task({ baseline_locked_at: null })], ...o });
    await e.api.jcKpiLockClick(); await e.api.jcKpiConfirmRebaseline();
    assert.equal(e.log.sb.length, 0); assert.equal(e.log.confirms.length, 0);
  }
});
test("RPC missing (404): friendly message, no reload; other errors surface the server message", async () => {
  for (const msg of ["Could not find the function public.lock_job_baseline(p_job_id, p_reason) in the schema cache", "HTTP 404"]) {
    const e = env({ tasks: [task({ baseline_locked_at: null })], sbImpl: async () => { throw new Error(msg); } });
    await e.api.jcKpiLockClick();
    assert.deepEqual(e.log.toasts, [["Baseline locking is not available yet", "warn"]]); assert.equal(e.log.loads, 0);
  }
  const s = env({ tasks: [task()], sbImpl: async () => { throw new Error("re-baseline requires a reason"); } });
  await s.api.jcKpiLockClick(); s.reason.value = "x"; await s.api.jcKpiConfirmRebaseline();
  assert.deepEqual(s.log.toasts, [["re-baseline requires a reason", "error"]]); assert.equal(s.log.loads, 0);
  assert.match(s.box.innerHTML, /jc-kpi-reason/);   // form stays open so the text is not lost
});
test("a double click does not send two RPCs", async () => {
  let release; const gate = new Promise((r) => (release = r));
  const e = env({ tasks: [task({ baseline_locked_at: null })], sbImpl: () => gate });
  const a = e.api.jcKpiLockClick(); await flush(); const b = e.api.jcKpiLockClick(); await flush(); release(null); await a; await b;
  assert.equal(e.log.sb.length, 1);
});

// ---------- robustness ----------
test("double submit of the re-baseline form sends one RPC", async () => {
  let release; const gate = new Promise((r) => (release = r));
  const e = env({ tasks: [task()], sbImpl: () => gate });
  await e.api.jcKpiLockClick(); e.reason.value = "why";
  const a = e.api.jcKpiConfirmRebaseline(); const b = e.api.jcKpiConfirmRebaseline(); await flush(); release(null); await a; await b;
  assert.equal(e.log.sb.length, 1);
});
test("'today' is the LOCAL date, early morning and late evening alike", () => {
  for (const now of ["2026-10-20T00:30:00", "2026-10-20T23:30:00"]) assert.equal(env({ now }).api.jcSchedToday(), "2026-10-20");
});
test("bar widths are clamped to 0..100 even for out-of-range progress", () => {
  const e = env({ tasks: [task({ progress: 250 })] }); e.api.jcRenderSchedKpis();
  const w = [...e.box.innerHTML.matchAll(/(?:width|left):(-?[\d.]+)%/g)].map((m) => +m[1]);
  assert.ok(w.length >= 1 && w.every((x) => x >= 0 && x <= 100), String(w));
});
test("never throws: undefined globals, null tasks, garbage values, missing container", () => {
  const u = env({ declareGlobals: false }); assert.doesNotThrow(() => u.api.jcRenderSchedKpis()); assert.match(text(u.box.innerHTML), /0%/);
  const n = env({ tasks: [null, undefined, task(), { progress: "abc", start_date: "nope", baseline_locked_at: 5 }, 7], phases: "x", links: [null] });
  assert.doesNotThrow(() => n.api.jcRenderSchedKpis()); assert.match(n.box.innerHTML, /jc-kpi2-row/);
  const m = env({ tasks: [task()], noContainer: true }); assert.doesNotThrow(() => m.api.jcRenderSchedKpis());
  const j = env({ tasks: [task()], status: null }); assert.doesNotThrow(() => j.api.jcRenderSchedKpis());
});
test("a compute failure degrades to a quiet message", () => {
  const bad = env({ tasks: [task()] }); bad.ctx.Date = class extends Date { constructor() { super("not a date"); } };
  assert.doesNotThrow(() => bad.api.jcRenderSchedKpis()); assert.match(bad.box.innerHTML, /Schedule KPIs unavailable/);
});
test("jcSchedJobCtx reads the open job from the form", () => {
  const e = env({ tasks: [task()], status: "On Hold", due: "2026-12-01" });
  assert.deepEqual({ ...e.api.jcSchedJobCtx() }, { id: JOB, job_no: "WO-0042", status: "On Hold", due_date: "2026-12-01" });
  const u = env({ jobId: null, due: "", status: null }); assert.deepEqual({ ...u.api.jcSchedJobCtx() }, { id: null, job_no: "WO-0042", status: "", due_date: null });
});
test("jcRpc posts to rpc/<name> through sb()", async () => {
  const e = env(); await e.api.jcRpc("lock_job_baseline", { a: 1 });
  assert.deepEqual(e.log.sb[0], ["rpc/lock_job_baseline", { method: "POST", body: { a: 1 } }]);
});

// ---------- static call-site pins ----------
test("markup: KPI container above the sched bar, hidden legacy overall span kept, CSS block present", () => {
  assert.match(html, /<div id="jc-sched-kpis"><\/div>\n\s*<div class="jc-sched-bar">\n\s*<span class="jc-sched-overall" id="jc-sched-overall" hidden><\/span>/);
  assert.ok(html.indexOf("/* schedule-kpi:begin */") > html.indexOf(".jc-sched-overall {") && html.includes("/* schedule-kpi:end */"));
  assert.ok(html.indexOf("// ── END SCHEDULE KPI ──") < html.indexOf("// ── SCHEDULE COMPUTE (shared) ──"));
});
