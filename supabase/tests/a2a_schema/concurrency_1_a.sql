-- Scenario 1, session A: a writer links X after Y and keeps its transaction open for 4 seconds.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE authenticated;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES ('c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d0','f1000000-0000-0000-0000-0000000000d1','f1000000-0000-0000-0000-0000000000d2');
SELECT 'A result ok';
SELECT pg_sleep(4);
COMMIT;
