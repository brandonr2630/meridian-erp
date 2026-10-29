// Mutation check for the A2a schedule window. Run: node scripts/tests/ui/schedule-window-mutate.mjs
// Each mutant breaks one rule of the SCHEDULE WINDOW block (or its wiring) in a COPY of index.html; schedule-window.test.mjs
// (pointed at the copy via UI_SRC) must fail. Exit 0 only when every mutant is caught: "mutation check passed: n/n mutants caught".
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "schedule-window.test.mjs");
const original = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text in index.html, replacement]
const MUTANTS = [
  ["job id regex not anchored at the end", "[0-9a-f]{12}$/i;", "[0-9a-f]{12}/i;"],
  ["job id not lower-cased", "parts[1].toLowerCase()", "parts[1]"],
  ["wrong route prefix accepted", "parts[0] === 'schedule' &&", "true &&"],
  ["new tab keeps the opener", "'_blank', 'noopener'", "'_blank'"],
  ["unsaved job opens a blank window", "if (!jobId) { showToast('Save the job before opening its schedule.', 'warn'); return; }", ""],
  ["rows sorted backwards", "(schedWinNum(a.sort_order) - schedWinNum(b.sort_order))", "(schedWinNum(b.sort_order) - schedWinNum(a.sort_order))"],
  ["unphased header without phases", "if (ph.length) rows.push({ kind: 'phase', id: '__unphased__'", "if (true) rows.push({ kind: 'phase', id: '__unphased__'"],
  ["orphaned tasks dropped", "t.phase_id == null || !known.has(t.phase_id)", "t.phase_id == null"],
  ["lag sign not shown", "(lag > 0 ? '+' : '')", "''"],
  ["link type not defaulted to FS", "l.link_type === 'SS' || l.link_type === 'FF' || l.link_type === 'SF' ? l.link_type : 'FS';\n    const name", "l.link_type || 'FS';\n    const name"],
  ["predecessor names not truncated", "name.length > 28 ? name.slice(0, 27) + '…' : name", "name"],
  ["temporary UIDs start at 0", "const SCHED_WIN_TEMP_UID = 1000000;", "const SCHED_WIN_TEMP_UID = 0;"],
  ["tasks numbered before phases", "for (const p of ph) phaseUid.set(p.id, ++next);\n  for (const t of ts) taskUid.set(t.id, ++next);", "for (const t of ts) taskUid.set(t.id, ++next);\n  for (const p of ph) phaseUid.set(p.id, ++next);"],
  ["self links exported", "|| tu === pu) continue;", ") continue;"],
  ["unknown links exported", "if (tu == null || pu == null", "if (false"],
  ["lag not rounded in the export", "lag_days: Math.round(schedWinNum(l.lag_days)) });\n  }\n  const no", "lag_days: schedWinNum(l.lag_days) });\n  }\n  const no"],
  ["export without the read-only marker", "manager: SCHED_WIN_MARKER", "manager: undefined"],
  ["export without the ownership notice", "{ notice: SCHED_WIN_NOTICE,", "{ notice: undefined,"],
  ["download name fixed", "a.download = schedWinFileName(w.job);", "a.download = 'x.xml';"],
  ["file name not sanitised", "[^A-Za-z0-9._-]+", "[^A-Za-z0-9._/-]+"],
  ["permission check removed", "if (!can('ops:work-orders:read'))", "if (false)"],
  ["job id not validated before the query", "if (!jid || !SCHED_WIN_UUID.test(jid))", "if (false)"],
  ["stale load overwrites a newer one", "if (seq !== schedWin.seq) return;\n    if (!jobs", "if (!jobs"],
  ["all job columns requested", "select=id,job_no,description,status,due_date,company_id", "select=*"],
  ["single predecessor fallback removed", "x && x.depends_on && x.id", "false && x.depends_on && x.id"],
  ["missing upgrade not reported", "nb.style.display = ok && !w.v2 ? '' : 'none';", "nb.style.display = 'none';"],
  ["values not escaped", "const schedWinEsc = v => escHTML(String(v == null ? \"\" : v));", "const schedWinEsc = v => String(v == null ? \"\" : v);"],
  ["zero rendered as empty", "const schedWinEsc = v => escHTML(String(v == null ? \"\" : v));", "const schedWinEsc = v => escHTML(v);"],
  ["title set through innerHTML", "t.textContent = w.job ? 'Schedule · ' + (w.job.job_no || '') : 'Schedule';", "t.innerHTML = w.job ? 'Schedule · ' + (w.job.job_no || '') : 'Schedule';"],
  ["oversized import read anyway", "if (file.size > SCHED_WIN_MAX_BYTES) {", "if (false) {"],
  ["unreadable file shows the raw error", "'The file could not be read.'", "String(e)"],
  ["temporary-UID export treated as our own", "p.manager !== SCHED_WIN_MARKER", "true"],
  ["any file treated as from this job", "p.uid && p.uid === schedWin.job.id &&", "true &&"],
  ["import preview not capped", "all.slice(0, 200)", "all"],
  ["zoom accepts anything", "schedWin.zoom = JC_GANTT_ZOOM[v] ? v : 'Day';", "schedWin.zoom = v;"],
  ["Gantt ignores the zoom", "const px = JC_GANTT_ZOOM[w.zoom] || JC_GANTT_ZOOM.Day, today = jcGanttToday();", "const px = JC_GANTT_ZOOM.Day, today = jcGanttToday();"],
  ["schedule view not in the operations guard", "'job-config','schedule']", "'job-config']"],
  ["loader not wired", "case 'schedule': await loadScheduleWindow(); break;", ""],
  ["job id dropped from the restored address", "history.replaceState({ view: 'schedule' }, '', '#/schedule/' + jid);", "history.replaceState({ view: 'schedule' }, '', '#/schedule');"],
  ["codec loaded after the code that uses it", '<script src="schedule-msp.js"></script>\n<script>\n// ═══', '<script>\n// ═══'],
  ["card button removed", 'onclick="schedWinOpen(jcCurrentJobId)"', 'onclick=""'],
  ["window writes through the API", "const rows = schedWinRows(w.tasks, w.phases), byId", "sbPost('x', {}); const rows = schedWinRows(w.tasks, w.phases), byId"],
  ["apply: merge allowed for any file","ok: w && own,","ok: w,"],
  ["apply: replace without the approver permission","ok: w && !!canApprove,","ok: w,"],
  ["apply: append without the write permission","Nothing existing changes.\", ok: w,","Nothing existing changes.\", ok: true,"],
  ["apply: job id compared case-sensitively","String(p.uid).toLowerCase() === String(job.id).toLowerCase()","String(p.uid) === String(job.id)"],
  ["apply: the read-only marker ignored for merge","=== String(job.id).toLowerCase() && p.manager !== SCHED_WIN_MARKER);","=== String(job.id).toLowerCase());"],
  ["apply: based_on takes the oldest","if (Number.isFinite(ms) && ms > bestMs)","if (Number.isFinite(ms) && ms < bestMs)"],
  ["apply: based_on ignores the links","for (const list of [tasks, phases, links])","for (const list of [tasks, phases])"],
  ["apply: based_on ignores the phases","for (const list of [tasks, phases, links])","for (const list of [tasks, links])"],
  ["apply: based_on ignores the tasks","for (const list of [tasks, phases, links])","for (const list of [phases, links])"],
  ["apply: based_on loses the microseconds","ms > bestMs) { bestMs = ms; best = s; }","ms > bestMs) { bestMs = ms; best = new Date(ms).toISOString(); }"],
  ["apply: based_on never sent","based_on: basedOn || null","based_on: null"],
  ["apply: file name never sent","file_name: fileName ? String(fileName).slice(0, 255) : null","file_name: null"],
  ["apply: file name not cut",".slice(0, 255) : null"," : null"],
  ["apply: payload modified in place","return Object.assign({}, payload, {","return Object.assign(payload, {"],
  ["apply: missing function not recognised","/could not find the function|does not exist|HTTP 404/i","/zzz/i"],
  ["apply: stale schedule not recognised","/schedule changed since preview|based_on is required/i","/zzz/i"],
  ["apply: based_on required not treated as stale","since preview|based_on is required/i","since preview/i"],
  ["apply: reason error not recognised","/replace requires a reason/i","/zzz/i"],
  ["apply: permission error not recognised","/permission denied|row-level security|HTTP 40[13]/i","/zzz/i"],
  ["apply: refused file not recognised","/invalid payload|cycle|deeper than|uid space|merge requires|too many|exceed/i","/zzz/i"],
  ["apply: refused file hides the server text","text: 'The server refused the file: ' + m","text: 'The server refused the file.'"],
  ["apply: unknown error hides the message","text: 'The import failed: ' + m","text: 'The import failed.'"],
  ["apply: replace counts never see the baseline","baseline: (w.tasks || []).some(x => x && x.baseline_locked_at)","baseline: false"],
  ["apply: replace counts take links from the tasks","links: (w.links || []).length, baseline","links: (w.tasks || []).length, baseline"],
  ["apply: any mode name accepted","imp.mode = ['append', 'merge', 'replace'].includes(mode) ? mode : null;","imp.mode = mode;"],
  ["apply: mode can change while applying","const imp = schedWin.imp; if (!imp || imp.busy) return;\n  imp.mode =","const imp = schedWin.imp; if (!imp) return;\n  imp.mode ="],
  ["apply: reason not cut to 500","imp.reason = String(v == null ? '' : v).slice(0, SCHED_WIN_REASON_MAX);","imp.reason = String(v == null ? '' : v);"],
  ["apply: typing does not clear the reason error","if (imp.reasonErr) { imp.reasonErr = ''; schedWinSet('sw-reason-err', ''); }",""],
  ["apply: Apply without a mode does nothing silently","if (!cur) { imp.applyErr = 'Choose how to import the file.'; schedWinImportRender(); return; }","if (!cur) { return; }"],
  ["apply: a disabled mode can be forced","if (!cur.ok) { imp.applyErr = cur.why; schedWinImportRender(); return; }",""],
  ["apply: Replace without the confirmation step","if (imp.mode === 'replace' && !imp.confirm) { imp.confirm = true;","if (false) { imp.confirm = true;"],
  ["apply: Replace without a reason","if (!reason) { imp.reasonErr = 'Enter a reason.'; schedWinImportRender(); return; }",""],
  ["apply: reason not trimmed","reason = String(imp.reason == null ? '' : imp.reason).trim().slice(0, SCHED_WIN_REASON_MAX);","reason = String(imp.reason == null ? '' : imp.reason).slice(0, SCHED_WIN_REASON_MAX);"],
  ["apply: a reason is sent with every mode","let reason = null;\n  if (imp.mode === 'replace') {","let reason = String(imp.reason == null ? '' : imp.reason);\n  if (false) {"],
  ["apply: a second press runs a second import","if (!imp || !imp.payload || imp.busy || !w.job) return;","if (!imp || !imp.payload || !w.job) return;"],
  ["apply: wrong RPC name","jcRpc('import_job_schedule',","jcRpc('import_job_schedule_x',"],
  ["apply: job id not sent","{ p_job_id: w.job.id, p_mode: imp.mode,","{ p_job_id: null, p_mode: imp.mode,"],
  ["apply: mode not sent","p_mode: imp.mode, p_payload: body","p_mode: 'append', p_payload: body"],
  ["apply: based_on not computed","const body = schedWinImportBody(imp.payload, imp.name, schedWinBasedOn(w.tasks, w.phases, w.links));","const body = schedWinImportBody(imp.payload, imp.name, null);"],
  ["apply: no reload after a successful import","await loadScheduleWindow();                                  // show what the database now holds",""],
  ["apply: result not shown","schedWin.imp = { name: imp.name, result }; schedWinImportRender();","schedWinImportRender();"],
  ["apply: success toast removed","showToast('Import applied.', 'success');",""],
  ["apply: answer of a closed preview still shown","if (w.imp !== imp) return;                                   // the preview was closed or the window reloaded meanwhile",""],
  ["apply: a failed import leaves the panel busy","imp.busy = false; const er = schedWinImportError(e && e.message);","const er = schedWinImportError(e && e.message);"],
  ["apply: a missing-reason answer shown as a general error","if (er.kind === 'reason') imp.reasonErr = er.text; else imp.applyErr = er.text;","imp.applyErr = er.text;"],
  ["apply: result numbers not coerced","(res && Number.isFinite(+res[x]) ? +res[x] : 0)","(res ? res[x] : 0)"],
  ["apply: warnings not guarded","Array.isArray(res && res.warnings) ? res.warnings : []","(res && res.warnings) || []"],
  ["apply: a reader gets the Apply buttons","if (!canW) return '<div class=\"sw-dim\">You can preview the file","if (false) return '<div class=\"sw-dim\">You can preview the file"],
  ["apply: disabled modes are clickable","${m.ok && !imp.busy ? '' : ' disabled'}",""],
  ["apply: the Replace button hides that it asks first","imp.mode === 'replace' ? 'Replace schedule…' : 'Apply import'","'Apply import'"],
  ["apply: the confirmation hides the locked baseline","${d.baseline ? '<br>Baseline locked' : ''}",""],
  ["apply: the confirmation cannot be cancelled","if (!imp || imp.busy) return; imp.confirm = false; imp.reasonErr","if (!imp || imp.busy) return; imp.confirm = true; imp.reasonErr"],
  ["apply: an empty schedule is not preselected","if (!schedWin.tasks.length && !schedWin.phases.length) imp.mode = 'append';",""],
  ["apply: Append is always preselected","if (!schedWin.tasks.length && !schedWin.phases.length) imp.mode = 'append';","imp.mode = 'append';"],
  ["apply: phases do not count as a schedule","!schedWin.tasks.length && !schedWin.phases.length","!schedWin.tasks.length"],
  ["apply: the result is titled as a preview", "${imp.result ? 'Import result' : 'Import preview'}", "Import preview"],
  ["apply: the result panel says the file is being read", "if (!imp.parsed && !imp.error && !imp.result) html +=", "if (!imp.parsed && !imp.error) html +="],
  ["apply: counts always plural", "(+n === 1 ? '' : 's')", "'s'"],
  ["apply: zero counted as singular", "(+n === 1 ? '' : 's')", "(+n <= 1 ? '' : 's')"],
  ["apply: the reason field loses the app field style", "<div class=\"field\"><label class=\"field-label\" for=\"sw-reason\">", "<div><label for=\"sw-reason\">"],
  ["apply: the reason field is not limited","maxlength=\"${SCHED_WIN_REASON_MAX}\" ",""],
];

function runTests(src) {
  const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, UI_SRC: src }, encoding: "utf8", timeout: 60000 });
  return r.status === 0 && !r.error;
}

const tmp = mkdtempSync(join(tmpdir(), "swin-mut-"));
let caught = 0; const survivors = [];
try {
  const base = join(tmp, "base.html"); writeFileSync(base, original);
  if (!runTests(base)) { console.error("baseline run is not green: fix the suite before mutating"); process.exit(2); }
  MUTANTS.forEach(([name, from, to], i) => {
    const n = original.split(from).length - 1;
    if (n < 1) { console.error("mutant '" + name + "' does not apply (text not found)"); process.exit(2); }
    const file = join(tmp, "m" + i + ".html");
    writeFileSync(file, original.replaceAll(from, () => to));
    if (!runTests(file)) { caught++; console.log("  caught   " + name); } else { survivors.push(name); console.log("  SURVIVED " + name); }
  });
} finally { rmSync(tmp, { recursive: true, force: true }); }

if (survivors.length) { console.error("mutation check FAILED: " + caught + "/" + MUTANTS.length + " caught; survivors: " + survivors.join("; ")); process.exit(1); }
console.log("mutation check passed: " + caught + "/" + MUTANTS.length + " mutants caught");
