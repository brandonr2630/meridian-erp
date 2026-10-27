-- Rollback for 202610271000_a2a_schema.sql. Idempotent. Lossy: dropping link_type loses SS/FF/SF information and dropping
-- parent_task_id flattens the hierarchy; copy job_task_links / job_tasks first if any non-FS link or parent exists.
DROP TRIGGER IF EXISTS job_tasks_parent_guard ON job_tasks;
DROP FUNCTION IF EXISTS job_tasks_parent_guard();
DROP INDEX IF EXISTS job_tasks_parent_idx;
ALTER TABLE job_tasks DROP COLUMN IF EXISTS parent_task_id;
DROP INDEX IF EXISTS job_tasks_msp_uid_uq;
DROP INDEX IF EXISTS job_phases_msp_uid_uq;
ALTER TABLE job_tasks  DROP COLUMN IF EXISTS msp_uid;
ALTER TABLE job_phases DROP COLUMN IF EXISTS msp_uid;
ALTER TABLE job_task_links DROP COLUMN IF EXISTS link_type;
