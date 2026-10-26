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
  ["Apply import enabled", '<button class="btn btn-primary btn-sm" disabled>Apply import</button>', '<button class="btn btn-primary btn-sm">Apply import</button>'],
  ["Apply note removed", "Applying an import is not available yet", "Applying an import"],
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
