-- Rollback of 202610210600_phase_a_sql.sql (Phase A, Schedule v2). Run in this order; harmless if run twice.
-- Phase B/C/D objects that call these functions or attach job_visibility_guard() must be rolled back first
-- (the DROP FUNCTION below fails on purpose, without CASCADE, while any such dependent exists).
-- depends_on is untouched, so the v1 schedule keeps working afterwards. job_audit_log rows stay (append-only).
DROP FUNCTION IF EXISTS job_schedule_status(uuid, date);
DROP FUNCTION IF EXISTS job_task_client_visible(uuid);
DROP FUNCTION IF EXISTS job_task_planned_pct(date, date, date, date, date);
DROP FUNCTION IF EXISTS job_task_weight(boolean, numeric, date, date);
DROP TRIGGER IF EXISTS job_tasks_visibility_guard ON job_tasks;
DROP TRIGGER IF EXISTS job_phases_visibility_guard ON job_phases;
DROP FUNCTION IF EXISTS job_visibility_guard();
DROP TRIGGER IF EXISTS job_tasks_set_updated_at ON job_tasks;
DROP FUNCTION IF EXISTS lock_job_baseline(uuid, text);
DROP TRIGGER IF EXISTS job_tasks_baseline_guard ON job_tasks;
DROP FUNCTION IF EXISTS job_tasks_baseline_guard();
DROP TABLE IF EXISTS job_task_links;
DROP FUNCTION IF EXISTS job_task_links_no_cycle();
ALTER TABLE job_tasks
  DROP CONSTRAINT IF EXISTS job_tasks_baseline_chk,
  DROP CONSTRAINT IF EXISTS job_tasks_milestone_chk,
  DROP COLUMN IF EXISTS phase_id,
  DROP COLUMN IF EXISTS is_milestone,
  DROP COLUMN IF EXISTS is_critical,
  DROP COLUMN IF EXISTS weight,
  DROP COLUMN IF EXISTS baseline_start,
  DROP COLUMN IF EXISTS baseline_end,
  DROP COLUMN IF EXISTS baseline_locked_at,
  DROP COLUMN IF EXISTS client_visible;
DROP TABLE IF EXISTS job_phases;
