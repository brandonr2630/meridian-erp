-- AFTER d0c_bills: full role x operation x scope matrix for bill_edit_events and bill_lines_archive.
-- Fixtures: C1 has bills b1,b4 (events e1 by adm, e1s by sup, e4; archive a1,a1s,a4), C2 has b2 (e2 by adm2; a2), C3 has b3 (e3; a3).
-- Visible counts: C1 = 4 events/3 archive (e5 authored by non-admin finance_manager), C2 = 2/1 (e6 authored by a C1 admin), C3 = 1/1. sup is a member of C1+C2 only.
BEGIN;
DO $$
DECLARE
  ops     uuid := '11111111-1111-1111-1111-111111111111';
  viewer  uuid := '22222222-2222-2222-2222-222222222222';
  adm     uuid := '33333333-3333-3333-3333-333333333333';
  sup     uuid := '44444444-4444-4444-4444-444444444444';
  office  uuid := '55555555-5555-5555-5555-555555555555';
  removed uuid := '66666666-6666-6666-6666-666666666666';
  ops2    uuid := '77777777-7777-7777-7777-777777777777';
  fin     uuid := '88880000-0000-0000-0000-000000000008';
  sales   uuid := '99990000-0000-0000-0000-000000000009';
  adm2    uuid := 'aaaa0000-0000-0000-0000-00000000000a';
  stg     uuid := 'bbbb0000-0000-0000-0000-00000000000b';
  usr     uuid := 'cccc0000-0000-0000-0000-00000000000c';
  client  uuid := '88888888-8888-8888-8888-888888888888';
  b1 text := 'd1000000-0000-0000-0000-000000000001';
  b2 text := 'd2000000-0000-0000-0000-000000000002';
  b3 text := 'd3000000-0000-0000-0000-000000000003';
  b4 text := 'd4000000-0000-0000-0000-000000000004';
  e1 text := 'f1000000-0000-0000-0000-000000000001';
  e1s text := 'f1500000-0000-0000-0000-000000000015';
  e2 text := 'f2000000-0000-0000-0000-000000000002';
  e3 text := 'f3000000-0000-0000-0000-000000000003';
  e5 text := 'f5000000-0000-0000-0000-000000000005';
  e6 text := 'f6000000-0000-0000-0000-000000000006';
  evq text := 'select * from public.bill_edit_events';
  arq text := 'select * from public.bill_lines_archive';
BEGIN
  -- ── policy shape ────────────────────────────────────────────────────────────
  PERFORM t_expect('legacy policy dropped (events)',  (select count(*)::text from pg_policies where tablename='bill_edit_events'  and policyname='authenticated users full access'), '0');
  PERFORM t_expect('legacy policy dropped (archive)', (select count(*)::text from pg_policies where tablename='bill_lines_archive' and policyname='authenticated users full access'), '0');
  PERFORM t_expect('no UPDATE/DELETE/ALL permissive policy (events)',  (select count(*)::text from pg_policies where tablename='bill_edit_events'  and permissive='PERMISSIVE' and cmd in ('UPDATE','DELETE','ALL')), '0');
  PERFORM t_expect('no UPDATE/DELETE/ALL permissive policy (archive)', (select count(*)::text from pg_policies where tablename='bill_lines_archive' and permissive='PERMISSIVE' and cmd in ('UPDATE','DELETE','ALL')), '0');
  PERFORM t_expect('D0a restrictive pair intact (events)',  (select count(*)::text from pg_policies where tablename='bill_edit_events'  and policyname in ('d0_staff_only','d0_no_anon')), '2');
  PERFORM t_expect('D0a restrictive pair intact (archive)', (select count(*)::text from pg_policies where tablename='bill_lines_archive' and policyname in ('d0_staff_only','d0_no_anon')), '2');
  PERFORM t_expect('no policy is USING true', (select count(*)::text from pg_policies where tablename in ('bill_edit_events','bill_lines_archive') and permissive='PERMISSIVE' and (qual='true' or with_check='true')), '0');

  -- ── SELECT: needs finance:ap:read and a bill in the caller's company ───────────
  PERFORM t_expect('events select: client (no staff row)',   t_count('authenticated', client,  evq), 'n:0');
  PERFORM t_expect('events select: removed staff',           t_count('authenticated', removed, evq), 'n:0');
  PERFORM t_expect('events select: anon',                    t_count('anon', null,             evq), 'n:0');
  PERFORM t_expect('events select: operations_tech (no AP)', t_count('authenticated', ops,     evq), 'n:0');
  PERFORM t_expect('events select: sales_rep (no AP)',       t_count('authenticated', sales,   evq), 'n:0');
  PERFORM t_expect('events select: ops C2 (no AP)',          t_count('authenticated', ops2,    evq), 'n:0');
  PERFORM t_expect('events select: viewer sees own company only', t_count('authenticated', viewer, evq), 'n:4');
  PERFORM t_expect('events select: Office Admin own company',     t_count('authenticated', office, evq), 'n:4');
  PERFORM t_expect('events select: finance_manager own company',  t_count('authenticated', fin,    evq), 'n:4');
  PERFORM t_expect('events select: company_admin C1 own company', t_count('authenticated', adm,    evq), 'n:4');
  PERFORM t_expect('events select: company_admin C2 own company', t_count('authenticated', adm2,   evq), 'n:2');
  PERFORM t_expect('events select: multi-company super sees C1+C2 not C3', t_count('authenticated', sup, evq), 'n:6');
  PERFORM t_expect('events select: C1 admin cannot see C2 bill events',  t_count('authenticated', adm,  evq || ' where bill_id = ''' || b2 || ''''), 'n:0');
  PERFORM t_expect('events select: C2 admin cannot see C1 bill events',  t_count('authenticated', adm2, evq || ' where bill_id = ''' || b1 || ''''), 'n:0');
  PERFORM t_expect('events select: super cannot see non-member C3 bill', t_count('authenticated', sup,  evq || ' where bill_id = ''' || b3 || ''''), 'n:0');
  PERFORM t_expect('events select: own bill filter works (UI query)',    t_count('authenticated', viewer, evq || ' where bill_id = ''' || b1 || ''' order by edited_at desc'), 'n:3');
  PERFORM t_expect('events select: embedded-bills query used by AP list', t_count('authenticated', viewer, 'select e.bill_id from public.bill_edit_events e join public.bills b on b.id = e.bill_id where b.company_id = ''c1000000-0000-0000-0000-000000000001'''), 'n:4');

  PERFORM t_expect('archive select: client',                 t_count('authenticated', client,  arq), 'n:0');
  PERFORM t_expect('archive select: removed staff',          t_count('authenticated', removed, arq), 'n:0');
  PERFORM t_expect('archive select: anon',                   t_count('anon', null,             arq), 'n:0');
  PERFORM t_expect('archive select: operations_tech (no AP)', t_count('authenticated', ops,     arq), 'n:0');
  PERFORM t_expect('archive select: sales_rep (no AP)',      t_count('authenticated', sales,   arq), 'n:0');
  PERFORM t_expect('archive select: ops C2 (no AP)',         t_count('authenticated', ops2,    arq), 'n:0');
  PERFORM t_expect('archive select: viewer own company',     t_count('authenticated', viewer,  arq), 'n:3');
  PERFORM t_expect('archive select: Office Admin own company', t_count('authenticated', office, arq), 'n:3');
  PERFORM t_expect('archive select: finance_manager own company', t_count('authenticated', fin, arq), 'n:3');
  PERFORM t_expect('archive select: company_admin C1',       t_count('authenticated', adm,     arq), 'n:3');
  PERFORM t_expect('archive select: company_admin C2',       t_count('authenticated', adm2,    arq), 'n:1');
  PERFORM t_expect('archive select: super sees C1+C2 not C3', t_count('authenticated', sup,    arq), 'n:4');
  PERFORM t_expect('archive select: archive of other-company event invisible (C1 admin, e2)', t_count('authenticated', adm,  arq || ' where edit_event_id = ''' || e2 || ''''), 'n:0');
  PERFORM t_expect('archive select: archive of other-company event invisible (C2 admin, e1)', t_count('authenticated', adm2, arq || ' where edit_event_id = ''' || e1 || ''''), 'n:0');
  PERFORM t_expect('archive select: super cannot see non-member C3 archive',               t_count('authenticated', sup,  arq || ' where edit_event_id = ''' || e3 || ''''), 'n:0');
  PERFORM t_expect('archive select: UI query by edit_event_id list', t_count('authenticated', viewer, arq || ' where edit_event_id in (''' || e1 || ''',''' || e1s || ''') order by line_order asc'), 'n:2');

  -- ── INSERT bill_edit_events: admin atom + edited_by = caller + bill in caller company ─
  PERFORM t_expect('events insert: client',              t_dml('authenticated', client,  'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || client  || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: removed staff',       t_dml('authenticated', removed, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || removed || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: anon',                t_dml('anon', null,             'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', null, ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: viewer denied',       t_dml('authenticated', viewer,  'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || viewer  || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: operations_tech denied', t_dml('authenticated', ops,  'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || ops     || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: sales_rep denied',    t_dml('authenticated', sales,   'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || sales   || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: Office Admin denied (AP write but not isAdmin, as the UI)', t_dml('authenticated', office, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || office || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: finance_manager denied (AP write but not isAdmin, as the UI)', t_dml('authenticated', fin, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || fin || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: settings-only admin allowed (isAdmin = admin:users OR admin:settings)', t_dml('authenticated', stg, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || stg || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: users-only admin allowed', t_dml('authenticated', usr, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || usr || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: company_admin own bill allowed', t_dml('authenticated', adm, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || adm || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: super own-company bill allowed', t_dml('authenticated', sup, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || sup || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: super in 2nd member company allowed', t_dml('authenticated', sup, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b2 || ''', ''' || sup || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: C2 admin on own company allowed', t_dml('authenticated', adm2, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b2 || ''', ''' || adm2 || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('events insert: C2 admin on C1 bill denied (cross-company)', t_dml('authenticated', adm2, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || adm2 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: C1 admin on C2 bill denied',     t_dml('authenticated', adm, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b2 || ''', ''' || adm || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: super on non-member C3 bill denied', t_dml('authenticated', sup, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b3 || ''', ''' || sup || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: edited_by forged (another user) denied', t_dml('authenticated', adm, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', ''' || sup || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: edited_by null denied',          t_dml('authenticated', adm, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', null, ''x'')'), 'err:42501');
  PERFORM t_expect('events insert: unknown bill denied',            t_dml('authenticated', adm, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''d9000000-0000-0000-0000-000000000009'', ''' || adm || ''', ''x'')'), 'err:42501');

  -- ── INSERT bill_lines_archive: admin atom + parent event by caller + its bill in caller company ─
  PERFORM t_expect('archive insert: client',             t_dml('authenticated', client,  'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: removed staff',      t_dml('authenticated', removed, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: anon',               t_dml('anon', null,             'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: viewer denied',      t_dml('authenticated', viewer,  'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: operations_tech denied', t_dml('authenticated', ops, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: sales_rep denied',   t_dml('authenticated', sales,   'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: Office Admin denied', t_dml('authenticated', office, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: finance_manager denied', t_dml('authenticated', fin, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: finance_manager into own historic event denied (not isAdmin)', t_dml('authenticated', fin, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e5 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: C1 admin into own event on a C2 bill denied', t_dml('authenticated', adm, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e6 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: settings-only admin into own event allowed', t_dml('authenticated', stg, 'insert into public.bill_lines_archive (edit_event_id, description) select id, ''x'' from public.bill_edit_events where edited_by = ''' || stg || ''' limit 1'), 'rows:1');
  PERFORM t_expect('archive insert: users-only admin into own event allowed', t_dml('authenticated', usr, 'insert into public.bill_lines_archive (edit_event_id, description) select id, ''x'' from public.bill_edit_events where edited_by = ''' || usr || ''' limit 1'), 'rows:1');
  PERFORM t_expect('archive insert: company_admin into own event allowed', t_dml('authenticated', adm, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('archive insert: super into own event allowed',         t_dml('authenticated', sup, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1s || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('archive insert: C2 admin into own event allowed',      t_dml('authenticated', adm2, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e2 || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('archive insert: into another admin''s event denied (same company)', t_dml('authenticated', sup, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: C1 admin into C2 event denied',        t_dml('authenticated', adm, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e2 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: C2 admin into C1 event denied',        t_dml('authenticated', adm2, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e1 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: super into non-member C3 event denied', t_dml('authenticated', sup, 'insert into public.bill_lines_archive (edit_event_id, description) values (''' || e3 || ''', ''x'')'), 'err:42501');
  PERFORM t_expect('archive insert: nonexistent event denied',             t_dml('authenticated', adm, 'insert into public.bill_lines_archive (edit_event_id, description) values (''d9000000-0000-0000-0000-000000000009'', ''x'')'), 'err:42501');

  -- ── UPDATE: nobody (history is append-only). Includes re-pointing an archive row to another company's event ─
  PERFORM t_expect('events update: company_admin',   t_dml('authenticated', adm,  'update public.bill_edit_events set reason = ''tampered'''), 'rows:0');
  PERFORM t_expect('events update: super',           t_dml('authenticated', sup,  'update public.bill_edit_events set reason = ''tampered'''), 'rows:0');
  PERFORM t_expect('events update: viewer',          t_dml('authenticated', viewer, 'update public.bill_edit_events set reason = ''tampered'''), 'rows:0');
  PERFORM t_expect('events update: re-point event to another company bill (admin)', t_dml('authenticated', adm, 'update public.bill_edit_events set bill_id = ''' || b2 || ''' where id = ''' || e1 || ''''), 'rows:0');
  PERFORM t_expect('archive update: company_admin',  t_dml('authenticated', adm,  'update public.bill_lines_archive set description = ''tampered'''), 'rows:0');
  PERFORM t_expect('archive update: super',          t_dml('authenticated', sup,  'update public.bill_lines_archive set description = ''tampered'''), 'rows:0');
  PERFORM t_expect('archive update: viewer',         t_dml('authenticated', viewer, 'update public.bill_lines_archive set description = ''tampered'''), 'rows:0');
  PERFORM t_expect('archive update: re-point row to another company event (admin)', t_dml('authenticated', adm, 'update public.bill_lines_archive set edit_event_id = ''' || e2 || ''' where edit_event_id = ''' || e1 || ''''), 'rows:0');
  PERFORM t_expect('archive update: re-point row to another company event (C2 admin pulls C1 row)', t_dml('authenticated', adm2, 'update public.bill_lines_archive set edit_event_id = ''' || e2 || ''' where edit_event_id = ''' || e1 || ''''), 'rows:0');
  PERFORM t_expect('update left rows intact (events)',  t_count('postgres', null, 'select * from public.bill_edit_events where reason = ''tampered'' or (id = ''' || e1 || ''' and bill_id <> ''' || b1 || ''')'), 'n:0');
  PERFORM t_expect('update left rows intact (archive)', t_count('postgres', null, 'select * from public.bill_lines_archive where description = ''tampered'' or edit_event_id = ''' || e2 || ''' and description = ''a1'''), 'n:0');

  -- ── DELETE: nobody directly ──────────────────────────────────────────────────
  PERFORM t_expect('events delete: company_admin',   t_dml('authenticated', adm,   'delete from public.bill_edit_events'), 'rows:0');
  PERFORM t_expect('events delete: super',           t_dml('authenticated', sup,   'delete from public.bill_edit_events'), 'rows:0');
  PERFORM t_expect('events delete: finance_manager', t_dml('authenticated', fin,   'delete from public.bill_edit_events'), 'rows:0');
  PERFORM t_expect('events delete: viewer',          t_dml('authenticated', viewer,'delete from public.bill_edit_events'), 'rows:0');
  PERFORM t_expect('archive delete: company_admin',  t_dml('authenticated', adm,   'delete from public.bill_lines_archive'), 'rows:0');
  PERFORM t_expect('archive delete: super',          t_dml('authenticated', sup,   'delete from public.bill_lines_archive'), 'rows:0');
  PERFORM t_expect('archive delete: finance_manager', t_dml('authenticated', fin,  'delete from public.bill_lines_archive'), 'rows:0');
  PERFORM t_expect('archive delete: viewer',         t_dml('authenticated', viewer,'delete from public.bill_lines_archive'), 'rows:0');
  PERFORM t_expect('rows survive the delete attempts (events: 7 seed + 6 inserted)', t_count('postgres', null, evq), 'n:13');
  PERFORM t_expect('rows survive the delete attempts (archive: 5 seed + 5 inserted)', t_count('postgres', null, arq), 'n:10');

  -- ── deleting a draft bill still removes its history (FK cascade runs as owner, not the caller) ─
  PERFORM t_expect('bill delete: company_admin deletes own draft bill (cascade)', t_dml('authenticated', adm, 'delete from public.bills where id = ''' || b4 || ''''), 'rows:1');
  PERFORM t_expect('bill delete cascaded to events',  t_count('postgres', null, evq || ' where bill_id = ''' || b4 || ''''), 'n:0');
  PERFORM t_expect('bill delete cascaded to archive', t_count('postgres', null, arq || ' where edit_event_id = ''f4000000-0000-0000-0000-000000000004'''), 'n:0');
END $$;
ROLLBACK;
