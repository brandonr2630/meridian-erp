# Phase C — Site/workshop updates, progress history and S-curve

*Status: draft, revised after cross-phase review rounds 1 and 2 (X1-X5, X10-X13, X15, X16, X19-X23) · 2026-10-19 · **requires Phase A's migration applied first**: `job_tasks.weight`, `baseline_start`, `baseline_end`, `is_milestone`, `client_visible`, plus Phase A's SQL helpers `job_task_weight`, `job_task_planned_pct`, `job_task_client_visible(task_id)`, `job_schedule_status(job_id)` and the shared trigger function `job_visibility_guard()` (all defined by Phase A and only referenced here; X19-X22) · **owner prerequisite before this migration: `pg_cron` and `pg_net` enabled once in the dashboard (X23)** · follows `00-overview.md`*

## Goal and scope

Give staff a dated, photo-backed log of what is happening on a job (workshop fabrication, site installation, milestones) and a progress history that powers the **Progress curve** (planned vs actual cumulative %, TODAY marker, "64% actual" label) and the **Latest from site & workshop** feed from the mockup. Everything is staff-side; every row and photo is designed so Phase D can later expose a client-safe subset through `portal_*` functions (`portal_updates`, `portal_progress_curve`, `portal_planned_curve`).

In scope:

- `job_updates` (the feed entries), `job_update_photos` (one row per image), `job_progress_snapshots` (one row per job per day).
- New private storage bucket `job-updates` with tenant-scoped storage policies.
- Browser-side image downscaling and EXIF stripping before upload; signed-URL viewing.
- Nightly snapshot job (`pg_cron`) plus on-save snapshot after task progress edits; one-off backfill.
- Planned-curve SQL (`job_planned_curve`), the progress calculation that **calls Phase A's `job_task_weight` and `job_task_planned_pct`** (X1, X20), a dependency-free SVG S-curve renderer, and an "Updates" card in the ERP job form.
- Snapshot rows that also freeze the schedule status (`schedule_status`, `forecast_end`, `slip_days`), taken from Phase A's `job_schedule_status()`, so Phase D reads stored values instead of recomputing.
- Cleanup of storage objects when updates, photos or a whole job are deleted.
- One new permission atom, `ops:updates:write`, and an explicit publish step.

## Out of scope

- Client login, client queries, signed-URL minting for clients, notifications to clients (Phase D). Phase C only guarantees the visibility flags and column whitelists Phase D needs.
- Editing baseline, weights, phases or task dates (Phase A). Phase C only reads them.
- Quality records, ITP, NCR and drawing approvals (Phase B). Updates may mention them in free text only.
- Video upload, PDF attachments, comments or reactions on updates, offline queueing of uploads (see Open questions).
- Fixing the live `job-drawings` storage policies: that belongs to Phase D0a (decision X12); Phase C only cites it (see Risks).
- Defining the progress rule, `job_task_weight`, `job_task_planned_pct`, `job_task_client_visible()`, `job_schedule_status()` or `job_visibility_guard()`: Phase A owns them; Phase C references them by name.
- Enabling `pg_cron` / `pg_net`: an owner prerequisite done once in the dashboard before this phase (X23); Phase C does not document how.
- Any change to the columns or policies of an existing table. Outside new objects, Phase C adds one `AFTER UPDATE` trigger on `job_tasks` (re-baseline hook, below) and the `ops:updates:write` atom in `erp_roles` rows.

## Data model

Verified live on 2026-10-19 (read-only): `job_tasks` has no Phase A columns yet and 0 rows; `jobs` has 13 rows; `job_drawings.created_by` references `erp_users(id)`; `pg_cron` and `pg_net` are **available but not installed** on the project (the existing `20260622_pg_cron_overdue_notifications.sql` is a manual-apply script and has evidently not been run here); both are enabled once by the owner as a prerequisite (X23); the existing trigger function `set_updated_at()` is reused; `erp_roles.permissions` is a JSON **object** of the form `{atom: true}` (`jsonb_typeof = 'object'` on all 7 roles) and `user_has_perm` has no super_admin wildcard, so the new atom must be seeded explicitly for every role that needs it (decision X11). Authors are stored as `created_by uuid REFERENCES erp_users(id)`, matching `job_drawings` (not `auth.users`), nullable with `ON DELETE SET NULL`.

Model decisions:

- **Update kind**: `site`, `workshop`, `milestone`, `general`. The mockup labels ("Workshop", "Site") are the kind. `task_id` optionally links an update to one `job_tasks` row (`ON DELETE SET NULL`); it is a reference only and never drives progress.
- **Visibility**: `client_visible` defaults `false` on all three tables. Publishing an update is an explicit action that sets `client_visible = true`, `published_at`, `published_by`. Individual photos carry their own flag so staff can withhold a photo while publishing the update. A photo is client-visible only if both its flag and its update's flag are true (Phase D's `portal_updates` must join both).
- **Publish gating is Phase A's shared `job_visibility_guard()`** (decisions X5, X19), attached to all three tables by trigger using A's argument contract: `TG_ARGV[0]` is ONE comma-separated string of client-facing wording columns, `TG_ARGV[1]` is the optional domain atom (empty string: none). Flipping `client_visible` needs `ops:work-orders:approve` (Phase C has no domain atom of its own), editing wording of an already-visible row auto-unpublishes it, and every visibility change writes a `visibility_changed` row to `job_audit_log`. Phase C does not implement any of this itself. It attaches the guard as `job_visibility_guard('title,body,kind,occurred_on','')` on `job_updates` and `('','')` on `job_update_photos` and `job_progress_snapshots` (photos and snapshots have no wording; their wording-less guard only gates and audits the visibility flip). `job_updates` and `job_update_photos` use `BEFORE INSERT OR UPDATE`, as Phase A attaches it, so an insert with `client_visible = true` is also permission-checked and audited. `job_progress_snapshots` is `BEFORE UPDATE` only (see the trigger comment: the definer upsert INSERT copies an already-approved job-level decision and must not be re-gated or write an audit row per night).
- **`published_at` is set by a Phase C trigger, not by the client** (X20 note): the guard does not touch it, so a small `BEFORE INSERT OR UPDATE` trigger on `job_updates` stamps `published_at` / `published_by` whenever `client_visible` becomes true (after the guard has run), so a direct PATCH that only sets `client_visible = true` still gets a timestamp and Phase D's `portal_updates` can order and page on `coalesce(published_at, created_at)`.
- **Snapshots** are written only by `SECURITY DEFINER` functions, never by direct client inserts (the INSERT policy is an explicit deny). Protection of the system-written columns uses a **transaction-local flag `app.snapshot_rpc`** (decision X4), set only inside the snapshot functions and checked by the column guard. `auth.uid()` is **not** a valid discriminator: inside a `SECURITY DEFINER` function it stays set to the calling user, so a guard keyed on `auth.uid() IS NULL` would block the legitimate on-save RPC. A snapshot row's `client_visible` is inherited from the job's existing snapshots (an INSERT, which the update-only visibility trigger does not gate because it copies an already-approved job-level decision), so "share progress curve with client" is a single job-level toggle that stays on as nightly rows arrive.
- **Schedule status is stored, not recomputed** (decision X2): each snapshot freezes `schedule_status`, `forecast_end` and `slip_days` as returned by Phase A's `job_schedule_status(job_id)` at write time, with Phase A's five labels (On track, At risk, Late, Complete, On hold; X21). `job_schedule_status` always returns a row, so `schedule_status` is never NULL on a stored snapshot; only `forecast_end` and `slip_days` may be NULL. Phase D reads these values.
- **The planned curve is server-side** (decision X3): `job_planned_curve(job_id, from, to, client_only)` returns `(d, planned_pct)` for any date range, so the chart and Phase D's `portal_planned_curve` draw the full S-curve including future dates. Snapshots still store a frozen `planned_pct` for audit; a **re-baseline rewrites** the stored `planned_pct` of the job's snapshots (hook below), so staff and client history agree after a re-baseline.

```sql
-- up: Phase C. File: supabase/migrations/YYYYMMDDHHMM_c_updates_progress.sql (decision X16).
-- MUST be applied after Phase A's migration (YYYYMMDDHHMM_a_schedule_v2.sql): the SQL functions below are
-- LANGUAGE sql and bind job_tasks.weight / baseline_* / is_milestone, and call job_task_weight(), job_task_planned_pct(),
-- job_task_client_visible(), job_schedule_status() and job_visibility_guard(), at CREATE time. Additive only.
-- OWNER PREREQUISITE (X23): pg_cron and pg_net are enabled once in the Supabase dashboard BEFORE this migration (the owner does this once
-- for the whole programme). This file only runs CREATE EXTENSION IF NOT EXISTS (a no-op once enabled) and never describes how to enable them.

-- ---------- permission atom (data, not schema; decision X11) ----------
-- erp_roles.permissions is a jsonb OBJECT {atom: true} (verified live); there is no super_admin wildcard, so seed explicitly.
UPDATE erp_roles
   SET permissions = permissions || '{"ops:updates:write": true}'::jsonb
 WHERE name IN ('super_admin', 'company_admin', 'operations_tech');

-- ---------- job_updates ----------
CREATE TABLE job_updates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    uuid NOT NULL REFERENCES companies(id),
  job_id        uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  task_id       uuid REFERENCES job_tasks(id) ON DELETE SET NULL,
  kind          text NOT NULL DEFAULT 'general'
                CHECK (kind IN ('site','workshop','milestone','general')),
  title         text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 160),
  body          text CHECK (body IS NULL OR char_length(body) <= 4000),
  occurred_on   date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Port_of_Spain')::date),
  created_by    uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  client_visible boolean NOT NULL DEFAULT false,
  published_at  timestamptz,
  published_by  uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX job_updates_job_idx         ON job_updates (job_id);
CREATE INDEX job_updates_company_job_idx ON job_updates (company_id, job_id, occurred_on DESC, created_at DESC);

-- ---------- job_update_photos ----------
CREATE TABLE job_update_photos (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    uuid NOT NULL REFERENCES companies(id),
  job_id        uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  update_id     uuid NOT NULL REFERENCES job_updates(id) ON DELETE CASCADE,
  storage_key   text NOT NULL,   -- <company_id>/<job_id>/<update_id>/<photo_id>.jpg  (inside bucket job-updates)
  thumb_key     text NOT NULL,   -- <company_id>/<job_id>/<update_id>/<photo_id>_t.jpg
  caption       text CHECK (caption IS NULL OR char_length(caption) <= 200),
  sort_order    integer NOT NULL DEFAULT 0,
  width         integer,
  height        integer,
  bytes         integer,
  client_visible boolean NOT NULL DEFAULT false,
  created_by    uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX job_update_photos_job_idx         ON job_update_photos (job_id);
CREATE INDEX job_update_photos_company_job_idx ON job_update_photos (company_id, job_id);
CREATE INDEX job_update_photos_update_idx      ON job_update_photos (update_id, sort_order);

-- ---------- job_progress_snapshots ----------
CREATE TABLE job_progress_snapshots (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    uuid NOT NULL REFERENCES companies(id),
  job_id        uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  snapshot_date date NOT NULL,
  actual_pct    numeric(5,2) NOT NULL CHECK (actual_pct BETWEEN 0 AND 100),
  planned_pct   numeric(5,2) NOT NULL CHECK (planned_pct BETWEEN 0 AND 100),
  planned_basis text NOT NULL DEFAULT 'baseline' CHECK (planned_basis IN ('baseline','mixed','current_dates')),
  schedule_status text,          -- one of Phase A's five labels from job_schedule_status() (X21): 'On track' | 'At risk' | 'Late' | 'Complete' | 'On hold'; the function always returns a row, so this is never NULL on a system-written snapshot
  forecast_end  date,            -- from job_schedule_status(); may be NULL
  slip_days     integer,         -- from job_schedule_status(); may be NULL
  task_count    integer NOT NULL DEFAULT 0,
  source        text NOT NULL DEFAULT 'nightly' CHECK (source IN ('nightly','save','backfill')),
  client_visible boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_progress_snapshots_job_date_uniq UNIQUE (job_id, snapshot_date)
);
CREATE INDEX job_progress_snapshots_job_idx         ON job_progress_snapshots (job_id);
CREATE INDEX job_progress_snapshots_company_job_idx ON job_progress_snapshots (company_id, job_id);

CREATE TRIGGER trg_job_updates_touch   BEFORE UPDATE ON job_updates          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_job_photos_touch    BEFORE UPDATE ON job_update_photos    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_job_snapshots_touch BEFORE UPDATE ON job_progress_snapshots FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- visibility guard (shared; defined by Phase A, decisions X5, X19) ----------
-- job_visibility_guard() is NOT created here. It enforces: flipping client_visible needs ops:work-orders:approve;
-- editing client-facing wording of a visible row auto-unpublishes it; every change writes a 'visibility_changed' row to job_audit_log.
-- Argument contract (Phase A): TG_ARGV[0] = ONE comma-separated string of wording columns; TG_ARGV[1] = domain atom, '' for none.
-- Do NOT pass the columns as separate arguments: the guard would read the second one as a permission atom.
CREATE TRIGGER trg_job_updates_vis BEFORE INSERT OR UPDATE ON job_updates
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('title,body,kind,occurred_on', '');
CREATE TRIGGER trg_job_photos_vis  BEFORE INSERT OR UPDATE ON job_update_photos
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('', '');
CREATE TRIGGER trg_job_snap_vis    BEFORE UPDATE ON job_progress_snapshots
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('', '');
-- Snapshots are deliberately UPDATE-only: the definer upsert INSERTs a row that copies an already-approved job-level client_visible,
-- which must neither be re-gated against the on-save caller's perms nor write one audit row per night. Direct client INSERT is
-- already refused by the WITH CHECK (false) policy, so no ungated publish path exists.
-- Trigger firing order is alphabetical by name: touch (set_updated_at), vis (guard), then the publish stamp below runs LAST so
-- it sees the guard's final client_visible (an auto-unpublish must not be stamped as a publish).

-- Publish stamp for updates: the guard does not set published_at, so do it here (X20 note: portal_updates orders on coalesce(published_at, created_at)).
CREATE OR REPLACE FUNCTION job_updates_stamp_published() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.client_visible AND (TG_OP = 'INSERT' OR NOT OLD.client_visible) THEN
    NEW.published_at := now();
    NEW.published_by := COALESCE(NEW.published_by,
                                 (SELECT u.id FROM erp_users u WHERE u.auth_user_id = auth.uid() LIMIT 1));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION job_updates_stamp_published() FROM PUBLIC, anon, authenticated;   -- trigger-only
CREATE TRIGGER trg_job_updates_wpub BEFORE INSERT OR UPDATE ON job_updates
  FOR EACH ROW EXECUTE FUNCTION job_updates_stamp_published();

-- ---------- snapshot column guard (decision X4) ----------
-- Only the snapshot functions below set the transaction-local flag app.snapshot_rpc = 'on'. Everyone else (PostgREST users, including
-- staff with approve) may change client_visible only. auth.uid() is NOT used: it stays set inside SECURITY DEFINER functions.
-- PostgREST cannot set a GUC. A manual correction by an operator needs: SET LOCAL app.snapshot_rpc = 'on'; inside the transaction.
CREATE OR REPLACE FUNCTION job_snapshots_guard_columns() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_setting('app.snapshot_rpc', true) IS DISTINCT FROM 'on'
     AND (NEW.company_id, NEW.job_id, NEW.snapshot_date, NEW.actual_pct, NEW.planned_pct, NEW.planned_basis,
          NEW.schedule_status, NEW.forecast_end, NEW.slip_days, NEW.task_count, NEW.source)
         IS DISTINCT FROM
         (OLD.company_id, OLD.job_id, OLD.snapshot_date, OLD.actual_pct, OLD.planned_pct, OLD.planned_basis,
          OLD.schedule_status, OLD.forecast_end, OLD.slip_days, OLD.task_count, OLD.source) THEN
    RAISE EXCEPTION 'snapshots are system-written' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION job_snapshots_guard_columns() FROM PUBLIC, anon, authenticated;   -- trigger-only

CREATE TRIGGER trg_job_snap_cols BEFORE UPDATE ON job_progress_snapshots
  FOR EACH ROW EXECUTE FUNCTION job_snapshots_guard_columns();

-- ---------- progress computation (decisions X1, X20: CALL Phase A's helpers, never re-derive) ----------
-- Phase A owns the rule: job_task_weight(is_milestone, weight, start_date, end_date) (milestones = 0, NULL weight = duration, undated = 1) and
-- job_task_planned_pct(baseline_start, baseline_end, start_date, end_date, on) (0..100, baseline with current-date fallback, undated = 0).
-- Both are granted to authenticated by Phase A, so the invoker functions below can call them for a staff session.
-- Rounding (X20): SQL stores 2 dp (numeric(5,2)); every UI rounds half-up to a whole number for display. The shared fixture compares both.

-- Weighted planned % for one job on one date. p_client_only = true restricts to tasks for which Phase A's job_task_client_visible(task_id)
-- is true (task visible AND (no phase OR phase visible); X22), so Gantt, KPIs and curve share one predicate.
-- SECURITY INVOKER on purpose: RLS on job_tasks applies to a staff caller; a client JWT has no erp_users row, so my_company_ids() is empty and it sees nothing.
-- Definer callers (the snapshot functions, Phase D's portal_planned_curve) run as the function owner and see all rows.
CREATE OR REPLACE FUNCTION job_planned_pct_on(p_job uuid, p_on date, p_client_only boolean DEFAULT false)
RETURNS numeric LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT round(SUM(job_task_weight(tk.is_milestone, tk.weight, tk.start_date, tk.end_date)
                   * job_task_planned_pct(tk.baseline_start, tk.baseline_end, tk.start_date, tk.end_date, p_on))
               / NULLIF(SUM(job_task_weight(tk.is_milestone, tk.weight, tk.start_date, tk.end_date)), 0), 2)
    FROM job_tasks tk
   WHERE tk.job_id = p_job AND NOT tk.is_milestone
     AND (NOT p_client_only OR job_task_client_visible(tk.id));
$$;
-- Invoker + RLS-scoped, so safe to expose; REQUIRED because the invoker function job_planned_curve below calls it as the caller
-- (EXECUTE on a callee is checked against the calling role), and staff chart calls would otherwise fail with "permission denied".
REVOKE ALL ON FUNCTION job_planned_pct_on(uuid, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_planned_pct_on(uuid, date, boolean) TO authenticated;

-- Weighted actual and planned % for one job on one date (all non-milestone tasks: this is the staff basis stored in snapshots).
CREATE OR REPLACE FUNCTION job_progress_calc(p_job uuid, p_on date,
    OUT actual_pct numeric, OUT planned_pct numeric, OUT planned_basis text)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH t AS (
    SELECT job_task_weight(is_milestone, weight, start_date, end_date) AS w,
           COALESCE(progress, 0) AS prog,
           (baseline_start IS NOT NULL AND baseline_end IS NOT NULL) AS has_b
      FROM job_tasks WHERE job_id = p_job AND NOT is_milestone)
  SELECT round(sum(w * prog) / NULLIF(sum(w), 0), 2),
         job_planned_pct_on(p_job, p_on, false),
         CASE WHEN bool_and(has_b) THEN 'baseline' WHEN bool_or(has_b) THEN 'mixed' ELSE 'current_dates' END
    FROM t;
$$;
REVOKE ALL ON FUNCTION job_progress_calc(uuid, date) FROM PUBLIC, anon, authenticated;   -- called by the definer functions below

-- Planned S-curve for any range (decision X3). Staff chart calls it with p_client_only = false; Phase D wraps it as portal_planned_curve with true.
-- Range is capped at 800 days. Callable by authenticated users; RLS (invoker) decides what rows they can see.
-- Its callee job_planned_pct_on is granted to authenticated above, so the chain curve -> pct_on -> Phase A's helpers works under a staff JWT.
CREATE OR REPLACE FUNCTION job_planned_curve(p_job_id uuid, p_from date, p_to date, p_client_only boolean DEFAULT false)
RETURNS TABLE (d date, planned_pct numeric)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT g::date, job_planned_pct_on(p_job_id, g::date, p_client_only)
    FROM generate_series(p_from, LEAST(p_to, p_from + 800), interval '1 day') g
   WHERE p_to >= p_from;
$$;
REVOKE ALL ON FUNCTION job_planned_curve(uuid, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_planned_curve(uuid, date, date, boolean) TO authenticated;

-- Internal upsert (idempotent on job_id + snapshot_date). Not callable by clients.
-- Sets the transaction-local flag that lets the column guard through; clears it before returning.
CREATE OR REPLACE FUNCTION job_progress_snapshot_upsert(p_job uuid, p_date date, p_source text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM set_config('app.snapshot_rpc', 'on', true);
  INSERT INTO job_progress_snapshots (company_id, job_id, snapshot_date, actual_pct, planned_pct, planned_basis,
                                      schedule_status, forecast_end, slip_days, task_count, source, client_visible)
  SELECT j.company_id, j.id, p_date, k.actual_pct, k.planned_pct, k.planned_basis,
         ss.status, ss.forecast_end, ss.slip_days,
         (SELECT count(*) FROM job_tasks WHERE job_id = j.id), p_source,
         COALESCE((SELECT bool_or(s.client_visible) FROM job_progress_snapshots s WHERE s.job_id = j.id), false)
    FROM jobs j, LATERAL job_progress_calc(j.id, p_date) k
    LEFT JOIN LATERAL job_schedule_status(j.id) ss ON true   -- Phase A (X2); evaluated at run time
   WHERE j.id = p_job AND k.actual_pct IS NOT NULL
  ON CONFLICT (job_id, snapshot_date) DO UPDATE
     SET actual_pct = EXCLUDED.actual_pct, planned_pct = EXCLUDED.planned_pct, planned_basis = EXCLUDED.planned_basis,
         schedule_status = EXCLUDED.schedule_status, forecast_end = EXCLUDED.forecast_end, slip_days = EXCLUDED.slip_days,
         task_count = EXCLUDED.task_count, source = EXCLUDED.source, updated_at = now();
  PERFORM set_config('app.snapshot_rpc', '', true);
END $$;
REVOKE ALL ON FUNCTION job_progress_snapshot_upsert(uuid, date, text) FROM PUBLIC, anon, authenticated;

-- On-save RPC called by the ERP after task progress is saved (debounced). The permission check is re-done inside the definer function.
CREATE OR REPLACE FUNCTION snapshot_job_progress(p_job uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT user_has_perm('ops:work-orders:write')
     OR NOT EXISTS (SELECT 1 FROM jobs WHERE id = p_job AND company_id IN (SELECT my_company_ids())) THEN
    RAISE EXCEPTION 'not permitted' USING ERRCODE = '42501';
  END IF;
  PERFORM job_progress_snapshot_upsert(p_job, (now() AT TIME ZONE 'America/Port_of_Spain')::date, 'save');
END $$;
REVOKE ALL ON FUNCTION snapshot_job_progress(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION snapshot_job_progress(uuid) TO authenticated;   -- the one intended RPC

-- Nightly sweep (cron only).
CREATE OR REPLACE FUNCTION snapshot_all_jobs_progress() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT id FROM jobs WHERE status IN ('Received','In Progress','On Hold') LOOP
    PERFORM job_progress_snapshot_upsert(r.id, (now() AT TIME ZONE 'America/Port_of_Spain')::date, 'nightly');
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION snapshot_all_jobs_progress() FROM PUBLIC, anon, authenticated;

-- ---------- re-baseline hook (decision X3) ----------
-- When baseline dates, weights or the milestone flag change on job_tasks (Phase A's lock_job_baseline RPC, or any later edit), rewrite the
-- stored planned_pct / planned_basis of every snapshot of the affected jobs, and refresh today's row so its status fields follow.
-- Statement-level trigger with transition tables: one pass per statement, however many tasks changed.
CREATE OR REPLACE FUNCTION job_progress_rebaseline(p_job uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM set_config('app.snapshot_rpc', 'on', true);
  UPDATE job_progress_snapshots s
     SET planned_pct = k.planned_pct, planned_basis = k.planned_basis, updated_at = now()
    FROM (SELECT d.snapshot_date, c.planned_pct, c.planned_basis
            FROM job_progress_snapshots d, LATERAL job_progress_calc(p_job, d.snapshot_date) c
           WHERE d.job_id = p_job) k
   WHERE s.job_id = p_job AND s.snapshot_date = k.snapshot_date AND k.planned_pct IS NOT NULL;
  PERFORM set_config('app.snapshot_rpc', '', true);
  PERFORM job_progress_snapshot_upsert(p_job, (now() AT TIME ZONE 'America/Port_of_Spain')::date, 'save');
END $$;
REVOKE ALL ON FUNCTION job_progress_rebaseline(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION job_tasks_rebaseline_hook() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT n.job_id
             FROM new_rows n JOIN old_rows o ON o.id = n.id
            WHERE (n.baseline_start, n.baseline_end, n.weight, n.is_milestone)
                  IS DISTINCT FROM (o.baseline_start, o.baseline_end, o.weight, o.is_milestone) LOOP
    PERFORM job_progress_rebaseline(r.job_id);
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION job_tasks_rebaseline_hook() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_job_tasks_rebaseline AFTER UPDATE ON job_tasks
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION job_tasks_rebaseline_hook();

-- ---------- nightly schedule (pg_cron enabled beforehand as an owner prerequisite, X23) ----------
-- 03:55 UTC = 23:55 America/Port_of_Spain (UTC-4, no DST), so the snapshot lands on the local business day.
-- Unlike the overdue-notification script this calls SQL directly: no pg_net, no service-role key.
CREATE EXTENSION IF NOT EXISTS pg_cron;   -- no-op once the prerequisite is done
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'job-progress-snapshots';
SELECT cron.schedule('job-progress-snapshots', '55 3 * * *', $$SELECT snapshot_all_jobs_progress();$$);

-- ---------- one-off backfill (run once after Phase A has populated baselines/weights) ----------
-- Writes today's row only, including schedule_status (one of the five labels) / forecast_end / slip_days from job_schedule_status() (no historical status exists).
-- SELECT job_progress_snapshot_upsert(id, (now() AT TIME ZONE 'America/Port_of_Spain')::date, 'backfill')
--   FROM jobs WHERE status IN ('Received','In Progress','On Hold');
```

### Progress and planned-curve formulas

Phase C **calls Phase A's progress rule (decisions X1, X20) and defines nothing of its own**: the SQL here uses `job_task_weight` and `job_task_planned_pct`, never a re-derivation. For a job on date `d`, over all tasks that are not milestones (`is_milestone = false`; milestones are excluded whatever their `weight`):

- Task weight `w = job_task_weight(...) = COALESCE(weight, duration_days)`, with `duration_days = max(end_date - start_date + 1, 1)` and `1` for a task missing either date.
- `actual(d) = Σ(w × progress) / Σ(w)` using current `progress` 0-100.
- `planned(d) = 100 × Σ(w × f) / Σ(w)` where, per task, `s = COALESCE(baseline_start, start_date)`, `e = COALESCE(baseline_end, end_date)`: `f = 0` if `d < s`; `f = 1` if `d >= e`; otherwise `f = (d - s + 1) / (e - s + 1)` (inclusive days). A task with no dates at all keeps its weight in the denominator and contributes `f = 0`. `planned_basis` records `baseline`, `mixed` or `current_dates`.
- **Assumption, stated explicitly:** work is linear within each task between its dates; calendar days, no working-calendar or holiday adjustment. There is no phase-level weight (Phase A defines none); `weight` is job-wide.
- **Client basis (`p_client_only = true`)** applies the same formula over the tasks for which Phase A's `job_task_client_visible(task_id)` is true (task visible and, if it has a phase, that phase visible; X22). The stored snapshot `planned_pct` is always the staff basis (all non-milestone tasks).
- **Rounding (X20).** SQL results are stored and returned at 2 dp; every UI rounds half-up to a whole number for display (so the chart label, the variance chip and Phase A's KPI agree). The shared fixture compares both the 2 dp SQL values and the half-up integers.
- **One rule, one SQL source, two mirrors.** SQL `job_progress_calc` / `job_planned_pct_on` get the rule by calling Phase A's helpers; the browser function `plannedPctOn(tasks, date)` (used for the instant "planned today" marker before a save round-trip) and Phase A's `jcSchedCompute` mirror it. A **shared fixture file** (owned by Phase A) is run against all of them; Phase C's gate is the parity test in the Test plan, which must pass before release and again whenever Phase A changes the rule.

### Backfill strategy

Actual history cannot be reconstructed (progress was overwritten in place, and `job_tasks` has 0 rows today). Therefore: no fabricated history. After Phase A seeds baselines, run the backfill statement once to give every active job a first snapshot dated today; the curve's actual line starts there. The planned curve needs no backfill because `job_planned_curve` computes it for any date range. Sanity check before backfill: confirm `job_tasks` has rows, or the function returns no snapshot (guarded by `actual_pct IS NOT NULL`). The status fields of the backfilled row are those of today, as computed by `job_schedule_status()` (always a row, one of the five labels).

## RLS and permissions

Permission atoms: reading uses existing `ops:work-orders:read`; creating/editing/deleting updates and photos uses **new `ops:updates:write`**; publishing (flipping `client_visible`) and sharing the curve use existing `ops:work-orders:approve`; the on-save snapshot RPC uses `ops:work-orders:write`. Note `user_has_perm` is not company-scoped, so every policy also constrains `company_id IN (SELECT my_company_ids())`.

Role grants (live roles, verified):

| Role | Read feed/curve | Write updates and photos | Publish |
|---|---|---|---|
| super_admin | yes | yes (migration adds atom) | yes |
| company_admin | yes | yes (migration adds atom) | yes |
| operations_tech | yes | yes (migration adds atom; site and workshop staff) | yes (has `ops:work-orders:approve`) |
| viewer | yes | no | no |
| finance_manager | no (no `ops:work-orders:read`) | no | no |
| sales_rep | no | no | no |
| Office Admin | no | no | no |

This deviates from `job_tasks` (whose SELECT is company-wide) by also requiring `ops:work-orders:read`, because photos carry more privacy risk than schedule rows.

```sql
ALTER TABLE job_updates           ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_update_photos     ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_progress_snapshots ENABLE ROW LEVEL SECURITY;

-- job_updates
CREATE POLICY job_updates_select ON job_updates FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:read'));
CREATE POLICY job_updates_insert ON job_updates FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write')
              AND (client_visible = false OR user_has_perm('ops:work-orders:approve')));
CREATE POLICY job_updates_update ON job_updates FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write'));
CREATE POLICY job_updates_delete ON job_updates FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write')
         AND (is_company_admin(company_id)
              OR created_by IN (SELECT id FROM erp_users WHERE auth_user_id = auth.uid())));

-- job_update_photos
CREATE POLICY job_update_photos_select ON job_update_photos FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:read'));
CREATE POLICY job_update_photos_insert ON job_update_photos FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write')
              AND (client_visible = false OR user_has_perm('ops:work-orders:approve')));
CREATE POLICY job_update_photos_update ON job_update_photos FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write'));
CREATE POLICY job_update_photos_delete ON job_update_photos FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:updates:write'));

-- job_progress_snapshots: written by definer functions only; staff may toggle client_visible
CREATE POLICY job_progress_snapshots_select ON job_progress_snapshots FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:read'));
CREATE POLICY job_progress_snapshots_insert ON job_progress_snapshots FOR INSERT TO authenticated
  WITH CHECK (false);
CREATE POLICY job_progress_snapshots_update ON job_progress_snapshots FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:approve'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:approve'));
CREATE POLICY job_progress_snapshots_delete ON job_progress_snapshots FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND is_company_admin(company_id));

-- ---------- storage: private bucket job-updates ----------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('job-updates', 'job-updates', false, 5242880, ARRAY['image/jpeg'])
ON CONFLICT (id) DO NOTHING;

-- Path: <company_id>/<job_id>/<update_id>/<file>. Folder 1 must be one of the caller's companies.
CREATE POLICY "job-updates read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-updates'
         AND (storage.foldername(name))[1] IN (SELECT c::text FROM my_company_ids() c)
         AND user_has_perm('ops:work-orders:read'));
CREATE POLICY "job-updates upload" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-updates'
         AND (storage.foldername(name))[1] IN (SELECT c::text FROM my_company_ids() c)
         AND EXISTS (SELECT 1 FROM jobs j WHERE j.id::text = (storage.foldername(name))[2]
                                            AND j.company_id::text = (storage.foldername(name))[1])
         AND user_has_perm('ops:updates:write'));
CREATE POLICY "job-updates delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'job-updates'
         AND (storage.foldername(name))[1] IN (SELECT c::text FROM my_company_ids() c)
         AND user_has_perm('ops:updates:write'));
-- No UPDATE policy: uploads never use x-upsert; filenames are unique UUIDs. Anonymous access: none.

-- down (commented; run in this order). Phase A's job_visibility_guard() is NOT dropped here: Phase A owns it.
-- DROP TRIGGER trg_job_tasks_rebaseline ON job_tasks;
-- DROP FUNCTION job_updates_stamp_published();   -- after the tables below are dropped (their triggers use it)
-- SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'job-progress-snapshots';
-- -- first empty the bucket through the Storage API (SQL deletes of storage.objects leave blobs behind), then:
-- DROP POLICY "job-updates read"   ON storage.objects;
-- DROP POLICY "job-updates upload" ON storage.objects;
-- DROP POLICY "job-updates delete" ON storage.objects;
-- DELETE FROM storage.buckets WHERE id = 'job-updates';
-- DROP FUNCTION job_tasks_rebaseline_hook(); DROP FUNCTION job_progress_rebaseline(uuid);
-- DROP FUNCTION snapshot_all_jobs_progress(); DROP FUNCTION snapshot_job_progress(uuid);
-- DROP FUNCTION job_progress_snapshot_upsert(uuid, date, text); DROP FUNCTION job_planned_curve(uuid, date, date, boolean);
-- DROP FUNCTION job_progress_calc(uuid, date); DROP FUNCTION job_planned_pct_on(uuid, date, boolean);
-- DROP TABLE job_update_photos; DROP TABLE job_updates; DROP TABLE job_progress_snapshots;   -- drops their triggers
-- DROP FUNCTION job_snapshots_guard_columns();
-- -- down for the seed (X11):
-- UPDATE erp_roles SET permissions = permissions - 'ops:updates:write';
```

## Staff UI (ERP)

New **Updates** card in the job form, placed directly under the existing "Schedule & Tasks" card (`index.html`, ~line 3382), plus the **Progress curve** card directly above it (or inside Phase A's overview screen when that exists). Both visible with `ops:work-orders:read`; composer controls need `ops:updates:write`; Publish needs `ops:work-orders:approve`. All user strings go through `escHTML`.

**Progress curve card** (binds to `job_progress_snapshots` rows for the job, plus `job_tasks` for the live planned curve):

- Header: "Progress curve", right-aligned variance chip: `actual − planned` points today (green if >= 0, gold if within -5, red below; thresholds are an Open question).
- Chart: dependency-free inline SVG, `viewBox 0 0 720 260`, margins 40/16/28/12, `role="img"` with an `aria-label` summarising actual, planned and variance; a collapsed `<details>` holds an accessible table of the data.
  - X axis: dates from `min(earliest baseline_start, first snapshot)` to `max(latest baseline_end, today)`, ticks per week or month by span. Y axis: 0–100 % with gridlines at 25 %.
  - **Planned**: dashed polyline (`stroke-dasharray 6 4`, `var(--text-3)`), fetched with one `job_planned_curve(job_id, from, to, false)` RPC call (one point per day, thinned in the browser to about 200 points); `plannedPctOn` (same rule, X1) is used only for the instant "planned today" marker before a save round-trip.
  - **Actual**: solid 2.5 px `var(--gold)` polyline through snapshot `(snapshot_date, actual_pct)`; end-point dot with the label "64% actual" (value of the latest snapshot); planned value at today shown as a small hollow marker.
  - **TODAY**: vertical line at today in `var(--green)` with a "TODAY" pill at the top.
  - Hover/tap: nearest snapshot tooltip (date, actual, planned, schedule status, source). Footnote when `planned_basis != 'baseline'`: "Planned curve uses current task dates (no baseline set)."
  - Empty state when fewer than 2 snapshots: "Progress history starts once tasks have weights and progress; check back tomorrow."
- Staff toggle "Share curve with client" (approve perm) sets `client_visible` on all job snapshots.
- After any task progress save, the schedule card calls `snapshot_job_progress(job_id)` (debounced 3 s) and refreshes the chart.

**Updates card** (mobile-first; site staff use phones):

- **Composer** (collapsed to a single "+ Add update" button, full-width, 44 px targets): kind segmented control (Site / Workshop / Milestone / General), Title (required), Notes (textarea), Date (default today), optional "Linked task" select from `job_tasks`, photo picker with two buttons ("Take photo" using `capture="environment"`, "Choose photos"), thumbnail strip with per-photo progress/remove/caption, privacy hint "Photos stay internal until you publish." Primary button "Save update" (saved as internal draft).
- **Feed**: reverse-chronological by `occurred_on`, then `created_at`; each entry renders `Title — Workshop · 17 Oct · 6 photos` with a kind chip, an Internal or Published badge, notes, and a 3-column thumbnail grid (thumbnails via signed URL; tap opens a lightbox with the full image, caption and author). 20 per page with "Load more". Overflow menu: Edit, Delete (author or company_admin), Publish/Unpublish.
- **Publish dialog** (approve perm): shows the exact title and notes that clients will see, a checklist of photos (all unticked by default; staff tick those to release), and a warning: "Check photos for other clients' equipment, people's faces and site-location details." Confirm sets update, selected photos and `published_at/by`. Unpublish reverts the update (photo flags are kept but ignored while the update is hidden).
- **Upload pipeline** (vanilla JS, per photo): validate `file.type` starts with `image/` and raw size <= 25 MB, up to 12 photos per update; decode with `createImageBitmap(file, {imageOrientation: 'from-image'})`; draw to a canvas scaled so the long edge is <= 1600 px (never upscale); `canvas.toBlob('image/jpeg', 0.82)` (re-encode at lower quality if > 5 MB); repeat at 400 px / 0.7 for the thumbnail. Re-encoding through canvas strips EXIF, including GPS coordinates. Generate `update_id` and `photo_id` with `crypto.randomUUID()`, insert the `job_updates` row first, then `POST /storage/v1/object/job-updates/<company_id>/<job_id>/<update_id>/<photo_id>.jpg` (and `_t.jpg`) without `x-upsert`, then insert the `job_update_photos` row. Failures retry per photo; a failed photo row never leaves a visible placeholder. HEIC files that the browser cannot decode produce a "convert to JPEG" toast.
- **Viewing**: batch-sign thumbnails for the visible page with one `POST /storage/v1/object/sign/job-updates` (expiry 3600 s), mirroring the signed-URL call used for `job-drawings` in `jcViewDrawingPdf`; full images are signed on tap. URLs are never stored.
- **Deletion**: deleting a photo or update first removes the storage objects (`DELETE /storage/v1/object/job-updates` with `prefixes`, as `jcHardDeleteDrawing` does for drawings), then the database rows; cascade never removes blobs.
- **Job deletion** (`jcDeleteJob`, ~line 8642): before `sbDelete('jobs', ...)`, select `storage_key, thumb_key` from `job_update_photos` for the job, delete those objects in batches of 100, and **abort the job deletion if storage removal fails** (unlike the drawing flow, which proceeds with a warning), because these files are privacy-sensitive.
- **Orphan safety net**: an admin-only diagnostic lists objects in `job-updates` whose job folder no longer exists in `jobs` (read-only SQL against `storage.objects`; removal goes through the Storage API, never `DELETE` on `storage.objects`). Existing orphaned drawing files (see handoff note) can be swept by the same tool but that is not in Phase C scope.

## Client-facing surface

None in this phase: no client login exists and the bucket has no client storage policy. What Phase C provides for Phase D, all behind `client_visible`:

- `portal_updates` (a Phase D `portal_*` **function**, decision X15) reads `job_updates` where `client_visible` and joins `job_update_photos` where both the update and the photo are `client_visible`; whitelist columns only: update `id, job_id, kind, title, body, occurred_on, published_at` (ordered and paged on `coalesce(published_at, created_at)`; Phase C's publish-stamp trigger sets `published_at` whenever `client_visible` becomes true, so the fallback is only defensive); photo `id, caption, sort_order, width, height`. **Staff attribution (decision X10):** the feed may show the publishing staff member's **first name plus a role label** (for example "Q2 project engineer"), derived by Phase D from `erp_users` inside the function. It must **not** expose `created_by`, `published_by` (the id), `task_id`, `storage_key`, `thumb_key` or `company_id`, nor any staff email, phone number or full name.
- `portal_progress_curve` reads snapshots where `client_visible`: `snapshot_date, actual_pct, planned_pct, schedule_status, forecast_end, slip_days`. Phase D reads these stored values and does not recompute the status (decision X2). The full planned S-curve, including future dates, comes from `portal_planned_curve`, a Phase D definer wrapper around `job_planned_curve(job_id, from, to, p_client_only => true)`; it returns only `(date, planned_pct)` from client-visible tasks and is gated by the job's snapshot `client_visible` flag, so clients get no `job_tasks` access and no task names or weights leak. Because a re-baseline rewrites snapshot `planned_pct` (hook above), the stored and live planned values stay consistent.
- Client image access: Phase D must mint short-lived signed URLs through an RPC or edge function that first checks the caller's project access and both visibility flags. Phase C never adds a client storage policy.
- **Privacy.** Photos may show other clients' equipment, identifiable people or site-location details, and free-text notes can contain internal remarks. Therefore everything defaults to internal, publish is a deliberate act with a review dialog, photos are individually releasable, edits to published wording auto-unpublish, and EXIF/GPS is stripped at upload. Costs and quote values never appear in feed fields; staff appear only as first name plus role label (X10).

## Migration and rollout

1. Prerequisite: **Phase A's migration (`YYYYMMDDHHMM_a_schedule_v2.sql`) applied first** (decision X16 order: D0a, A, B, then C) and populated (baseline dates and weights); Phase C's migration fails at CREATE time otherwise, because its SQL functions bind A's columns and functions. Owner prerequisite (X23, step 0 of the programme order): `pg_cron` and `pg_net` already enabled once in the dashboard (neither is installed live as of 2026-10-19); this migration only runs `CREATE EXTENSION IF NOT EXISTS`.
2. Apply the up migration `YYYYMMDDHHMM_c_updates_progress.sql` (timestamped name, X16; additive apart from one trigger on `job_tasks`; reversible via the down section). The bucket and policies ship in the same migration. Re-run the Q-D definer-function sweep afterwards (X13): the only authenticated-executable functions added are `snapshot_job_progress` (definer RPC) and the two invoker, RLS-scoped functions `job_planned_curve` and `job_planned_pct_on`; none is executable by anon.
3. Ship the ERP changes behind existing role checks: Updates card first (no dependency on snapshots), then the curve card and on-save RPC call.
4. Run the one-off backfill statement; confirm `SELECT count(*) FROM job_progress_snapshots` equals the number of active jobs with tasks.
5. Confirm tomorrow's nightly run: `SELECT * FROM cron.job_run_details WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname = 'job-progress-snapshots')`.
6. Rollback: unschedule cron, empty the bucket via the Storage API, run the down section. No existing table column or policy was altered (only the `job_tasks` trigger is dropped), so the ERP continues to work with the UI card hidden.

## Test plan

- **RLS with a real non-privileged user** (not service role): viewer can read but not insert; sales_rep and finance_manager see zero rows; operations_tech can write and publish; a user in company B cannot read, insert or sign company A's photos or rows; direct insert into `job_progress_snapshots` is refused; a write-only user cannot set `client_visible = true` (insert or update).
- **Storage**: upload with a mismatched company or job folder is rejected; `image/png` and an over-5 MB file are rejected; anonymous request returns 400/403; signed URL expires.
- **Formula parity**: fixture jobs (weights 1/2/3, tasks before, during, after baseline, no-baseline fallback, weight 0 milestone, no tasks) must give identical planned/actual values in `job_progress_calc`, `plannedPctOn` and Phase A's `jcSchedCompute`. The test runs **Phase A's shared fixture file** (decisions X1, X20), extended with: NULL weight (duration-weighted, incl. one-day and undated tasks), a milestone with a non-zero explicit weight (still excluded), baseline-vs-current-date fallback, and an explicit weight 0 task. It compares **both** the 2 dp SQL values and the half-up integer the UI displays. Release is blocked unless all implementations agree. A grep-style check confirms `job_planned_pct_on` and `job_progress_calc` call `job_task_weight` / `job_task_planned_pct` and contain no inline weight or fraction arithmetic.
- **Same-day double save (X4 regression)**: as a real staff user, call `snapshot_job_progress` twice on one day after changing a task's progress between calls; both calls succeed and the row holds the second values. Also after the nightly function has written the day's row. Direct `UPDATE job_progress_snapshots SET actual_pct = ...` through PostgREST as the same user, with or without `ops:work-orders:approve`, is refused (42501), while setting only `client_visible` is allowed for an approver.
- **Schedule status fields**: a snapshot's `schedule_status`, `forecast_end`, `slip_days` equal `job_schedule_status(job_id)` at write time. `job_schedule_status` always returns a row, so a job without dated tasks still stores a non-NULL `schedule_status` (one of On track, At risk, Late, Complete, On hold; X21) with possibly NULL `forecast_end` and `slip_days`. Fixtures cover all five labels: an On Hold job's nightly snapshot stores `On hold`, and the on-save snapshot of a completed job stores `Complete`.
- **Planned curve**: `job_planned_curve` for a fixture job matches `job_planned_pct_on` per day; with `p_client_only = true` a task excluded by Phase A's `job_task_client_visible` (task flag false, or its phase flag false) is excluded, and the result equals the predicate used by Phase D's `portal_schedule` (X22); a client-style JWT (no `erp_users` row) calling it directly gets zero rows; a range over 800 days is capped. **Staff-JWT call chain (finding 3)**: as a real `operations_tech` user (not service role), `SELECT * FROM job_planned_curve(<job>, d1, d2, false)` succeeds and returns the same values as `job_planned_pct_on` per day (no "permission denied for function job_planned_pct_on"); `anon` gets permission denied on both functions.
- **Visibility guard attachment (X19)**: in `pg_trigger`, `trg_job_updates_vis` and `trg_job_photos_vis` are `BEFORE INSERT OR UPDATE` and `trg_job_snap_vis` is `BEFORE UPDATE`; their arguments are `('title,body,kind,occurred_on','')`, `('','')` and `('','')` (one comma-separated string, never separate column arguments).
- **Publish stamp (X20 note)**: a direct PATCH setting only `client_visible = true` on an update by an approver sets `published_at` (and `published_by`); an auto-unpublish does not set `published_at`; republishing refreshes it.
- **Re-baseline**: change `baseline_end` on a task via Phase A's lock RPC; every snapshot's stored `planned_pct` for that job changes to the new live value, other jobs' snapshots do not, and `actual_pct` history is untouched.
- **Idempotency**: call `snapshot_job_progress` twice and the nightly function twice on one day; row count is unchanged and values update.
- **Unpublish-on-edit** (delegated to `job_visibility_guard()`, attached with the X19 argument contract): editing the title of a published update clears `client_visible`; **editing the `body` of a published update (and, separately, its `kind` and `occurred_on`) unpublishes it and writes a `visibility_changed` row to `job_audit_log` with reason `wording_edited`**; editing only `task_id` or a photo caption does not unpublish an update; a write-only user (no approve) cannot flip `client_visible` on updates, photos or snapshots, and an INSERT of an update or photo with `client_visible = true` by a write-only user is refused by the guard as well as by the policy.
- **Upload**: portrait phone photo (EXIF orientation) renders upright; GPS tags absent from the stored file; 12 photos on a throttled connection with one forced failure retry correctly.
- **Deletion**: delete a photo, an update and a job with photos; confirm zero remaining objects under the prefix; simulate a storage failure and confirm the job is not deleted.
- **UI**: 375 px viewport (composer and feed usable one-handed), empty and single-snapshot chart states, 400-day job, dark theme variables, `escHTML` on a title containing `<img onerror>`.

## Risks

- **`job-drawings` policies are not tenant-scoped.** Live policies (`job-drawings auth read/upload/delete`) only check `bucket_id`, so any authenticated user can read or delete any company's drawings. Phase C deliberately does better for `job-updates`. The `job-drawings` fix belongs to Phase D0a (decision X12) and must land before the first client account; Phase C only cites it.
- **Orphaned blobs on deletion** (no cascade); mitigated by the delete flows and the diagnostic, but a crash between storage removal and row deletion can still strand objects.
- **Storage growth.** At 12 photos x about 400 KB per update, 100 updates is roughly 500 MB; the free plan's 1 GB is reachable. Monitor with `get_storage_usage`-style checks; thumbnails and 1600 px limits are the main control.
- **Dependence on Phase A** (helpers `job_task_weight`, `job_task_planned_pct`, `job_task_client_visible`, column names, `job_schedule_status()`, `job_visibility_guard()` argument contract). If Phase A's names or signatures differ, only `job_planned_pct_on`, `job_progress_calc`, `plannedPctOn`, the snapshot upsert and the three `CREATE TRIGGER` lines change.
- **Flag-based snapshot guard.** `app.snapshot_rpc` is a transaction-local GUC: PostgREST cannot set it, so only the definer functions (and an operator running raw SQL) can. A staff user able to run arbitrary SQL could forge it; that stays inside the staff trust boundary, as with `app.portal_rpc` (X6).
- **Status fields are as-of-run.** `job_schedule_status()` evaluates today's state, so a re-baseline refreshes only today's row; earlier rows keep the status they had.
- **`pg_cron` must be enabled beforehand (owner prerequisite, X23)**; if it is forgotten the migration's `CREATE EXTENSION IF NOT EXISTS pg_cron` or `cron.schedule` fails loudly rather than skipping the nightly job. Cron runs in UTC; wrong schedule shifts snapshots to the wrong local day. Idempotent upsert makes a missed night harmless but leaves a gap on the chart (the line interpolates).
- **`user_has_perm` is unscoped**: a user with the atom in one company could pass the perm check in another; policies pair it with `my_company_ids()`, so access is bounded by membership.
- **Client-side enforcement gaps**: limits of 12 photos and 25 MB raw are client-side; the bucket enforces only 5 MB and JPEG.

## Open questions

1. **Variance chip thresholds.** *Default: green >= 0 points, gold -5 to 0, red below -5.*
2. **Which statuses are snapshotted nightly?** *Default: Received, In Progress, On Hold; Completed jobs get a final snapshot via the on-save RPC when their last task is saved.*
3. **Should sales_rep and finance_manager see the feed?** *Default: no (they lack `ops:work-orders:read`); add if sales wants to show progress to clients.*
4. **Retention of photos after job Close.** *Default: keep indefinitely; revisit at 70 % of plan storage, then offer an admin "archive photos" action that deletes full-size images and keeps thumbnails.*
5. **Offline queueing of uploads for poor site signal.** *Default: not in Phase C; retries per photo only. Revisit if site staff report failures.*
6. **Edit-by-others rule**: may any `ops:updates:write` holder edit another person's update? *Default: yes; delete restricted to author or company_admin.*
7. **Client planned vs actual basis.** The client planned curve covers client-visible tasks only (X3) while stored `actual_pct` covers all non-milestone tasks, so the two lines can differ in basis when only some tasks are shared. *Default: accept, with a footnote in Phase D's chart; recommended practice is to share all tasks of a job or none. Alternative: Phase D stores a client-basis actual as well.*

## Acceptance criteria

- Migration applies (after Phase A's) and rolls back cleanly on a branch DB; no existing table column or policy altered (one `job_tasks` trigger added); `job_updates`, `job_update_photos`, `job_progress_snapshots` exist with RLS enabled and four explicit policies each.
- Every new definer function is revoked from PUBLIC and anon, and from `authenticated` unless it is an intended RPC (`snapshot_job_progress`); `job_planned_curve` and `job_planned_pct_on` are SECURITY INVOKER, RLS-scoped, granted to `authenticated` only (never anon), and a staff JWT can call the curve end to end; the Q-D sweep is clean.
- `ops:updates:write` exists on super_admin, company_admin and operations_tech only; a viewer cannot create anything; a write-only user cannot publish.
- A staff user on a 375 px phone can create an update with 6 photos; stored files are JPEG, long edge <= 1600 px, no EXIF/GPS, under `job-updates/<company_id>/<job_id>/<update_id>/`; another company's user cannot sign or read them.
- The feed shows entries like "Chute liners welded and inspected — Workshop · 17 Oct · 6 photos"; new updates are Internal; publishing requires the review dialog; editing a published update un-publishes it.
- The Progress curve renders planned (dashed) vs actual (solid), a TODAY marker and an "NN% actual" label from snapshots; planned values match the SQL function on Phase A's shared fixtures; two staff saves on the same day both succeed; a re-baseline rewrites stored planned values.
- Nightly cron produces exactly one snapshot per active job per local day; repeated runs and on-save calls never create duplicates.
- Deleting a photo, update or job leaves no storage objects; a failed storage removal blocks job deletion.
- The `portal_updates`, `portal_progress_curve` and `portal_planned_curve` whitelists above are documented for Phase D (snapshots carry `schedule_status`, `forecast_end`, `slip_days`) and no client-readable policy exists in Phase C.
