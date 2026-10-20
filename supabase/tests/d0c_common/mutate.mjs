// Mutation check for a D0c family. Usage: node supabase/tests/d0c_common/mutate.mjs <family>
// Reads supabase/tests/<family>/mutations.json: [{ "name": "...", "find": "exact text in the migration", "replace": "broken text",
//   "equivalent": false, "reason": "required only when equivalent is true" }]
// Each mutant is written to a temp file and run through run.sh in mutant mode: the AFTER assertions must FAIL (mutant caught).
// Prints "mutation check passed: N/N mutants caught" when every non-equivalent mutant is caught, otherwise exits 1.
import { readFileSync, writeFileSync, readdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const family = process.argv[2];
if (!family) { console.error("usage: mutate.mjs <family>"); process.exit(2); }
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const migDir = join(root, "supabase", "migrations");
const migFile = readdirSync(migDir).find((f) => f.endsWith(`_${family}.sql`));
if (!migFile) { console.error("migration not found for " + family); process.exit(2); }
const sql = readFileSync(join(migDir, migFile), "utf8").replaceAll("\r\n", "\n");
const muts = JSON.parse(readFileSync(join(root, "supabase", "tests", family, "mutations.json"), "utf8"));
if (!Array.isArray(muts) || muts.length < 3) { console.error("need at least 3 mutations"); process.exit(2); }
const tmp = mkdtempSync(join(tmpdir(), "d0c-mut-"));
let caught = 0, counted = 0; const survivors = [];
for (const [i, m] of muts.entries()) {
  const find = String(m.find).replaceAll("\r\n", "\n");
  if (!sql.includes(find)) { console.error(`mutation "${m.name}": find text not present in the migration`); process.exit(2); }
  if (m.equivalent) { if (!m.reason) { console.error(`mutation "${m.name}": equivalent needs a reason`); process.exit(2); } continue; }
  counted++;
  const file = join(tmp, `m${i}.sql`);
  writeFileSync(file, sql.replace(find, m.replace), "utf8");
  const r = spawnSync("bash", [join(root, "supabase", "tests", "d0c_common", "run.sh"), family, file], { encoding: "utf8" });
  const out = (r.stdout || "") + (r.stderr || "");
  if (r.status === 0 && out.includes("MUTANT CAUGHT")) { caught++; console.log(`  caught   ${m.name}`); }
  else { survivors.push(m.name); console.log(`  SURVIVED ${m.name}`); }
}
if (survivors.length) { console.error(`mutation check FAILED: ${survivors.length} survivor(s): ${survivors.join("; ")}`); process.exit(1); }
console.log(`mutation check passed: ${caught}/${counted} mutants caught`);
