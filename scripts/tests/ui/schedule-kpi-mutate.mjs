// Mutation check for the Schedule KPI / baseline lock UI. Run: node scripts/tests/ui/schedule-kpi-mutate.mjs
// Each mutant breaks one rule of the SCHEDULE KPI block in a COPY of index.html; schedule-kpi.test.mjs (pointed at the copy via UI_SRC) must fail.
// Exit 0 only when every mutant is caught: "mutation check passed: n/n mutants caught".
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "schedule-kpi.test.mjs");
const original = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text in the block, replacement]
const MUTANTS = [
  ["permission check flipped", "if (!can('ops:work-orders:approve')) return false;", "if (can('ops:work-orders:approve')) return false;"],
  ["approve permission dropped", "if (!can('ops:work-orders:approve')) return false;", ""],
  ["read-only role sees the button", "if (jcIsReadOnlyRole()) return false;", ""],
  ["unsaved job sees the button", "if (!st.job.id) return false;", ""],
  ["undated tasks count as dated", "return st.tasks.some(t => t.start_date && t.end_date);", "return true;"],
  ["reason requirement dropped", "if (!reason) { showToast('A reason is required to re-baseline.', 'warn'); return; }", ""],
  ["reason not trimmed", "const reason = String(ta && ta.value != null ? ta.value : jcKpiReasonText).trim();", "const reason = String(ta && ta.value != null ? ta.value : jcKpiReasonText);"],
  ["re-baseline skips the reason form", "if (jcKpiLockedAt(st.tasks)) {   // baseline exists", "if (false) {   // baseline exists"],
  ["first lock skips the confirm dialog", "if (ok) await jcKpiDoLock(st.job.id, null);", "await jcKpiDoLock(st.job.id, null);"],
  ["wrong RPC name", "await jcRpc('lock_job_baseline',", "await jcRpc('lock_job_baselines',"],
  ["wrong RPC body key", "{ p_job_id: jobId, p_reason: reason }", "{ job_id: jobId, p_reason: reason }"],
  ["RPC not guarded against double submit", "if (jcKpiBusy || !jobId) return;", "if (!jobId) return;"],
  ["404 hidden behind the friendly message for every error", "if (/could not find the function|PGRST202|HTTP 404/i.test(msg))", "if (true)"],
  ["server error message swallowed", "else showToast(msg || 'Could not lock the baseline.', 'error');", "else showToast('Could not lock the baseline.', 'error');"],
  ["no reload after success", "if (typeof jcLoadTasks === 'function') await jcLoadTasks();", ""],
  ["audit name not escaped", "${name ? ' by ' + escHTML(name) : ''}", "${name ? ' by ' + name : ''}"],
  ["reason text not escaped", ">${escHTML(jcKpiReasonText)}</textarea>", ">${jcKpiReasonText}</textarea>"],
  ["Late shown with the amber class", "'Late': 'bad'", "'Late': 'warn'"],
  ["At risk shown with the red class", "'At risk': 'warn'", "'At risk': 'bad'"],
  ["On hold forecast not greyed", "${cls === 'hold' ? ' jc-kpi2-grey' : ''}\">${escHTML(line)}", "\">${escHTML(line)}"],
  ["button label ignores existing baseline", "${lockedAt ? 'Re-baseline' : 'Lock baseline'}", "Lock baseline"],
  ["audit query uses the wrong actions", "action_type=in.(baseline_locked,baseline_reset)", "action_type=in.(baseline_locked)"],
  ["audit lookup not cached", "if (hit && hit !== 'pending') return hit.name;\n  if (!hit) {", "if (hit && hit !== 'pending') return hit.name;\n  if (true) {"],
  ["caption uses the earliest lock time", "String(t.baseline_locked_at) > max", "String(t.baseline_locked_at) < max"],
  ["year always shown", "return `${jcKpiPad(d)} ${JC_KPI_MON[m - 1]}${y === cy ? '' : ' ' + y}`;", "return `${jcKpiPad(d)} ${JC_KPI_MON[m - 1]} ${y}`;"],
  ["today taken from UTC", "const d = new Date();\n  return `${d.getFullYear()}-${jcKpiPad(d.getMonth() + 1)}-${jcKpiPad(d.getDate())}`;", "return new Date().toISOString().slice(0, 10);"],
  ["entry point lets errors escape", "} catch (e) {\n    try { if (el) el.innerHTML = '<div class=\"jc-kpi2-quiet\">Schedule KPIs unavailable</div>'; } catch (_) { /* nothing more to do */ }\n  }", "} finally { }"],
  ["null tasks not filtered", ".filter(t => t && typeof t === 'object')", ""],
  ["bar width unclamped", "Math.min(100, Math.max(0, n))", "n"],
  ["missing baseline note dropped", "${lockedAt ? '' : '<div class=\"jc-kpi2-note\">No baseline: status uses the due date only</div>'}", ""],
  ["planned marker shown with no tasks", "${hasTasks ? `<div class=\"jc-kpi2-plan\" style=\"left:${planned}%\"></div>` : ''}", "<div class=\"jc-kpi2-plan\" style=\"left:${planned}%\"></div>"],
];

function runTests(src) {
  const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, UI_SRC: src }, encoding: "utf8", timeout: 60000 });
  return r.status === 0 && !r.error;
}

const tmp = mkdtempSync(join(tmpdir(), "kpi-mut-"));
let caught = 0; const survivors = [];
try {
  const base = join(tmp, "base.html"); writeFileSync(base, original);
  if (!runTests(base)) { console.error("baseline run is not green: fix the suite before mutating"); process.exit(2); }
  MUTANTS.forEach(([name, from, to], i) => {
    if (original.split(from).length - 1 < 1) { console.error("mutant '" + name + "' does not apply (text not found)"); process.exit(2); }
    const file = join(tmp, "m" + i + ".html");
    writeFileSync(file, original.replaceAll(from, () => to));
    if (!runTests(file)) { caught++; console.log("  caught   " + name); } else { survivors.push(name); console.log("  SURVIVED " + name); }
  });
} finally { rmSync(tmp, { recursive: true, force: true }); }

if (survivors.length) { console.error("mutation check FAILED: " + caught + "/" + MUTANTS.length + " caught; survivors: " + survivors.join("; ")); process.exit(1); }
console.log("mutation check passed: " + caught + "/" + MUTANTS.length + " mutants caught");
