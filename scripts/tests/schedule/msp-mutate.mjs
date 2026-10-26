// Mutation check for the MS Project codec. Run: node scripts/tests/schedule/msp-mutate.mjs
// Each mutant breaks one rule of schedule-msp.js in a COPY of the file; msp.test.mjs (pointed at the copy via MSP_SRC) must fail.
// Exit 0 only when every mutant is caught: "msp mutation check passed: n/n mutants caught".
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "msp.test.mjs");
const original = readFileSync(join(root, "schedule-msp.js"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text in the codec, replacement]
const MUTANTS = [
  ["parse: FF and SF codes swapped", "{ 0: 'FF', 1: 'FS', 2: 'SF', 3: 'SS' }", "{ 0: 'FF', 1: 'FS', 2: 'SS', 3: 'SF' }"],
  ["build: SF and SS codes swapped", "{ FF: 0, FS: 1, SF: 2, SS: 3 }", "{ FF: 0, FS: 1, SF: 3, SS: 2 }"],
  ["lag rounds down instead of away from zero", "Math.round(Math.abs(lagMin) / minutesPerDay)", "Math.floor(Math.abs(lagMin) / minutesPerDay)"],
  ["lag unit is hundredths of a minute", "(num(pl, 'LinkLag') || 0) / 10, fmt", "(num(pl, 'LinkLag') || 0) / 100, fmt"],
  ["lag loses its sign", "let lagDays = Math.sign(lagMin) * Math.round(", "let lagDays = Math.round("],
  ["lag upper clamp 366", "Math.min(365, lagDays)", "Math.min(366, lagDays)"],
  ["lag lower clamp -31", "Math.max(-30, Math.min(", "Math.max(-31, Math.min("],
  ["DOCTYPE accepted", "if (/<!DOCTYPE|<!ENTITY/i.test(src)) throw", "if (false) throw"],
  ["size cap doubled", "if (src.length > LIMITS.chars) throw", "if (src.length > LIMITS.chars * 2) throw"],
  ["non-XML accepted", "if (!/^\\s*<\\?xml[\\s?]/.test(src) && !/^\\s*<[A-Za-z]/.test(src)) throw", "if (false) throw"],
  ["task cap off by one", "if (rows.length >= LIMITS.tasks) throw", "if (rows.length > LIMITS.tasks) throw"],
  ["link cap off by one", "++linkCount > LIMITS.links", "++linkCount > LIMITS.links + 1"],
  ["namespace not checked", "if (proj.a.xmlns !== NS) throw", "if (false) throw"],
  ["root not checked", "if (proj.n !== 'Project') throw", "if (false) throw"],
  ["mismatched closing tag accepted", "if (stack.length < 2 || top.n !== name) throw", "if (stack.length < 2) throw"],
  ["unclosed tags accepted", "if (stack.length !== 1) throw", "if (false) throw"],
  ["UID 0 kept", "uid <= 0 ||", "uid < 0 ||"],
  ["IsNull rows kept", "|| num(tn, 'IsNull') === 1) { if (uid !== 0)", "|| false) { if (uid !== 0)"],
  ["duplicate UIDs kept", "if (seen.has(uid)) {", "if (false) {"],
  ["control characters kept in names", ".replace(/[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F]/g, '').replace(/\\s+/g, ' ')", ".replace(/\\s+/g, ' ')"],
  ["name cap 1000", ".slice(0, max == null ? LIMITS.nameLen : max)", ".slice(0, 1000)"],
  ["entities decoded twice", "return { amp: '&', lt: '<', gt: '>', quot: '\"', apos: \"'\" }[e];", "return { amp: '&', lt: '<', gt: '>', quot: '\"', apos: \"'\" }[e] + ''.replace('', '') + (e === 'amp' ? 'amp;' : '');"],
  ["impossible dates accepted", "return ymdOf(n) === m[1] + '-' + m[2] + '-' + m[3] ? n : null;", "return n;"],
  ["year range widened", "if (y < 2000 || y > 2100 || mo < 1", "if (y < 1900 || y > 2100 || mo < 1"],
  ["finish before start kept", "&& e < s) {", "&& false) {"],
  ["zero-duration leaves are not milestones", "(r.milestoneFlag || r.hours === 0)", "(r.milestoneFlag)"],
  ["milestone end not pinned to its start", "if (isMilestone && s != null) e = s;", ""],
  ["outline: equal levels nest", "stack[stack.length - 1].level >= r.level", "stack[stack.length - 1].level > r.level"],
  ["outline depth cap removed", "depthOf(r) > LIMITS.outlineDepth", "depthOf(r) > LIMITS.outlineDepth + 5"],
  ["summary taken from the file flag", "const isSummary = hk.has(r.uid);", "const isSummary = r.summaryFlag;"],
  ["working-day calendars ignored", "const useCal = !!cal && !cal.allDays;", "const useCal = false;"],
  ["7-day calendars recomputed too", "const useCal = !!cal && !cal.allDays;", "const useCal = !!cal;"],
  ["every finish recomputed", "&& !isWorkingDay(cal, e)) {", ") {"],
  ["interval boundary off by one", "if (remaining <= b - from + 1e-9) return n;", "if (remaining < b - from) return n;"],
  ["start time of day ignored", "const from = n === start ? Math.max(a, startMin) : a;", "const from = a;"],
  ["weekday numbering off by one", "(((n + 4) % 7) + 7) % 7 + 1", "(((n + 5) % 7) + 7) % 7 + 1"],
  ["exceptions ignored", "for (let k = cal.ex.length - 1; k >= 0; k--) { const e = cal.ex[k]; if (n >= e.from && n <= e.to) return e.working; }", ""],
  ["material resources not detected", "type === 0 || !!label", "false"],
  ["absurd work not detected", "work > 100000", "work > 1e15"],
  ["UID 0 resource kept", "uid == null || uid === 0 || uid === PLACEHOLDER_RESOURCE", "uid == null || uid === PLACEHOLDER_RESOURCE"],
  ["wrong baseline number", "num(b, 'Number') === 0", "num(b, 'Number') === 1"],
  ["percent not clamped", "Math.max(0, Math.min(100, Math.round(num(tn, 'PercentComplete') || 0)))", "Math.round(num(tn, 'PercentComplete') || 0)"],
  ["payload: every level-1 row is a phase", "t.level === 1 && t.isSummary)", "t.level === 1)"],
  ["payload: tasks keep the phase as parent", "t.parentUid != null && !phaseUids.has(t.parentUid) ? t.parentUid : null", "t.parentUid"],
  ["payload: links to phases kept", "|| phaseUids.has(l.predUid)) {", ") {"],
  ["payload: self links kept", "l.predUid === t.uid ||", ""],
  ["build: constraint pin dropped", "<ConstraintType>4</ConstraintType>", "<ConstraintType>0</ConstraintType>"],
  ["build: duration off by one day", "(e - s + 1) * 8", "(e - s) * 8"],
  ["build: lag factor 480", "* 4800)", "* 480)"],
  ["build: '<' not escaped", ".replace(/</g, '&lt;')", ""],
  ["build: '&' not escaped", ".replace(/&/g, '&amp;')", ""],
  ["build: tasks one level too deep", "walk(t, 2); }", "walk(t, 3); }"],
  ["build: phase span from the latest start", "(lo == null || a < lo)", "(lo == null || a > lo)"],
  ["build: duplicate UIDs accepted", "|| all.has(r.uid)) throw", ") throw"],
  ["build: unknown link type accepted", "if (code === undefined) throw", "if (false) throw"],
  ["build: UID 0 accepted", "r.uid <= 0 ||", ""],
  ["notes of our own notice reported", "if (note && note !== subject)", "if (note)"],
];

function runTests(src) {
  const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, MSP_SRC: src }, encoding: "utf8", timeout: 60000 });
  return r.status === 0 && !r.error;
}

const tmp = mkdtempSync(join(tmpdir(), "msp-mut-"));
let caught = 0; const survivors = [];
try {
  const base = join(tmp, "base.js"); writeFileSync(base, original);
  if (!runTests(base)) { console.error("baseline run is not green: fix the suite before mutating"); process.exit(2); }
  MUTANTS.forEach(([name, from, to], i) => {
    const n = original.split(from).length - 1;
    if (n < 1) { console.error("mutant '" + name + "' does not apply (text not found)"); process.exit(2); }
    const file = join(tmp, "m" + i + ".js");
    writeFileSync(file, original.replaceAll(from, () => to));
    if (!runTests(file)) { caught++; console.log("  caught   " + name); } else { survivors.push(name); console.log("  SURVIVED " + name); }
  });
} finally { rmSync(tmp, { recursive: true, force: true }); }

if (survivors.length) { console.error("msp mutation check FAILED: " + caught + "/" + MUTANTS.length + " caught; survivors: " + survivors.join("; ")); process.exit(1); }
console.log("msp mutation check passed: " + caught + "/" + MUTANTS.length + " mutants caught");
