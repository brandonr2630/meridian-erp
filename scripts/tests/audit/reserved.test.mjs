import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { auditWrites, reservedList, appTypes, splitTop, check } from '../../verify-audit-reserved.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const POLICY = `CREATE POLICY d0c_job_audit_log_insert ON public.job_audit_log FOR INSERT TO authenticated WITH CHECK (
  user_id = (SELECT auth.uid()) AND action_type NOT LIKE 'staff.access.%' AND action_type NOT IN ('baseline_locked', 'schedule_imported') AND job_id IS NOT NULL);`;
const reservedMig = { name: '202610290900_d0c_audit_reserved.sql', sql: POLICY };
const fn = (body, def = true) => `CREATE OR REPLACE FUNCTION f() RETURNS void LANGUAGE plpgsql ${def ? 'SECURITY DEFINER' : ''} SET search_path = public AS $$ BEGIN ${body} END $$;`;
const ins = (expr) => `INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata) VALUES (j, n, u, 'x', ${expr}, 'd', '{}'::jsonb);`;

test('the real repository passes', () => {
  const dir = join(root, 'supabase', 'migrations');
  const migrations = readdirSync(dir).filter((f) => f.endsWith('.sql')).map((name) => ({ name, sql: readFileSync(join(dir, name), 'utf8') }));
  assert.deepEqual(check({ migrations, html: readFileSync(join(root, 'index.html'), 'utf8') }), []);
});

test('the real reserved list is exactly the types the database functions write', () => {
  const dir = join(root, 'supabase', 'migrations');
  const migrations = readdirSync(dir).filter((f) => f.endsWith('.sql')).map((name) => ({ name, sql: readFileSync(join(dir, name), 'utf8') }));
  const reserved = reservedList(migrations.find((m) => /_d0c_audit_reserved\.sql$/.test(m.name)).sql).sort();
  const written = new Set();
  for (const m of migrations) if (!/_d0c_audit_reserved\.sql$/.test(m.name)) for (const w of auditWrites(m.sql)) for (const t of w.types || []) written.add(t);
  assert.deepEqual([...written].sort(), reserved);
});

test('splitTop ignores commas inside parentheses and quotes', () => {
  assert.deepEqual(splitTop("a, f(b, c), 'x, y', CASE WHEN p THEN 'q' ELSE 'r' END"), ['a', 'f(b, c)', "'x, y'", "CASE WHEN p THEN 'q' ELSE 'r' END"]);
  assert.deepEqual(splitTop("'it''s, fine', b"), ["'it''s, fine'", 'b']);
});

test('a plain literal and a CASE are read; the CASE comparison literal is not taken for a type', () => {
  assert.deepEqual(auditWrites(fn(ins("'baseline_locked'")))[0].types, ['baseline_locked']);
  const c = auditWrites(fn(ins("CASE WHEN p_mode = 'replace' AND b THEN 'baseline_reset' ELSE 'baseline_locked' END")))[0];
  assert.deepEqual(c.types, ['baseline_reset', 'baseline_locked']);
  assert.equal(c.definer, true);
});

test('a type written by a function but not reserved is reported', () => {
  const errs = check({ migrations: [reservedMig, { name: '1_x.sql', sql: fn(ins("'brand_new'")) }], html: '' });
  assert.equal(errs.length, 1); assert.match(errs[0], /'brand_new'.*not reserved/);
});

test('a reserved type written by a SECURITY DEFINER function passes', () => {
  assert.deepEqual(check({ migrations: [reservedMig, { name: '1_x.sql', sql: fn(ins("'schedule_imported'")) }], html: '' }), []);
});

test('an INSERT outside a SECURITY DEFINER function is reported', () => {
  const errs = check({ migrations: [reservedMig, { name: '1_x.sql', sql: fn(ins("'schedule_imported'"), false) }], html: '' });
  assert.equal(errs.length, 1); assert.match(errs[0], /not inside a SECURITY DEFINER/);
});

test('a dynamic action_type that cannot be read is reported, not ignored', () => {
  const errs = check({ migrations: [reservedMig, { name: '1_x.sql', sql: fn(ins('v_action')) }], html: '' });
  assert.equal(errs.length, 1); assert.match(errs[0], /cannot read/);
});

test('the function that contains the INSERT is the one looked at, not an earlier definer one', () => {
  const sql = fn('NULL;') + '\n' + fn(ins("'schedule_imported'"), false);
  assert.equal(check({ migrations: [reservedMig, { name: '1_x.sql', sql }], html: '' }).length, 1);
});

test('the app writing a reserved type is reported', () => {
  const errs = check({ migrations: [reservedMig], html: "sbPost('job_audit_log', { action_type:'schedule_imported' })" });
  assert.equal(errs.length, 1); assert.match(errs[0], /index\.html writes/);
});

test('the app writing a non-reserved type passes; appTypes reads both quote styles', () => {
  assert.deepEqual(appTypes(`x({action_type:'job_saved'}) y({ action_type: "job_deleted" })`), ['job_saved', 'job_deleted']);
  assert.deepEqual(check({ migrations: [reservedMig], html: `x({action_type:'job_saved'})` }), []);
});

test('a missing or duplicated reserved-actions migration is reported', () => {
  assert.match(check({ migrations: [], html: '' })[0], /exactly one/);
  assert.match(check({ migrations: [reservedMig, { ...reservedMig, name: '9_d0c_audit_reserved.sql' }], html: '' })[0], /exactly one/);
});

test('an unreadable reserved list is reported', () => {
  assert.match(check({ migrations: [{ name: '1_d0c_audit_reserved.sql', sql: 'SELECT 1;' }], html: '' })[0], /could not read/);
});
