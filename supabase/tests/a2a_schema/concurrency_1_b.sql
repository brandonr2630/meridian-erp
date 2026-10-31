-- Scenario 1, session B: another writer makes Y a child of X while A holds the per-job lock.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE authenticated;
SELECT set_config('conc.t0', clock_timestamp()::text, true);
DO $$ BEGIN
  UPDATE job_tasks SET parent_task_id = 'f1000000-0000-0000-0000-0000000000d1' WHERE id = 'f1000000-0000-0000-0000-0000000000d2';
  RAISE NOTICE 'B result ok';
EXCEPTION WHEN OTHERS THEN PERFORM set_config('conc.err', SQLSTATE, true);
END $$;
SELECT 'B result ' || coalesce(nullif(current_setting('conc.err', true), ''), 'ok');
SELECT 'B waited_ms ' || round(extract(epoch FROM clock_timestamp() - current_setting('conc.t0')::timestamptz) * 1000);
COMMIT;
