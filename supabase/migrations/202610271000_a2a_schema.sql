-- Phase A2a: schema columns (link types, MSPDI uids, task hierarchy).
-- Spec: docs/specs/project-portal/phase-a2-projectlibre.md (N1, N2, "Data model"). Order: after Phase A (202610210600).
-- Additive and idempotent. Every new column is nullable or defaulted, so existing rows stay valid and no result changes (N2).
-- BASE CONTRACT: the three column definitions below are fixed (other a2a_* migrations assume only them). The hierarchy guards at the end
-- (parent same-job check, cycle, depth cap 5 tasks) are the a2a_schema leaf and nothing else may rely on them.
-- Rollback: supabase/rollbacks/202610271000_a2a_schema_down.sql
-- Built and tested on a throwaway Postgres 17 (bash supabase/tests/d0c_common/run.sh a2a_schema). NOT applied to prod.

ALTER TABLE job_task_links
  ADD COLUMN IF NOT EXISTS link_type text NOT NULL DEFAULT 'FS' CHECK (link_type IN ('FS', 'SS', 'FF', 'SF'));

ALTER TABLE job_phases ADD COLUMN IF NOT EXISTS msp_uid integer;
ALTER TABLE job_tasks  ADD COLUMN IF NOT EXISTS msp_uid integer;
-- M3: a uid is 1..100000000 (the import payload range). A writer could otherwise UPDATE msp_uid to 2147483647 and block every import
-- ("uid space exhausted") or overflow the export's max+n. Named constraints, dropped and re-added so a re-run (or a database that
-- got the first version of this migration, whose inline CHECK was msp_uid > 0 and is named *_msp_uid_check) ends in the same state.
-- NOT VALID: no table scan or failure on existing rows (there are none on prod: A2a is not applied yet); new and updated rows are checked.
-- Pre-check (read-only, expect 0 and 0):  SELECT (SELECT count(*) FROM job_phases WHERE msp_uid > 100000000) AS phases_over_cap,
--                                                 (SELECT count(*) FROM job_tasks  WHERE msp_uid > 100000000) AS tasks_over_cap;
ALTER TABLE job_phases DROP CONSTRAINT IF EXISTS job_phases_msp_uid_check;
ALTER TABLE job_phases DROP CONSTRAINT IF EXISTS job_phases_msp_uid_range;
ALTER TABLE job_phases ADD CONSTRAINT job_phases_msp_uid_range CHECK (msp_uid IS NULL OR (msp_uid > 0 AND msp_uid <= 100000000)) NOT VALID;
ALTER TABLE job_tasks  DROP CONSTRAINT IF EXISTS job_tasks_msp_uid_check;
ALTER TABLE job_tasks  DROP CONSTRAINT IF EXISTS job_tasks_msp_uid_range;
ALTER TABLE job_tasks  ADD CONSTRAINT job_tasks_msp_uid_range CHECK (msp_uid IS NULL OR (msp_uid > 0 AND msp_uid <= 100000000)) NOT VALID;
CREATE UNIQUE INDEX IF NOT EXISTS job_phases_msp_uid_uq ON job_phases (job_id, msp_uid) WHERE msp_uid IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS job_tasks_msp_uid_uq  ON job_tasks  (job_id, msp_uid) WHERE msp_uid IS NOT NULL;

-- N1: job_phases stays level 1; a task may nest under another task of the same job. A summary is a task that has children (derived).
-- ON DELETE SET NULL: deleting a parent promotes its children to direct children of their phase (nothing is lost silently).
ALTER TABLE job_tasks ADD COLUMN IF NOT EXISTS parent_task_id uuid REFERENCES job_tasks(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS job_tasks_parent_idx ON job_tasks (parent_task_id) WHERE parent_task_id IS NOT NULL;

-- ===== H1: a schedule row's company must be the company of its job =====
-- The Phase A policies on job_phases / job_tasks / job_task_links check only company_id (own company + write atom), not that job_id
-- belongs to that company, so a writer of company C2 could INSERT rows carrying the job_id of a C1 job. Import and export trust rows by
-- job_id, so such a row leaks C1 data into C2-readable rows, plants a huge msp_uid or a far-future updated_at and blocks the C1 job.
-- Root-cause fix: a BEFORE INSERT OR UPDATE OF job_id, company_id trigger on the three tables. SQLSTATE A2C01 (class A2, "company").
-- SECURITY DEFINER with a fixed search_path on purpose: it must see the job whatever the writer's RLS says, and a job that does not
-- exist and a job of another company raise the SAME error, so it cannot be used to probe job ids. It reads only jobs.company_id,
-- takes no input but the row, and trigger functions need no EXECUTE grant (revoked from every API role below).
-- Pre-check on prod, read-only (expect 0 0 0; if rows exist the trigger only guards FUTURE writes, nothing fails and nothing is changed):
--   SELECT (SELECT count(*) FROM job_phases x     JOIN jobs j ON j.id = x.job_id WHERE j.company_id IS DISTINCT FROM x.company_id) AS phases,
--          (SELECT count(*) FROM job_tasks x      JOIN jobs j ON j.id = x.job_id WHERE j.company_id IS DISTINCT FROM x.company_id) AS tasks,
--          (SELECT count(*) FROM job_task_links x JOIN jobs j ON j.id = x.job_id WHERE j.company_id IS DISTINCT FROM x.company_id) AS links;
CREATE OR REPLACE FUNCTION job_schedule_company_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = NEW.job_id AND j.company_id = NEW.company_id) THEN
    RAISE EXCEPTION '% row must belong to the company of its job', TG_TABLE_NAME USING ERRCODE = 'A2C01';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION job_schedule_company_guard() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS job_phases_company_guard ON job_phases;
CREATE TRIGGER job_phases_company_guard BEFORE INSERT OR UPDATE OF job_id, company_id ON job_phases
  FOR EACH ROW EXECUTE FUNCTION job_schedule_company_guard();
DROP TRIGGER IF EXISTS job_tasks_company_guard ON job_tasks;
CREATE TRIGGER job_tasks_company_guard BEFORE INSERT OR UPDATE OF job_id, company_id ON job_tasks
  FOR EACH ROW EXECUTE FUNCTION job_schedule_company_guard();
DROP TRIGGER IF EXISTS job_task_links_company_guard ON job_task_links;
CREATE TRIGGER job_task_links_company_guard BEFORE INSERT OR UPDATE OF job_id, company_id ON job_task_links
  FOR EACH ROW EXECUTE FUNCTION job_schedule_company_guard();

-- ===== L1 (review 2): free uids =====
-- The uid space of a job is 1..100000000 across phases and tasks. A writer can set one row's msp_uid to 100000000 (inside the CHECK range),
-- so "max + n" was already over the cap and import and export refused for good. When max + n does not fit, import and export take the
-- first n UNUSED numbers (gaps) instead. Pure read, invoker, only rows of this job and company. Returns fewer than p_n numbers only when
-- all 100000000 are taken.
CREATE OR REPLACE FUNCTION sched_free_uids(p_job_id uuid, p_company uuid, p_n integer) RETURNS integer[]
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  k_cap constant integer := 100000000;
  v_out integer[] := ARRAY[]::integer[]; r record; v_hi integer; v_want integer;
BEGIN
  IF p_n IS NULL OR p_n <= 0 THEN RETURN v_out; END IF;
  FOR r IN SELECT z.u AS prev, lead(z.u) OVER (ORDER BY z.u) AS nxt
             FROM (SELECT 0 AS u
                   UNION SELECT msp_uid FROM job_phases WHERE job_id = p_job_id AND company_id = p_company AND msp_uid BETWEEN 1 AND k_cap
                   UNION SELECT msp_uid FROM job_tasks  WHERE job_id = p_job_id AND company_id = p_company AND msp_uid BETWEEN 1 AND k_cap) z
            ORDER BY z.u LOOP
    v_want := p_n - cardinality(v_out);
    EXIT WHEN v_want <= 0;
    v_hi := coalesce(r.nxt - 1, k_cap);
    IF v_hi >= r.prev + 1 THEN
      v_out := v_out || ARRAY(SELECT g FROM generate_series(r.prev + 1, LEAST(v_hi, r.prev + v_want)) g);
    END IF;
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION sched_free_uids(uuid, uuid, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== L3 (review 2): a job with schedule rows keeps its company =====
-- If jobs.company_id changed after the job had a schedule, its rows would belong to the old company and import / export would
-- refuse for good (A2C01). Refuse the change instead (SQLSTATE A2C02): move the schedule first, or replace it. Definer, fixed search_path,
-- reads only row existence; trigger functions need no EXECUTE grant.
CREATE OR REPLACE FUNCTION jobs_company_change_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.company_id IS DISTINCT FROM OLD.company_id AND (
       EXISTS (SELECT 1 FROM job_phases WHERE job_id = OLD.id) OR EXISTS (SELECT 1 FROM job_tasks WHERE job_id = OLD.id)
       OR EXISTS (SELECT 1 FROM job_task_links WHERE job_id = OLD.id)) THEN
    RAISE EXCEPTION 'cannot change the company of a job that has a schedule' USING ERRCODE = 'A2C02';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION jobs_company_change_guard() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS jobs_company_change_guard ON jobs;
CREATE TRIGGER jobs_company_change_guard BEFORE UPDATE OF company_id ON jobs
  FOR EACH ROW EXECUTE FUNCTION jobs_company_change_guard();

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
