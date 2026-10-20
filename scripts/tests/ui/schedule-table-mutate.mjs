// Mutation check for the Schedule v2 task table. Run: node scripts/tests/ui/schedule-table-mutate.mjs
// Each mutant breaks one rule of the SCHEDULE TASK TABLE code in a COPY of index.html (each target text must occur exactly once);
// schedule-table.test.mjs (pointed at the copy via UI_SRC) must fail. Exit 0 only when every mutant is caught.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "schedule-table.test.mjs");
const original = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text, replacement]
const MUTANTS = [
  // critical-flag cache
  ["critical cache rewrites every row", "if (!!t.is_critical !== want)", "if (true)"],
  ["critical cache runs for read-only roles", "if (!jcSchedV2 || !jcCurrentJobId || jcIsReadOnlyRole() || !jcCanEditTasks()) return;", "if (!jcSchedV2 || !jcCurrentJobId) return;"],
  ["critical cache flags swapped", "(want ? on : off).push(t.id)", "(want ? off : on).push(t.id)"],
  ["critical cache failure surfaces", "} catch (e) { /* cosmetic cache: ignore */ }", "} catch (e) { throw e; }"],
  ["critical cache not refreshed after an edit", "  jcSchedSyncCritical();\n}\nfunction jcSchedInitOnce", "}\nfunction jcSchedInitOnce"],
  ["critical cache runs without the migration", "if (!jcSchedV2 || !jcCurrentJobId || jcIsReadOnlyRole()", "if (!jcCurrentJobId || jcIsReadOnlyRole()"],
  // load / fallback
  ["v2 assumed even when the tables are missing", "jcSchedV2 = Array.isArray(phases) && Array.isArray(links);", "jcSchedV2 = true;"],
  ["a missing table is treated as a load failure", "get('job_phases', `job_id=eq.${jid}&order=sort_order.asc`).catch(() => null)", "get('job_phases', `job_id=eq.${jid}&order=sort_order.asc`).catch(e => { failed = e; return null; })"],
  ["stale load overwrites a newer one", "if (seq !== jcSchedLoadSeq) return;", ""],
  ["links not loaded per job", "get('job_task_links', `job_id=eq.${jid}&order=created_at.asc`)", "get('job_task_links', `order=created_at.asc`)"],
  // predecessors
  ["depends_on mirrors the LAST predecessor", "const first = ordered[0] || null;", "const first = ordered[ordered.length - 1] || null;"],
  ["existing links are POSTed again", "const add = valid.filter(p => !curIds.includes(p));", "const add = valid.slice();"],
  ["removed links are never deleted", "if (drop.length) { await sbDeleteWhere(", "if (false) { await sbDeleteWhere("],
  ["no client-side loop check", "if (add.some(p => jcSchedWouldCycle(id, p)))", "if (false)"],
  ["DB cycle error is not recognised", "cyc = /cycle/i.test(msg);", "cyc = false;"],
  ["v2 depends_on edit bypasses the links", "if (jcSchedV2 && field === 'depends_on') {", "if (false && field === 'depends_on') {"],
  ["dangling links counted as selected", "const cur = jcSchedLinks.filter(l => l.task_id === id && have.has(l.predecessor_id));", "const cur = jcSchedLinks.filter(l => l.task_id === id);"],
  ["dangling links shown", "if (!nameOf.has(l.predecessor_id)) continue;", ""],
  ["deleted task keeps its links", "jcSchedLinks = jcSchedLinks.filter(l => l.task_id !== id && l.predecessor_id !== id);", ""],
  ["dropdown lists the task itself", "const items = jcTasks.filter(o => o.id !== t.id).map(o =>", "const items = jcTasks.map(o =>"],
  // milestone / weight
  ["milestone start edit leaves the end", "if (t.is_milestone) patch.end_date = val;", "if (false) patch.end_date = val;"],
  ["milestone end edit leaves the start", "if (t.is_milestone) patch.start_date = val;", "if (false) patch.start_date = val;"],
  ["becoming a milestone keeps the duration", "if (t.start_date) patch.end_date = t.start_date; else if (t.end_date) patch.start_date = t.end_date;", ""],
  ["empty weight stored as 0", "if (raw === '' || raw == null) val = null;", "if (raw === '' || raw == null) val = 0;"],
  ["negative weight accepted", "!Number.isFinite(n) || n < 0 ||", "!Number.isFinite(n) ||"],
  ["explicit weight 0 shown as empty", "value=\"${t.weight == null ? '' :", "value=\"${!t.weight ? '' :"],
  ["milestone weight field stays enabled", "type=\"number\" disabled placeholder=\"n/a\"", "type=\"number\" placeholder=\"n/a\""],
  // publishing
  ["publish not gated on approve", "if (field === 'client_visible' && val && !jcSchedCanPublish())", "if (false)"],
  ["publish toggle never disabled", "ms = !!t.is_milestone, vis = !!t.client_visible, blocked = !canPub && !vis;", "ms = !!t.is_milestone, vis = !!t.client_visible, blocked = false;"],
  ["auto-unpublish badge never shown", "else if (field === 'task_name' && wasVisible && !t.client_visible) {", "else if (false) {"],
  ["server row ignored after a save", "if (srv) Object.assign(t, srv);", ""],
  ["phase publish not gated", "if (val && !jcSchedCanPublish()) { showToast(JC_SCHED_PUBLISH_TIP, 'warn'); jcRenderTasks(); return; }", ""],
  // phases
  ["template sort_order gaps of 5", "sort_order: (i + 1) * 10, name }));", "sort_order: (i + 1) * 5, name }));"],
  ["template applied to jobs that have phases", "|| jcSchedPhases.length || jcSchedPhaseBusy) return;\n  jcSchedPhaseBusy = true;\n  const jid = jcCurrentJobId;\n  try {\n    const jt", "|| jcSchedPhaseBusy) return;\n  jcSchedPhaseBusy = true;\n  const jid = jcCurrentJobId;\n  try {\n    const jt"],
  ["template double click not guarded", "|| jcSchedPhases.length || jcSchedPhaseBusy) return;", "|| jcSchedPhases.length) return;"],
  ["job_type lookup walks the prototype", "(jt && jcSchedOwn(JC_PHASE_TEMPLATES.byJobType, jt) && ", "(jt && "],
  ["reorder gaps of 5", "const want = (k + 1) * 10;", "const want = (k + 1) * 5;"],
  ["reorder rewrites unchanged rows", "if (Number(list[k].sort_order) !== want) {", "if (true) {"],
  ["phase delete without confirmation", "  if (!ok) return;\n  return jcSchedSerial('phases', async () => {", "  return jcSchedSerial('phases', async () => {"],
  ["phase delete leaves tasks pointing at it", "jcTasks.forEach(t => { if (t.phase_id === id) t.phase_id = null; });", ""],
  ["empty phase name accepted", "if (!name) { showToast('A phase needs a name.', 'warn'); jcRenderTasks(); return; }", ""],
  // add task / catalogue
  ["new task ignores the phase above", "(last ? last.phase_id || null : null)", "null"],
  ["v1 insert sends phase_id", "if (jcSchedV2) row.phase_id =", "row.phase_id ="],
  ["add task double click not guarded", "if (!jcCanEditTasks() || jcSchedAdding) return;", "if (!jcCanEditTasks()) return;"],
  ["catalogue: unmapped category (prototype key) mapped", "if (category == null || !jcSchedOwn(map, category)) return", "if (category == null) return"],
  ["catalogue: picked task ignores the phase", "phase_id: jcSchedPhaseForCategory(row.category).phaseId });", "phase_id: null });"],
  ["catalogue: unmapped not marked in the picker", "'⚠ unmapped category'", "''"],
  // read-only / escaping / plumbing
  ["read-only roles get enabled controls", "const edit = jcCanEditTasks(), dis = edit ? '' : ' disabled';\n  if (!jcTasks.length) {", "const edit = jcCanEditTasks(), dis = '';\n  if (!jcTasks.length) {"],
  ["phase rename not guarded for read-only", "function jcPhaseRename(id, raw) {\n  if (!jcCanEditTasks()) return;", "function jcPhaseRename(id, raw) {"],
  ["phase name not escaped", "${p.id === t.phase_id ? ' selected' : ''}>${escHTML(p.name)}</option>", "${p.id === t.phase_id ? ' selected' : ''}>${p.name}</option>"],
  ["updated_at sent for schedule tables", "new Set(['job_tasks','job_phases','job_task_links','sequence_counters',", "new Set(['sequence_counters',"],
  ["rapid edits not serialised per task", "const next = prev.catch(() => {}).then(fn);", "const next = Promise.resolve().then(fn);"],
  ["Gantt hook before KPI hook", "  if (typeof jcRenderSchedKpis === 'function') jcRenderSchedKpis();\n  if (typeof jcRenderSchedGantt === 'function') jcRenderSchedGantt();", "  if (typeof jcRenderSchedGantt === 'function') jcRenderSchedGantt();\n  if (typeof jcRenderSchedKpis === 'function') jcRenderSchedKpis();"],
  ["KPI hook called unguarded", "if (typeof jcRenderSchedKpis === 'function') jcRenderSchedKpis();", "jcRenderSchedKpis();"],
];

function runTests(src) {
  const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, UI_SRC: src }, encoding: "utf8", timeout: 120000 });
  return r.status === 0 && !r.error;
}

const tmp = mkdtempSync(join(tmpdir(), "sched-table-mut-"));
let caught = 0; const survivors = [];
try {
  const baseFile = join(tmp, "base.html"); writeFileSync(baseFile, original);
  if (!runTests(baseFile)) { console.error("baseline run is not green: fix the suite before mutating"); process.exit(2); }
  MUTANTS.forEach(([name, from, to], i) => {
    const n = original.split(from).length - 1;
    if (n !== 1) { console.error(`mutant '${name}' does not apply exactly once (found ${n})`); process.exit(2); }
    const file = join(tmp, "m" + i + ".html");
    writeFileSync(file, original.replace(from, () => to));
    if (!runTests(file)) { caught++; console.log("  caught   " + name); } else { survivors.push(name); console.log("  SURVIVED " + name); }
  });
} finally { rmSync(tmp, { recursive: true, force: true }); }

if (survivors.length) { console.error(`mutation check FAILED: ${caught}/${MUTANTS.length} caught; survivors: ${survivors.join("; ")}`); process.exit(1); }
console.log(`mutation check passed: ${caught}/${MUTANTS.length} mutants caught`);
