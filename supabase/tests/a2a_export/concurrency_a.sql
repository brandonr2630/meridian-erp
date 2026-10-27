-- Session A of concurrency.sh: a writer exports, then holds its transaction open for 4 seconds before committing.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
SET LOCAL ROLE authenticated;
SELECT 'A result ' || prepare_schedule_export('b1000000-0000-0000-0000-0000000000c0');
SELECT pg_sleep(4);
COMMIT;
