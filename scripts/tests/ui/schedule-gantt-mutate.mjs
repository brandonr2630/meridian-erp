// Mutation check for the Schedule v2 Gantt renderer block. Run: node scripts/tests/ui/schedule-gantt-mutate.mjs
// Each mutant breaks one rule of the block in a COPY of index.html; schedule-gantt.test.mjs (pointed at the copy via UI_SRC) must fail.
// Exit 0 only when every mutant is caught: "mutation check passed: n/n mutants caught".
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const testFile = join(here, "schedule-gantt.test.mjs");
const original = readFileSync(join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");

// [name, exact text in the block, replacement]; from/to may be arrays of the same length for multi-step edits
const MUTANTS = [
  ["wrong px-per-day at Week zoom", "Week: 8,", "Week: 7,"],
  ["wrong px-per-day at Day zoom", "Day: 28,", "Day: 24,"],
  ["wrong px-per-day at Month zoom", "Month: 3 }", "Month: 4 }"],
  ["ghost bar uses the current dates instead of the baseline", "const gs = spanOf(n.bs, n.be);", "const gs = spanOf(n.s, n.e);"],
  ["ghost bar not 4 px lower", "y: by + 4, width: gs.width", "y: by, width: gs.width"],
  ["ghost bar as thick as the actual bar", "height: JC_GANTT_GHOST_H };", "height: JC_GANTT_BAR_H };"],
  ["milestone filled logic inverted", "const filled = n.prog >= 100,", "const filled = n.prog < 100,"],
  ["milestone past-due includes today", "n.e < T && !filled", "n.e <= T && !filled"],
  ["milestone past-due ignores completion", "n.e < T && !filled", "n.e < T"],
  ["milestone label on the left", "x: cx + r + 6, y: cy }", "x: cx - r - 6, y: cy }"],
  ["milestone not at the centre of its end day", "const cx = X(n.e) + px / 2,", "const cx = X(n.e),"],
  ["collapsed phase rows still drawn", "if (collapsed) continue;", ""],
  ["collapse key reset never happens on job change", "jcGanttCollapsed.clear(); jcGanttJobId = jobId;", "jcGanttJobId = jobId;"],
  ["TODAY line off by one day", "x: X(T) + px / 2, day", "x: X(T + 1) + px / 2, day"],
  ["TODAY line at the start of the day, not the middle", "x: X(T) + px / 2, day", "x: X(T), day"],
  ["TODAY line drawn under the bars", ["  for (const c of layout.connectors) {", "  if (layout.today) body.appendChild(S('line', { class: 'gt-today-ln', x1: layout.today.x, x2: layout.today.x, y1: 0, y2: bh }));   // above the bars\n"],
    ["  if (layout.today) body.appendChild(S('line', { class: 'gt-today-ln', x1: layout.today.x, x2: layout.today.x, y1: 0, y2: bh }));\n  for (const c of layout.connectors) {", ""]],
  ["today taken as the UTC date", "String(d.getDate()).padStart(2, '0')", "String(d.getUTCDate()).padStart(2, '0')"],
  ["unescaped label: text helper assigns innerHTML", "if (text != null) n.textContent = String(text); return n; };\n  const S", "if (text != null) n.innerHTML = String(text); return n; };\n  const S"],
  ["unescaped label: svg text helper assigns innerHTML", "if (text != null) n.textContent = String(text);\n    return n;", "if (text != null) n.innerHTML = String(text);\n    return n;"],
  ["critical colour ignores crit", "colour = crit ? JC_GANTT_CRIT : col;", "colour = col;"],
  ["critical set ignores the live compute result", "new Set(comp ? comp.crit :", "new Set(false ? comp.crit :"],
  ["no fallback to the cached is_critical", "nt.filter(n => n.t.is_critical).map(n => n.id)", "[]"],
  ["connectors drawn for all links by default", "if (!critical && !showAll) continue;", ""],
  ["a link is critical when only one end is", "critSet.has(l.predecessor_id) && critSet.has(l.task_id)", "critSet.has(l.predecessor_id) || critSet.has(l.task_id)"],
  ["connector starts at the predecessor start", "const x1 = a.x1, y1 = a.y, x2 = b.x0", "const x1 = a.x0, y1 = a.y, x2 = b.x0"],
  ["connector ends at the successor finish", "const x1 = a.x1, y1 = a.y, x2 = b.x0", "const x1 = a.x1, y1 = a.y, x2 = b.x1"],
  ["connector ignores the diamond edge", "anchors.set(n.id, { y: cy, x0: cx - r, x1: cx + r });", "anchors.set(n.id, { y: cy, x0: cx, x1: cx });"],
  ["y offset error on task rows", "const y2 = rows.length * rowH, crit = critSet.has(n.id)", "const y2 = rows.length * rowH + 1, crit = critSet.has(n.id)"],
  ["y offset error on phase rows", "const y = rows.length * rowH;\n    const label", "const y = rows.length * rowH + rowH;\n    const label"],
  ["progress portion ignores progress", "progressWidth: sp.width * n.prog / 100, colour, critical: crit", "progressWidth: sp.width, colour, critical: crit"],
  ["progress not clamped at 100", "Math.min(100, Math.max(0, n)) : 0; };", "Math.max(0, n) : 0; };"],
  ["bar width loses the inclusive last day", "(ce - cs + 1) * px)", "(ce - cs) * px)"],
  ["undated task still marked scheduled", "unscheduled: n.s == null,", "unscheduled: false,"],
  ["Unphased group dropped", "if (loose.length) groups.push", "if (false) groups.push"],
  ["phases ignore sort_order", "(jcSchedNum(a.p.sort_order) ?? 0) - (jcSchedNum(b.p.sort_order) ?? 0)", "0"],
  ["phase % read from the wrong rollup", "rollups.get(g.phase ? g.phase.id : null)", "rollups.get(null)"],
  ["end before start not normalised (negative width)", "bad = true; const x = s; s = e; e = x;", "bad = true;"],
  ["progress label always outside the bar", "const inside = sp.width >= 36;", "const inside = false;"],
  ["progress label inside even for tiny bars", "const inside = sp.width >= 36;", "const inside = true;"],
  ["weekday off by one (Monday ticks)", "if (((d % 7) + 7 + 4) % 7 === 1) ticks.push", "if (((d % 7) + 7 + 3) % 7 === 1) ticks.push"],
  ["weekend shading wrong days", "weekend: dow === 0 || dow === 6", "weekend: dow === 1 || dow === 6"],
  ["'added after baseline' shown without a baseline", "else if (hasBaseline) lines.push", "else lines.push"],
  ["slip measured the wrong way round", "const sl = n.e - n.be;", "const sl = n.be - n.e;"],
  ["scroll position lost on redraw", "else { wrap.scrollLeft = keepL; wrap.scrollTop = keepT; }", "else { }"],
  ["TODAY not scrolled into view on open", "Math.max(0, layout.today.x - 0.35", "Math.max(0, layout.today.x * 0 - 0.35"],
  ["legacy depends_on fallback removed", "if (!links.length) links = tasks.filter(", "if (false) links = tasks.filter("],
  ["failure not reported quietly", "m.textContent = 'The schedule chart could not be drawn.';", "m.textContent = '';"],
  ["dependency toggle ignored on redraw", "showAll: jcGanttShowAll,\n      onToggle", "showAll: false,\n      onToggle"],
  ["left rows not 28 px", "lr.style.height = r.h + 'px';", "lr.style.height = (r.h + 2) + 'px';"],
  ["hostile phase colour accepted", "&& /^#[0-9a-fA-F]{6}$/.test(c))", "&& true)"],
];
const MUT_FIX = (m) => (Array.isArray(m[1]) ? [m[1], m[2]] : [[m[1]], [m[2]]]);

const dir = mkdtempSync(join(tmpdir(), "gantt-mut-"));
let caught = 0; const survivors = [];
try {
  for (const m of MUTANTS) {
    const [froms, tos] = MUT_FIX(m);
    let src = original;
    froms.forEach((from, i) => {
      const count = src.split(from).length - 1;
      if (count !== 1) { console.error(`mutant "${m[0]}": pattern ${i} found ${count}x (need exactly 1)`); process.exit(2); }
      src = src.replace(from, () => tos[i]);
    });
    const file = join(dir, "index.html"); writeFileSync(file, src);
    const r = spawnSync(process.execPath, ["--test", testFile], { env: { ...process.env, UI_SRC: file }, encoding: "utf8" });
    if (r.status !== 0) { caught++; console.log("caught    " + m[0]); } else { survivors.push(m[0]); console.log("SURVIVED  " + m[0]); }
  }
} finally { rmSync(dir, { recursive: true, force: true }); }
if (survivors.length) { console.error(`mutation check FAILED: ${caught}/${MUTANTS.length} mutants caught; survivors: ${survivors.join("; ")}`); process.exit(1); }
console.log(`mutation check passed: ${caught}/${MUTANTS.length} mutants caught`);
