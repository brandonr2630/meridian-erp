-- Phase A2a: prepare_schedule_export (stable MSPDI UID assignment + export audit).
-- Spec: docs/specs/project-portal/phase-a2-projectlibre.md ("Data model" function comment, "Round-trip identity",
-- "RLS and permissions", "Test plan -> prepare_schedule_export"), X13, X26, N9. Order: after 202610271000_a2a_schema.sql
-- (needs job_phases.msp_uid / job_tasks.msp_uid) and Phase A (job_phases, job_tasks, job_audit_log, user_has_perm, my_company_ids).
-- Additive and idempotent (CREATE OR REPLACE). No table, column or policy changes. No new permission atoms.
-- Rollback: supabase/rollbacks/202610271200_a2a_export_down.sql
-- Built and tested on a throwaway Postgres 17 (bash supabase/tests/d0c_common/run.sh a2a_export). NOT applied to prod.
--
-- Two functions, one body of logic:
--   prepare_schedule_export(uuid, text)   the API function (spec name and signature). GRANTed to authenticated.
--       'staff'  : needs company membership of the job's company and ops:work-orders:read (in that company).
--       'client' : refused when the session role is authenticated, anon or authenticator. Allowed for service_role / the
--                  owner / any non-API session role. (A SECURITY DEFINER body cannot see its caller's current_user, because it
--                  is the owner by then; the session role setting 'role' is what PostgREST sets per request, so that is checked.)
--       anything else: refused ('unknown export kind').
--   schedule_export_core(uuid, text)      the shared body. EXECUTE only for its owner: Phase D's definer (portal_schedule)
--       calls this one for kind 'client' from inside a client's authenticated session, where the session-role check above
--       would (rightly) refuse. Not callable through the API (no grant to authenticated/anon).
-- Both are SECURITY DEFINER with a fixed search_path and must be owned by the role that owns lock_job_baseline (they are
-- created by the same migration role; checked in the tests).
--
-- Independent attack review (H1, M3): every row predicate is scoped to the job AND the job's company (rows of another company that carry the
-- job id are neither counted, nor numbered, nor given a uid; the a2a_schema trigger now stops them being written), and stored uids above
-- 100000000 (the a2a_schema CHECK range) are ignored when the next uid is chosen; if the space would be crossed the export refuses
-- ('uid space exhausted') before writing anything.

CREATE OR REPLACE FUNCTION schedule_export_core(p_job_id uuid, p_kind text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_company  uuid;
  v_job_no   text;
  v_read     boolean := false;
  v_write    boolean := false;
  v_max      integer;
  v_n        integer;
  v_assigned integer := 0;
  v_phases   integer;
  v_tasks    integer;
  v_pnull    integer;
  v_tnull    integer;
  k_uid_cap  constant integer := 100000000;   -- msp_uid CHECK range (a2a_schema, M3)
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('staff', 'client') THEN
    RAISE EXCEPTION 'unknown export kind';
  END IF;

  IF p_kind = 'staff' THEN
    -- membership first: a non-member learns nothing about the job (same message for missing and foreign jobs)
    SELECT j.company_id, j.job_no INTO v_company, v_job_no
      FROM jobs j WHERE j.id = p_job_id AND j.company_id IN (SELECT my_company_ids());
  ELSE
    SELECT j.company_id, j.job_no INTO v_company, v_job_no FROM jobs j WHERE j.id = p_job_id;
  END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'job not found'; END IF;

  -- the caller's atoms in THIS job's company (a role held only in another company does not count)
  SELECT coalesce(bool_or((r.permissions ->> 'ops:work-orders:read')::boolean), false),
         coalesce(bool_or((r.permissions ->> 'ops:work-orders:write')::boolean), false)
    INTO v_read, v_write
    FROM erp_users eu
    JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id AND ucr.company_id = v_company
    JOIN erp_roles r ON r.id = ucr.role_id
   WHERE eu.auth_user_id = v_uid AND eu.is_active = true;

  IF p_kind = 'staff' AND NOT v_read THEN
    RAISE EXCEPTION 'permission denied: ops:work-orders:read required';
  END IF;

  -- UIDs are created only by a writer (read-only callers export with temporary UIDs on the client side)
  IF v_write AND v_read THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_job_id::text));
    -- one UID space per job across BOTH tables; UID 0 is never used because max() starts at 0 and we add 1.
    -- H1: only rows of THIS job AND of the job's own company count (a row planted by another company's writer is ignored; the
    -- a2a_schema trigger now stops such rows from being written at all). M3: a stored uid above the cap (impossible through the
    -- CHECK, possible only in a database that predates it) is ignored, so v_max + n can never overflow integer.
    SELECT coalesce(max(u), 0) INTO v_max
      FROM (SELECT msp_uid AS u FROM job_phases WHERE job_id = p_job_id AND company_id = v_company AND msp_uid <= k_uid_cap
            UNION ALL
            SELECT msp_uid FROM job_tasks WHERE job_id = p_job_id AND company_id = v_company AND msp_uid <= k_uid_cap) s;
    SELECT count(*) INTO v_pnull FROM job_phases WHERE job_id = p_job_id AND company_id = v_company AND msp_uid IS NULL;
    SELECT count(*) INTO v_tnull FROM job_tasks  WHERE job_id = p_job_id AND company_id = v_company AND msp_uid IS NULL;
    IF v_max::bigint + v_pnull + v_tnull > k_uid_cap THEN RAISE EXCEPTION 'uid space exhausted' USING ERRCODE = '22023'; END IF;

    WITH n AS (SELECT id, row_number() OVER (ORDER BY sort_order, id) AS rn
                 FROM job_phases WHERE job_id = p_job_id AND company_id = v_company AND msp_uid IS NULL)
    UPDATE job_phases p SET msp_uid = v_max + n.rn FROM n WHERE p.id = n.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_assigned := v_n;
    v_max := v_max + v_n;

    WITH n AS (SELECT id, row_number() OVER (ORDER BY sort_order, id) AS rn
                 FROM job_tasks WHERE job_id = p_job_id AND company_id = v_company AND msp_uid IS NULL)
    UPDATE job_tasks t SET msp_uid = v_max + n.rn FROM n WHERE t.id = n.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_assigned := v_assigned + v_n;
  END IF;

  SELECT count(*) INTO v_phases FROM job_phases WHERE job_id = p_job_id AND company_id = v_company;
  SELECT count(*) INTO v_tasks  FROM job_tasks  WHERE job_id = p_job_id AND company_id = v_company;

  INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
  VALUES (p_job_id, v_job_no, v_uid,
          (SELECT u.full_name FROM erp_users u WHERE u.auth_user_id = v_uid LIMIT 1),
          'schedule_exported',
          'Schedule exported (' || p_kind || ')',
          jsonb_build_object('kind', p_kind, 'tasks', v_tasks, 'phases', v_phases, 'assigned', v_assigned));
  RETURN v_assigned;
END $$;
-- owner-only: Supabase default privileges also grant EXECUTE to anon/authenticated/service_role, so revoke them all
REVOKE ALL ON FUNCTION schedule_export_core(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION prepare_schedule_export(p_job_id uuid, p_kind text DEFAULT 'staff')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_kind IS DISTINCT FROM 'staff'
     AND coalesce(current_setting('role', true), '') IN ('authenticated', 'anon', 'authenticator') THEN
    RAISE EXCEPTION 'permission denied: client export is not available to this role';
  END IF;
  RETURN schedule_export_core(p_job_id, p_kind);
END $$;
-- X13: Supabase default privileges also grant EXECUTE to anon, so PUBLIC alone is not enough.
REVOKE ALL ON FUNCTION prepare_schedule_export(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION prepare_schedule_export(uuid, text) TO authenticated;
