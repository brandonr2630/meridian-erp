-- Session B of concurrency.sh: another writer exports the same job while A still holds the advisory lock; prints result and wait time.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE authenticated;
SELECT set_config('conc.t0', clock_timestamp()::text, true);
SELECT 'B result ' || prepare_schedule_export('b1000000-0000-0000-0000-0000000000c0');
SELECT 'B waited_ms ' || round(extract(epoch FROM clock_timestamp() - current_setting('conc.t0')::timestamptz) * 1000);
COMMIT;
