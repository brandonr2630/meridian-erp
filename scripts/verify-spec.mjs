// Verifies a phase spec under docs/specs/project-portal/ against the contract in 00-overview.md.
// Usage: node scripts/verify-spec.mjs phase-a-schedule-v2.md   (prints "spec verification passed" on success)
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

const DIR = process.env.SPEC_DIR || 'docs/specs/project-portal';
const file = process.argv[2];
if (!file) { console.error('usage: verify-spec.mjs <file-in-spec-dir>'); process.exit(2); }
const path = join(DIR, file);
if (!existsSync(path)) { console.error('FAIL: missing ' + path); process.exit(1); }
const text = readFileSync(path, 'utf8').replaceAll('\r\n', '\n');
const errs = [];

// Tables that exist live (verified against Supabase 2026-10-19) — plus auth.users.
const LIVE = new Set(('accounting_periods,accounts,bank_accounts,bank_transactions,bill_edit_events,bill_lines,bill_lines_archive,bills,companies,config_consumables,config_equipment,config_fuel,config_hardware,config_labour,config_materials,config_qc_checklists,config_tasks,config_tooling,consumable_entries,contact_persons,contacts,credit_note_lines,credit_notes,crm_activities,crm_opportunities,crm_tasks,crm_team_members,currencies,delivery_note_lines,delivery_notes,employees,equipment_entries,erp_notifications,erp_roles,erp_user_company_roles,erp_users,exchange_rates,fiscal_years,hardware_entries,invoice_lines,invoices,job_audit_log,job_drawings,job_tasks,jobs,journal_entries,journal_lines,labour_entries,material_entries,notification_log,notification_preferences,notification_types,opportunity_team,payment_allocations,payment_receipts,payments,po_lines,purchase_orders,quotation_lines,quotations,sales_leads,sequence_counters,subcontractor_entries,tooling_entries,user_company_access,users').split(','));

// Names reserved in 00-overview.md for specs written in parallel; resolvable by REFERENCES, creatable only by the owning phase.
const RESERVED = { a: ['job_phases', 'job_task_links'], b: ['job_itp_items', 'job_hold_points', 'job_ncrs'], c: ['job_updates', 'job_update_photos', 'job_progress_snapshots'], d: ['project_clients', 'project_messages', 'project_message_reads'] };
for (const v of Object.values(RESERVED)) for (const t of v) LIVE.add(t);

const isOverview =basename(file).startsWith('00-');
const REQUIRED = ['Goal and scope', 'Out of scope', 'Data model', 'RLS and permissions', 'Staff UI', 'Client-facing surface', 'Migration and rollout', 'Test plan', 'Risks', 'Open questions', 'Acceptance criteria'];

// Strip fences for heading analysis, keep sql blocks for DDL analysis.
const sqlBlocks = [...text.matchAll(/```sql\n([\s\S]*?)```/g)].map(m => m[1]);
const prose = text.replace(/```[\s\S]*?```/g, '');

if (!isOverview) {
  if (!/^# Phase [A-D] — .+/m.test(prose)) errs.push('missing "# Phase X — title" heading');
  const heads = [...prose.matchAll(/^## (.+)$/gm)].map(m => m[1].trim());
  let at = -1;
  for (const r of REQUIRED) {
    const i = heads.findIndex(h => h.toLowerCase().startsWith(r.toLowerCase()));
    if (i < 0) errs.push('missing section: ' + r);
    else if (i < at) errs.push('section out of order: ' + r);
    else at = i;
  }
  // every section must have real content (>= 40 chars)
  for (const r of REQUIRED) {
    const m = prose.match(new RegExp('^## ' + r.replace(/[()]/g, '\\$&') + '[^\\n]*\\n([\\s\\S]*?)(?=^## |$(?![\\s\\S]))', 'mi'));
    if (m && m[1].trim().length < 40) errs.push('section too thin: ' + r);
  }
  if (!sqlBlocks.length) errs.push('no ```sql block in Data model');
}

const sql = sqlBlocks.join('\n');

// Tables this spec creates, and tables created by sibling specs.
const created = new Set([...sql.matchAll(/CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:public\.)?([a-z_0-9]+)/gi)].map(m => m[1].toLowerCase()));
const siblings = new Set();
if (existsSync(DIR)) for (const f of readdirSync(DIR)) {
  if (f === file || !f.endsWith('.md')) continue;
  const t = readFileSync(join(DIR, f), 'utf8').replaceAll('\r\n', '\n');
  for (const m of t.matchAll(/CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:public\.)?([a-z_0-9]+)/gi)) siblings.add(m[1].toLowerCase());
}

// Every FK target must exist live or be defined in this/sibling specs.
for (const m of sql.matchAll(/REFERENCES\s+(?:public\.|auth\.)?([a-z_0-9]+)/gi)) {
  const t = m[1].toLowerCase();
  if (!LIVE.has(t) && !created.has(t) && !siblings.has(t)) errs.push('REFERENCES unknown table: ' + t);
}

// A phase may only CREATE tables reserved to it (or unreserved ones); never another phase's.
const mine = (basename(file).match(/^phase-([a-d])-/) || [])[1];
if (mine) for (const [ph, names] of Object.entries(RESERVED)) {
  if (ph === mine) continue;
  for (const t of created) if (names.includes(t)) errs.push('creates ' + t + ', which is reserved to phase ' + ph.toUpperCase());
}

// Every table created here needs RLS enabled and at least one policy.
for (const t of created) {
  if (!new RegExp('ALTER TABLE\\s+(?:public\\.)?' + t + '\\s+ENABLE ROW LEVEL SECURITY', 'i').test(sql)) errs.push('no ENABLE ROW LEVEL SECURITY for ' + t);
  if (!new RegExp('CREATE POLICY[^;]*ON\\s+(?:public\\.)?' + t + '\\b', 'i').test(sql)) errs.push('no CREATE POLICY for ' + t);
  if (!new RegExp('CREATE TABLE\\s+(?:IF NOT EXISTS\\s+)?(?:public\\.)?' + t + '[\\s\\S]*?job_id', 'i').test(sql) && !/portal|message|client/i.test(t)) errs.push('table ' + t + ' has no job_id');
}

// Existing live tables must not be altered destructively.
if (/DROP\s+(TABLE|COLUMN)\s/i.test(sql.replace(/--.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*--.*$/gm, '')) && !/-- down/i.test(sql)) errs.push('DROP in up-migration without a "-- down" section');

// Client-facing objects must never expose internal cost columns.
const COST = /\b(quoted_ttd|misc_ttd|costing_notes|rate_ttd|amount_ttd|unit_cost_ttd|cost_ttd|default_unit_cost_ttd|payment_terms|customer_po)\b/i;
for (const m of sql.matchAll(/CREATE (?:OR REPLACE )?(?:VIEW|FUNCTION)\s+(?:public\.)?(portal_[a-z_0-9]+|client_[a-z_0-9]+)[\s\S]*?(?=\n\s*(?:CREATE|ALTER|GRANT|COMMENT|--)\s|$(?![\s\S]))/gi)) {
  if (COST.test(m[0])) errs.push('client-facing object ' + m[1] + ' references a cost/commercial column');
}

if (/Phase D/i.test(file) || /phase-d/i.test(file)) {
  if (!/portal_[a-z_]+/i.test(sql)) errs.push('Phase D defines no portal_* views/functions');
  if (!/security_invoker|SECURITY DEFINER/i.test(sql)) errs.push('Phase D views/functions do not state their security mode');
}

// Each phase must address the mockup blocks mapped to it in 00-overview.md section 4.
const COVER = {
  a: ['milestone', 'baseline', 'critical path', 'today', 'planned', 'phase', 'schedule status', 'overall progress'],
  b: ['ITP', 'hold point', 'NCR', 'approval', 'revision', 'sign'],
  c: ['S-curve|progress curve', 'snapshot', 'photo', 'update', 'storage', 'planned', 'actual'],
  d: ['portal_', 'invite', 'message', 'notification', 'subdomain|separate app', 'client role|client user', 'cost', 'penetration|attack|abuse']
};
const letter = (basename(file).match(/^phase-([a-d])-/) || [])[1];
if (letter) for (const k of COVER[letter]) {
  if (!new RegExp(k, 'i').test(text)) errs.push('coverage: phase ' + letter.toUpperCase() + ' spec never mentions "' + k + '"');
}

if (errs.length) { console.error('FAIL: ' + file + '\n - ' + errs.join('\n - ')); process.exit(1); }
console.log('spec verification passed: ' + file + ` (${sqlBlocks.length} sql blocks, ${created.size} new tables)`);
