// Generates the REAL payloads used by 20_after.sql (G3: what schedule-msp.js toPayload emits is what the RPC must accept).
//   node supabase/tests/a2a_import/gen-payloads.mjs --write   regenerate payloads/*.json and the block inside 20_after.sql
//   node supabase/tests/a2a_import/gen-payloads.mjs --check   fail (exit 1) when either is out of date
// Payloads f01..f07 are the verbatim output of MspCodec.toPayload(MspCodec.parse(<fixture>)) for the seven files in
// scripts/tests/schedule/mspdi/. own04 is fixture 04 re-labelled as an export of the job JOB_OWN (the uids the server assigns on an
// append: phases first, then tasks, in payload order) with three edits, used for the merge round trip. ro04 is the same file written by a
// read-only user (temporary uids marker).
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const C = createRequire(import.meta.url)(join(root, "schedule-msp.js"));
const JOB_OWN = "b1000000-0000-0000-0000-0000000e00f1";
const fixDir = join(root, "scripts", "tests", "schedule", "mspdi");
const files = readdirSync(fixDir).filter((f) => f.endsWith(".xml")).sort();
const out = {};
const meta = {};
for (const f of files) {
  const key = "f" + f.slice(0, 2);
  out[key] = JSON.parse(JSON.stringify(C.toPayload(C.parse(readFileSync(join(fixDir, f), "utf8")))));
}
// own04: remap uids to the order the server assigns (phases 1..P, then tasks P+1..), set project.uid = the job, edit three things
{
  const p = JSON.parse(JSON.stringify(out.f04));
  const P = p.phases.length, map = new Map();
  p.phases.forEach((x, i) => map.set(x.uid, i + 1));
  p.tasks.forEach((x, i) => map.set(x.uid, P + i + 1));
  p.phases.forEach((x) => { x.uid = map.get(x.uid); });
  for (const t of p.tasks) {
    t.uid = map.get(t.uid);
    if (t.phase_uid != null) t.phase_uid = map.get(t.phase_uid);
    if (t.parent_uid != null) t.parent_uid = map.get(t.parent_uid);
    for (const l of t.links) l.pred_uid = map.get(l.pred_uid);
  }
  p.project.uid = JOB_OWN;
  const baseTasks = p.tasks.length;
  const dropped = p.tasks.pop();                                   // a Meridian-only row: it is in the job but not in the file
  const dropLinks = p.tasks.some((t) => t.links.some((l) => l.pred_uid === dropped.uid));
  if (dropLinks) for (const t of p.tasks) t.links = t.links.filter((l) => l.pred_uid !== dropped.uid);
  p.tasks[2].name = "Renamed in ProjectLibre";                      // edit 1
  p.tasks[3].progress = 55;                                         // edit 2
  p.tasks.push({ uid: 9999, name: "Added in ProjectLibre", phase_uid: p.phases[0].uid, parent_uid: null, start_date: "2026-12-01", end_date: "2026-12-03",
    progress: 0, is_milestone: false, is_summary: false, baseline_start: null, baseline_end: null, sort_order: 900, links: [] });   // a new row
  out.own04 = p;
  meta.own04 = { job: JOB_OWN, base_tasks: baseTasks, base_phases: P, expect: { created: 1, updated: 2, kept: 1, skipped: P + baseTasks - 1 - 2 } };
  const r = JSON.parse(JSON.stringify(p)); r.project.manager = "meridian-readonly-export"; out.ro04 = r;
}
const names = Object.keys(out).sort();
const sql = ["-- BEGIN GENERATED PAYLOADS (node supabase/tests/a2a_import/gen-payloads.mjs --write; do not edit by hand)",
  "CREATE TEMP TABLE t_payloads (name text PRIMARY KEY, body jsonb NOT NULL, meta jsonb);",
  "GRANT ALL ON t_payloads TO PUBLIC;"];
for (const n of names) {
  const body = JSON.stringify(out[n]);
  if (body.includes("$j$")) throw new Error("payload contains the dollar quote");
  sql.push(`INSERT INTO t_payloads VALUES ('${n}', $j$${body}$j$::jsonb, ${meta[n] ? `$j$${JSON.stringify(meta[n])}$j$::jsonb` : "NULL"});`);
}
sql.push("-- END GENERATED PAYLOADS");
const block = sql.join("\n");
const afterPath = join(here, "20_after.sql");
const src = readFileSync(afterPath, "utf8").replaceAll("\r\n", "\n");
const re = /-- BEGIN GENERATED PAYLOADS[\s\S]*?-- END GENERATED PAYLOADS/;
if (!re.test(src)) throw new Error("20_after.sql has no GENERATED PAYLOADS markers");
const next = src.replace(re, () => block);
const json = (n) => JSON.stringify(out[n], null, 1) + "\n";
if (process.argv.includes("--write")) {
  mkdirSync(join(here, "payloads"), { recursive: true });
  for (const n of names) writeFileSync(join(here, "payloads", n + ".json"), json(n));
  writeFileSync(afterPath, next);
  console.log("wrote", names.length, "payloads and the 20_after.sql block");
} else {
  let bad = next !== src;
  for (const n of names) { let cur = ""; try { cur = readFileSync(join(here, "payloads", n + ".json"), "utf8").replaceAll("\r\n", "\n"); } catch {} if (cur !== json(n)) bad = true; }
  if (bad) { console.error("payloads are out of date: run with --write"); process.exit(1); }
  console.log("payloads up to date:", names.join(", "));
}
