// Cross-spec contract check (decision X19): every trigger that executes job_visibility_guard must pass exactly two
// string arguments (wording columns, domain atom). Also checks the live role name 'Office Admin' is never spelled office_admin.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const DIR = process.env.SPEC_DIR || 'docs/specs/project-portal';
const errs = [];
let attachments = 0;
for (const f of readdirSync(DIR).filter(n => /^phase-[a-d]-.*\.md$/.test(n))) {
  const text = readFileSync(join(DIR, f), 'utf8').replaceAll('\r\n', '\n');
  const lines = text.split('\n');
  lines.forEach((line, i) => {
    const m = line.match(/EXECUTE (?:FUNCTION|PROCEDURE)\s+job_visibility_guard\((.*)\)\s*;?/i);
    if (m) {
      attachments++;
      const args = m[1].match(/'[^']*'/g) || [];
      const leftover = m[1].replace(/'[^']*'/g, '').replace(/[\s,]/g, '');
      if (args.length !== 2 || leftover) errs.push(`${f}:${i + 1}: job_visibility_guard has ${args.length} string args (need exactly 2): ${line.trim()}`);
    }
    if (/office_admin/i.test(line) && !/never|not\b|wrong|instead/i.test(line)) errs.push(`${f}:${i + 1}: uses office_admin; the live role name is exactly 'Office Admin'`);
  });
}
if (attachments < 6) errs.push(`expected at least 6 guard attachments across A-C, found ${attachments}`);
if (errs.length) { console.error('FAIL: guard contract\n - ' + errs.join('\n - ')); process.exit(1); }
console.log(`guard contract verification passed (${attachments} attachments)`);
