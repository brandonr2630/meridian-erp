-- Phase A2a: schema columns (link types, MSPDI uids, task hierarchy).
-- Spec: docs/specs/project-portal/phase-a2-projectlibre.md (N1, N2, "Data model"). Order: after Phase A (202610210600).
-- Additive and idempotent. Every new column is nullable or defaulted, so existing rows stay valid and no result changes (N2).
-- BASE CONTRACT: the three column definitions below are fixed (other a2a_* migrations assume only them). The hierarchy guards at the end
-- (parent same-job check, cycle, depth cap 5 tasks) are the a2a_schema leaf and nothing else may rely on them.
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

-- ===== Hierarchy guards (N1): parent in the same job and company, no cycle, depth cap =====
-- Depth: job_phases is level 1, tasks nest below it, the maximum level is 6, so a chain of tasks is at most 5 deep
-- (a root task is chain position 1). On re-parenting the deepest descendant of the moved subtree is checked too.
-- SQLSTATEs (custom class A2): A2H01 parent in another job/company, A2H02 cycle, A2H03 depth cap, A2H04 self-parent,
-- A2H05 job_id/company_id change on a task that has a parent or children (detach first, then move), A2H06 parent not found.
-- Rulings: phase_id is NOT compared with the parent's phase. Runs as the caller (RLS applies to its lookups; all rows involved
-- share one company). Hierarchy writes of one job are serialised with a transaction advisory lock so two concurrent moves
-- cannot jointly create a cycle or exceed the cap.
CREATE OR REPLACE FUNCTION job_tasks_parent_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  c_max_depth CONSTANT integer := 5;
  v_pj uuid; v_pc uuid; v_anc integer; v_cycle boolean; v_height integer;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.parent_task_id IS NOT DISTINCT FROM OLD.parent_task_id
     AND NEW.job_id = OLD.job_id AND NEW.company_id = OLD.company_id THEN
    RETURN NEW;                                   -- nothing hierarchical changed
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('job_tasks_parent:' || NEW.job_id::text, 0));

  IF TG_OP = 'UPDATE' AND (NEW.job_id <> OLD.job_id OR NEW.company_id <> OLD.company_id)
     AND (OLD.parent_task_id IS NOT NULL OR EXISTS (SELECT 1 FROM job_tasks c WHERE c.parent_task_id = OLD.id)) THEN
    RAISE EXCEPTION 'cannot change job or company of a task that has a parent or children; detach it first' USING ERRCODE = 'A2H05';
  END IF;

  IF NEW.parent_task_id IS NULL THEN RETURN NEW; END IF;

  IF NEW.parent_task_id = NEW.id THEN
    RAISE EXCEPTION 'a task cannot be its own parent: %', NEW.id USING ERRCODE = 'A2H04';
  END IF;

  SELECT t.job_id, t.company_id INTO v_pj, v_pc FROM job_tasks t WHERE t.id = NEW.parent_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parent task % does not exist', NEW.parent_task_id USING ERRCODE = 'A2H06';
  END IF;
  IF v_pj IS DISTINCT FROM NEW.job_id OR v_pc IS DISTINCT FROM NEW.company_id THEN
    RAISE EXCEPTION 'parent task must belong to the same job and company as the task' USING ERRCODE = 'A2H01';
  END IF;

  -- walk up from the parent: ancestor count (parent = 1) and whether NEW.id is among them
  WITH RECURSIVE up(id, parent_id, lvl) AS (
    SELECT t.id, t.parent_task_id, 1 FROM job_tasks t WHERE t.id = NEW.parent_task_id
    UNION ALL
    SELECT t.id, t.parent_task_id, u.lvl + 1 FROM job_tasks t JOIN up u ON t.id = u.parent_id WHERE u.lvl < 50
  )
  SELECT coalesce(max(lvl), 0), coalesce(bool_or(id = NEW.id), false) INTO v_anc, v_cycle FROM up;
  IF v_cycle THEN
    RAISE EXCEPTION 'task hierarchy cycle: % cannot be placed under %', NEW.id, NEW.parent_task_id USING ERRCODE = 'A2H02';
  END IF;

  -- height of the moved subtree including the task itself (a new row or a leaf = 1)
  IF TG_OP = 'UPDATE' THEN
    WITH RECURSIVE down(id, lvl) AS (
      SELECT NEW.id, 1
      UNION ALL
      SELECT c.id, d.lvl + 1 FROM job_tasks c JOIN down d ON c.parent_task_id = d.id WHERE d.lvl < 50
    )
    SELECT max(lvl) INTO v_height FROM down;
  ELSE
    v_height := 1;
  END IF;

  IF v_anc + v_height > c_max_depth THEN
    RAISE EXCEPTION 'task hierarchy too deep: % ancestor(s) + subtree of % exceeds the maximum chain of % tasks (phase = level 1, max level 6)',
      v_anc, v_height, c_max_depth USING ERRCODE = 'A2H03';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS job_tasks_parent_guard ON job_tasks;
CREATE TRIGGER job_tasks_parent_guard BEFORE INSERT OR UPDATE OF parent_task_id, job_id, company_id ON job_tasks
  FOR EACH ROW EXECUTE FUNCTION job_tasks_parent_guard();
