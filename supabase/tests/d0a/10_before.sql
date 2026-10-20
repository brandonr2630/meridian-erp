-- BEFORE D0a: prove the live holes exist in the stub (positive control for the AFTER tests).
BEGIN;
DO $$
DECLARE
  client uuid := '88888888-8888-8888-8888-888888888888';
BEGIN
  -- a client-shaped user (no erp_users row) reads and writes cost data across companies
  PERFORM t_expect('before: client reads all jobs',            t_count('authenticated', client, 'select * from public.jobs'), 'n:2');
  PERFORM t_expect('before: client reads labour_entries',      t_count('authenticated', client, 'select * from public.labour_entries'), 'n:2');
  PERFORM t_expect('before: client reads employees',           t_count('authenticated', client, 'select * from public.employees'), 'n:2');
  PERFORM t_expect('before: client writes jobs',               t_dml('authenticated', client, 'update public.jobs set quoted_ttd = 1'), 'rows:2');
  -- storage: any authenticated user lists/reads/deletes every company's drawings and uploads logos
  PERFORM t_expect('before: client lists all drawings',        t_count('authenticated', client, 'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:3');
  PERFORM t_expect('before: client deletes a drawing',         t_dml('authenticated', client, 'delete from storage.objects where bucket_id = ''job-drawings'' and name like ''c2%'''), 'rows:1');
  PERFORM t_expect('before: client uploads a logo',            t_dml('authenticated', client, 'insert into storage.objects (bucket_id, name) values (''company-logos'', ''x.png'')'), 'rows:1');
  -- anon can run the definer functions
  PERFORM t_expect('before: anon runs next_job_no',            t_dml('anon', null, 'select public.next_job_no()'), 'rows:1');
  PERFORM t_expect('before: anon runs is_company_admin',       t_dml('anon', null, 'select public.is_company_admin(''c1000000-0000-0000-0000-000000000001'')'), 'rows:1');
END $$;
ROLLBACK;
