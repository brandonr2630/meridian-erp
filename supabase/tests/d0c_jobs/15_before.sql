-- BEFORE the migration: the legacy open policy lets every active staff member read and write every company's jobs.
BEGIN;
DO $$
DECLARE
  viewer text := '22222222-2222-2222-2222-222222222222'; fin text := '88888888-8888-8888-8888-888888888888';
  opsc1 text := '11111111-1111-1111-1111-111111111111'; sales text := '99999999-9999-9999-9999-999999999999';
BEGIN
  PERFORM t_expect('before: ops C1 sees C2 jobs too', t_count('authenticated', opsc1::uuid, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('before: finance_manager (no ops atoms) reads all jobs', t_count('authenticated', fin::uuid, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('before: sales_rep reads all jobs', t_count('authenticated', sales::uuid, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('before: viewer can UPDATE a job', t_dml('authenticated', viewer::uuid, 'UPDATE jobs SET customer=''x'' WHERE id=''b1000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('before: viewer can INSERT a job', t_dml('authenticated', viewer::uuid, 'INSERT INTO jobs (company_id, job_no) VALUES (''c1000000-0000-0000-0000-000000000001'',''WO-900'')'), 'rows:1');
  PERFORM t_expect('before: ops C1 can write a C2 job', t_dml('authenticated', opsc1::uuid, 'UPDATE jobs SET customer=''x'' WHERE id=''b2000000-0000-0000-0000-000000000002'''), 'rows:1');
  PERFORM t_expect('before: viewer can DELETE a job', t_dml('authenticated', viewer::uuid, 'DELETE FROM jobs WHERE id=''b1000000-0000-0000-0000-000000000003'''), 'rows:1');
  PERFORM t_expect('before: a job can be moved to another company', t_dml('authenticated', opsc1::uuid, 'UPDATE jobs SET company_id=''c2000000-0000-0000-0000-000000000002'' WHERE id=''b1000000-0000-0000-0000-000000000004'''), 'rows:1');
END $$;
ROLLBACK;
