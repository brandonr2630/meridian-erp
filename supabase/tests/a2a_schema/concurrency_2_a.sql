-- Scenario 2, session A: a writer makes Y a child of X and keeps its transaction open for 4 seconds.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE authenticated;
UPDATE job_tasks SET parent_task_id = 'f1000000-0000-0000-0000-0000000000d1' WHERE id = 'f1000000-0000-0000-0000-0000000000d2';
SELECT 'A result ok';
SELECT pg_sleep(4);
COMMIT;
