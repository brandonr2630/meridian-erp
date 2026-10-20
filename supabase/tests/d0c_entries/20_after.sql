-- AFTER d0c_entries: role x operation x scope matrix on all 7 tables.
-- Pass 1 runs with jobs still open (today's state); pass 2 runs after jobs gets a scoped policy as d0c_jobs will (company +
-- ops:work-orders atoms), because the entry policies subquery jobs under the caller's RLS.
-- Every write case runs in its own rolled-back sub-block so cases do not affect each other's counts.
BEGIN;

CREATE FUNCTION public.t_w(p_name text, p_role text, p_sub uuid, p_sql text, p_expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE got text;
BEGIN
  BEGIN
    got := t_dml(p_role, p_sub, p_sql);
    RAISE EXCEPTION 'rollback marker' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  PERFORM t_expect(p_name, got, p_expected);
END $$;

CREATE FUNCTION public.t_matrix(lbl text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  ops     uuid := '11111111-1111-1111-1111-111111111111';
  viewer  uuid := '22222222-2222-2222-2222-222222222222';
  adm     uuid := '33333333-3333-3333-3333-333333333333';
  sup     uuid := '44444444-4444-4444-4444-444444444444';
  office  uuid := '55555555-5555-5555-5555-555555555555';
  removed uuid := '66666666-6666-6666-6666-666666666666';
  ops2    uuid := '77777777-7777-7777-7777-777777777777';
  client  uuid := '88888888-8888-8888-8888-888888888888';
  fin     uuid := '99999999-9999-9999-9999-999999999999';
  sales   uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  j1 text := 'b1000000-0000-0000-0000-000000000001';
  j2 text := 'b2000000-0000-0000-0000-000000000002';
  j9 text := 'b9000000-0000-0000-0000-000000000009';
  t text; p text; ins1 text; ins2 text; ins9 text; upd text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    p := lbl || ' ' || t || ': ';
    ins1 := 'insert into public.' || t || ' (job_id) values (''' || j1 || ''')';
    ins2 := 'insert into public.' || t || ' (job_id) values (''' || j2 || ''')';
    ins9 := 'insert into public.' || t || ' (job_id) values (''' || j9 || ''')';
    upd  := 'update public.' || t || ' set sort_order = 9';

    -- SELECT
    PERFORM t_expect(p || 'ops C1 reads own company only',      t_count('authenticated', ops,     'select * from public.' || t), 'n:1');
    PERFORM t_expect(p || 'ops C2 reads own company only',      t_count('authenticated', ops2,    'select * from public.' || t), 'n:1');
    PERFORM t_expect(p || 'viewer reads (work-orders:read)',    t_count('authenticated', viewer,  'select * from public.' || t), 'n:1');
    PERFORM t_expect(p || 'company_admin reads',                t_count('authenticated', adm,     'select * from public.' || t), 'n:1');
    PERFORM t_expect(p || 'multi-company super_admin reads both', t_count('authenticated', sup,   'select * from public.' || t), 'n:2');
    PERFORM t_expect(p || 'Office Admin reads (work-orders:read)', t_count('authenticated', office, 'select * from public.' || t), 'n:1');
    PERFORM t_expect(p || 'finance_manager (no ops atom) reads none', t_count('authenticated', fin, 'select * from public.' || t), 'n:0');
    PERFORM t_expect(p || 'sales_rep (no ops atom) reads none', t_count('authenticated', sales,   'select * from public.' || t), 'n:0');
    PERFORM t_expect(p || 'removed staff reads none',           t_count('authenticated', removed, 'select * from public.' || t), 'n:0');
    PERFORM t_expect(p || 'client (no staff row) reads none',   t_count('authenticated', client,  'select * from public.' || t), 'n:0');
    PERFORM t_expect(p || 'anon reads none',                    t_count('anon', null,             'select * from public.' || t), 'n:0');
    PERFORM t_expect(p || 'ops C1 cannot see C2 job rows by id', t_count('authenticated', ops, 'select * from public.' || t || ' where job_id = ''' || j2 || ''''), 'n:0');

    -- INSERT into a job of the caller's company
    PERFORM t_w(p || 'ops inserts own job',           'authenticated', ops,     ins1, 'rows:1');
    PERFORM t_w(p || 'company_admin inserts own job', 'authenticated', adm,     ins1, 'rows:1');
    PERFORM t_w(p || 'super_admin inserts C1 job',    'authenticated', sup,     ins1, 'rows:1');
    PERFORM t_w(p || 'super_admin inserts C2 job',    'authenticated', sup,     ins2, 'rows:1');
    PERFORM t_w(p || 'ops C2 inserts own job',        'authenticated', ops2,    ins2, 'rows:1');
    PERFORM t_w(p || 'viewer cannot insert',          'authenticated', viewer,  ins1, 'err:42501');
    PERFORM t_w(p || 'Office Admin cannot insert (no write atom)', 'authenticated', office, ins1, 'err:42501');
    PERFORM t_w(p || 'finance_manager cannot insert', 'authenticated', fin,     ins1, 'err:42501');
    PERFORM t_w(p || 'sales_rep cannot insert',       'authenticated', sales,   ins1, 'err:42501');
    PERFORM t_w(p || 'removed staff cannot insert',   'authenticated', removed, ins1, 'err:42501');
    PERFORM t_w(p || 'client cannot insert',          'authenticated', client,  ins1, 'err:42501');
    PERFORM t_w(p || 'anon cannot insert',            'anon', null,             ins1, 'err:42501');
    -- INSERT across companies / unknown job
    PERFORM t_w(p || 'ops C1 cannot insert into C2 job', 'authenticated', ops,  ins2, 'err:42501');
    PERFORM t_w(p || 'ops C2 cannot insert into C1 job', 'authenticated', ops2, ins1, 'err:42501');
    PERFORM t_w(p || 'company_admin C1 cannot insert into C2 job', 'authenticated', adm, ins2, 'err:42501');
    PERFORM t_w(p || 'ops cannot insert for unknown job', 'authenticated', ops, ins9, 'err:42501');

    -- UPDATE
    PERFORM t_w(p || 'ops updates own company rows only', 'authenticated', ops,  upd, 'rows:1');
    PERFORM t_w(p || 'ops C2 updates own company rows only', 'authenticated', ops2, upd, 'rows:1');
    PERFORM t_w(p || 'company_admin updates',        'authenticated', adm,     upd, 'rows:1');
    PERFORM t_w(p || 'super_admin updates both companies', 'authenticated', sup, upd, 'rows:2');
    PERFORM t_w(p || 'viewer cannot update',         'authenticated', viewer,  upd, 'rows:0');
    PERFORM t_w(p || 'Office Admin cannot update',   'authenticated', office,  upd, 'rows:0');
    PERFORM t_w(p || 'finance_manager cannot update','authenticated', fin,     upd, 'rows:0');
    PERFORM t_w(p || 'sales_rep cannot update',      'authenticated', sales,   upd, 'rows:0');
    PERFORM t_w(p || 'removed staff cannot update',  'authenticated', removed, upd, 'rows:0');
    PERFORM t_w(p || 'client cannot update',         'authenticated', client,  upd, 'rows:0');
    PERFORM t_w(p || 'anon cannot update',           'anon', null,             upd, 'rows:0');
    -- UPDATE re-pointing a child row to another company's job
    PERFORM t_w(p || 'ops cannot re-point own row to C2 job',  'authenticated', ops,  'update public.' || t || ' set job_id = ''' || j2 || ''' where job_id = ''' || j1 || '''', 'err:42501');
    PERFORM t_w(p || 'ops C2 cannot re-point own row to C1 job', 'authenticated', ops2, 'update public.' || t || ' set job_id = ''' || j1 || ''' where job_id = ''' || j2 || '''', 'err:42501');
    PERFORM t_w(p || 'company_admin cannot re-point to C2 job', 'authenticated', adm, 'update public.' || t || ' set job_id = ''' || j2 || ''' where job_id = ''' || j1 || '''', 'err:42501');
    PERFORM t_w(p || 'ops cannot re-point to unknown job',     'authenticated', ops,  'update public.' || t || ' set job_id = ''' || j9 || ''' where job_id = ''' || j1 || '''', 'err:42501');
    PERFORM t_w(p || 'ops cannot touch C2 row (re-point attempt matches nothing)', 'authenticated', ops, 'update public.' || t || ' set job_id = ''' || j1 || ''' where job_id = ''' || j2 || '''', 'rows:0');
    PERFORM t_w(p || 'super_admin (member of both) may move between own companies', 'authenticated', sup, 'update public.' || t || ' set job_id = ''' || j2 || ''' where job_id = ''' || j1 || '''', 'rows:1');
    -- no WHERE clause: the UPDATE needs no SELECT rights, so the UPDATE policy's WITH CHECK is the only guard on the new job_id
    PERFORM t_w(p || 'ops cannot re-point (no WHERE) to C2 job', 'authenticated', ops, 'update public.' || t || ' set job_id = ''' || j2 || '''', 'err:42501');
    PERFORM t_w(p || 'ops C2 cannot re-point (no WHERE) to C1 job', 'authenticated', ops2, 'update public.' || t || ' set job_id = ''' || j1 || '''', 'err:42501');
    PERFORM t_w(p || 'ops cannot re-point (no WHERE) to unknown job', 'authenticated', ops, 'update public.' || t || ' set job_id = ''' || j9 || '''', 'err:42501');
    PERFORM t_w(p || 'super_admin (both companies) may re-point (no WHERE)', 'authenticated', sup, 'update public.' || t || ' set job_id = ''' || j2 || '''', 'rows:2');
    PERFORM t_w(p || 'viewer cannot re-point',       'authenticated', viewer,  'update public.' || t || ' set job_id = ''' || j2 || ''' where job_id = ''' || j1 || '''', 'rows:0');

    -- DELETE
    PERFORM t_w(p || 'ops deletes own company rows only', 'authenticated', ops,  'delete from public.' || t, 'rows:1');
    PERFORM t_w(p || 'ops C2 deletes own company rows only', 'authenticated', ops2, 'delete from public.' || t, 'rows:1');
    PERFORM t_w(p || 'company_admin deletes',        'authenticated', adm,     'delete from public.' || t, 'rows:1');
    PERFORM t_w(p || 'super_admin deletes both',     'authenticated', sup,     'delete from public.' || t, 'rows:2');
    PERFORM t_w(p || 'viewer cannot delete',         'authenticated', viewer,  'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'Office Admin cannot delete',   'authenticated', office,  'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'finance_manager cannot delete','authenticated', fin,     'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'sales_rep cannot delete',      'authenticated', sales,   'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'removed staff cannot delete',  'authenticated', removed, 'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'client cannot delete',         'authenticated', client,  'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'anon cannot delete',           'anon', null,             'delete from public.' || t, 'rows:0');
    PERFORM t_w(p || 'ops C1 cannot delete C2 job rows', 'authenticated', ops, 'delete from public.' || t || ' where job_id = ''' || j2 || '''', 'rows:0');
    -- the job-card save pattern for a writer: delete by job_id then insert, in the caller's company
    PERFORM t_w(p || 'ops save pattern (delete by job_id)', 'authenticated', ops, 'delete from public.' || t || ' where job_id = ''' || j1 || '''', 'rows:1');
  END LOOP;
END $$;

DO $$
DECLARE t text;
BEGIN
  -- structure: legacy open policy gone, 4 scoped policies + the 2 D0a restrictive ones remain, nothing permissive and open
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    PERFORM t_expect(t || ': legacy open policy dropped', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname='authenticated users full access'), '0');
    PERFORM t_expect(t || ': 4 d0c policies', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname like 'd0c\_%'), '4');
    PERFORM t_expect(t || ': D0a restrictive pair intact', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname in ('d0_staff_only','d0_no_anon') and permissive='RESTRICTIVE'), '2');
    PERFORM t_expect(t || ': no permissive policy with a constant-true clause', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and permissive='PERMISSIVE' and (qual='true' or with_check='true')), '0');
    PERFORM t_expect(t || ': d0c policies only for authenticated', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname like 'd0c\_%' and roles <> '{authenticated}'), '0');
  END LOOP;

  -- pass 1: jobs open (today)
  PERFORM public.t_matrix('[jobs open]');

  -- pass 2: jobs scoped the way d0c_jobs will (company + ops:work-orders atoms)
  DROP POLICY "authenticated users full access" ON public.jobs;
  CREATE POLICY d0c_jobs_select ON public.jobs FOR SELECT TO authenticated
    USING (company_id IN (SELECT public.my_company_ids())
           AND ((SELECT public.user_has_perm('ops:work-orders:read')) OR (SELECT public.user_has_perm('ops:work-orders:write'))));
  CREATE POLICY d0c_jobs_write ON public.jobs FOR ALL TO authenticated
    USING (company_id IN (SELECT public.my_company_ids()) AND (SELECT public.user_has_perm('ops:work-orders:write')))
    WITH CHECK (company_id IN (SELECT public.my_company_ids()) AND (SELECT public.user_has_perm('ops:work-orders:write')));
  PERFORM public.t_matrix('[jobs scoped]');
END $$;
ROLLBACK;
