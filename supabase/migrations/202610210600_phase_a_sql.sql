-- Phase A (Schedule v2): phases, multi-predecessor links, milestones, baseline lock, publish guard, canonical progress/status SQL.
-- Spec: docs/specs/project-portal/phase-a-schedule-v2.md (binding decisions X1-X23 in 00-overview.md section 8).
-- Order (X23): after D0a/D0c, before Phase B and C. Additive; existing rows keep working; depends_on is untouched.
-- Idempotent: tables/columns/indexes use IF NOT EXISTS, functions CREATE OR REPLACE, triggers and policies are dropped first.
-- Rollback: supabase/rollbacks/202610210600_phase_a_sql_down.sql
-- Built and tested on a throwaway Postgres 17 (bash supabase/tests/d0c_common/run.sh phase_a_sql). NOT applied to prod.
--
-- Changes against the desk-checked spec SQL (found while executing it; see the PR body):
--   * job_schedule_status: v_gap is numeric (spec declared int, which rounded the gap and moved the "gap < -10" boundary).
--   * new-table policies are TO authenticated (the exact live job_tasks pattern): anon gets no policy instead of a 42501 from my_company_ids().
--   * baseline guard also requires current_user = owner of lock_job_baseline (the setting alone is not trusted), and
--     lock_job_baseline switches the setting off again before returning.
--   * the depends_on backfill skips (with a NOTICE) rows that would form a cycle, point at themselves or at another job,
--     instead of aborting the whole migration; job_task_links_no_cycle also rejects links across jobs/companies.
--   * self-link is reported by the CHECK constraint (23514) rather than as a "cycle".

-- ===== job_phases =====
CREATE TABLE IF NOT EXISTS job_phases (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid NOT NULL REFERENCES companies(id),
  job_id      uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order  integer NOT NULL DEFAULT 0,
  name        text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  colour      text CHECK (colour IS NULL OR colour ~ '^#[0-9a-fA-F]{6}$'),
  client_visible boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS job_phases_job_idx         ON job_phases (job_id);
CREATE INDEX IF NOT EXISTS job_phases_company_job_idx ON job_phases (company_id, job_id);

-- ===== job_tasks: new columns and constraints =====
ALTER TABLE job_tasks
  ADD COLUMN IF NOT EXISTS phase_id           uuid REFERENCES job_phases(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS is_milestone       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_critical        boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS weight             numeric(8,2) CHECK (weight IS NULL OR weight >= 0),
  ADD COLUMN IF NOT EXISTS baseline_start     date,
  ADD COLUMN IF NOT EXISTS baseline_end       date,
  ADD COLUMN IF NOT EXISTS baseline_locked_at timestamptz,
  ADD COLUMN IF NOT EXISTS client_visible     boolean NOT NULL DEFAULT false;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'job_tasks_baseline_chk' AND conrelid = 'public.job_tasks'::regclass) THEN
    ALTER TABLE job_tasks ADD CONSTRAINT job_tasks_baseline_chk
      CHECK (baseline_start IS NULL OR baseline_end IS NULL OR baseline_end >= baseline_start);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'job_tasks_milestone_chk' AND conrelid = 'public.job_tasks'::regclass) THEN
    ALTER TABLE job_tasks ADD CONSTRAINT job_tasks_milestone_chk
      CHECK (NOT is_milestone OR start_date IS NULL OR end_date IS NULL OR start_date = end_date);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS job_tasks_phase_idx ON job_tasks (phase_id);

-- ===== job_task_links =====
CREATE TABLE IF NOT EXISTS job_task_links (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id     uuid NOT NULL REFERENCES companies(id),
  job_id         uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  task_id        uuid NOT NULL REFERENCES job_tasks(id) ON DELETE CASCADE,
  predecessor_id uuid NOT NULL REFERENCES job_tasks(id) ON DELETE CASCADE,
  lag_days       integer NOT NULL DEFAULT 0 CHECK (lag_days BETWEEN -30 AND 365),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_task_links_distinct CHECK (task_id <> predecessor_id),
  CONSTRAINT job_task_links_uniq UNIQUE (task_id, predecessor_id)
);
CREATE INDEX IF NOT EXISTS job_task_links_job_idx         ON job_task_links (job_id);
CREATE INDEX IF NOT EXISTS job_task_links_company_job_idx ON job_task_links (company_id, job_id);
CREATE INDEX IF NOT EXISTS job_task_links_pred_idx        ON job_task_links (predecessor_id);

-- Cycle guard: reject a link if the predecessor is already downstream of the task. Also keeps links inside one job/company.
CREATE OR REPLACE FUNCTION job_task_links_no_cycle() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v_tj uuid; v_tc uuid; v_pj uuid;
BEGIN
  IF NEW.task_id = NEW.predecessor_id THEN RETURN NEW; END IF;      -- the CHECK constraint reports a self-link
  SELECT t.job_id, t.company_id INTO v_tj, v_tc FROM job_tasks t WHERE t.id = NEW.task_id;
  SELECT t.job_id INTO v_pj FROM job_tasks t WHERE t.id = NEW.predecessor_id;
  IF v_tj IS DISTINCT FROM NEW.job_id OR v_pj IS DISTINCT FROM NEW.job_id OR v_tc IS DISTINCT FROM NEW.company_id THEN
    RAISE EXCEPTION 'link must connect two tasks of its own job and company' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (
    WITH RECURSIVE down(id) AS (
      SELECT NEW.task_id
      UNION
      SELECT l.task_id FROM job_task_links l JOIN down d ON l.predecessor_id = d.id
    )
    SELECT 1 FROM down WHERE id = NEW.predecessor_id
  ) THEN
    RAISE EXCEPTION 'dependency cycle: % cannot depend on %', NEW.task_id, NEW.predecessor_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS job_task_links_no_cycle ON job_task_links;
CREATE TRIGGER job_task_links_no_cycle BEFORE INSERT OR UPDATE ON job_task_links
  FOR EACH ROW EXECUTE FUNCTION job_task_links_no_cycle();

-- Backfill: existing single parents become links (idempotent). Legacy data may hold self-references, cross-job parents or
-- depends_on cycles (v1 allowed them): those rows are skipped with a NOTICE instead of aborting the migration.
DO $$
DECLARE r record; v_skip integer := 0;
BEGIN
  FOR r IN SELECT id, company_id, job_id, depends_on FROM job_tasks WHERE depends_on IS NOT NULL ORDER BY id LOOP
    BEGIN
      INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
      VALUES (r.company_id, r.job_id, r.id, r.depends_on)
      ON CONFLICT (task_id, predecessor_id) DO NOTHING;
    EXCEPTION WHEN check_violation THEN
      v_skip := v_skip + 1;
      RAISE NOTICE 'backfill skipped depends_on % -> %: %', r.id, r.depends_on, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'job_task_links backfill: % row(s) skipped', v_skip;
END $$;

-- ===== Baseline guard: baseline columns change only inside lock_job_baseline() =====
-- Two conditions must both hold to let a baseline write through: the transaction-local setting app.baseline_rpc = 'on' AND
-- current_user = the owner of lock_job_baseline() (i.e. we are executing inside that SECURITY DEFINER function, or a
-- superuser/owner doing a deliberate seed). An API caller (current_user authenticated/anon) can never satisfy the second.
CREATE OR REPLACE FUNCTION job_tasks_baseline_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v_ok boolean;
BEGIN
  v_ok := current_setting('app.baseline_rpc', true) IS NOT DISTINCT FROM 'on';
  IF v_ok THEN
    v_ok := current_user IS NOT DISTINCT FROM
            (SELECT pg_get_userbyid(p.proowner) FROM pg_proc p WHERE p.oid = to_regprocedure('public.lock_job_baseline(uuid,text)'));
  END IF;
  IF NOT v_ok THEN
    IF TG_OP = 'INSERT' AND (NEW.baseline_start IS NOT NULL OR NEW.baseline_end IS NOT NULL OR NEW.baseline_locked_at IS NOT NULL) THEN
      RAISE EXCEPTION 'baseline is set only by lock_job_baseline()';
    ELSIF TG_OP = 'UPDATE' AND (NEW.baseline_start, NEW.baseline_end, NEW.baseline_locked_at)
          IS DISTINCT FROM (OLD.baseline_start, OLD.baseline_end, OLD.baseline_locked_at) THEN
      RAISE EXCEPTION 'baseline is set only by lock_job_baseline()';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS job_tasks_baseline_guard ON job_tasks;
CREATE TRIGGER job_tasks_baseline_guard BEFORE INSERT OR UPDATE ON job_tasks
  FOR EACH ROW EXECUTE FUNCTION job_tasks_baseline_guard();

-- Lock (first time) or re-baseline (reason required). SECURITY DEFINER so it can write job_audit_log.
CREATE OR REPLACE FUNCTION lock_job_baseline(p_job_id uuid, p_reason text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_job jobs%ROWTYPE; v_first boolean; v_n integer;
BEGIN
  IF NOT user_has_perm('ops:work-orders:approve') THEN
    RAISE EXCEPTION 'permission denied: ops:work-orders:approve required';
  END IF;
  SELECT * INTO v_job FROM jobs WHERE id = p_job_id AND company_id IN (SELECT my_company_ids());
  IF NOT FOUND THEN RAISE EXCEPTION 'job not found'; END IF;
  SELECT NOT EXISTS (SELECT 1 FROM job_tasks WHERE job_id = p_job_id AND baseline_locked_at IS NOT NULL) INTO v_first;
  IF NOT v_first AND coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 're-baseline requires a reason';
  END IF;
  PERFORM set_config('app.baseline_rpc', 'on', true);
  UPDATE job_tasks SET baseline_start = start_date, baseline_end = end_date, baseline_locked_at = now()
   WHERE job_id = p_job_id AND start_date IS NOT NULL AND end_date IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('app.baseline_rpc', 'off', true);
  INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
  VALUES (p_job_id, v_job.job_no, auth.uid(),
          (SELECT u.full_name FROM erp_users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
          CASE WHEN v_first THEN 'baseline_locked' ELSE 'baseline_reset' END,
          CASE WHEN v_first THEN 'Schedule baseline locked' ELSE 'Schedule re-baselined: ' || p_reason END,
          jsonb_build_object('tasks', v_n, 'reason', p_reason));
  RETURN v_n;
END $$;
-- X13: Supabase default privileges also grant EXECUTE to anon, so PUBLIC alone is not enough.
-- The permission and company-membership checks inside stay as the authorization (defence in depth).
REVOKE ALL ON FUNCTION lock_job_baseline(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION lock_job_baseline(uuid, text) TO authenticated;

-- ===== updated_at (X16: the existing set_updated_at(); job_tasks has no triggers today) =====
DROP TRIGGER IF EXISTS job_phases_set_updated_at ON job_phases;
CREATE TRIGGER job_phases_set_updated_at     BEFORE UPDATE ON job_phases
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS job_task_links_set_updated_at ON job_task_links;
CREATE TRIGGER job_task_links_set_updated_at BEFORE UPDATE ON job_task_links
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS job_tasks_set_updated_at ON job_tasks;
CREATE TRIGGER job_tasks_set_updated_at      BEFORE UPDATE ON job_tasks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ===== X5 / X19: the shared publish guard. DEFINED HERE; Phases B and C attach it to their tables. =====
-- CALL CONTRACT (X19, binding on B and C): attach BEFORE INSERT OR UPDATE with EXACTLY TWO trigger arguments:
--   TG_ARGV[0] = comma-separated client-facing WORDING columns of that table (e.g. 'title,body,kind,occurred_on'; empty string if none)
--   TG_ARGV[1] = the table domain atom that may publish besides ops:work-orders:approve (empty string if none,
--                e.g. 'quality:docs:issue' for documents)
-- Any other argument count or a comma-less misuse silently changes behaviour: do not.
-- EXEMPTION (X19): direct SQL as session_user postgres or supabase_admin (migrations, backfills, seed scripts)
--   is exempt from rule 1, so such inserts are not silently downgraded or rejected. PostgREST sessions have
--   session_user = authenticator, so the exemption is unreachable from the API.
-- Rules:
--  1. Setting client_visible to true (INSERT with true, or false->true) needs ops:work-orders:approve OR the domain atom.
--     Setting it to false (unpublish) is always allowed to a writer.
--  2. If the row is already visible and stays visible but a wording column changed, client_visible is forced
--     to false (auto-unpublish; the editor must re-publish with the permission in rule 1).
--  3. Every visibility change (publish, unpublish, auto-unpublish) writes a visibility_changed job_audit_log row.
-- SECURITY DEFINER only so it can write job_audit_log whatever the caller RLS; it is trigger-only (no EXECUTE for API roles).
-- The session_user exemption is the condition v_pub AND session_user NOT IN (...) below.
CREATE OR REPLACE FUNCTION job_visibility_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cols  text[] := string_to_array(coalesce(TG_ARGV[0], ''), ',');
  v_atom  text   := nullif(TG_ARGV[1], '');
  v_old   jsonb;  v_new jsonb;  c text;
  v_pub   boolean := false;   -- row is being published now
  v_unpub boolean := false;   -- row is being unpublished now (explicitly)
  v_auto  boolean := false;   -- row is auto-unpublished by a wording edit
  v_jobno text;
BEGIN
  v_new := to_jsonb(NEW);
  IF TG_OP = 'INSERT' THEN
    v_pub := NEW.client_visible;
  ELSE
    v_old := to_jsonb(OLD);
    IF NEW.client_visible AND NOT OLD.client_visible THEN
      v_pub := true;
    ELSIF OLD.client_visible AND NOT NEW.client_visible THEN
      v_unpub := true;
    ELSIF OLD.client_visible AND NEW.client_visible THEN
      FOREACH c IN ARRAY v_cols LOOP
        IF c <> '' AND (v_new -> c) IS DISTINCT FROM (v_old -> c) THEN v_auto := true; END IF;
      END LOOP;
      IF v_auto THEN NEW.client_visible := false; END IF;
    END IF;
  END IF;

  IF v_pub AND session_user NOT IN ('postgres', 'supabase_admin') THEN   -- X19 exemption: migrations/backfills pass
    IF NOT (user_has_perm('ops:work-orders:approve') OR (v_atom IS NOT NULL AND user_has_perm(v_atom))) THEN
      RAISE EXCEPTION 'permission denied: publishing to the client needs ops:work-orders:approve%',
        CASE WHEN v_atom IS NULL THEN '' ELSE ' or ' || v_atom END;
    END IF;
  END IF;

  IF v_pub OR v_unpub OR v_auto THEN
    SELECT job_no INTO v_jobno FROM jobs WHERE id = NEW.job_id;
    INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
    VALUES (NEW.job_id, v_jobno, auth.uid(),
            (SELECT u.full_name FROM erp_users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
            'visibility_changed',
            CASE WHEN v_pub THEN 'Published to client' WHEN v_auto THEN 'Auto-unpublished after wording edit'
                 ELSE 'Unpublished from client' END,
            jsonb_build_object('table', TG_TABLE_NAME, 'row_id', v_new ->> 'id',
                               'from', (v_auto OR v_unpub), 'to', v_pub,
                               'reason', CASE WHEN v_auto THEN 'wording_edited' WHEN v_pub THEN 'publish' ELSE 'unpublish' END));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION job_visibility_guard() FROM PUBLIC, anon, authenticated;

-- Wording columns: phase name; task name. Dates, progress and flags are NOT wording (they change daily and must not unpublish).
-- Explicit two-argument form (X19): (wording columns, domain atom). Phase A has no domain atom, hence the empty string.
DROP TRIGGER IF EXISTS job_phases_visibility_guard ON job_phases;
CREATE TRIGGER job_phases_visibility_guard BEFORE INSERT OR UPDATE ON job_phases
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('name', '');
DROP TRIGGER IF EXISTS job_tasks_visibility_guard ON job_tasks;
CREATE TRIGGER job_tasks_visibility_guard  BEFORE INSERT OR UPDATE ON job_tasks
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('task_name', '');

-- ===== X22: the ONE client-visibility predicate for schedule data. =====
-- A task is client-visible only if task.client_visible AND (task.phase_id IS NULL OR its phase.client_visible).
-- Phase C job_planned_curve(..., client_only) and Phase D portal_schedule MUST both use this function,
-- never re-state the predicate. SECURITY INVOKER (RLS-scoped for staff); Phase D postgres-owned definers call it with owner rights.
CREATE OR REPLACE FUNCTION job_task_client_visible(task_id uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT t.client_visible AND (t.phase_id IS NULL OR COALESCE(p.client_visible, false))
       FROM job_tasks t LEFT JOIN job_phases p ON p.id = t.phase_id
      WHERE t.id = task_id), false)
$$;
REVOKE ALL ON FUNCTION job_task_client_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_task_client_visible(uuid) TO authenticated;

-- ===== X1 / X20: the single progress rule, as two IMMUTABLE helpers. They are the ONE SQL implementation:
-- Phase C job_progress_calc and job_planned_pct_on MUST CALL job_task_weight and job_task_planned_pct (never re-derive the formula).
-- Both return unrounded numerics; SQL consumers round to 2 dp (X20), UIs round half-up to an integer. =====
-- Weight = COALESCE(weight, duration_days); duration = end - start + 1, min 1; undated task = 1; milestones always 0 (excluded).
CREATE OR REPLACE FUNCTION job_task_weight(p_milestone boolean, p_weight numeric, p_start date, p_end date)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_milestone THEN 0::numeric
              ELSE COALESCE(p_weight,
                            GREATEST(1, CASE WHEN p_start IS NOT NULL AND p_end IS NOT NULL
                                             THEN p_end - p_start + 1 ELSE 1 END)::numeric) END
$$;
-- Planned % on day p_on, 0..100. Uses baseline dates, falling back to current dates; no dates at all => 0.
CREATE OR REPLACE FUNCTION job_task_planned_pct(p_bstart date, p_bend date, p_start date, p_end date, p_on date)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN COALESCE(p_bstart, p_start) IS NULL OR COALESCE(p_bend, p_end) IS NULL THEN 0::numeric
    ELSE 100 * LEAST(1::numeric, GREATEST(0::numeric,
         (p_on - COALESCE(p_bstart, p_start) + 1)::numeric
         / GREATEST(1, COALESCE(p_bend, p_end) - COALESCE(p_bstart, p_start) + 1)::numeric)) END
$$;
REVOKE ALL ON FUNCTION job_task_weight(boolean, numeric, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION job_task_planned_pct(date, date, date, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_task_weight(boolean, numeric, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION job_task_planned_pct(date, date, date, date, date) TO authenticated;

-- ===== X2: the canonical schedule status. JS jcSchedCompute mirrors this line by line. =====
-- SECURITY INVOKER on purpose: it reads job_tasks / job_task_links / jobs under the caller RLS, so a caller with no
-- company membership (e.g. a client JWT) gets zero rows. Phase C definer snapshot function (and the nightly cron)
-- call it with the owner rights. Phase D never calls it: it reads the values C stores (X2).
-- Labels (X21), exactly five: On track | At risk | Late | Complete | On hold. It ALWAYS returns one row for a visible
-- job and status is never NULL. forecast_end is NULL when nothing is scheduled;
-- slip_days = forecast_end - (max baseline_end, else jobs.due_date), NULL if either side is missing (may be negative).
-- Consumers must handle NULL forecast_end / slip_days; Phase D shows planned handover NULL when slip_days is NULL (never forecast).
-- p_today defaults to the business-local date (Trinidad); JS uses local midnight, the same calendar day.
CREATE OR REPLACE FUNCTION job_schedule_status(
  p_job_id uuid,
  p_today  date DEFAULT (timezone('America/Port_of_Spain', now()))::date)
RETURNS TABLE (status text, forecast_end date, slip_days integer)
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  k_late_days constant integer := 5;     -- Open question 2 defaults; keep equal to the JS constants
  k_gap_pts   constant integer := 10;
  v_job jobs%ROWTYPE;
  n int := 0; m int := 0; i int; j int; t int; p int; pass int;
  ids uuid[] := '{}'; rem int[] := '{}'; es date[] := '{}'; ef date[] := '{}'; ls date[] := '{}'; lf date[] := '{}';
  endd date[] := '{}'; done boolean[] := '{}'; ms boolean[] := '{}'; sched boolean[] := '{}';
  lt int[] := '{}'; lp int[] := '{}'; llag int[] := '{}';
  r record; v_changed boolean; cand date; v_deadline date; v_fe date; v_minslack int;
  v_overall numeric; v_planned numeric; v_has_bl boolean; v_base_end date; v_slip int; v_gap numeric;
  v_late boolean := false; v_late_days int := 0; v_status text; v_dur int; v_prog int;
BEGIN
  SELECT * INTO v_job FROM jobs WHERE id = p_job_id;
  IF NOT FOUND THEN RETURN; END IF;               -- invisible under RLS or missing: no rows

  -- load tasks (milestones: rem 0; done = progress 100)
  FOR r IN SELECT id, start_date, end_date, progress, is_milestone FROM job_tasks
            WHERE job_id = p_job_id ORDER BY sort_order, id LOOP
    n := n + 1;
    v_prog := coalesce(r.progress, 0);
    v_dur  := GREATEST(1, CASE WHEN r.start_date IS NOT NULL AND r.end_date IS NOT NULL
                               THEN r.end_date - r.start_date + 1 ELSE 1 END);
    ids  := ids  || r.id;
    endd := endd || r.end_date;
    done := done || (v_prog = 100);
    ms   := ms   || r.is_milestone;
    rem  := rem  || (CASE WHEN r.is_milestone OR v_prog = 100 THEN 0
                          ELSE GREATEST(1, ceil(v_dur * (100 - v_prog) / 100.0)::int) END);
    sched := sched || (r.start_date IS NOT NULL AND r.end_date IS NOT NULL);
    -- base earliest start: done and started tasks keep their actual start; others start today
    es := es || (CASE WHEN v_prog = 100 OR v_prog > 0 THEN coalesce(r.start_date, p_today) ELSE p_today END);
    ef := ef || (CASE WHEN v_prog = 100 THEN r.end_date ELSE NULL END);   -- done keep their actual end
    ls := ls || NULL::date;  lf := lf || NULL::date;                      -- pre-size (array lower bound stays 1)
  END LOOP;

  FOR r IN SELECT task_id, predecessor_id, lag_days FROM job_task_links WHERE job_id = p_job_id LOOP
    t := array_position(ids, r.task_id); p := array_position(ids, r.predecessor_id);
    IF t IS NOT NULL AND p IS NOT NULL THEN
      m := m + 1; lt := lt || t; lp := lp || p; llag := llag || r.lag_days;
      -- undated tasks with a link take part in the pass (dur 1, start today); done undated stay out
      IF NOT (done[t] AND endd[t] IS NULL) THEN sched[t] := true; END IF;
      IF NOT (done[p] AND endd[p] IS NULL) THEN sched[p] := true; END IF;
    END IF;
  END LOOP;

  FOR i IN 1..n LOOP
    IF sched[i] AND ef[i] IS NULL THEN ef[i] := es[i] + rem[i]; END IF;
  END LOOP;

  -- forward pass (relaxation over links; terminates in <= n passes on a DAG, cycles are rejected by trigger)
  pass := 0;
  LOOP
    v_changed := false;
    FOR j IN 1..m LOOP
      t := lt[j]; p := lp[j];
      IF sched[t] AND sched[p] AND NOT done[t] AND ef[p] IS NOT NULL THEN
        cand := ef[p] + llag[j];
        IF cand > es[t] THEN es[t] := cand; ef[t] := cand + rem[t]; v_changed := true; END IF;
      END IF;
    END LOOP;
    EXIT WHEN NOT v_changed;
    pass := pass + 1;
    IF pass > n + 1 THEN RAISE EXCEPTION 'dependency cycle in job %', p_job_id; END IF;
  END LOOP;

  SELECT max(ef[g.ix]) INTO v_fe FROM generate_subscripts(ef, 1) AS g(ix) WHERE sched[g.ix];
  v_deadline := coalesce(v_job.due_date, v_fe);

  -- backward pass (incomplete tasks only)
  FOR i IN 1..n LOOP
    IF sched[i] AND NOT done[i] THEN lf[i] := v_deadline; ls[i] := v_deadline - rem[i]; END IF;
  END LOOP;
  pass := 0;
  LOOP
    v_changed := false;
    FOR j IN 1..m LOOP
      t := lt[j]; p := lp[j];                       -- t = successor, p = predecessor
      IF sched[t] AND sched[p] AND NOT done[t] AND NOT done[p] THEN
        cand := ls[t] - llag[j];
        IF cand < lf[p] THEN lf[p] := cand; ls[p] := cand - rem[p]; v_changed := true; END IF;
      END IF;
    END LOOP;
    EXIT WHEN NOT v_changed;
    pass := pass + 1;
    IF pass > n + 1 THEN RAISE EXCEPTION 'dependency cycle in job %', p_job_id; END IF;
  END LOOP;

  -- slack and critical set: slack <= 0; if the deadline is later than the forecast (min slack > 0) the min-slack path
  SELECT min(ls[g.ix] - es[g.ix]) INTO v_minslack FROM generate_subscripts(ls, 1) AS g(ix)
   WHERE sched[g.ix] AND NOT done[g.ix];
  FOR i IN 1..n LOOP
    -- late critical: an incomplete critical task, or incomplete milestone, whose end_date is already past
    IF NOT done[i] AND endd[i] IS NOT NULL AND endd[i] < p_today
       AND ((sched[i] AND (ls[i] - es[i]) <= GREATEST(0, v_minslack)) OR ms[i]) THEN
      v_late := true; v_late_days := GREATEST(v_late_days, p_today - endd[i]);
    END IF;
  END LOOP;

  -- overall and planned today, by the X1 rule, via the X20 helpers; stored precision is 2 dp (the gap uses 2 dp values)
  SELECT COALESCE(ROUND(SUM(w * progress) / NULLIF(SUM(w), 0), 2), 0),
         COALESCE(ROUND(SUM(w * job_task_planned_pct(baseline_start, baseline_end, start_date, end_date, p_today))
                        / NULLIF(SUM(w), 0), 2), 0)
    INTO v_overall, v_planned
    FROM (SELECT job_task_weight(is_milestone, weight, start_date, end_date) AS w, progress,
                 baseline_start, baseline_end, start_date, end_date
            FROM job_tasks WHERE job_id = p_job_id) x
   WHERE w > 0;

  SELECT EXISTS (SELECT 1 FROM job_tasks WHERE job_id = p_job_id AND baseline_locked_at IS NOT NULL) INTO v_has_bl;
  SELECT coalesce(max(baseline_end), v_job.due_date) INTO v_base_end FROM job_tasks WHERE job_id = p_job_id;
  v_slip := CASE WHEN v_fe IS NOT NULL AND v_base_end IS NOT NULL THEN v_fe - v_base_end END;
  v_gap  := CASE WHEN v_has_bl THEN v_overall - v_planned END;

  v_status := CASE
    WHEN v_job.status IN ('Completed', 'Invoiced', 'Closed') THEN 'Complete'
    WHEN v_job.status = 'On Hold' THEN 'On hold'
    WHEN coalesce(v_slip, 0) > k_late_days OR v_late_days > k_late_days THEN 'Late'
    WHEN coalesce(v_slip, 0) BETWEEN 1 AND k_late_days OR coalesce(v_gap, 0) < -k_gap_pts OR v_late THEN 'At risk'
    ELSE 'On track' END;

  status := v_status; forecast_end := v_fe; slip_days := v_slip;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION job_schedule_status(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_schedule_status(uuid, date) TO authenticated;

-- ===== RLS (exact pattern of job_tasks: TO authenticated, company membership, writes need ops:work-orders:write) =====
ALTER TABLE job_phases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "job_phases members read" ON job_phases;
CREATE POLICY "job_phases members read" ON job_phases FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()));
DROP POLICY IF EXISTS "job_phases writers insert" ON job_phases;
CREATE POLICY "job_phases writers insert" ON job_phases FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_phases writers update" ON job_phases;
CREATE POLICY "job_phases writers update" ON job_phases FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_phases writers delete" ON job_phases;
CREATE POLICY "job_phases writers delete" ON job_phases FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));

ALTER TABLE job_task_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "job_task_links members read" ON job_task_links;
CREATE POLICY "job_task_links members read" ON job_task_links FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()));
DROP POLICY IF EXISTS "job_task_links writers insert" ON job_task_links;
CREATE POLICY "job_task_links writers insert" ON job_task_links FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_task_links writers update" ON job_task_links;
CREATE POLICY "job_task_links writers update" ON job_task_links FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_task_links writers delete" ON job_task_links;
CREATE POLICY "job_task_links writers delete" ON job_task_links FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
