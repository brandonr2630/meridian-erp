-- Scenario 2, session B: another writer links X after Y while A holds the per-job lock.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE authenticated;
SELECT set_config('conc.t0', clock_timestamp()::text, true);
DO $$ BEGIN
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES ('c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d0','f1000000-0000-0000-0000-0000000000d1','f1000000-0000-0000-0000-0000000000d2');
EXCEPTION WHEN OTHERS THEN PERFORM set_config('conc.err', SQLSTATE, true);
END $$;
SELECT 'B result ' || coalesce(nullif(current_setting('conc.err', true), ''), 'ok');
SELECT 'B waited_ms ' || round(extract(epoch FROM clock_timestamp() - current_setting('conc.t0')::timestamptz) * 1000);
COMMIT;
