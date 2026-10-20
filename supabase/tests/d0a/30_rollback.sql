-- AFTER the down script: the original state is back exactly (holes reopen, policies and grants restored).
BEGIN;
DO $$
DECLARE client uuid := '88888888-8888-8888-8888-888888888888';
BEGIN
  PERFORM t_expect('rollback: client reads all jobs again',      t_count('authenticated', client, 'select * from public.jobs'), 'n:2');
  PERFORM t_expect('rollback: client lists drawings again',      t_count('authenticated', client, 'select * from storage.objects where bucket_id = ''job-drawings'''), 'n:3');
  PERFORM t_expect('rollback: anon runs next_job_no again',      t_dml('anon', null, 'select public.next_job_no()'), 'rows:1');
  PERFORM t_expect('rollback: d0 table policies gone',           (select count(*)::text from pg_policies where policyname like 'd0\_%'), '0');
  PERFORM t_expect('rollback: legacy storage policies restored', (select count(*)::text from pg_policies where schemaname='storage' and policyname in ('job-drawings auth read','job-drawings auth upload','job-drawings auth delete','Authenticated logo upload')), '4');
  PERFORM t_expect('rollback: next_job_no search_path restored', (select array_to_string(proconfig, ',') from pg_proc where proname='next_job_no'), 'search_path=public');
  PERFORM t_expect('rollback: my_company_ids search_path reset', (select coalesce(array_to_string(proconfig, ','), 'none') from pg_proc where proname='my_company_ids'), 'none');
  PERFORM t_expect('rollback: audit index gone',                 (select count(*)::text from pg_indexes where indexname = 'job_audit_log_user_created_idx'), '0');
END $$;
ROLLBACK;
