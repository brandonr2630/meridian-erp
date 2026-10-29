-- Session B of concurrency.sh: a UI editor changes one task and keeps its transaction open for 4 seconds before committing.
BEGIN;
UPDATE job_tasks SET progress = 77 WHERE job_id = 'b1000000-0000-0000-0000-0000000000d0' AND task_name = 'B1';
SELECT pg_sleep(4);
COMMIT;
SELECT 'B committed';
