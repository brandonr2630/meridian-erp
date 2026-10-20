// Mutation check for the Schedule v2 compute block. Run: node scripts/tests/schedule/mutate.mjs
// Each mutant breaks one rule of the block in a COPY of index.html; compute.test.mjs (pointed at the copy via UI_SRC) must fail.
// Exit 0 only when every mutant is caught: "mutation check passed: n/n mutants caught".
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "compute.test.mjs");
const original = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text in the block, replacement]
const MUTANTS = [
  ["weights ignore milestones", "if (isMilestone) return 0;", "if (false) return 0;"],
  ["explicit weight 0 treated as NULL", "if (w != null) return w;", "if (w) return w;"],
  ["weight duration off by one", "return Math.max(1, s != null && e != null ? e - s + 1 : 1);\n}\n// SQL job_task_planned_pct", "return Math.max(1, s != null && e != null ? e - s : 1);\n}\n// SQL job_task_planned_pct"],
  ["planned % loses the +1 day", "(t - s + 1) / Math.max(1, e - s + 1)", "(t - s) / Math.max(1, e - s + 1)"],
  ["planned % not clamped below 0", "Math.min(1, Math.max(0, (t - s + 1) / Math.max(1, e - s + 1)))", "Math.min(1, (t - s + 1) / Math.max(1, e - s + 1))"],
  ["planned % not clamped above 1", "Math.min(1, Math.max(0, (t - s + 1) / Math.max(1, e - s + 1)))", "Math.max(0, (t - s + 1) / Math.max(1, e - s + 1))"],
  ["planned % ignores baseline dates", "jcSchedDay(bStart) ?? jcSchedDay(start)", "jcSchedDay(start)"],
  ["Late threshold off by one (>=)", "sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS", "sl >= JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS"],
  ["overdue Late threshold off by one (>=)", "sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS", "sl > JC_SCHED_LATE_DAYS || lateDays >= JC_SCHED_LATE_DAYS"],
  ["At risk upper bound off by one", "sl <= JC_SCHED_LATE_DAYS)", "sl < JC_SCHED_LATE_DAYS)"],
  ["At risk lower bound includes 0", "(sl >= 1 && sl <= JC_SCHED_LATE_DAYS)", "(sl >= 0 && sl <= JC_SCHED_LATE_DAYS)"],
  ["gap threshold off by one (<=)", "(gap ?? 0) < -JC_SCHED_GAP_PTS", "(gap ?? 0) <= -JC_SCHED_GAP_PTS"],
  ["late-days constant 6", "const JC_SCHED_LATE_DAYS = 5;", "const JC_SCHED_LATE_DAYS = 6;"],
  ["gap-points constant 11", "const JC_SCHED_GAP_PTS = 10;", "const JC_SCHED_GAP_PTS = 11;"],
  ["task without id registered (phantom links)", "if (t.id != null && !idx.has(t.id)) idx.set(t.id, i);", "if (!idx.has(t.id)) idx.set(t.id, i);"],
  ["a label renamed", "atRisk: 'At risk'", "atRisk: 'At Risk'"],
  ["gap evaluated without a baseline", "const gap = hasBl ?", "const gap = true ?"],
  ["gap uses truncation instead of int-cast rounding", "Math.sign(gapC) * Math.floor((Math.abs(gapC) + 50) / 100)", "Math.trunc(gapC / 100)"],
  ["gap compared unrounded", "Math.sign(gapC) * Math.floor((Math.abs(gapC) + 50) / 100)", "gapC / 100"],
  ["lag ignored", "const cand = ef[p] + llag[j];", "const cand = ef[p];"],
  ["lag sign flipped in the backward pass", "const cand = ls[t] - llag[j];", "const cand = ls[t] + llag[j];"],
  ["done tasks moved by predecessors", "if (sched[t] && sched[p] && !done[t] && ef[p] != null) {", "if (sched[t] && sched[p] && ef[p] != null) {"],
  ["done tasks lose their actual end", "ef.push(prog === 100 ? e : null);", "ef.push(null);"],
  ["started tasks restart today", "es.push(prog > 0 ? (s ?? T) : T);", "es.push(T);"],
  ["remaining duration floors instead of ceils", "Math.floor((dur * (100 - prog) + 99) / 100)", "Math.floor((dur * (100 - prog)) / 100)"],
  ["undated linked successor excluded from the pass", "if (!(done[t] && endd[t] == null)) sched[t] = true;", ""],
  ["deadline ignores due_date", "deadline = due ?? fe;", "deadline = fe;"],
  ["slip measured against due_date before baseline", "const baseEnd = maxBe ?? due;", "const baseEnd = due ?? maxBe;"],
  ["critical limit ignores the min-slack path", "Math.max(0, minSlack ?? 0)", "0"],
  ["done tasks can be critical", "const slack = sched[i] && !done[i] ? ls[i] - es[i] : null;", "const slack = sched[i] ? ls[i] - es[i] : null;"],
  ["overdue milestones ignored", "(isCrit || ms[i])", "isCrit"],
  ["overdue non-critical tasks counted", "(isCrit || ms[i])", "true"],
  ["status order: Complete never wins", "if (['Completed', 'Invoiced', 'Closed'].includes(job.status)) status = L.complete;", "if (false) status = L.complete;"],
  ["status order: On hold after Late", "else if (job.status === 'On Hold') status = L.onHold;\n  else if (sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS) status = L.late;", "else if (sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS) status = L.late;\n  else if (job.status === 'On Hold') status = L.onHold;"],
  ["status order: At risk checked before Late", "else if (sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS) status = L.late;\n  else if ((sl >= 1 && sl <= JC_SCHED_LATE_DAYS) || (gap ?? 0) < -JC_SCHED_GAP_PTS || late) status = L.atRisk;", "else if ((sl >= 1 && sl <= JC_SCHED_LATE_DAYS) || (gap ?? 0) < -JC_SCHED_GAP_PTS || late) status = L.atRisk;\n  else if (sl > JC_SCHED_LATE_DAYS || lateDays > JC_SCHED_LATE_DAYS) status = L.late;"],
  ["2 dp rounding truncates", "Math.floor(x + 0.5 + 1e-7)", "Math.floor(x)"],
  ["2 dp rounding ties go down", "Math.floor(x + 0.5 + 1e-7)", "Math.floor(x + 0.5 - 1e-7)"],
  ["display rounds ties down", "Math.floor((cents + 50) / 100)", "Math.floor((cents + 49) / 100)"],
  ["display truncates", "Math.floor((cents + 50) / 100)", "Math.floor(cents / 100)"],
  ["milestones weighed in the aggregation", "jcTaskWeight(t.is_milestone, t.weight, t.start_date, t.end_date)", "jcTaskWeight(false, t.weight, t.start_date, t.end_date)"],
  ["null progress breaks the sum", "sp += w * (jcSchedNum(t.progress) ?? 0);", "sp += w * t.progress;"],
  ["baselineLocked override ignored", "typeof job.baselineLocked === 'boolean' ? job.baselineLocked : tasks.some", "tasks.some"],
  ["phase rollups unsorted", ".slice().sort((x, y) => (jcSchedNum(x.sort_order) ?? 0) - (jcSchedNum(y.sort_order) ?? 0))", ""],
  ["cycle not reported", "warnings.push('cycle')", "0"],
  ["unknown-task links not ignored", "if (t === undefined || p === undefined) continue;", ""],
];

function runTests(src) {
  const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, UI_SRC: src }, encoding: "utf8", timeout: 60000 });
  return r.status === 0 && !r.error;
}

const tmp = mkdtempSync(join(tmpdir(), "sched-mut-"));
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
