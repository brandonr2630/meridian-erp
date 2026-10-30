-- Phase A2a: import_job_schedule(p_job_id, p_mode, p_payload, p_reason) - the atomic MS Project / ProjectLibre import.
-- Spec: docs/specs/project-portal/phase-a2-projectlibre.md ("Data model", "Import RPC contract", "Baseline on import", "RLS and permissions",
--       N1 hierarchy via parent_task_id, N6/N9). Order: after 202610271000_a2a_schema.sql (needs link_type, msp_uid, parent_task_id).
-- This is the highest-risk function in A2 (replace mode deletes the schedule): see supabase/tests/a2a_import/ATTACK_NOTES.md.
-- Idempotent (CREATE OR REPLACE + REVOKE/GRANT). Rollback: supabase/rollbacks/202610271300_a2a_import_down.sql
-- Built and tested on a throwaway Postgres 17 (bash supabase/tests/d0c_common/run.sh a2a_import). NOT applied to prod.
--
-- PAYLOAD SHAPE = what schedule-msp.js MspCodec.toPayload() emits (it wins over the spec's JSON example), plus three wrapper fields the
-- caller adds: file_name, based_on (stale check) and, optionally, project_uid / temporary_uids (the codec carries them as
-- project.uid and project.manager). See the Rulings in ATTACK_NOTES.md. Accepted keys (all others are ignored):
--   { format?: 'mspdi', version?: 1, file_name?: text, based_on?: timestamptz text, project_uid?: text, temporary_uids?: bool,
--     project?: { uid?: text, manager?: text },
--     phases: [ { uid, name, sort_order? } ],
--     tasks:  [ { uid, name, phase_uid?, parent_uid?, start_date?, end_date?, progress?, is_milestone?, is_summary?, assignee?,
--                 baseline_start?, baseline_end?, sort_order?, links?: [ { pred_uid, link_type?, lag_days? } ] } ],
--     warnings?: [ { code, message?, count } ], resources?/assignments? (ignored with a warning: A2b) }
--
-- Security model: SECURITY DEFINER, owner = the owner of lock_job_baseline (checked at the end of this file), fixed search_path, no dynamic SQL,
-- authorisation inside (company membership + company-scoped atoms), baseline columns written only with app.baseline_rpc='on' around the
-- single baseline UPDATE. The helpers below are SECURITY INVOKER and revoked from every API role.
--
-- Independent attack review fixes (see ATTACK_NOTES.md "Review findings"): H1 every stored-row predicate is scoped to the job's company and a
-- schedule that already contains rows of another company is refused (SQLSTATE A2C01; the a2a_schema trigger stops new ones); M2 the cycle check
-- looks only at the part of the graph reachable from edges that are new in the file; M3 uids are 1..100000000 and stored uids above that are
-- ignored; L4 a merge that moves a published task to another phase unpublishes it; L5 replace locks the rows first, copies the full deleted rows
-- (to_jsonb) into the audit metadata and audits a replaced locked baseline as 'baseline_reset'; L6 the name cleaner strips more invisible characters.
-- Prod pre-check for H1 (read-only, expect 0 0 0) is in the a2a_schema migration header.

-- ===== helpers (pure / invoker; called only from the definer function, which runs them as its owner) =====
-- Strip control characters, line breaks become spaces, bidi/zero-width controls removed, runs of spaces collapsed, trimmed.
CREATE OR REPLACE FUNCTION import_sched_clean(p_s text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  -- L2 (review 2): other space characters (no-break, en/em/thin..., ideographic) become a plain space, and a name made only of invisible
  -- marks and spaces (braille blank U+2800, combining grapheme joiner, variation selectors, Khmer inherent vowels) becomes empty, so the
  -- caller names it '(unnamed)'. The marks are kept inside real text (emoji need U+FE0F).
  SELECT CASE WHEN q.s ~ '^[ \u034f\u17b4\u17b5\u2800\ufe00-\ufe0f]*$' THEN '' ELSE q.s END
    FROM (SELECT btrim(regexp_replace(
                   regexp_replace(
                     regexp_replace(
                       regexp_replace(p_s, '[\t\n\r\f\v]+', ' ', 'g'),
                       '[\u0001-\u001f\u007f-\u009f\u00ad\u061c\u115f\u1160\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\u3164\ufeff\uffa0\ufff9-\ufffb\U000e0000-\U000e007f]', '', 'g'),
                     '[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]', ' ', 'g'),
                   ' {2,}', ' ', 'g')) AS s) q
$$;

CREATE OR REPLACE FUNCTION import_sched_str(o jsonb, k text, w text, p_max integer, p_req boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v jsonb := o -> k; s text;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    IF p_req THEN RAISE EXCEPTION 'invalid payload: %.% is required', w, k USING ERRCODE = '22023'; END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'string' THEN RAISE EXCEPTION 'invalid payload: %.% must be a string', w, k USING ERRCODE = '22023'; END IF;
  s := v #>> '{}';
  IF char_length(s) > p_max THEN RAISE EXCEPTION 'invalid payload: %.% is longer than % characters', w, k, p_max USING ERRCODE = '22023'; END IF;
  RETURN import_sched_clean(s);
END $$;

CREATE OR REPLACE FUNCTION import_sched_int(o jsonb, k text, w text, p_lo bigint, p_hi bigint, p_req boolean DEFAULT false) RETURNS integer
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v jsonb := o -> k; n numeric;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
    IF p_req THEN RAISE EXCEPTION 'invalid payload: %.% is required', w, k USING ERRCODE = '22023'; END IF;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(v) <> 'number' THEN RAISE EXCEPTION 'invalid payload: %.% must be a number', w, k USING ERRCODE = '22023'; END IF;
  n := (v #>> '{}')::numeric;
  IF n <> trunc(n) THEN RAISE EXCEPTION 'invalid payload: %.% must be a whole number', w, k USING ERRCODE = '22023'; END IF;
  IF n < p_lo OR n > p_hi THEN RAISE EXCEPTION 'invalid payload: %.% is out of range', w, k USING ERRCODE = '22023'; END IF;
  RETURN n::integer;
END $$;

CREATE OR REPLACE FUNCTION import_sched_date(o jsonb, k text, w text) RETURNS date
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v jsonb := o -> k; s text; d date;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN RETURN NULL; END IF;
  IF jsonb_typeof(v) <> 'string' THEN RAISE EXCEPTION 'invalid payload: %.% must be a date string', w, k USING ERRCODE = '22023'; END IF;
  s := v #>> '{}';
  IF s !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION 'invalid payload: %.% must be YYYY-MM-DD', w, k USING ERRCODE = '22023'; END IF;
  BEGIN
    d := s::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'invalid payload: %.% is not a real date', w, k USING ERRCODE = '22023';
  END;
  IF d < DATE '2000-01-01' OR d > DATE '2100-12-31' THEN RAISE EXCEPTION 'invalid payload: %.% is outside 2000..2100', w, k USING ERRCODE = '22023'; END IF;
  RETURN d;
END $$;

CREATE OR REPLACE FUNCTION import_sched_bool(o jsonb, k text, w text) RETURNS boolean
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v jsonb := o -> k;
BEGIN
  IF v IS NULL OR jsonb_typeof(v) = 'null' THEN RETURN NULL; END IF;
  IF jsonb_typeof(v) <> 'boolean' THEN RAISE EXCEPTION 'invalid payload: %.% must be true or false', w, k USING ERRCODE = '22023'; END IF;
  RETURN (v #>> '{}')::boolean;
END $$;

-- Company-scoped atom check (user_has_perm() is not company scoped): the caller holds the atom through a role assigned IN this company.
CREATE OR REPLACE FUNCTION import_sched_has_atom(p_company uuid, p_atom text) RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM erp_users eu
                   JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id AND ucr.company_id = p_company
                   JOIN erp_roles r ON r.id = ucr.role_id
                  WHERE eu.auth_user_id = auth.uid() AND eu.is_active
                    AND jsonb_typeof(r.permissions) = 'object' AND (r.permissions ->> p_atom) = 'true')
$$;

-- Fold one warning into a jsonb array of {code, message, count}; at most 60 distinct codes, counts capped.
CREATE OR REPLACE FUNCTION import_sched_warn(p_w jsonb, p_code text, p_msg text, p_n integer DEFAULT 1) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE i integer;
BEGIN
  IF p_n IS NULL OR p_n < 1 THEN RETURN p_w; END IF;
  FOR i IN 0 .. jsonb_array_length(p_w) - 1 LOOP
    IF (p_w -> i ->> 'code') = p_code THEN
      RETURN jsonb_set(p_w, ARRAY[i::text, 'count'], to_jsonb(least((p_w -> i ->> 'count')::bigint + p_n, 1000000::bigint)));
    END IF;
  END LOOP;
  IF jsonb_array_length(p_w) >= 60 THEN RETURN p_w; END IF;
  RETURN p_w || jsonb_build_array(jsonb_build_object('code', p_code, 'message', p_msg, 'count', least(p_n, 1000000)));
END $$;

REVOKE ALL ON FUNCTION import_sched_clean(text), import_sched_str(jsonb, text, text, integer, boolean),
  import_sched_int(jsonb, text, text, bigint, bigint, boolean), import_sched_date(jsonb, text, text),
  import_sched_bool(jsonb, text, text), import_sched_has_atom(uuid, text), import_sched_warn(jsonb, text, text, integer)
  FROM PUBLIC, anon, authenticated, service_role;

-- ===== the import RPC =====
CREATE OR REPLACE FUNCTION import_job_schedule(p_job_id uuid, p_mode text, p_payload jsonb, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  k_max_tasks constant integer := 2000;   k_max_phases constant integer := 500;
  k_max_links constant integer := 5000;   k_max_job_tasks constant integer := 10000;
  k_max_depth constant integer := 6;      k_max_bytes constant integer := 6000000;
  v_job_no text; v_company uuid; v_approver boolean; v_reason text; v_username text;
  v_file text; v_based timestamptz; v_puid text; v_pm text; v_temp boolean := false;
  v_phases jsonb; v_tasks jsonb; r record; lrec record; w text; lw text;
  v_uid integer; v_name text; v_t text; v_bs date; v_be date; v_sd date; v_ed date; v_ms boolean;
  v_warn jsonb := '[]'::jsonb; v_wcode text; v_wcnt integer;
  n_trunc integer := 0; n_defaulted integer := 0; n_bl_partial integer := 0; n_bl_ignored integer := 0; n_kind integer := 0; n_res integer := 0;
  n_links integer := 0; n_total_links integer := 0;
  v_cur timestamptz; v_ex_p integer := 0; v_ex_t integer := 0; v_matched integer := 0;
  v_new_p integer; v_new_t integer; v_free integer[];
  v_created integer := 0; v_updated integer := 0; v_kept integer := 0; v_skipped integer := 0; n integer;
  v_has_bl boolean; v_locked boolean := false; v_bl_ok boolean := false; v_nb integer := 0;
  v_recovery jsonb := NULL; v_del_p integer := 0; v_del_t integer := 0; v_del_l integer := 0; v_links_written integer := 0;
  v_rec_p jsonb; v_rec_t jsonb; v_rec_l jsonb; v_prior_bl boolean := false;
  v_front uuid[]; v_done integer; v_nodes integer;
BEGIN
  -- ---- 1. cheap argument checks and authorisation (nothing below runs for an unauthorised caller)
  IF p_mode IS NULL OR p_mode NOT IN ('append', 'merge', 'replace') THEN
    RAISE EXCEPTION 'invalid import mode' USING ERRCODE = '22023';
  END IF;
  IF p_job_id IS NULL THEN RAISE EXCEPTION 'job not found'; END IF;
  SELECT j.job_no, j.company_id INTO v_job_no, v_company
    FROM jobs j WHERE j.id = p_job_id AND j.company_id IN (SELECT my_company_ids());
  IF NOT FOUND THEN RAISE EXCEPTION 'job not found'; END IF;
  IF NOT import_sched_has_atom(v_company, 'ops:work-orders:write') THEN
    RAISE EXCEPTION 'permission denied: ops:work-orders:write required' USING ERRCODE = '42501';
  END IF;
  v_approver := import_sched_has_atom(v_company, 'ops:work-orders:approve');
  v_reason := left(import_sched_clean(coalesce(p_reason, '')), 500);
  IF p_mode = 'replace' THEN
    IF NOT v_approver THEN RAISE EXCEPTION 'permission denied: ops:work-orders:approve required for replace' USING ERRCODE = '42501'; END IF;
    IF v_reason = '' THEN RAISE EXCEPTION 'replace requires a reason' USING ERRCODE = '22023'; END IF;
  END IF;
  v_username := (SELECT u.full_name FROM erp_users u WHERE u.auth_user_id = auth.uid() LIMIT 1);

  -- ---- 2. payload envelope (types, size, counts, identity of the file)
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN RAISE EXCEPTION 'invalid payload: a JSON object is required' USING ERRCODE = '22023'; END IF;
  IF octet_length(p_payload::text) > k_max_bytes THEN RAISE EXCEPTION 'invalid payload: too large' USING ERRCODE = '22023'; END IF;
  IF p_payload ? 'format' AND (jsonb_typeof(p_payload -> 'format') <> 'string' OR (p_payload ->> 'format') <> 'mspdi') THEN
    RAISE EXCEPTION 'invalid payload: format must be mspdi' USING ERRCODE = '22023';
  END IF;
  IF p_payload ? 'version' AND (jsonb_typeof(p_payload -> 'version') <> 'number' OR (p_payload ->> 'version')::numeric <> 1) THEN
    RAISE EXCEPTION 'invalid payload: unsupported version' USING ERRCODE = '22023';
  END IF;
  v_file := import_sched_str(p_payload, 'file_name', 'payload', 255, false);
  IF coalesce(jsonb_typeof(p_payload -> 'based_on'), 'null') NOT IN ('null', 'string') THEN
    RAISE EXCEPTION 'invalid payload: based_on must be a timestamp string' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload -> 'based_on') = 'string' THEN
    BEGIN
      v_based := (p_payload ->> 'based_on')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'invalid payload: based_on is not a timestamp' USING ERRCODE = '22023';
    END;
  END IF;
  IF coalesce(jsonb_typeof(p_payload -> 'project'), 'null') NOT IN ('null', 'object') THEN
    RAISE EXCEPTION 'invalid payload: project must be an object' USING ERRCODE = '22023';
  END IF;
  v_puid := lower(import_sched_str(p_payload, 'project_uid', 'payload', 64, false));
  IF jsonb_typeof(p_payload -> 'project') = 'object' THEN
    v_t := lower(import_sched_str(p_payload -> 'project', 'uid', 'payload.project', 64, false));
    IF v_t IS NOT NULL AND v_puid IS NOT NULL AND v_t <> v_puid THEN RAISE EXCEPTION 'invalid payload: project_uid and project.uid disagree' USING ERRCODE = '22023'; END IF;
    v_puid := coalesce(v_puid, v_t);
    v_pm := import_sched_str(p_payload -> 'project', 'manager', 'payload.project', 255, false);
  END IF;
  v_temp := coalesce(import_sched_bool(p_payload, 'temporary_uids', 'payload'), false) OR v_pm = 'meridian-readonly-export';
  IF p_mode = 'merge' AND (v_temp OR v_puid IS DISTINCT FROM lower(p_job_id::text)) THEN
    RAISE EXCEPTION 'merge requires a file exported from this job (use append, or replace as an approver)' USING ERRCODE = '22023';
  END IF;
  IF coalesce(jsonb_typeof(p_payload -> 'phases'), 'array') <> 'array' OR coalesce(jsonb_typeof(p_payload -> 'tasks'), 'array') <> 'array' THEN
    RAISE EXCEPTION 'invalid payload: phases and tasks must be arrays' USING ERRCODE = '22023';
  END IF;
  IF coalesce(jsonb_typeof(p_payload -> 'links'), 'null') <> 'null'
     AND (jsonb_typeof(p_payload -> 'links') <> 'array' OR jsonb_array_length(p_payload -> 'links') > 0) THEN
    RAISE EXCEPTION 'invalid payload: links belong inside tasks[].links' USING ERRCODE = '22023';
  END IF;
  v_phases := coalesce(p_payload -> 'phases', '[]'::jsonb);
  v_tasks  := coalesce(p_payload -> 'tasks', '[]'::jsonb);
  IF jsonb_array_length(v_tasks) > k_max_tasks THEN RAISE EXCEPTION 'invalid payload: more than % tasks', k_max_tasks USING ERRCODE = '22023'; END IF;
  IF jsonb_array_length(v_phases) > k_max_phases THEN RAISE EXCEPTION 'invalid payload: more than % phases', k_max_phases USING ERRCODE = '22023'; END IF;
  IF jsonb_array_length(v_tasks) + jsonb_array_length(v_phases) = 0 THEN RAISE EXCEPTION 'invalid payload: it has no rows' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_payload -> 'resources') = 'array' THEN n_res := jsonb_array_length(p_payload -> 'resources'); END IF;

  -- ---- 3. row validation into working tables (no write to a real table yet)
  DROP TABLE IF EXISTS pg_temp.imp_p;  DROP TABLE IF EXISTS pg_temp.imp_t;  DROP TABLE IF EXISTS pg_temp.imp_l;
  DROP TABLE IF EXISTS pg_temp.imp_e;  DROP TABLE IF EXISTS pg_temp.imp_n;
  DROP TABLE IF EXISTS pg_temp.imp_a;  DROP TABLE IF EXISTS pg_temp.imp_r;  DROP TABLE IF EXISTS pg_temp.imp_g;  DROP TABLE IF EXISTS pg_temp.imp_d;
  DROP TABLE IF EXISTS pg_temp.imp_x;  DROP TABLE IF EXISTS pg_temp.imp_xr;  DROP TABLE IF EXISTS pg_temp.imp_xg;  DROP TABLE IF EXISTS pg_temp.imp_xd;
  CREATE TEMP TABLE imp_p (idx integer NOT NULL, uid integer NOT NULL, name text NOT NULL, sort_order integer,
    id uuid NOT NULL DEFAULT gen_random_uuid(), matched boolean NOT NULL DEFAULT false, changed boolean NOT NULL DEFAULT false, new_uid integer) ON COMMIT DROP;
  CREATE TEMP TABLE imp_t (idx integer NOT NULL, uid integer NOT NULL, name text NOT NULL, phase_uid integer, parent_uid integer,
    start_date date, end_date date, progress integer, is_milestone boolean, has_assignee boolean NOT NULL DEFAULT false, assignee text,
    bstart date, bend date, sort_order integer, id uuid NOT NULL DEFAULT gen_random_uuid(), parent_id uuid,
    matched boolean NOT NULL DEFAULT false, changed boolean NOT NULL DEFAULT false, new_uid integer) ON COMMIT DROP;
  CREATE TEMP TABLE imp_l (ord serial, task_uid integer NOT NULL, pred_uid integer NOT NULL, link_type text NOT NULL, lag integer NOT NULL) ON COMMIT DROP;

  FOR r IN SELECT t.e, t.i FROM jsonb_array_elements(v_phases) WITH ORDINALITY AS t(e, i) LOOP
    w := 'phases[' || (r.i - 1) || ']';
    IF jsonb_typeof(r.e) <> 'object' THEN RAISE EXCEPTION 'invalid payload: % must be an object', w USING ERRCODE = '22023'; END IF;
    v_uid := import_sched_int(r.e, 'uid', w, 1, 100000000, true);
    v_name := import_sched_str(r.e, 'name', w, 255, true);
    IF v_name = '' THEN v_name := '(unnamed)'; n_defaulted := n_defaulted + 1; END IF;
    IF char_length(v_name) > 80 THEN v_name := btrim(left(v_name, 80)); n_trunc := n_trunc + 1; END IF;
    INSERT INTO pg_temp.imp_p (idx, uid, name, sort_order) VALUES (r.i, v_uid, v_name, import_sched_int(r.e, 'sort_order', w, 0, 100000000, false));
  END LOOP;

  FOR r IN SELECT t.e, t.i FROM jsonb_array_elements(v_tasks) WITH ORDINALITY AS t(e, i) LOOP
    w := 'tasks[' || (r.i - 1) || ']';
    IF jsonb_typeof(r.e) <> 'object' THEN RAISE EXCEPTION 'invalid payload: % must be an object', w USING ERRCODE = '22023'; END IF;
    v_uid := import_sched_int(r.e, 'uid', w, 1, 100000000, true);
    v_name := import_sched_str(r.e, 'name', w, 255, true);
    IF v_name = '' THEN v_name := '(unnamed)'; n_defaulted := n_defaulted + 1; END IF;
    v_sd := import_sched_date(r.e, 'start_date', w);
    v_ed := import_sched_date(r.e, 'end_date', w);
    IF v_sd IS NOT NULL AND v_ed IS NOT NULL AND v_ed < v_sd THEN RAISE EXCEPTION 'invalid payload: %.end_date is before start_date', w USING ERRCODE = '22023'; END IF;
    v_ms := import_sched_bool(r.e, 'is_milestone', w);
    IF coalesce(v_ms, false) AND v_sd IS NOT NULL AND v_ed IS NOT NULL AND v_sd <> v_ed THEN
      RAISE EXCEPTION 'invalid payload: %: a milestone must have equal start and end dates', w USING ERRCODE = '22023';
    END IF;
    PERFORM import_sched_bool(r.e, 'is_summary', w);                                  -- type-checked only: a summary is derived, never stored
    v_bs := import_sched_date(r.e, 'baseline_start', w);
    v_be := import_sched_date(r.e, 'baseline_end', w);
    IF v_bs IS NOT NULL AND v_be IS NOT NULL AND v_be < v_bs THEN RAISE EXCEPTION 'invalid payload: %.baseline_end is before baseline_start', w USING ERRCODE = '22023'; END IF;
    IF (v_bs IS NULL) <> (v_be IS NULL) THEN n_bl_partial := n_bl_partial + 1; v_bs := NULL; v_be := NULL; END IF;
    INSERT INTO pg_temp.imp_t (idx, uid, name, phase_uid, parent_uid, start_date, end_date, progress, is_milestone, has_assignee, assignee, bstart, bend, sort_order)
    VALUES (r.i, v_uid, v_name, import_sched_int(r.e, 'phase_uid', w, 1, 100000000, false), import_sched_int(r.e, 'parent_uid', w, 1, 100000000, false),
            v_sd, v_ed, import_sched_int(r.e, 'progress', w, 0, 100, false), v_ms,
            (r.e ? 'assignee'), import_sched_str(r.e, 'assignee', w, 120, false), v_bs, v_be, import_sched_int(r.e, 'sort_order', w, 0, 100000000, false));
    IF coalesce(jsonb_typeof(r.e -> 'links'), 'array') NOT IN ('array', 'null') THEN RAISE EXCEPTION 'invalid payload: %.links must be an array', w USING ERRCODE = '22023'; END IF;
    IF r.e ? 'links' AND jsonb_typeof(r.e -> 'links') = 'array' THEN
      n_links := jsonb_array_length(r.e -> 'links');
      IF n_total_links + n_links > k_max_links THEN RAISE EXCEPTION 'invalid payload: more than % links', k_max_links USING ERRCODE = '22023'; END IF;
      n_total_links := n_total_links + n_links;
      FOR lrec IN SELECT x.e, x.i FROM jsonb_array_elements(r.e -> 'links') WITH ORDINALITY AS x(e, i) LOOP
        lw := w || '.links[' || (lrec.i - 1) || ']';
        IF jsonb_typeof(lrec.e) <> 'object' THEN RAISE EXCEPTION 'invalid payload: % must be an object', lw USING ERRCODE = '22023'; END IF;
        v_t := coalesce(import_sched_str(lrec.e, 'link_type', lw, 2, false), 'FS');
        IF v_t NOT IN ('FS', 'SS', 'FF', 'SF') THEN RAISE EXCEPTION 'invalid payload: %.link_type must be FS, SS, FF or SF', lw USING ERRCODE = '22023'; END IF;
        INSERT INTO pg_temp.imp_l (task_uid, pred_uid, link_type, lag)
        VALUES (v_uid, import_sched_int(lrec.e, 'pred_uid', lw, 1, 100000000, true), v_t, coalesce(import_sched_int(lrec.e, 'lag_days', lw, -30, 365, false), 0));
      END LOOP;
    END IF;
  END LOOP;

  -- the codec's own warnings pass through (code and message cleaned and length-limited, count bounded)
  IF coalesce(jsonb_typeof(p_payload -> 'warnings'), 'array') <> 'array' THEN RAISE EXCEPTION 'invalid payload: warnings must be an array' USING ERRCODE = '22023'; END IF;
  FOR r IN SELECT t.e FROM jsonb_array_elements(coalesce(p_payload -> 'warnings', '[]'::jsonb)) AS t(e) LIMIT 100 LOOP
    IF jsonb_typeof(r.e) <> 'object' THEN CONTINUE; END IF;
    v_wcode := import_sched_str(r.e, 'code', 'warnings[]', 64, false);
    IF v_wcode IS NULL OR v_wcode !~ '^[A-Za-z0-9_-]{1,64}$' THEN CONTINUE; END IF;
    v_wcnt := CASE WHEN jsonb_typeof(r.e -> 'count') = 'number' AND (r.e ->> 'count')::numeric BETWEEN 1 AND 1000000 THEN trunc((r.e ->> 'count')::numeric)::integer ELSE 1 END;
    v_warn := import_sched_warn(v_warn, v_wcode, left(coalesce(import_sched_str(r.e, 'message', 'warnings[]', 300, false), v_wcode), 300), v_wcnt);
  END LOOP;

  -- identity and reference rules inside the payload
  IF EXISTS (SELECT 1 FROM pg_temp.imp_p GROUP BY uid HAVING count(*) > 1) OR EXISTS (SELECT 1 FROM pg_temp.imp_t GROUP BY uid HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'invalid payload: a uid is used twice' USING ERRCODE = '22023';
  END IF;
  CREATE UNIQUE INDEX ON pg_temp.imp_p (uid);
  CREATE UNIQUE INDEX ON pg_temp.imp_t (uid);
  CREATE INDEX ON pg_temp.imp_l (task_uid);
  IF EXISTS (SELECT 1 FROM pg_temp.imp_p a JOIN pg_temp.imp_t b ON b.uid = a.uid) THEN
    RAISE EXCEPTION 'invalid payload: a uid is used by both a phase and a task' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_t t WHERE t.phase_uid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_temp.imp_p p WHERE p.uid = t.phase_uid)) THEN
    RAISE EXCEPTION 'invalid payload: a task refers to a missing phase' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_t t WHERE t.parent_uid IS NOT NULL
               AND (t.parent_uid = t.uid OR NOT EXISTS (SELECT 1 FROM pg_temp.imp_t p WHERE p.uid = t.parent_uid))) THEN
    RAISE EXCEPTION 'invalid payload: a task has a missing or self parent' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_t c JOIN pg_temp.imp_t p ON p.uid = c.parent_uid WHERE p.phase_uid IS DISTINCT FROM c.phase_uid) THEN
    RAISE EXCEPTION 'invalid payload: a task and its parent are in different phases' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_l l WHERE l.task_uid = l.pred_uid) THEN
    RAISE EXCEPTION 'invalid payload: a task is linked to itself' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_l l WHERE NOT EXISTS (SELECT 1 FROM pg_temp.imp_t t WHERE t.uid = l.pred_uid)) THEN
    RAISE EXCEPTION 'invalid payload: a link refers to a missing task' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.imp_l l GROUP BY l.task_uid, l.pred_uid HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'invalid payload: a task has the same predecessor twice' USING ERRCODE = '22023';
  END IF;

  -- ---- 4. serialise on the job, then the checks that depend on the stored schedule
  PERFORM pg_advisory_xact_lock(hashtext(p_job_id::text));
  -- H1: rows of ANOTHER company that carry this job's id (the a2a_schema trigger now stops them being written; this guards a database that
  -- already has some) would leak into this company's rows through merge and could block the job (uid 100000000, updated_at in the future).
  -- Refuse instead of guessing; every stored-row predicate below is ALSO scoped to the job's company.
  IF EXISTS (SELECT 1 FROM job_phases WHERE job_id = p_job_id AND company_id <> v_company)
     OR EXISTS (SELECT 1 FROM job_tasks WHERE job_id = p_job_id AND company_id <> v_company)
     OR EXISTS (SELECT 1 FROM job_task_links WHERE job_id = p_job_id AND company_id <> v_company) THEN
    RAISE EXCEPTION 'schedule contains rows of another company' USING ERRCODE = 'A2C01';
  END IF;
  -- L5: replace takes row locks on the whole stored schedule BEFORE the stale check and before anything is copied or deleted, so a
  -- concurrent UI edit either lands before the check (and makes it fail) or waits until this transaction ends. Fixed order: phases, tasks, links.
  IF p_mode = 'replace' THEN
    PERFORM p.id FROM job_phases p WHERE p.job_id = p_job_id AND p.company_id = v_company ORDER BY p.id FOR UPDATE OF p;
    PERFORM t.id FROM job_tasks t WHERE t.job_id = p_job_id AND t.company_id = v_company ORDER BY t.id FOR UPDATE OF t;
    PERFORM k.id FROM job_task_links k WHERE k.job_id = p_job_id AND k.company_id = v_company ORDER BY k.id FOR UPDATE OF k;
  END IF;
  SELECT max(u) INTO v_cur FROM (SELECT max(updated_at) AS u FROM job_tasks WHERE job_id = p_job_id AND company_id = v_company
                                 UNION ALL SELECT max(updated_at) FROM job_phases WHERE job_id = p_job_id AND company_id = v_company
                                 UNION ALL SELECT max(updated_at) FROM job_task_links WHERE job_id = p_job_id AND company_id = v_company) s;
  IF v_cur IS NOT NULL AND v_based IS NULL THEN
    RAISE EXCEPTION 'invalid payload: based_on is required for a job that already has a schedule' USING ERRCODE = '22023';
  END IF;
  IF date_trunc('milliseconds', v_cur) IS DISTINCT FROM date_trunc('milliseconds', v_based) AND (v_cur IS NOT NULL OR v_based IS NOT NULL) THEN
    RAISE EXCEPTION 'schedule changed since preview' USING ERRCODE = '40001';
  END IF;

  SELECT count(*) INTO v_ex_p FROM job_phases WHERE job_id = p_job_id AND company_id = v_company;
  SELECT count(*) INTO v_ex_t FROM job_tasks  WHERE job_id = p_job_id AND company_id = v_company;
  IF p_mode <> 'replace' AND v_ex_t + (SELECT count(*) FROM pg_temp.imp_t) > k_max_job_tasks THEN
    RAISE EXCEPTION 'the schedule would exceed % tasks', k_max_job_tasks USING ERRCODE = '22023';
  END IF;

  -- merge: match on msp_uid only (the payload belongs to this job, checked above); a phase never matches a task row and vice versa
  IF p_mode = 'merge' THEN
    UPDATE pg_temp.imp_p ip SET id = p.id, matched = true FROM job_phases p WHERE p.job_id = p_job_id AND p.company_id = v_company AND p.msp_uid = ip.uid;
    UPDATE pg_temp.imp_t it SET id = t.id, matched = true FROM job_tasks t WHERE t.job_id = p_job_id AND t.company_id = v_company AND t.msp_uid = it.uid;
    SELECT (SELECT count(*) FROM pg_temp.imp_p ip WHERE NOT ip.matched AND EXISTS (SELECT 1 FROM job_tasks t WHERE t.job_id = p_job_id AND t.company_id = v_company AND t.msp_uid = ip.uid))
         + (SELECT count(*) FROM pg_temp.imp_t it WHERE NOT it.matched AND EXISTS (SELECT 1 FROM job_phases p WHERE p.job_id = p_job_id AND p.company_id = v_company AND p.msp_uid = it.uid))
      INTO n_kind;
  END IF;
  SELECT (SELECT count(*) FROM pg_temp.imp_p WHERE matched) + (SELECT count(*) FROM pg_temp.imp_t WHERE matched) INTO v_matched;
  UPDATE pg_temp.imp_t c SET parent_id = p.id FROM pg_temp.imp_t p WHERE p.uid = c.parent_uid;
  -- which matched rows really differ from what is stored (name, dates, progress, flags, assignee, phase, order or parent)
  UPDATE pg_temp.imp_p ip SET changed = true FROM job_phases p
   WHERE ip.matched AND p.id = ip.id AND p.job_id = p_job_id AND p.company_id = v_company AND (p.name, p.sort_order) IS DISTINCT FROM (ip.name, coalesce(ip.sort_order, p.sort_order));
  UPDATE pg_temp.imp_t it SET changed = true FROM job_tasks t
   WHERE it.matched AND t.id = it.id AND t.job_id = p_job_id AND t.company_id = v_company
     AND (t.task_name, t.start_date, t.end_date, t.progress, t.is_milestone, t.assignee, t.phase_id, t.sort_order, t.parent_task_id)
         IS DISTINCT FROM (it.name,
                           CASE WHEN it.start_date IS NOT NULL AND it.end_date IS NOT NULL THEN it.start_date ELSE t.start_date END,
                           CASE WHEN it.start_date IS NOT NULL AND it.end_date IS NOT NULL THEN it.end_date   ELSE t.end_date   END,
                           coalesce(it.progress, t.progress), coalesce(it.is_milestone, t.is_milestone),
                           CASE WHEN it.has_assignee THEN it.assignee ELSE t.assignee END,
                           (SELECT ph.id FROM pg_temp.imp_p ph WHERE ph.uid = it.phase_uid), coalesce(it.sort_order, t.sort_order), it.parent_id);
  SELECT (SELECT count(*) FROM pg_temp.imp_p WHERE changed) + (SELECT count(*) FROM pg_temp.imp_t WHERE changed) INTO v_updated;

  -- the whole final graph (stored rows that stay + payload rows) must be acyclic and at most 6 levels deep (the phase is level 1 even when absent, matching the job_tasks_parent_guard trigger: a task chain is at most 5), BEFORE any write
  CREATE TEMP TABLE imp_e (t uuid NOT NULL, p uuid NOT NULL) ON COMMIT DROP;       -- the payload's edges (task, predecessor)
  CREATE TEMP TABLE imp_n (id uuid NOT NULL, parent uuid, has_phase boolean NOT NULL) ON COMMIT DROP;
  IF p_mode <> 'replace' THEN
    INSERT INTO pg_temp.imp_n SELECT t.id, t.parent_task_id, t.phase_id IS NOT NULL FROM job_tasks t
      WHERE t.job_id = p_job_id AND t.company_id = v_company AND NOT EXISTS (SELECT 1 FROM pg_temp.imp_t i WHERE i.id = t.id);
  END IF;
  INSERT INTO pg_temp.imp_e SELECT a.id, b.id FROM pg_temp.imp_l l JOIN pg_temp.imp_t a ON a.uid = l.task_uid JOIN pg_temp.imp_t b ON b.uid = l.pred_uid;
  INSERT INTO pg_temp.imp_n SELECT i.id, i.parent_id, i.phase_uid IS NOT NULL FROM pg_temp.imp_t i;
  CREATE INDEX ON pg_temp.imp_e (t);  CREATE INDEX ON pg_temp.imp_n (id);
  -- M2: the stored links were checked one by one by job_task_links_no_cycle, so a cycle must pass through an edge that is NEW in this
  -- file. Nothing new (the usual merge of an own file, or a file without links) -> no scan at all. Otherwise only the part of the graph
  -- reachable (through predecessors) from the new edges is looked at, and it is peeled from its sources with a worklist, so the cost
  -- follows the size of that part, not of the whole stored schedule (a one-task append on a 10k-task chain used to cost 10 s).
  -- append: the file's tasks are all new rows, so stored links cannot touch them; replace: the stored links are about to be deleted.
  IF EXISTS (SELECT 1 FROM pg_temp.imp_e) THEN
    CREATE TEMP TABLE imp_a (t uuid NOT NULL, p uuid NOT NULL) ON COMMIT DROP;     -- every edge that can matter
    INSERT INTO pg_temp.imp_a SELECT e.t, e.p FROM pg_temp.imp_e e;
    IF p_mode = 'merge' THEN
      INSERT INTO pg_temp.imp_a SELECT k.task_id, k.predecessor_id FROM job_task_links k WHERE k.job_id = p_job_id AND k.company_id = v_company;
    END IF;
    CREATE INDEX ON pg_temp.imp_a (t);
    CREATE TEMP TABLE imp_r (id uuid PRIMARY KEY) ON COMMIT DROP;                   -- nodes reachable from a new edge's predecessor
    INSERT INTO pg_temp.imp_r
      WITH RECURSIVE rch(id) AS (
        SELECT e.p FROM pg_temp.imp_e e
         WHERE p_mode <> 'merge' OR NOT EXISTS (SELECT 1 FROM job_task_links k WHERE k.task_id = e.t AND k.predecessor_id = e.p AND k.job_id = p_job_id AND k.company_id = v_company)
        UNION
        SELECT a.p FROM rch JOIN pg_temp.imp_a a ON a.t = rch.id)
      SELECT id FROM rch;
    -- a cycle needs a new edge (t, p) whose t is reachable from some new predecessor: if none is, the file closes no cycle and the peel is skipped
    IF EXISTS (SELECT 1 FROM pg_temp.imp_e e JOIN pg_temp.imp_r x ON x.id = e.t) THEN
      CREATE TEMP TABLE imp_g (t uuid NOT NULL, p uuid NOT NULL) ON COMMIT DROP;   -- the edges of that part
      INSERT INTO pg_temp.imp_g SELECT a.t, a.p FROM pg_temp.imp_a a WHERE a.t IN (SELECT id FROM pg_temp.imp_r);
      CREATE INDEX ON pg_temp.imp_g (p);
      CREATE TEMP TABLE imp_d (id uuid PRIMARY KEY, deg integer NOT NULL) ON COMMIT DROP;   -- predecessors still unplaced, per node
      INSERT INTO pg_temp.imp_d SELECT x.id, 0 FROM pg_temp.imp_r x;
      UPDATE pg_temp.imp_d d SET deg = c.n FROM (SELECT g.t, count(*)::integer AS n FROM pg_temp.imp_g g GROUP BY g.t) c WHERE c.t = d.id;
      SELECT count(*) INTO v_nodes FROM pg_temp.imp_d;
      v_front := ARRAY(SELECT d.id FROM pg_temp.imp_d d WHERE d.deg = 0);
      v_done := 0;
      WHILE coalesce(array_length(v_front, 1), 0) > 0 LOOP                    -- place the sources, then whatever only waited for them
        v_done := v_done + array_length(v_front, 1);
        WITH dec AS (
          UPDATE pg_temp.imp_d d SET deg = d.deg - c.n
            FROM (SELECT g.t, count(*)::integer AS n FROM pg_temp.imp_g g WHERE g.p = ANY (v_front) GROUP BY g.t) c
           WHERE d.id = c.t RETURNING d.id, d.deg)
        SELECT coalesce(array_agg(dec.id) FILTER (WHERE dec.deg = 0), ARRAY[]::uuid[]) INTO v_front FROM dec;
      END LOOP;
      IF v_done < v_nodes THEN RAISE EXCEPTION 'dependency cycle in the imported schedule' USING ERRCODE = '23514'; END IF;
    END IF;
  END IF;
  IF EXISTS (
    WITH RECURSIVE up(id, cur, d) AS (
      SELECT x.id, x.parent, 1 FROM pg_temp.imp_n x
      UNION ALL
      SELECT up.id, y.parent, up.d + 1 FROM up JOIN pg_temp.imp_n y ON y.id = up.cur WHERE up.d < 9)
    SELECT 1 FROM up WHERE up.cur = up.id) THEN
    RAISE EXCEPTION 'task hierarchy cycle in the imported schedule' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
    WITH RECURSIVE up(id, cur, d) AS (
      SELECT x.id, x.parent, 1 FROM pg_temp.imp_n x
      UNION ALL
      SELECT up.id, y.parent, up.d + 1 FROM up JOIN pg_temp.imp_n y ON y.id = up.cur WHERE up.d < 9)
    SELECT 1 FROM (SELECT up.id, max(up.d) AS depth FROM up GROUP BY up.id) m JOIN pg_temp.imp_n z ON z.id = m.id
     WHERE m.depth + 1 > k_max_depth) THEN
    RAISE EXCEPTION 'task hierarchy is deeper than % levels', k_max_depth USING ERRCODE = '23514';
  END IF;
  -- r3d M2: a link between a task and its own ancestor / descendant (final hierarchy: stored rows that stay + the file's) is refused here, before any
  -- write, like cycles and depth (job_task_links_z_hierarchy_guard would refuse it later at the INSERT, A2L01; job_schedule_status goes quadratic on such a link).
  -- Only the file's own links are checked. A stored link that the file's re-parenting turns into one is refused during the write phase by
  -- job_tasks_parent_link_guard (A2L02) and the whole RPC rolls back; a stored (legacy / DBA-planted) link of that kind that nothing touches is left alone.
  IF EXISTS (SELECT 1 FROM pg_temp.imp_e) AND EXISTS (SELECT 1 FROM pg_temp.imp_n WHERE parent IS NOT NULL) AND EXISTS (
    WITH RECURSIVE up(id, anc, d) AS (
      SELECT x.id, x.parent, 1 FROM pg_temp.imp_n x WHERE x.parent IS NOT NULL
      UNION ALL
      SELECT up.id, y.parent, up.d + 1 FROM up JOIN pg_temp.imp_n y ON y.id = up.anc WHERE y.parent IS NOT NULL AND up.d < 9)
    SELECT 1 FROM pg_temp.imp_e e JOIN up ON (up.id = e.t AND up.anc = e.p) OR (up.id = e.p AND up.anc = e.t)) THEN
    RAISE EXCEPTION 'a link joins a task and its own ancestor or descendant in the imported schedule' USING ERRCODE = '23514';
  END IF;

  -- r4 M1: the same final graph must not close a cycle THROUGH the hierarchy either (the link guard refuses it later at the INSERT with A2L03, and
  -- job_schedule_status never settles on it). The value-flow graph G* of sched_flow_reach (a2a_schema migration), with the file's final hierarchy:
  -- node a = the task, node md5(a || 'N') = what a link into a imposes on everything below a; edges (stored as "t depends on p"): link y after q
  -- gives q -> y and q -> N(y); kid k of s gives k -> s, N(s) -> k and N(s) -> N(k). Same method as the link-cycle check above: only the part
  -- reachable from the file's links is looked at and it is peeled from its sources; a link whose predecessor is not in that part cannot close a
  -- cycle, so then nothing is peeled. Needs a link and a parent: without either no hierarchy cycle exists. A stored cycle that this region reaches
  -- (DBA-planted / legacy) refuses the file too, like the link-cycle check. Hierarchy changes of a file WITHOUT links of its own (stored links
  -- only) are caught during the write phase by job_tasks_parent_link_guard (A2L03) and the RPC rolls back.
  IF EXISTS (SELECT 1 FROM pg_temp.imp_e) AND EXISTS (SELECT 1 FROM pg_temp.imp_n WHERE parent IS NOT NULL) THEN
    CREATE TEMP TABLE imp_x (t uuid NOT NULL, p uuid NOT NULL) ON COMMIT DROP;
    INSERT INTO pg_temp.imp_x
      SELECT a.t, a.p FROM pg_temp.imp_a a
      UNION ALL SELECT md5(a.t::text || 'N')::uuid, a.p FROM pg_temp.imp_a a
      UNION ALL SELECT n.parent, n.id FROM pg_temp.imp_n n WHERE n.parent IS NOT NULL
      UNION ALL SELECT n.id, md5(n.parent::text || 'N')::uuid FROM pg_temp.imp_n n WHERE n.parent IS NOT NULL
      UNION ALL SELECT md5(n.id::text || 'N')::uuid, md5(n.parent::text || 'N')::uuid FROM pg_temp.imp_n n WHERE n.parent IS NOT NULL;
    CREATE INDEX ON pg_temp.imp_x (p);
    CREATE TEMP TABLE imp_xr (id uuid PRIMARY KEY) ON COMMIT DROP;                  -- nodes reachable from the targets of the file's links
    INSERT INTO pg_temp.imp_xr
      WITH RECURSIVE rx(id) AS (
        SELECT e.t FROM pg_temp.imp_e e
        UNION SELECT md5(e.t::text || 'N')::uuid FROM pg_temp.imp_e e
        UNION SELECT x.t FROM rx JOIN pg_temp.imp_x x ON x.p = rx.id)
      SELECT id FROM rx;
    IF EXISTS (SELECT 1 FROM pg_temp.imp_e e JOIN pg_temp.imp_xr xr ON xr.id = e.p) THEN
      CREATE TEMP TABLE imp_xg (t uuid NOT NULL, p uuid NOT NULL) ON COMMIT DROP;   -- the edges of that part
      INSERT INTO pg_temp.imp_xg SELECT x.t, x.p FROM pg_temp.imp_x x WHERE x.t IN (SELECT id FROM pg_temp.imp_xr) AND x.p IN (SELECT id FROM pg_temp.imp_xr);
      CREATE INDEX ON pg_temp.imp_xg (p);
      CREATE TEMP TABLE imp_xd (id uuid PRIMARY KEY, deg integer NOT NULL) ON COMMIT DROP;
      INSERT INTO pg_temp.imp_xd SELECT xr.id, 0 FROM pg_temp.imp_xr xr;
      UPDATE pg_temp.imp_xd d SET deg = c.n FROM (SELECT g.t, count(*)::integer AS n FROM pg_temp.imp_xg g GROUP BY g.t) c WHERE c.t = d.id;
      SELECT count(*) INTO v_nodes FROM pg_temp.imp_xd;
      v_front := ARRAY(SELECT d.id FROM pg_temp.imp_xd d WHERE d.deg = 0);
      v_done := 0;
      WHILE coalesce(array_length(v_front, 1), 0) > 0 LOOP
        v_done := v_done + array_length(v_front, 1);
        WITH dec AS (
          UPDATE pg_temp.imp_xd d SET deg = d.deg - c.n
            FROM (SELECT g.t, count(*)::integer AS n FROM pg_temp.imp_xg g WHERE g.p = ANY (v_front) GROUP BY g.t) c
           WHERE d.id = c.t RETURNING d.id, d.deg)
        SELECT coalesce(array_agg(dec.id) FILTER (WHERE dec.deg = 0), ARRAY[]::uuid[]) INTO v_front FROM dec;
      END LOOP;
      IF v_done < v_nodes THEN RAISE EXCEPTION 'dependency cycle through the task hierarchy in the imported schedule' USING ERRCODE = '23514'; END IF;
    END IF;
  END IF;

  -- ---- 5. uid assignment from the per-job counter (phases and tasks of the job share one space; never 0; never handed out twice, X26)
  -- sched_next_uids returns the next free numbers above a counter that only moves forward (review L1: a planted uid cannot block the job;
  -- stored uids above the cap are ignored). Replace deletes every stored row, so those numbers are not "used", but the counter does not go back.
  SELECT count(*) INTO v_new_p FROM pg_temp.imp_p WHERE NOT matched;
  SELECT count(*) INTO v_new_t FROM pg_temp.imp_t WHERE NOT matched;
  v_free := sched_next_uids(p_job_id, v_company, v_new_p + v_new_t, p_mode = 'replace');
  UPDATE pg_temp.imp_p ip SET new_uid = v_free[s.rn] FROM (SELECT uid, row_number() OVER (ORDER BY idx) AS rn FROM pg_temp.imp_p WHERE NOT matched) s WHERE s.uid = ip.uid;
  UPDATE pg_temp.imp_t it SET new_uid = v_free[v_new_p + s.rn] FROM (SELECT uid, row_number() OVER (ORDER BY idx) AS rn FROM pg_temp.imp_t WHERE NOT matched) s WHERE s.uid = it.uid;

  -- ---- 6. baseline decision (Baseline on import): approver, >= 1 complete baseline, and no baseline locked yet unless replacing
  SELECT EXISTS (SELECT 1 FROM pg_temp.imp_t WHERE bstart IS NOT NULL AND bend IS NOT NULL) INTO v_has_bl;
  SELECT EXISTS (SELECT 1 FROM job_tasks WHERE job_id = p_job_id AND company_id = v_company AND baseline_locked_at IS NOT NULL) INTO v_prior_bl;
  IF p_mode <> 'replace' THEN v_locked := v_prior_bl; END IF;
  v_bl_ok := v_approver AND v_has_bl AND NOT v_locked;
  IF v_has_bl AND NOT v_bl_ok THEN
    SELECT count(*) INTO n_bl_ignored FROM pg_temp.imp_t WHERE bstart IS NOT NULL AND bend IS NOT NULL;
  END IF;

  -- ---- 7. writes (everything above this line has changed nothing)
  IF p_mode = 'replace' THEN
    -- L5: the recovery copy is the full row (to_jsonb) of exactly the rows this DELETE removes (DELETE ... RETURNING), so nothing can
    -- slip in between copy and delete, and every column (dates, baseline, flags, weight, hierarchy, uids) can be restored from it.
    -- Bounded by the 10000-task cap. The rows were locked in section 4.
    WITH d AS (DELETE FROM job_task_links WHERE job_id = p_job_id AND company_id = v_company RETURNING to_jsonb(job_task_links.*) AS j)
      SELECT coalesce(jsonb_agg(d.j ORDER BY d.j ->> 'created_at', d.j ->> 'id'), '[]'::jsonb), count(*)::integer INTO v_rec_l, v_del_l FROM d;
    WITH d AS (DELETE FROM job_tasks WHERE job_id = p_job_id AND company_id = v_company RETURNING to_jsonb(job_tasks.*) AS j)
      SELECT coalesce(jsonb_agg(d.j ORDER BY (d.j ->> 'sort_order')::integer, d.j ->> 'id'), '[]'::jsonb), count(*)::integer INTO v_rec_t, v_del_t FROM d;
    WITH d AS (DELETE FROM job_phases WHERE job_id = p_job_id AND company_id = v_company RETURNING to_jsonb(job_phases.*) AS j)
      SELECT coalesce(jsonb_agg(d.j ORDER BY (d.j ->> 'sort_order')::integer, d.j ->> 'id'), '[]'::jsonb), count(*)::integer INTO v_rec_p, v_del_p FROM d;
    v_recovery := jsonb_build_object(
      'note', 'full rows (to_jsonb) of what replace deleted: phases, tasks, links (task_id, predecessor_id, link_type, lag_days); written by the RPC itself',
      'phases', v_rec_p, 'tasks', v_rec_t, 'links', v_rec_l);
  END IF;

  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid, client_visible)
    SELECT ip.id, v_company, p_job_id, coalesce(ip.sort_order, ip.idx * 10), ip.name, ip.new_uid, false
      FROM pg_temp.imp_p ip WHERE NOT ip.matched ORDER BY ip.idx;
  GET DIAGNOSTICS n = ROW_COUNT;  v_created := v_created + n;
  UPDATE job_phases p SET name = ip.name, sort_order = coalesce(ip.sort_order, p.sort_order)
    FROM pg_temp.imp_p ip WHERE ip.matched AND ip.changed AND p.id = ip.id AND p.job_id = p_job_id AND p.company_id = v_company;

  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, assignee, phase_id, is_milestone, is_critical, client_visible, msp_uid)
    SELECT it.id, v_company, p_job_id, coalesce(it.sort_order, it.idx * 10), it.name, it.start_date, it.end_date, coalesce(it.progress, 0), it.assignee,
           ph.id, coalesce(it.is_milestone, false), false, false, it.new_uid
      FROM pg_temp.imp_t it LEFT JOIN pg_temp.imp_p ph ON ph.uid = it.phase_uid WHERE NOT it.matched ORDER BY it.idx;
  GET DIAGNOSTICS n = ROW_COUNT;  v_created := v_created + n;
  -- matched rows: a payload without dates keeps the stored dates; both dates or neither are taken
  UPDATE job_tasks t SET
      task_name = it.name,
      start_date = CASE WHEN it.start_date IS NOT NULL AND it.end_date IS NOT NULL THEN it.start_date ELSE t.start_date END,
      end_date   = CASE WHEN it.start_date IS NOT NULL AND it.end_date IS NOT NULL THEN it.end_date   ELSE t.end_date   END,
      progress = coalesce(it.progress, t.progress), is_milestone = coalesce(it.is_milestone, t.is_milestone),
      assignee = CASE WHEN it.has_assignee THEN it.assignee ELSE t.assignee END,
      phase_id = ph.id, sort_order = coalesce(it.sort_order, t.sort_order), is_critical = false,
      -- L4: a published task that moves to another phase (or out of its phase) must not become visible through the new phase's flag:
      -- it is unpublished in the same UPDATE, and job_visibility_guard writes the audit row; the editor re-publishes with the atom.
      client_visible = CASE WHEN t.phase_id IS DISTINCT FROM ph.id THEN false ELSE t.client_visible END
    FROM pg_temp.imp_t it LEFT JOIN pg_temp.imp_p ph ON ph.uid = it.phase_uid
   WHERE it.matched AND it.changed AND t.id = it.id AND t.job_id = p_job_id AND t.company_id = v_company;
  -- hierarchy: detach first (so a swap never passes through a cycle), then attach
  UPDATE job_tasks t SET parent_task_id = NULL FROM pg_temp.imp_t it
   WHERE it.id = t.id AND t.job_id = p_job_id AND t.company_id = v_company AND t.parent_task_id IS NOT NULL AND t.parent_task_id IS DISTINCT FROM it.parent_id;
  UPDATE job_tasks t SET parent_task_id = it.parent_id FROM pg_temp.imp_t it
   WHERE it.id = t.id AND t.job_id = p_job_id AND t.company_id = v_company AND it.parent_id IS NOT NULL AND t.parent_task_id IS DISTINCT FROM it.parent_id;

  -- links: new pairs inserted, an existing pair takes the file's type and lag (merge never deletes a link)
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type, lag_days)
    SELECT v_company, p_job_id, a.id, b.id, l.link_type, l.lag
      FROM pg_temp.imp_l l JOIN pg_temp.imp_t a ON a.uid = l.task_uid JOIN pg_temp.imp_t b ON b.uid = l.pred_uid ORDER BY l.ord
    ON CONFLICT (task_id, predecessor_id) DO UPDATE SET link_type = EXCLUDED.link_type, lag_days = EXCLUDED.lag_days
      WHERE (job_task_links.link_type, job_task_links.lag_days) IS DISTINCT FROM (EXCLUDED.link_type, EXCLUDED.lag_days);
  GET DIAGNOSTICS v_links_written = ROW_COUNT;
  -- depends_on keeps mirroring the FIRST predecessor of the file, only when it is Finish-to-Start (X24)
  UPDATE job_tasks t SET depends_on = f.pred_id
    FROM (SELECT DISTINCT ON (l.task_uid) l.task_uid, CASE WHEN l.link_type = 'FS' THEN b.id END AS pred_id
            FROM pg_temp.imp_l l JOIN pg_temp.imp_t b ON b.uid = l.pred_uid ORDER BY l.task_uid, l.ord) f
         JOIN pg_temp.imp_t a ON a.uid = f.task_uid
   WHERE t.id = a.id AND t.job_id = p_job_id AND t.company_id = v_company AND t.depends_on IS DISTINCT FROM f.pred_id;

  -- baseline: the only place the baseline columns are written, and only with the setting on for exactly this statement
  IF v_bl_ok THEN
    PERFORM set_config('app.baseline_rpc', 'on', true);
    UPDATE job_tasks t SET baseline_start = it.bstart, baseline_end = it.bend, baseline_locked_at = now()
      FROM pg_temp.imp_t it WHERE t.id = it.id AND t.job_id = p_job_id AND t.company_id = v_company AND it.bstart IS NOT NULL AND it.bend IS NOT NULL;
    GET DIAGNOSTICS v_nb = ROW_COUNT;
    PERFORM set_config('app.baseline_rpc', 'off', true);
  END IF;

  -- ---- 8. result and audit
  v_kept := CASE WHEN p_mode = 'replace' THEN 0 ELSE (v_ex_p + v_ex_t) - v_matched END;
  v_skipped := greatest(v_matched - v_updated, 0);
  v_warn := import_sched_warn(v_warn, 'name-truncated', 'Phase names longer than 80 characters were shortened.', n_trunc);
  v_warn := import_sched_warn(v_warn, 'name-defaulted', 'Rows with an empty name were called (unnamed).', n_defaulted);
  v_warn := import_sched_warn(v_warn, 'baseline-incomplete', 'Baselines with only a start or only a finish were ignored.', n_bl_partial);
  v_warn := import_sched_warn(v_warn, 'baseline-ignored',
              CASE WHEN NOT v_approver THEN 'Baseline dates were not imported: locking a baseline needs approval permission.'
                   ELSE 'Baseline dates were not imported: the job already has a locked baseline (use replace to reset it).' END, n_bl_ignored);
  v_warn := import_sched_warn(v_warn, 'uid-kind-changed', 'Rows whose file UID belongs to a different kind of row here were added as new rows.', n_kind);
  v_warn := import_sched_warn(v_warn, 'resources-ignored', 'Resources and assignments are not imported yet.', n_res);

  INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
  VALUES (p_job_id, v_job_no, auth.uid(), v_username, 'schedule_imported', 'Schedule imported (' || p_mode || ')',
          jsonb_build_object('mode', p_mode, 'file_name', v_file, 'created', v_created, 'updated', v_updated, 'kept', v_kept, 'skipped', v_skipped,
                             'warnings', v_warn, 'reason', nullif(v_reason, ''), 'links_written', v_links_written, 'baseline_tasks', v_nb,
                             'deleted', CASE WHEN p_mode = 'replace' THEN jsonb_build_object('phases', v_del_p, 'tasks', v_del_t, 'links', v_del_l) END,
                             'recovery', v_recovery));
  -- L5: replace that deletes a LOCKED baseline is a re-baseline whatever the new file carries: 'baseline_reset', the action name
  -- lock_job_baseline() (Phase A) uses for every lock after the first; a first lock stays 'baseline_locked'.
  IF v_nb > 0 OR (p_mode = 'replace' AND v_prior_bl) THEN
    INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
    VALUES (p_job_id, v_job_no, auth.uid(), v_username,
            CASE WHEN p_mode = 'replace' AND v_prior_bl THEN 'baseline_reset' ELSE 'baseline_locked' END,
            CASE WHEN p_mode = 'replace' AND v_prior_bl THEN 'Schedule re-baselined by import (replace): ' || v_reason ELSE 'Schedule baseline locked by import' END,
            jsonb_build_object('tasks', v_nb, 'source', 'import', 'mode', p_mode, 'file_name', v_file, 'reason', nullif(v_reason, '')));
  END IF;

  RETURN jsonb_build_object('created', v_created, 'updated', v_updated, 'kept', v_kept, 'skipped', v_skipped, 'warnings', v_warn);
END $$;
-- X13: Supabase default privileges also grant EXECUTE to anon, so PUBLIC alone is not enough. Authorisation is inside as well.
REVOKE ALL ON FUNCTION import_job_schedule(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION import_job_schedule(uuid, text, jsonb, text) TO authenticated;

-- ===== owner rule: the baseline guard lets baseline columns change only when current_user owns lock_job_baseline =====
DO $$
DECLARE v_lock oid; v_imp oid;
BEGIN
  SELECT p.proowner INTO v_lock FROM pg_proc p WHERE p.oid = to_regprocedure('public.lock_job_baseline(uuid,text)');
  SELECT p.proowner INTO v_imp  FROM pg_proc p WHERE p.oid = to_regprocedure('public.import_job_schedule(uuid,text,jsonb,text)');
  IF v_lock IS NULL THEN RAISE EXCEPTION 'lock_job_baseline(uuid,text) is missing: apply the Phase A migration first'; END IF;
  IF v_imp IS DISTINCT FROM v_lock THEN
    RAISE EXCEPTION 'import_job_schedule must be owned by % (the owner of lock_job_baseline), not %', pg_get_userbyid(v_lock), pg_get_userbyid(v_imp);
  END IF;
END $$;
