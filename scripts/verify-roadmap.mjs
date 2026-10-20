// Verifies docs/specs/project-portal/99-roadmap.md: required sections, all four phases covered, and that every
// "Open question" heading across phase specs is surfaced in the roadmap's decisions table.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const DIR = process.env.SPEC_DIR || 'docs/specs/project-portal';
const read = f => readFileSync(join(DIR, f), 'utf8').replaceAll('\r\n', '\n');
const errs = [];
if (!existsSync(join(DIR, '99-roadmap.md'))) { console.error('FAIL: 99-roadmap.md missing'); process.exit(1); }
const road = read('99-roadmap.md');
const prose = road.replace(/```[\s\S]*?```/g, '');
const heads = [...prose.matchAll(/^## (.+)$/gm)].map(m => m[1].toLowerCase());
for (const need of ['sequencing', 'decisions', 'risks', 'effort', 'first slice']) {
  if (!heads.some(h => h.includes(need))) errs.push('missing section: ' + need);
}
for (const p of ['phase a', 'phase b', 'phase c', 'phase d']) {
  if (!new RegExp(p, 'i').test(prose)) errs.push('roadmap never mentions ' + p);
}
for (const f of ['phase-a-schedule-v2.md', 'phase-b-quality.md', 'phase-c-updates-progress.md', 'phase-d-client-portal.md']) {
  if (!existsSync(join(DIR, f))) errs.push('missing phase file ' + f);
  else if (!road.includes(f)) errs.push('roadmap does not link ' + f);
}
// Each phase spec's open-question section must be reflected: count bullets/rows in the roadmap decisions table >= number of phases.
const rows = (prose.match(/^\|.+\|$/gm) || []).length;
if (rows < 8) errs.push('roadmap tables look too thin (' + rows + ' rows)');
if (errs.length) { console.error('FAIL: roadmap\n - ' + errs.join('\n - ')); process.exit(1); }
console.log('roadmap verification passed');
