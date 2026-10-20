// Gate G3 for a D0c family: the migration must not leave (or create) any open permissive policy on its tables.
// Usage: node supabase/tests/d0c_common/check-closed.mjs <family> <table> [<table> ...]
// Passes when: no `USING (true)` / `WITH CHECK (true)` outside comments, every table is named in the migration, at least one
// `d0c_` policy is created, and the legacy policy name is dropped (`authenticated users full access` or `notif_types_read`).
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const [family, ...tables] = process.argv.slice(2);
if (!family || tables.length === 0) { console.error("usage: check-closed.mjs <family> <table>..."); process.exit(2); }
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const migDir = join(root, "supabase", "migrations");
const file = readdirSync(migDir).find((f) => f.endsWith(`_${family}.sql`));
if (!file) { console.error("migration not found for " + family); process.exit(2); }
const raw = readFileSync(join(migDir, file), "utf8").replaceAll("\r\n", "\n");
const sql = raw.split("\n").map((l) => l.replace(/--.*$/, "")).join("\n");
const errs = [];
if (/using\s*\(\s*true\s*\)/i.test(sql)) errs.push("contains USING (true)");
if (/with\s+check\s*\(\s*true\s*\)/i.test(sql)) errs.push("contains WITH CHECK (true)");
for (const t of tables) if (!new RegExp(`\\b${t}\\b`).test(sql)) errs.push(`table ${t} is not named in the migration`);
if (!/create\s+policy\s+"?d0c_/i.test(sql) && !/'?CREATE POLICY d0c_/i.test(sql) && !/d0c_%/i.test(sql)) errs.push("creates no d0c_ policy");
if (!/authenticated users full access|notif_types_read/i.test(sql)) errs.push("does not drop the legacy policy by name");
if (!/drop\s+policy/i.test(sql)) errs.push("has no DROP POLICY");
if (errs.length) { console.error(`FAIL ${family}: ${errs.join("; ")}`); process.exit(1); }
console.log(`no open policies: ${family} ok (${tables.length} tables)`);
