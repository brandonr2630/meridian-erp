-- Phase A2a: schema columns (link types, MSPDI uids, task hierarchy).
-- Spec: docs/specs/project-portal/phase-a2-projectlibre.md (N1, N2, "Data model"). Order: after Phase A (202610210600).
-- Additive and idempotent. Every new column is nullable or defaulted, so existing rows stay valid and no result changes (N2).
-- BASE CONTRACT: this file starts as the columns only. The guards (parent same-job check, parent cycle, depth cap 6) are added
-- to THIS file by the a2a_schema leaf. Other a2a_* migrations assume these columns exist and nothing else from this file.
-- Rollback: supabase/rollbacks/202610271000_a2a_schema_down.sql
-- Built and tested on a throwaway Postgres 17 (bash supabase/tests/d0c_common/run.sh a2a_schema). NOT applied to prod.

ALTER TABLE job_task_links
  ADD COLUMN IF NOT EXISTS link_type text NOT NULL DEFAULT 'FS' CHECK (link_type IN ('FS', 'SS', 'FF', 'SF'));

ALTER TABLE job_phases ADD COLUMN IF NOT EXISTS msp_uid integer CHECK (msp_uid IS NULL OR msp_uid > 0);
ALTER TABLE job_tasks  ADD COLUMN IF NOT EXISTS msp_uid integer CHECK (msp_uid IS NULL OR msp_uid > 0);
CREATE UNIQUE INDEX IF NOT EXISTS job_phases_msp_uid_uq ON job_phases (job_id, msp_uid) WHERE msp_uid IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS job_tasks_msp_uid_uq  ON job_tasks  (job_id, msp_uid) WHERE msp_uid IS NOT NULL;

-- N1: job_phases stays level 1; a task may nest under another task of the same job. A summary is a task that has children (derived).
-- ON DELETE SET NULL: deleting a parent promotes its children to direct children of their phase (nothing is lost silently).
ALTER TABLE job_tasks ADD COLUMN IF NOT EXISTS parent_task_id uuid REFERENCES job_tasks(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS job_tasks_parent_idx ON job_tasks (parent_task_id) WHERE parent_task_id IS NOT NULL;
