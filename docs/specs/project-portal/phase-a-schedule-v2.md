# Phase A — Schedule v2 and project KPIs

*Status: draft for review (revised after cross-phase review round 2); the SQL below was executed and tested on a throwaway Postgres 17 on 2026-10-21 and is NOT applied to prod · 2026-10-19 · depends on `00-overview.md` (decisions D1-D5 and the binding cross-phase decisions X1-X23 in its section 8 apply unchanged)*

**What this phase owns for the other phases (binding, per section 8 of the overview):** the single progress rule (X1, X20: `job_task_weight`, `job_task_planned_pct`, `jcSchedCompute`), the schedule-status source (X2, X21: `job_schedule_status`), the client-visibility predicate (X22: `job_task_client_visible`) and the shared publish guard (X5, X19: `job_visibility_guard()`). Phases B, C and D reference these by name and must not redefine them. Order (X23): D0a, then A, then B, then C. Phase B is applied after this migration (its visibility triggers call `job_visibility_guard()`), though B may be developed in parallel; Phase C also requires this migration applied first.

## Goal and scope

Turn the per-job "Schedule & Tasks" card (shipped in PR #143) into a project schedule that can carry the mockup's Gantt and its first two KPI tiles, for staff only.

In scope:

1. **Phases.** Each job's tasks are grouped under ordered phase headers (Assess, Design, Make, Install, Commission by default) held in the new table `job_phases`.
2. **Milestones, critical path, baseline.** `job_tasks` gains a phase link, `is_milestone`, `is_critical`, baseline dates and a progress weight. Predecessors move to a join table (`job_task_links`) so a task can have several.
3. **Derived KPIs.** Overall progress (weighted), schedule status (On track / At risk / Late) and a handover forecast date, all computed by one shared pure function.
4. **Custom Gantt renderer** for the per-job view, replacing frappe-gantt there: phase header rows, milestone diamonds, a TODAY line, critical-path colouring, planned (ghost) vs actual bars with % labels.
5. **Baseline lock** with an audit trail in the existing `job_audit_log`.

Verified live facts this relies on (2026-10-19): `job_tasks` columns are `id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, assignee, depends_on, created_at, updated_at`; constraints `job_tasks_depends_on_fkey (→ job_tasks ON DELETE SET NULL)`, `job_tasks_job_id_fkey (→ jobs ON DELETE CASCADE)`, `job_tasks_dates_chk`, `job_tasks_progress_check`; `jobs.job_type` exists (text); `config_tasks` has `task_name, category, sort_order, status, is_active` and 14 trade categories (Machining, Metalwork, Welding, Inspection, ...), no phase concept; `job_audit_log` has `job_id, job_no, user_id (→ auth.users), username, action_type, description, metadata jsonb`.

Live column types (verified 2026-10-19 against `information_schema`): `job_tasks.progress` is **integer**; `job_tasks.start_date` and `end_date` are **date**; `job_tasks.depends_on` is **uuid**; `job_drawings.revision_no` is **text** (Phase B/D comparisons must use text); `erp_users.full_name` is text and `erp_users.auth_user_id` exists; `job_audit_log.username` is text. `erp_roles.permissions` is a JSON **object** `{atom: true}` (`jsonb_typeof = 'object'` on all 7 roles) and the function `set_updated_at()` (returns trigger, sets `NEW.updated_at = now()`) exists; `job_tasks` currently has **no triggers**. Phase D functions must return `job_tasks.progress` as `integer` and bind text parameters for `revision_no`.

## Out of scope

- Resource levelling, calendars (working days, holidays), cost-loaded schedules, MS Project import/export.
- Drag-to-resize bars on the Gantt (read-only chart; editing stays in the inline task table). Parked as a follow-up.
- Any client-facing view (Phase D). Progress history and the S-curve (Phase C reads this phase's baseline and weights).
- Quality KPIs (ITP, hold points, NCRs: Phase B).
- Replacing frappe-gantt on the portfolio Gantt (it stays, see Staff UI).

## Data model

Design decisions embedded in the SQL below:

- **`job_phases`** is per job (not a global catalogue) so a job can rename, reorder or drop phases without touching others. Phase start/end/progress are **derived** from member tasks, never stored.
- **`job_tasks.phase_id`** is nullable with `ON DELETE SET NULL`; ungrouped tasks render under an implicit "Unphased" header. This keeps all existing rows valid with no backfill.
- **`is_milestone`**: a zero-duration task (start = end), progress 0 or 100. Milestones are **always excluded** from progress weighting (X1), whatever their `weight` column holds; the UI does not offer a weight field for them.
- **`weight`**: nullable. NULL means "weight = duration in days" (`COALESCE(weight, duration)`, X1). Explicit values let staff weight a long but trivial task down.
- **`is_critical`** is a **cache** of the computed critical-path result, rewritten whenever a staff member with write permission saves a schedule change. It exists so the portfolio view and Phase D `portal_*` functions (`portal_schedule`) can read it without re-running the algorithm. The client-side computation is authoritative; a stale flag is cosmetic.
- **Baseline** columns `baseline_start`, `baseline_end`, `baseline_locked_at` live on `job_tasks`. They are written only by the `lock_job_baseline` RPC (a guard trigger rejects direct writes).
- **Multiple predecessors**: see recommendation below; `job_task_links` is added, `depends_on` is kept and mirrored.
- **`client_visible`** (default false) on `job_phases` and `job_tasks` per overview rule 3. Nothing reads it in Phase A. Flipping it to true is gated, and editing the client-facing wording of a visible row auto-unpublishes it, by the shared trigger function `job_visibility_guard()` defined below (X5); every change writes a `visibility_changed` row to `job_audit_log`.
- No `created_by` anywhere (the `created_by` FK inconsistency noted in the overview; matches `job_tasks`). Audit identity goes through `job_audit_log.user_id`, and `username` is populated from `erp_users.full_name`.
- `updated_at` is maintained by the existing `set_updated_at()` trigger function (X16), attached to `job_phases`, `job_task_links` and (new) `job_tasks`. The UI never sends `updated_at`; any client-set value is overwritten.
- **Migration file** `supabase/migrations/202610210600_phase_a_sql.sql` (the final name; the `_phase_a_sql` suffix is what the shared runner `bash supabase/tests/d0c_common/run.sh phase_a_sql` globs for; keep the order). Position in the overall order (X16): after D0a (staff-only restrictive policy and storage hardening), before B and C. **Pin order (X23): A, then B, then C.** B is applied after A because B's `*_visibility_guard` triggers call `job_visibility_guard()` defined here (CREATE TRIGGER fails otherwise); B may be developed in parallel. C also requires this migration applied first (its SQL calls `job_task_weight`, `job_task_planned_pct` and `job_task_client_visible`, and reads `weight` and `baseline_*` at CREATE time). Phase A needs none of the owner prerequisite step 0 (pg_cron / pg_net enablement, X23); it has no cron job.

**Multiple predecessors, recommendation: yes, via a join table.** A single parent cannot express "Install starts when both Fabrication and Painting finish", which is the normal case for a conveyor package and the common reason a critical path comes out wrong. Cost is small: one table, finish-to-start links only, optional `lag_days`. `job_tasks.depends_on` stays for backward compatibility (the existing dependency select and the portfolio frappe arrows): the UI mirrors the *first* predecessor into it, and the migration backfills links from existing `depends_on`. Dependency types other than finish-to-start are out of scope.

```sql
-- ===== up =====  (verbatim copy of supabase/migrations/202610210600_phase_a_sql.sql, executed and tested)
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
    ELSIF TG_OP = 'UPDATE' AND (NEW.baseline_start, NEW.baseline_end, NEW.baseline_locked_at) IS DISTINCT FROM (OLD.baseline_start, OLD.baseline_end, OLD.baseline_locked_at) THEN
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
CREATE OR REPLACE FUNCTION job_visibility_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
CREATE POLICY "job_phases members read" ON job_phases FOR SELECT TO authenticated USING (company_id IN (SELECT my_company_ids()));
DROP POLICY IF EXISTS "job_phases writers insert" ON job_phases;
CREATE POLICY "job_phases writers insert" ON job_phases FOR INSERT TO authenticated WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_phases writers update" ON job_phases;
CREATE POLICY "job_phases writers update" ON job_phases FOR UPDATE TO authenticated USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write')) WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_phases writers delete" ON job_phases;
CREATE POLICY "job_phases writers delete" ON job_phases FOR DELETE TO authenticated USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));

ALTER TABLE job_task_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "job_task_links members read" ON job_task_links;
CREATE POLICY "job_task_links members read" ON job_task_links FOR SELECT TO authenticated USING (company_id IN (SELECT my_company_ids()));
DROP POLICY IF EXISTS "job_task_links writers insert" ON job_task_links;
CREATE POLICY "job_task_links writers insert" ON job_task_links FOR INSERT TO authenticated WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_task_links writers update" ON job_task_links;
CREATE POLICY "job_task_links writers update" ON job_task_links FOR UPDATE TO authenticated USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write')) WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
DROP POLICY IF EXISTS "job_task_links writers delete" ON job_task_links;
CREATE POLICY "job_task_links writers delete" ON job_task_links FOR DELETE TO authenticated USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
```

```sql
-- ===== down =====  (verbatim copy of supabase/rollbacks/202610210600_phase_a_sql_down.sql; run in this order, harmless twice)
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
```

### Execution notes (SQL run on a throwaway Postgres 17, 2026-10-21)

The SQL above is the executed migration, not the desk-checked draft. What running it changed (behaviour is as specified unless stated):

1. **`job_schedule_status` gap type.** `v_gap` was declared `int`, which silently rounded the 2 dp gap and moved the `gap < -10` boundary (a gap of -10.01 became -10 and read On track). It is `numeric` now; the precision cases (overall 39.995 -> 40.00, gap -10.00 On track; 39.99 -> gap -10.01 At risk; planned 33.33 kept to 2 dp) pin it.
2. **Policies are `TO authenticated`**, the exact live `job_tasks` pattern. Without it the policies applied to `anon` too, so an anon query died with 42501 inside `my_company_ids()` instead of returning zero rows.
3. **Baseline guard is stricter, same behaviour for the RPC.** The transaction-local setting `app.baseline_rpc` alone is not trusted: the guard also requires `current_user` to be the owner of `lock_job_baseline` (true only inside that SECURITY DEFINER function or an owner/superuser seed). `lock_job_baseline` also switches the setting off before returning. A caller that sets the setting itself still cannot write baselines.
4. **Backfill cannot abort the migration.** v1 allowed a task to depend on itself, on a task of another job, or to form a `depends_on` cycle; the plain `INSERT ... SELECT` would fail on the cycle trigger. The backfill now skips such rows with a NOTICE (the chain rows are kept, `depends_on` is untouched).
5. **`job_task_links_no_cycle` also keeps a link inside one job and company** (task and predecessor must belong to the link's own job and company; otherwise 23514). A self-link is reported by the CHECK (23514), not as a cycle. Cycle and integrity failures use SQLSTATE 23514 (`check_violation`).
6. **Trigger order vs RLS.** BEFORE triggers run before the RLS WITH CHECK, so an INSERT by a user who cannot see the tasks fails with 23514 (integrity) and a refused publish by a non-approver fails with P0001 (guard) rather than 42501. Both are refusals; a client that has no `erp_users` row cannot create anything.
7. **Test-harness trap for the X19 exemption.** `SET ROLE authenticated` inside a postgres session keeps `session_user = postgres`, so the guard exempts it. The publish-guard tests must run through a login role that is a member of `authenticated` (`SET SESSION AUTHORIZATION authenticator` then `SET ROLE`), which `supabase/tests/phase_a_sql/10_stub_extra.sql` provides as `t_dml_api`. The real PostgREST path is still to be confirmed after the migration is applied (the Test plan publish-guard case run through the REST API).
8. **`service_role` over the REST API is not exempt** (session_user is `authenticator`, `auth.uid()` is NULL), so an edge function that inserts a row with `client_visible = true` through PostgREST is refused. Use direct SQL (session_user postgres) or set the flag in a second step as an approver.

Run: `bash supabase/tests/d0c_common/run.sh phase_a_sql` (before / apply / re-apply / after / rollback / re-apply), `node supabase/tests/d0c_common/mutate.mjs phase_a_sql` (mutation check) and `bash supabase/tests/phase_a_sql/run-fixture.sh [fixture.json]` (shared JSON fixture against SQL, see `scripts/tests/schedule/sql-fixture-runner.mjs`).

### Phase templates and ordering

Phases order by `job_phases.sort_order` (gaps of 10, rewritten on reorder). Tasks order within a phase by `job_tasks.sort_order` (already exists; unchanged meaning, now scoped by phase).

Templates are a **versioned constant in `index.html`**, not a new table (a `job_phase_templates` table would need its own job-less scope and admin UI for little gain). Shape:

```json
{ "default": ["Assess", "Design", "Make", "Install", "Commission"],
  "byJobType": { "<jobs.job_type value>": ["Assess", "Make", "Commission"] },
  "categoryToPhase": { "Engineering": "Design", "Mechanical Engineering": "Design",
    "Machining": "Make", "Metalwork": "Make", "Welding": "Make", "Coatings": "Make",
    "Mechanical Fitting": "Install", "Electrical Motor": "Install", "Inspection": "Commission", "HSE": "Assess" } }
```

"Apply template" on a job with no phases creates the phase rows (job_type list if matched, else default). The existing "add from catalogue" picker over `config_tasks` then places a picked task in the phase given by `categoryToPhase[config_tasks.category]` (falling back to Unphased). Unmapped categories are visible in the picker so staff can fix them. The `byJobType` keys must be confirmed against live `jobs.job_type` values before build (Open question 3).

## RLS and permissions

- **Reads**: any company member (identical to `job_tasks`, so no new exposure path). The Schedule UI itself is shown only to holders of `ops:work-orders:read`, which today is company_admin, operations_tech, super_admin and viewer. finance_manager, sales_rep and Office Admin do not hold it and do not see the screen (their RLS read access is unchanged from today).
- **Writes** (phases, links, task fields): `user_has_perm('ops:work-orders:write')` with `company_id IN (SELECT my_company_ids())`. Held by company_admin, operations_tech, super_admin. viewer is read-only.
- **Baseline lock / re-baseline**: the existing atom `ops:work-orders:approve` (live on company_admin, operations_tech, super_admin), enforced inside `lock_job_baseline`. **No new permission atom is proposed.** Rationale: baseline changes are an approval-class action, the atom already exists with the right role set, and adding atoms means editing `erp_roles` JSON in production.
- **Atoms (X11).** `erp_roles.permissions` is a JSON object `{atom: true}` (verified live on all 7 roles) and `user_has_perm` has no super_admin wildcard, so any new atom must be seeded explicitly: `UPDATE erp_roles SET permissions = permissions || jsonb_build_object('<atom>', true) WHERE name IN (...)` with a `-- down` of `permissions - '<atom>'`. **Phase A adds no atom and therefore seeds none**: it reuses `ops:work-orders:read|write|approve`, which are already present on the roles named above. If review adds an atom, the seed UPDATE and its `-- down` go in the migration file.
- **Publishing (X5).** `job_phases.client_visible` and `job_tasks.client_visible` can be set to true only with `ops:work-orders:approve` (Phase A has no domain atom), enforced by the trigger `job_visibility_guard()` (rules and SQL above), not by the UI. A writer without approve can still unpublish. Editing `name` / `task_name` of a visible row auto-unpublishes it. Because `ops:work-orders:write` holders without approve (none today in the live role set, but possible later) cannot republish, the UI shows an "Unpublished by edit: re-publish" badge.
- **Function exposure (X13).** `lock_job_baseline` and the helper/status functions are revoked from `PUBLIC, anon` and granted to `authenticated`, with authorization re-checked inside (`lock_job_baseline`) or RLS-scoped (`job_schedule_status` is SECURITY INVOKER). `job_visibility_guard` is trigger-only and revoked from all API roles. The Q-D definer sweep (inventory queries Q-A..Q-E) is re-run after this migration. `job_task_client_visible` is SECURITY INVOKER, revoked from `PUBLIC, anon`, granted to `authenticated`.
- `user_has_perm` is not company-scoped, which is why every policy pairs it with the `my_company_ids()` test. The RPC re-checks company membership on the job.
- Cost fields are never touched by this phase; the KPI function reads only `job_tasks`, `job_task_links`, `job_phases` and `jobs.due_date`/`status`.

## Staff UI (ERP)

All inside `index.html`, in the existing Work Order detail "Schedule & Tasks" card (`jcRenderSchedGantt`, `jcTaskSet`, task table). Dark theme using existing variables (`--bg-2`, `--gold`, `--green`, plus the ERP red/amber tokens; no new palette).

**1. KPI strip** (top of the card; Phase D later shows the same two tiles from the values Phase C stores, not by recomputing). Bindings are outputs of `jcSchedCompute()` below (the shared module, which mirrors SQL `job_schedule_status`):

| Tile | Shows | Binds to |
|---|---|---|
| Overall progress | `NN%` large, sub-line "planned NN% today" and a thin bar | `overall`, `plannedToday` |
| Schedule status | pill On track (green) / At risk (amber) / Late (red) / Complete (green, muted) / On hold (grey), sub-line "Handover forecast 14 Mar · due 10 Mar (+4 d)" | `status`, `forecastEnd`, `jobs.due_date` |

If no baseline exists the tile shows "No baseline" and status falls back to the due-date rule only. A **Lock baseline** button (visible with `ops:work-orders:approve`) and a "Baseline locked 02 Oct by <name>" caption sit beside the tiles; re-baseline asks for a reason.

**2. Grouped Gantt** (custom renderer, per-job only). Structure: a two-pane layout in one scroll container. Left pane = CSS grid rows (name, assignee, %), right pane = one `<svg>` sharing row height (28 px) with the left rows. Vertical scroll is shared; horizontal scroll moves only the SVG; header date axis is sticky.

- **Phase header rows**: full-width tinted row, chevron to collapse, phase name, derived span (min start to max end), weighted phase % and a thin rollup bar. Binds to `job_phases` plus member tasks. Collapsed phases hide their task rows.
- **Task rows**: planned ghost bar (`baseline_start`..`baseline_end`, 35% opacity, drawn 4 px lower and thinner), actual/current bar (`start_date`..`end_date`) with a darker filled portion = `progress`, and the `%` label inside or right of the bar when width allows. Bars for tasks without dates are omitted and the row shows "unscheduled".
- **Critical colouring**: bar stroke/fill red-amber when `crit` is true (cache `is_critical`, recomputed live), otherwise the phase colour. A legend row explains ghost, actual, critical, milestone.
- **Milestones**: a rotated-square diamond at `end_date`; filled when `progress = 100`, outlined otherwise, red outline if past today and incomplete. Label to the right.
- **TODAY line**: vertical gold line with a "TODAY" flag at `new Date()` normalised to local midnight, drawn above bars; auto-scrolls into view on open.
- **Dependency arrows**: thin elbow connectors from each `job_task_links` predecessor finish to successor start; shown only for critical links by default, all links via a toggle.
- **Zoom**: the existing `#jc-sched-zoom` select (Day/Week/Month) sets px-per-day (28/8/3).
- All text via `escHTML`; the renderer builds SVG with `createElementNS`, no `innerHTML` for user strings. Dependency-free; no CDN library. Tooltip on hover: name, dates, baseline dates, slip days, assignee.

**3. Task table** (existing inline-save rows) gains: Phase select, Milestone checkbox, Weight, and a multi-select "Predecessors" (replacing the single `depends_on` select; the first pick is mirrored to `depends_on`). A "Visible to client" toggle per phase and task (shown with `ops:work-orders:write`; enabling it needs `ops:work-orders:approve`, enforced by `job_visibility_guard()`, so the control is disabled with a tooltip otherwise) and an "Unpublished by edit" badge after an auto-unpublish. Edits PATCH as today (never sending `updated_at`: the trigger owns it), then call `jcSchedCompute()` and PATCH `is_critical` for rows whose cached flag changed (single batched `sbPatchWhere` per flag value).

**4. Portfolio Gantt (Work Orders dashboard)** stays on frappe-gantt 1.0.3: it is a cross-job overview of one bar per task, where group headers and ghost bars add little. Changes are limited to (a) milestone tasks excluded from the portfolio bars, (b) bar colour from cached `is_critical` and per-job status (computed lazily, only for the visible jobs), and (c) a "Open schedule" link into the per-job renderer. Both views call the same `jcSchedCompute()` so numbers never disagree. Retiring frappe entirely is a later decision once the custom renderer has a multi-job mode.

### Computation (one shared JS module, mirrored by the SQL source of truth)

**One module.** The compute code lives in a single clearly delimited, DOM-free block of `index.html` (`// ── SCHEDULE COMPUTE (shared) ──`) exporting `jcTaskWeight`, `jcPlannedPct` and `jcSchedCompute`. The staff Gantt renderer, the KPI tiles, the portfolio Gantt colouring **and Phase C's staff progress screen (its `plannedPctOn` is a thin call to `jcPlannedPct`/`jcTaskWeight`, not a second implementation)** all call this one module; nothing else in the ERP computes progress or status. The Phase D portal app does not compute: it shows the values Phase C stores (X2), and its Gantt (from `portal_schedule`) shows critical colouring from the cached `is_critical` but **no dependency arrows**, because `job_task_links` is never exposed to clients.

**Canonical SQL (X1, X2, X20).** SQL is the source of truth that the JS must match: `job_task_weight`, `job_task_planned_pct` and `job_schedule_status(job_id)` in the migration above. Phase C's `job_progress_calc`, `job_planned_pct_on` and snapshot function MUST CALL `job_task_weight` and `job_task_planned_pct` (they stay the single SQL implementation of the formula) and `job_schedule_status`; they must not re-derive weights, planned % or status. The JS mirrors them line by line, including the constants (5 days, 10 points) and the labels. A shared fixture test (see Test plan) proves JS and SQL agree.

`jcSchedCompute({tasks, links, phases, job, today}) -> {overall, plannedToday, phaseRollups, forecastEnd, status, slipDays, crit[], slackByTask}`

**Weighted overall progress (X1).** For each non-milestone task `i`: `dur_i = max(1, end - start + 1)` calendar days (tasks without both dates: `dur_i = 1`); `w_i = COALESCE(weight_i, dur_i)`. Milestones (`is_milestone`) are always excluded (`w = 0`), whatever their stored `weight`. Then:

```
overall      = round( SUM(w_i * progress_i) / SUM(w_i) )          // 0 if SUM(w)=0
s_i, e_i     = COALESCE(baseline_start, start_date), COALESCE(baseline_end, end_date)   // baseline, else current dates
planned_i(t) = 0 if s_i or e_i is NULL, else clamp((t - s_i + 1) / (e_i - s_i + 1), 0, 1) * 100
plannedToday = round( SUM(w_i * planned_i(today)) / SUM(w_i) )     // every weighted task; undated tasks plan 0
phase %      = same formula over the phase's tasks
```

**Precision (X20).** SQL stores and returns 2 decimal places (`ROUND(num / den, 2)`, exact numeric arithmetic, half-up); the status gap is computed on those 2 dp values. Every UI (staff tiles, Gantt labels, client portal) rounds half-up to an integer for display: JS computes `Math.round(num / den * 100) / 100` for the 2 dp value and `Math.round(num / den)` for display (non-negative, so half-up in both). The shared fixture compares both representations (2 dp and displayed integer), including an exact `.5` case. Milestones do not contribute to progress but gate status (a milestone is "done" at progress 100). Tasks added after the baseline was locked have no ghost bar (the ghost needs baseline dates) but, per X1, do count in `plannedToday` using their current dates; the tooltip lists them as "added after baseline". The schedule-status **gap** (below) is only evaluated when a baseline exists.

**Critical path.** Forecast CPM on remaining work, finish-to-start with lag, calendar days:

```
rem_i = 0 if progress_i = 100 else max(1, ceil(dur_i * (100 - progress_i) / 100))   // milestones: 0
order = topological sort of tasks over job_task_links      // cycle => abort, show warning banner
forward pass, in order:
  base_i = start_i if progress_i > 0 (started or done) else today
  ES_i = max( base_i, max over preds p ( EF_p + lag(p,i) ) )  // done tasks are not moved by preds
  EF_i = ES_i + rem_i                                        // done tasks keep their actual end_date
forecastEnd = max EF_i over all tasks
deadline    = job.due_date ?? forecastEnd
backward pass, reverse order:
  LF_i = min( deadline, min over succs s ( LS_s - lag(i,s) ) )
  LS_i = LF_i - rem_i
slack_i    = LS_i - ES_i
critical_i = progress_i < 100 AND slack_i <= 0
```

Tasks without dates and without predecessors are ignored by the forward pass (not scheduled). When `due_date` is later than `forecastEnd` nothing is critical on slack alone, so in that case the longest path (tasks with slack equal to the minimum slack) is flagged instead. This makes "critical" always mean "the path that sets the handover date".

**Handover forecast date** = `forecastEnd` above. If every task is complete, it is `max(end_date)` (actual).

**Schedule status (canonical implementation: SQL `job_schedule_status(job_id)` returning `(status, forecast_end, slip_days)`; this table is its specification and the JS mirrors it).** Let `slip = forecastEnd - (baseline max end, else job.due_date)` in days, `gap = overall - plannedToday` in points (only if a baseline exists), `lateCrit` = any incomplete task that is critical, or any incomplete milestone, with `end_date < today` (overdue days = `today - end_date`, maximum taken):

| Status | Rule (first match wins) |
|---|---|
| Late | `slip > 5` OR `lateCrit` overdue by more than 5 days |
| At risk | `slip BETWEEN 1 AND 5` OR `gap < -10` OR `lateCrit` |
| On track | otherwise |

Thresholds (5 days, 10 points) are constants at the top of the compute module and are the Open question 2 defaults. Jobs with status Completed, Invoiced or Closed show "Complete" instead; On Hold shows "On hold" with the forecast greyed out. **Labels (X21):** exactly five, confirmed: `On track`, `At risk`, `Late`, `Complete`, `On hold`. `job_schedule_status` **always returns a row** for a job the caller can see (status never NULL; zero rows only when the job is invisible under RLS). `forecast_end` is NULL when no task is scheduled; `slip_days` is NULL when `forecast_end` is NULL or when there is neither a baseline nor a `jobs.due_date` (the status then falls back to the gap and `lateCrit` rules, treating slip as 0). Because planned handover is derived as forecast minus slip, Phase D shows planned handover as NULL whenever `slip_days` is NULL (never "planned = forecast"). Phase C stores these three values per snapshot and Phase D reads them without recomputing.

## Client-facing surface

None in this phase, and nothing is exposed. Explanation: Phase D reads schedule data only through `portal_*` **functions** (`portal_schedule`, `portal_project_kpis`; the Gantt and KPI tiles), never through the base tables, so Phase A's only obligation is to make that possible safely. It does so by adding `client_visible boolean NOT NULL DEFAULT false` to `job_phases` and `job_tasks` (every existing and new row is hidden until staff opt it in; publishing is gated and audited by `job_visibility_guard()`), keeping `assignee` and all internal notes off any whitelist, and storing the KPI inputs (weights, baseline, cached `is_critical`) in plain columns. Progress and schedule status are computed once, in SQL (`job_task_weight`, `job_schedule_status`), taking no cost inputs; Phase C stores the results and Phase D reads the stored values rather than recomputing. Which tasks a client may see is decided in one place, `job_task_client_visible(task_id)` (task visible AND (no phase OR phase visible), X22), which Phase C's client planned curve and Phase D's `portal_schedule` both call. The client Gantt shows critical colouring (from `is_critical`) but no dependency arrows, because `job_task_links` is never exposed.

## Migration and rollout

0. **Order (X16, X23).** Apply `supabase/migrations/202610210600_phase_a_sql.sql` after D0a and before Phase B's and Phase C's migrations (strict order D0a, A, B, C; B may be developed in parallel but is applied after A). No owner prerequisite step 0 (pg_cron / pg_net) is needed for A. Run the Q-D SECURITY DEFINER sweep (inventory queries Q-A..Q-E) after applying it.
1. Ship the migration (additive; existing rows keep working). The ERP v1 schedule reads only old columns, so the migration can go out before the UI. (The new `job_tasks_set_updated_at` and visibility triggers are the only behaviour change to existing writes: `updated_at` is now server-set, and no existing row is visible so the guard is inert until someone publishes.)
2. Deploy the UI behind the existing `index.html` release: renderer, KPI strip, table fields. Old `depends_on` stays populated, so frappe on the portfolio view is unaffected.
3. Optional one-time "Apply template" per job (manual, never automatic). No bulk data change on existing jobs.
4. Baselines are not auto-created; ops locks them per job when the plan is agreed.
5. Rollback: UI revert then the `-- down` block; no data in other tables depends on the new columns (Phase C/D add dependents later and must be rolled back first).
6. Verify the RLS with a real non-privileged user (viewer cannot insert or call the RPC; operations_tech can), not only the service role. Service worker/cache version bump follows the repo's usual release step.

## Test plan

- **SQL/RLS**: as viewer, SELECT succeeds and INSERT/UPDATE/DELETE on `job_phases`, `job_task_links`, `job_tasks` fail; as operations_tech they succeed; cross-company rows are invisible; `lock_job_baseline` fails for a role without `ops:work-orders:approve`, works for operations_tech; second call without a reason fails; direct `UPDATE job_tasks SET baseline_start=...` fails for every role.
- **Constraints**: self-link, duplicate link, A→B→A cycle, milestone with start<>end, weight < 0, bad hex colour all rejected.
- **Audit**: lock and re-baseline each write one `job_audit_log` row with `action_type` `baseline_locked` / `baseline_reset`, `metadata.reason`, and `username` equal to the caller's `erp_users.full_name`.
- **Publish guard (X5)**: as a `write`-only role (a test role holding `ops:work-orders:write` but not `approve`) setting `client_visible = true` on a phase or task fails, unpublishing works; as operations_tech publishing works and writes one `visibility_changed` row (`metadata.table`, `row_id`, `to=true`, `username` set); editing `task_name` / `name` of a visible row sets `client_visible=false` in the same statement and writes a `visibility_changed` row with `reason='wording_edited'`; editing dates or progress of a visible row does not unpublish; `INSERT ... client_visible=true` follows the same permission rule; `job_visibility_guard()` is not callable by `authenticated`/`anon`; a migration-style insert with `client_visible=true` run as `postgres` / `supabase_admin` (SQL editor) succeeds (X19 exemption) while the same insert through the REST API as a write-only user fails; the triggers on `job_phases` / `job_tasks` pass exactly two arguments.
- **`job_task_client_visible` (X22)**: false for a visible task in an invisible phase; true for a visible task with no phase; true for a visible task in a visible phase; false for an invisible task in a visible phase; false for an unknown id.
- **Status contract (X21)**: `job_schedule_status` returns exactly one row, with status one of the five labels, for a job with no tasks, no baseline and no due date (`forecast_end` and `slip_days` NULL), for a job with tasks but neither baseline nor due date (`slip_days` NULL), for Complete and On hold jobs; and zero rows for an invisible job.
- **Precision (X20)**: SQL `overall` / `plannedToday` come back with 2 dp, JS shows the half-up integer of the same value; the fixture asserts both forms (for example 62.50 displays 63, 62.49 displays 62).
- **Function exposure (X13)**: `anon` cannot execute `lock_job_baseline`, `job_task_weight`, `job_task_planned_pct`, `job_schedule_status`; a JWT with no company membership gets zero rows from `job_schedule_status`.
- **`updated_at`**: PATCH of a `job_tasks`, `job_phases` or `job_task_links` row moves `updated_at` forward even when the request body carries an older value.
- **Shared fixture (X1/X2, mandatory)**: one JSON fixture file defines table-driven jobs (tasks, links, baseline, `today`, job status/due date) with expected `{overall, plannedToday, forecastEnd, status, slipDays}` (overall and plannedToday as both the 2 dp value and the displayed integer, X20). It is executed twice and both runs must produce identical output: (1) by the scratch HTML test page against `jcSchedCompute`; (2) by a SQL script that seeds each case into a scratch job inside a rolled-back transaction and calls `job_schedule_status(job_id, today)` and the same weighted sums through `job_task_weight` / `job_task_planned_pct`. Phase C's `job_progress_calc` and `plannedPctOn` are added to the same fixture run, so one failing case blocks all three. Cases include: a milestone carrying an explicit non-zero `weight` (must still be excluded), a NULL-weight task (duration weighting), an undated task (weight 1, planned 0), a task added after baseline (planned from current dates), an exact `.5` rounding case, and every status boundary below.
- **Compute (pure function, table-driven cases in a scratch HTML test page; these are also fixture cases)**: single chain; diamond graph with two predecessors; zero-weight milestone; all-complete job; no-baseline job; undated tasks; due_date earlier than forecast (everything critical) and later (longest path flagged); status boundary cases at slip 0/1/5/6 and gap -10/-11.
- **UI**: collapsed phases, TODAY line position at each zoom, ghost vs actual bars after a slip, diamond states, XSS strings (`<img onerror>`) in task and phase names render as text, 200-task job stays smooth (target < 100 ms render).
- **Regression**: v1 inline task edit still saves; portfolio Gantt still renders arrows from `depends_on`.

## Risks

- **Cache drift**: `is_critical` can be stale if a task changes outside the UI (SQL, import). Mitigation: it is cosmetic; the UI recomputes on load and rewrites differences for writers.
- **Mirrored `depends_on`**: two sources of truth for the first predecessor. Mitigation: links table is authoritative; `depends_on` is written only by the UI save path and is documented as legacy; removal is a later migration.
- **Calendar-day arithmetic** overstates durations across weekends. Accepted for v1; calendars are out of scope.
- **Weight semantics**: NULL = duration can surprise staff who expect equal weights. Mitigation: the table shows the effective weight greyed in the cell.
- **Read exposure**: SELECT is company-wide (same as today), so finance/sales roles can read schedule rows through the REST API even though the UI hides the screen. Matches `job_tasks`; tightening belongs to a repo-wide decision.
- **Two implementations (SQL and JS) of one rule**: drift is the main risk. Mitigations: SQL is canonical, JS mirrors it, one shared fixture runs both (Test plan), constants are mirrored in a comment on both sides, and Phase C calls the SQL helpers instead of copying them.
- **Guard definer and exemption**: `job_visibility_guard()` is SECURITY DEFINER and exempts `session_user IN ('postgres','supabase_admin')` for migrations and backfills. PostgREST connects as `authenticator`, so the exemption is unreachable from the API; confirm with the Test plan publish-guard case run through the REST API, not the SQL editor.
- **Baseline trigger vs RPC**: the guard needs the transaction-local setting AND `current_user` = owner of `lock_job_baseline`; any future function writing baselines must be SECURITY DEFINER under the same owner and set the setting deliberately (and switch it off again). Documented in the migration comment.

## Open questions

1. **Are `is_critical` and `weight` OK as specified (cache; NULL = duration)?** Recommended default: yes, as written.
2. **Status thresholds** (slip > 5 d = Late, 1-5 d = At risk, gap < -10 pts = At risk)? Recommended default: use these, held as constants, revisit after a month of real jobs.
3. **Phase template keys per `jobs.job_type`**: live values must be listed and mapped by ops before build. Recommended default: ship only the `default` five-phase template and an empty `byJobType`, add types as ops names them.
4. **Who may re-baseline?** Recommended default: `ops:work-orders:approve` (company_admin, operations_tech, super_admin), reason mandatory, every change audited.
5. **Auto-apply template when a job moves to In Progress?** Recommended default: no, manual button only.
6. **Phase of tasks added from `config_tasks` with unmapped category**: Recommended default: place under "Unphased" and flag in the picker.
7. **Retire frappe on the portfolio view?** Recommended default: not in this phase.

## Acceptance criteria

1. Migration applies cleanly on the live schema and the `-- down` block reverses it; v1 schedule works before and after.
2. `job_phases` and `job_task_links` have RLS with four explicit policies each; verified with a non-privileged user as in the Test plan.
3. A job with the default template shows five phase headers, milestone diamonds, a TODAY line, red critical bars and ghost vs actual bars with % labels, escaped against injection.
4. Overall progress equals the weighted formula on a hand-calculated sample job, and the Schedule status tile and handover forecast match the rules above for the boundary cases tested. The shared fixture gives identical results from `jcSchedCompute` and from SQL `job_schedule_status` / `job_task_weight` / `job_task_planned_pct`.
5. A task with two predecessors schedules after the later of both, and a cycle is rejected at the database.
6. Locking a baseline requires `ops:work-orders:approve`, cannot be changed by direct UPDATE, and writes `job_audit_log` rows; re-baseline requires a reason.
7. The portfolio Gantt still renders unchanged apart from milestone exclusion and critical colouring, and both views show identical status and progress for the same job.
8. No cost column is read by any Phase A query and no row is client-visible by default.
9. `job_task_client_visible(task_id)` exists with the X22 predicate and is the only place it is defined; the guard is attached to `job_phases` and `job_tasks` with explicit two-argument form and carries the `session_user IN ('postgres','supabase_admin')` exemption; `job_schedule_status` always returns one row with one of five labels.
10. `job_visibility_guard()` blocks publishing without `ops:work-orders:approve`, auto-unpublishes on a wording edit, and writes a `visibility_changed` audit row with `username` populated; `lock_job_baseline` and the helper functions are not executable by `anon`; no new permission atom was added; `updated_at` is maintained by `set_updated_at()` on all three tables.
