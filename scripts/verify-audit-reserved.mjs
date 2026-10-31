// Drift guard for the audit-log reserved action types (supabase/migrations/*_d0c_audit_reserved.sql).
//
//   node scripts/verify-audit-reserved.mjs        exit 1 on any violation
//
// Rules it enforces (see the header of the reserved-actions migration):
//   1. Every action_type that a migration's SQL writes into job_audit_log is in the reserved list, so a browser session cannot forge it.
//   2. The function doing that INSERT is SECURITY DEFINER (otherwise RLS would apply to it and the reserved list would block it).
//   3. No action_type the web app (index.html) writes itself is in the reserved list (the app would lose those rows silently).
// Run it before merging any change that touches job_audit_log writers or the reserved list.
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// split a VALUES / column list at top-level commas (ignores commas inside parentheses and quotes)
export function splitTop(s) {
  const out = []; let depth = 0, q = false, cur = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { cur += c; if (c === "'") { if (s[i + 1] === "'") { cur += s[++i]; } else q = false; } continue; }
    if (c === "'") { q = true; cur += c; continue; }
    if (c === '(') depth++;
    if (c === ')') depth--;
    if (c === ',' && depth === 0) { out.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

// text of the balanced (...) group that starts at index i (s[i] === '(')
function group(s, i) {
  let depth = 0, q = false;
  for (let j = i; j < s.length; j++) {
    const c = s[j];
    if (q) { if (c === "'") { if (s[j + 1] === "'") j++; else q = false; } continue; }
    if (c === "'") { q = true; continue; }
    if (c === '(') depth++;
    if (c === ')') { depth--; if (depth === 0) return s.slice(i + 1, j); }
  }
  return null;
}

// every INSERT INTO job_audit_log in a migration: { types: string[]|null, definer: boolean }
export function auditWrites(sql) {
  const writes = [];
  const re = /INSERT\s+INTO\s+(?:public\.)?job_audit_log\s*\(/gi;
  let m;
  while ((m = re.exec(sql))) {
    const colsStart = m.index + m[0].length - 1;
    const cols = group(sql, colsStart);
    if (cols == null) continue;
    const names = splitTop(cols).map((c) => c.toLowerCase());
    const idx = names.indexOf('action_type');
    const afterCols = colsStart + cols.length + 2;
    const v = /^\s*VALUES\s*\(/i.exec(sql.slice(afterCols));
    let types = null;
    if (idx >= 0 && v) {
      const vals = group(sql, afterCols + v[0].length - 1);
      const expr = vals == null ? null : splitTop(vals)[idx];
      if (expr != null) {
        const plain = /^'([^']*)'$/.exec(expr);
        if (plain) types = [plain[1]];
        else {
          const lits = [...expr.matchAll(/(?:THEN|ELSE)\s+'([^']*)'/gi)].map((x) => x[1]);
          types = lits.length ? lits : null;
        }
      }
    }
    // the function that contains this INSERT: the last CREATE ... FUNCTION header before it
    const before = sql.slice(0, m.index);
    const f = [...before.matchAll(/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION[\s\S]*?\bAS\s+\$/gi)].pop();
    writes.push({ types, definer: !!f && /SECURITY\s+DEFINER/i.test(f[0]) });
  }
  return writes;
}

// the reserved list: literals of the "action_type NOT IN (...)" clause of the policy in the reserved-actions migration
export function reservedList(sql) {
  const m = /CREATE\s+POLICY\s+d0c_job_audit_log_insert[\s\S]*?action_type\s+NOT\s+IN\s*\(([^)]*)\)/i.exec(sql);
  return m ? [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]) : null;
}

// action types the web app writes itself
export function appTypes(html) {
  return [...new Set([...html.matchAll(/action_type\s*:\s*['"]([^'"]+)['"]/g)].map((x) => x[1]))];
}

export function check({ migrations, html }) {
  const errors = [];
  const rm = migrations.filter((x) => /_d0c_audit_reserved\.sql$/.test(x.name));
  if (rm.length !== 1) return ['expected exactly one *_d0c_audit_reserved.sql migration, found ' + rm.length];
  const reserved = reservedList(rm[0].sql);
  if (!reserved || !reserved.length) return ['could not read the reserved list from ' + rm[0].name];
  for (const mig of migrations) {
    if (mig.name === rm[0].name) continue;
    for (const w of auditWrites(mig.sql)) {
      if (w.types == null) errors.push(mig.name + ': an INSERT INTO job_audit_log has an action_type this guard cannot read (use a literal or a CASE with literals), so it cannot be checked against the reserved list');
      else for (const t of w.types) if (!reserved.includes(t)) errors.push(mig.name + ": action_type '" + t + "' is written by a database function but is not reserved (add it to the list in a new migration)");
      if (!w.definer) errors.push(mig.name + ': an INSERT INTO job_audit_log is not inside a SECURITY DEFINER function (RLS would apply to it)');
    }
  }
  for (const t of appTypes(html)) if (reserved.includes(t)) errors.push("index.html writes action_type '" + t + "' but it is reserved (the app would lose those rows)");
  return errors;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const dir = join(root, 'supabase', 'migrations');
  const migrations = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort().map((name) => ({ name, sql: readFileSync(join(dir, name), 'utf8') }));
  const html = readFileSync(join(root, 'index.html'), 'utf8');
  const errors = check({ migrations, html });
  if (errors.length) { console.error(errors.map((e) => 'FAIL ' + e).join('\n')); process.exit(1); }
  const rm = migrations.find((x) => /_d0c_audit_reserved\.sql$/.test(x.name));
  console.log('audit reserved list OK: ' + reservedList(rm.sql).join(', ') + ' | app writes: ' + appTypes(html).join(', '));
}
