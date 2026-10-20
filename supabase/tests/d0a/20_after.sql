-- AFTER D0a: staff keep working, non-staff get nothing, storage is tenant- and permission-scoped, functions are hardened.
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
  client  uuid := '88888888-8888-8888-8888-888888888888';
  c1 text := 'c1000000-0000-0000-0000-000000000001';
  c2 text := 'c2000000-0000-0000-0000-000000000002';
  j1 text := 'b1000000-0000-0000-0000-000000000001';
  j2 text := 'b2000000-0000-0000-0000-000000000002';
  t text; n int := 0;
  tables text[] := ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','jobs','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types'];
BEGIN
  -- ── all 22 tables: non-staff get nothing, staff unchanged ───────────────────
  FOREACH t IN ARRAY tables LOOP
    PERFORM t_expect(t || ': client select',  t_count('authenticated', client,  'select * from public.' || t), 'n:0');
    PERFORM t_expect(t || ': removed select', t_count('authenticated', removed, 'select * from public.' || t), 'n:0');
    PERFORM t_expect(t || ': anon select',    t_count('anon', null,             'select * from public.' || t), 'n:0');
    IF t <> 'jobs' THEN
      PERFORM t_expect(t || ': client insert', t_dml('authenticated', client, 'insert into public.' || t || ' (company_id) values (''' || c1 || ''')'), 'err:42501');
      PERFORM t_expect(t || ': anon insert',   t_dml('anon', null,            'insert into public.' || t || ' (company_id) values (''' || c1 || ''')'), 'err:42501');
    END IF;
    PERFORM t_expect(t || ': ops select unchanged', t_count('authenticated', ops, 'select * from public.' || t), 'n:2');
    n := n + 1;
  END LOOP;
  PERFORM t_expect('jobs: client insert', t_dml('authenticated', client, 'insert into public.jobs (company_id, job_no) values (''' || c1 || ''', ''X'')'), 'err:42501');
  PERFORM t_expect('jobs: client update', t_dml('authenticated', client, 'update public.jobs set quoted_ttd = 1'), 'rows:0');
  PERFORM t_expect('jobs: client delete', t_dml('authenticated', client, 'delete from public.jobs'), 'rows:0');
  PERFORM t_expect('jobs: ops update (unchanged behaviour)', t_dml('authenticated', ops, 'update public.jobs set quoted_ttd = quoted_ttd'), 'rows:2');
  PERFORM t_expect('labour_entries: ops insert', t_dml('authenticated', ops, 'insert into public.labour_entries (company_id, note) values (''' || c1 || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('labour_entries: viewer insert (legacy, unchanged until D0c)', t_dml('authenticated', viewer, 'insert into public.labour_entries (company_id, note) values (''' || c1 || ''', ''x'')'), 'rows:1');
  PERFORM t_expect('labour_entries: office insert (active staff, unchanged)', t_dml('authenticated', office, 'insert into public.labour_entries (company_id, note) values (''' || c1 || ''', ''x'')'), 'rows:1');
  -- control table the migration must not touch
  PERFORM t_expect('invoices control: ops sees own company only', t_count('authenticated', ops, 'select * from public.invoices'), 'n:1');
  PERFORM t_expect('invoices control: client sees none',          t_count('authenticated', client, 'select * from public.invoices'), 'n:0');
  PERFORM t_expect('invoices: no d0 policy added', (select count(*)::text from pg_policies where tablename='invoices' and policyname like 'd0_%'), '0');

  -- ── storage: job-drawings ───────────────────────────────────────────────────
  PERFORM t_expect('drawings: ops sees own company only',  t_count('authenticated', ops,    'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:1');
  PERFORM t_expect('drawings: ops2 sees only its company',         t_count('authenticated', ops2,   'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:1');
  PERFORM t_expect('drawings: viewer can read (has read atom)',    t_count('authenticated', viewer, 'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:1');
  PERFORM t_expect('drawings: super reads company drawings',       t_count('authenticated', sup,    'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:1');
  PERFORM t_expect('drawings: office (no read atom) sees none',    t_count('authenticated', office, 'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:0');
  PERFORM t_expect('drawings: client sees none',                   t_count('authenticated', client, 'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:0');
  PERFORM t_expect('drawings: removed sees none',                  t_count('authenticated', removed,'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:0');
  PERFORM t_expect('drawings: anon sees none',                     t_count('anon', null,            'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:0');
  PERFORM t_expect('drawings: ops upload own company/job',         t_dml('authenticated', ops,    'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/' || j1 || '/2-new.pdf'')'), 'rows:1');
  PERFORM t_expect('drawings: ops upload other company prefix',    t_dml('authenticated', ops,    'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c2 || '/' || j2 || '/3.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: ops upload unknown job',             t_dml('authenticated', ops,    'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/b9000000-0000-0000-0000-000000000009/3.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: ops upload company/jobOfOtherCompany', t_dml('authenticated', ops,  'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/' || j2 || '/3.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: ops upload bare key (no prefix)',    t_dml('authenticated', ops,    'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''loose.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: viewer upload (no write atom)',      t_dml('authenticated', viewer, 'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/' || j1 || '/4.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: client upload',                      t_dml('authenticated', client, 'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/' || j1 || '/5.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: anon upload',                        t_dml('anon', null,            'insert into storage.objects (bucket_id, name) values (''job-drawings'', ''' || c1 || '/' || j1 || '/5.pdf'')'), 'err:42501');
  PERFORM t_expect('drawings: ops delete (not admin)',             t_dml('authenticated', ops,    'delete from storage.objects where bucket_id = ''job-drawings'' and name like ''c1%'''), 'rows:0');
  PERFORM t_expect('drawings: client delete',                      t_dml('authenticated', client, 'delete from storage.objects where bucket_id = ''job-drawings'''), 'rows:0');
  -- two C1 objects exist at this point: the seeded one and the one ops uploaded above
  PERFORM t_expect('drawings: admin deletes own company objects',  t_dml('authenticated', adm,    'delete from storage.objects where bucket_id = ''job-drawings'' and name like ''c1%'''), 'rows:2');
  PERFORM t_expect('drawings: admin cannot delete other company',  t_dml('authenticated', adm,    'delete from storage.objects where bucket_id = ''job-drawings'' and name like ''c2%'''), 'rows:0');
  PERFORM t_expect('drawings: nobody can overwrite (no UPDATE policy)', t_dml('authenticated', adm, 'update storage.objects set name = name where bucket_id = ''job-drawings'''), 'rows:0');

  -- cross-tenant IDOR via the legacy-key fallback: a C1 member plants a job_drawings row that names a C2 object key
  PERFORM t_expect('IDOR: ops plants a row pointing at a C2 key', t_dml('authenticated', ops, 'insert into public.job_drawings (job_id, company_id, storage_key) values (''' || j1 || ''', ''' || c1 || ''', ''' || c2 || '/' || j2 || '/1-b.pdf'')'), 'rows:1');
  PERFORM t_expect('IDOR: planted row does not expose the C2 object to ops', t_count('authenticated', ops, 'select * from storage.objects where bucket_id = ''job-drawings'' and name like ''c2%'''), 'n:0');
  PERFORM t_expect('IDOR: planted row does not let a C1 admin delete the C2 object', t_dml('authenticated', adm, 'delete from storage.objects where bucket_id = ''job-drawings'' and name like ''c2%'''), 'rows:0');

  -- ── storage: company-logos ──────────────────────────────────────────────────
  PERFORM t_expect('logos: client upload',            t_dml('authenticated', client, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''x.png'')'), 'err:42501');
  PERFORM t_expect('logos: ops (not admin) upload',   t_dml('authenticated', ops,    'insert into storage.objects (bucket_id, name) values (''company-logos'', ''' || c1 || '-124.png'')'), 'err:42501');
  PERFORM t_expect('logos: admin uploads own logo',   t_dml('authenticated', adm,    'insert into storage.objects (bucket_id, name) values (''company-logos'', ''' || c1 || '-125.png'')'), 'rows:1');
  PERFORM t_expect('logos: admin cannot upload other company logo', t_dml('authenticated', adm, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''' || c2 || '-125.png'')'), 'err:42501');
  PERFORM t_expect('logos: admin cannot upload new-company logo',   t_dml('authenticated', adm, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''new-125.png'')'), 'err:42501');
  PERFORM t_expect('logos: super uploads new-company logo',         t_dml('authenticated', sup, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''new-126.png'')'), 'rows:1');
  PERFORM t_expect('logos: anon upload',              t_dml('anon', null, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''x.png'')'), 'err:42501');
  PERFORM t_expect('logos: removed upload',           t_dml('authenticated', removed, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''' || c1 || '-127.png'')'), 'err:42501');

  -- ── definer functions ───────────────────────────────────────────────────────
  PERFORM t_expect('next_job_no: anon denied',     t_dml('anon', null, 'select public.next_job_no()'), 'err:42501');
  PERFORM t_expect('next_job_no: client denied',   t_dml('authenticated', client, 'select public.next_job_no()'), 'err:42501');
  PERFORM t_expect('next_job_no: removed denied',  t_dml('authenticated', removed, 'select public.next_job_no()'), 'err:42501');
  PERFORM t_expect('next_job_no: staff ok',        t_dml('authenticated', ops, 'select public.next_job_no()'), 'rows:1');
  PERFORM t_expect('next_job_no: returns WO-nnn',  (select public.next_job_no() from (select set_config('request.jwt.claim.sub', ops::text, true)) s), 'WO-' || lpad((select last_value::text from public.job_no_seq), 3, '0'));
  PERFORM t_expect('is_company_admin: anon denied', t_dml('anon', null, 'select public.is_company_admin(''' || c1 || ''')'), 'err:42501');
  PERFORM t_expect('is_company_admin: authenticated still works', t_dml('authenticated', adm, 'select public.is_company_admin(''' || c1 || ''')'), 'rows:1');
  PERFORM t_expect('is_erp_staff: anon denied',    t_dml('anon', null, 'select public.is_erp_staff()'), 'err:42501');
  PERFORM t_expect('is_erp_staff: client false',   (select public.is_erp_staff()::text from (select set_config('request.jwt.claim.sub', client::text, true)) s), 'false');
  PERFORM t_expect('is_erp_staff: staff true',     (select public.is_erp_staff()::text from (select set_config('request.jwt.claim.sub', ops::text, true)) s), 'true');
  PERFORM t_expect('is_erp_staff: removed false',  (select public.is_erp_staff()::text from (select set_config('request.jwt.claim.sub', removed::text, true)) s), 'false');
  FOREACH t IN ARRAY ARRAY['my_company_ids','is_super_admin','user_has_perm','next_job_no','is_company_admin','is_erp_staff'] LOOP
    PERFORM t_expect('search_path pinned: ' || t,
      (select array_to_string(proconfig, ',') from pg_proc where pronamespace = 'public'::regnamespace and proname = t),
      'search_path=public, pg_temp');
  END LOOP;
  PERFORM t_expect('no PUBLIC execute on next_job_no / is_company_admin / is_erp_staff',
    (select count(*)::text from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.pronamespace = 'public'::regnamespace and p.proname in ('next_job_no','is_company_admin','is_erp_staff')
        and a.privilege_type = 'EXECUTE' and a.grantee = 0), '0');

  -- ── inventory gates (spec Q-C and Q-R) ──────────────────────────────────────
  PERFORM t_expect('Q-R: tables lacking restrictive companions', (
    select count(*)::text from (
      select distinct p.tablename from pg_policies p
      where p.schemaname = 'public' and p.permissive = 'PERMISSIVE'
        and coalesce(p.qual,'') || ' ' || coalesce(p.with_check,'') !~* '(auth\.uid|my_company_ids|is_super_admin|is_company_admin|user_has_perm|is_erp_staff|erp_users|portal_)'
        and (not exists (select 1 from pg_policies r where r.schemaname='public' and r.tablename=p.tablename and r.policyname='d0_staff_only' and r.permissive='RESTRICTIVE')
          or not exists (select 1 from pg_policies r where r.schemaname='public' and r.tablename=p.tablename and r.policyname='d0_no_anon' and r.permissive='RESTRICTIVE'))
    ) q), '0');
  PERFORM t_expect('Q-C: identity-free permissive storage policies left', (
    select count(*)::text from pg_policies
    where schemaname = 'storage' and permissive = 'PERMISSIVE'
      and coalesce(qual,'') || ' ' || coalesce(with_check,'') !~* '(auth\.uid|my_company_ids|is_super_admin|is_company_admin|user_has_perm|is_erp_staff|erp_users|portal_)'), '0');
  PERFORM t_expect('legacy storage policy names gone', (
    select count(*)::text from pg_policies where schemaname='storage' and policyname in ('job-drawings auth read','job-drawings auth upload','job-drawings auth delete','Authenticated logo upload')), '0');
  PERFORM t_expect('22 tables got both restrictive policies', (
    select count(*)::text from pg_policies where schemaname='public' and policyname in ('d0_staff_only','d0_no_anon')), '44');
  RAISE NOTICE 'PASS summary: % tables checked', n;
END $$;
ROLLBACK;
