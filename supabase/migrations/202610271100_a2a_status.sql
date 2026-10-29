-- Phase A2a: job_schedule_status honours link types (FS/SS/FF/SF) and the task hierarchy, exactly like the JS engine
-- jcSchedCompute (index.html). Spec: docs/specs/project-portal/phase-a2-projectlibre.md ("Resolutions of N1-N11", "Link-type semantics").
-- Order: after 202610271000_a2a_schema.sql (needs job_task_links.link_type and job_tasks.parent_task_id; nothing else from it).
-- CREATE OR REPLACE with the SAME signature, return shape (status text, forecast_end date, slip_days integer), SECURITY INVOKER,
-- STABLE and search_path as Phase A, so grants and every existing caller are untouched. Idempotent. NOT applied to prod.
-- Rollback: supabase/rollbacks/202610271100_a2a_status_down.sql (restores the exact Phase A body).
-- Built and tested on a throwaway Postgres 17: bash supabase/tests/d0c_common/run.sh a2a_status ; shared fixture:
-- bash supabase/tests/phase_a_sql/run-fixture.sh ; mutants: node supabase/tests/d0c_common/mutate.mjs a2a_status
--
-- What changes against Phase A (everything else is the Phase A body, line for line):
--   * link types. Day numbers: es = first day, ef/lf = day after the last. Forward: the earliest start a link allows is
--     FS ef[p]+lag, SS es[p]+lag, FF ef[p]+lag-rem[c], SF es[p]+lag-rem[c]. Backward (latest finish): FS ls[t]-lag, FF lf[t]-lag,
--     SS ls[t]-lag+rem[c], SF lf[t]-lag+rem[c]. A missing / unknown link_type is FS.
--   * hierarchy (job_tasks.parent_task_id, N1). A task with children is a SUMMARY: dates derived from its leaf descendants,
--     weight 0 and no progress of its own (excluded from overall / planned, X1 amendment), never critical, never "late" by itself,
--     not part of the forecast. A parent outside this job, or itself, is ignored; a parent cycle is cut (hierarchy-cycle in JS):
--     walking tasks in sort order, the edge that would close the loop is dropped. A link whose successor is a summary constrains
--     every leaf of it for start-bound types (FS, SS); a finish-bound type (FF, SF) into a summary is ignored (summary-link-approx).
--     Backward the same with predecessor-summary: FS and FF apply to every leaf, SS and SF are ignored.
--   * a pass that does not settle (n+1 passes) STOPS and carries on with the values so far, as JS does ('cycle' warning), instead
--     of raising: a leaf linked to its own summary is reachable through the hierarchy (the link trigger only sees link cycles),
--     and a status function that raises would break the dashboard and the nightly snapshot for the whole job.
CREATE OR REPLACE FUNCTION job_schedule_status(
  p_job_id uuid,
  p_today  date DEFAULT (timezone('America/Port_of_Spain', now()))::date)
RETURNS TABLE (status text, forecast_end date, slip_days integer)
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  k_late_days constant integer := 5;     -- Open question 2 defaults; keep equal to the JS constants
  k_gap_pts   constant integer := 10;
  v_jstatus text; v_due date;
  n int := 0; m int := 0; i int; j int; t int; p int; pass int;
  ids uuid[] := '{}'; rem int[] := '{}'; es date[] := '{}'; ef date[] := '{}'; ls date[] := '{}'; lf date[] := '{}';
  endd date[] := '{}'; done boolean[] := '{}'; ms boolean[] := '{}'; sched boolean[] := '{}';
  lt int[] := '{}'; lp int[] := '{}'; llag int[] := '{}'; lty text[] := '{}';
  pids uuid[] := '{}'; par int[] := '{}'; is_sum boolean[] := '{}'; depth int[] := '{}';
  sd int[]; sumids uuid[] := '{}'; seen int[];
  c int; c_lo int; c_hi int; k int; nx int; s int; ty text; e0 date; f0 date; b0 date; v_all boolean; v_any boolean; v_ok boolean;
  r record; v_changed boolean; cand date; v_deadline date; v_fe date; v_minslack int;
  v_overall numeric; v_planned numeric; v_has_bl boolean; v_base_end date; v_slip int; v_gap numeric;
  v_late boolean := false; v_late_days int := 0; v_status text; v_dur int; v_prog int; v_sd date; v_ed date;
BEGIN
  SELECT j.status, j.due_date INTO v_jstatus, v_due FROM jobs j WHERE j.id = p_job_id;
  IF NOT FOUND THEN RETURN; END IF;               -- invisible under RLS or missing: no rows

  -- load tasks (milestones: rem 0; done = progress 100)
  FOR r IN SELECT id, start_date, end_date, progress, is_milestone, parent_task_id FROM job_tasks
            WHERE job_id = p_job_id ORDER BY sort_order, id LOOP
    n := n + 1;
    v_prog := coalesce(r.progress, 0);
    -- M1 (review 2): a writer can store any date (year 99999), and v_dur * (100 - v_prog) or es + rem would then overflow integer and make
    -- this function raise for the whole job (dashboard, nightly snapshot). Dates are clamped to 2000-01-01..2100-12-31 on load (the import range).
    v_sd := CASE WHEN r.start_date IS NULL THEN NULL ELSE LEAST(GREATEST(r.start_date, DATE '2000-01-01'), DATE '2100-12-31') END;
    v_ed := CASE WHEN r.end_date   IS NULL THEN NULL ELSE LEAST(GREATEST(r.end_date,   DATE '2000-01-01'), DATE '2100-12-31') END;
    v_dur  := GREATEST(1, CASE WHEN v_sd IS NOT NULL AND v_ed IS NOT NULL
                               THEN v_ed - v_sd + 1 ELSE 1 END);
    ids  := ids  || r.id;
    pids := pids || r.parent_task_id;
    endd := endd || v_ed;
    done := done || (v_prog = 100);
    ms   := ms   || r.is_milestone;
    rem  := rem  || (CASE WHEN r.is_milestone OR v_prog = 100 THEN 0
                          ELSE GREATEST(1, ceil(v_dur * (100 - v_prog) / 100.0)::int) END);
    sched := sched || (v_sd IS NOT NULL AND v_ed IS NOT NULL);
    -- base earliest start: done and started tasks keep their actual start; others start today
    es := es || (CASE WHEN v_prog = 100 OR v_prog > 0 THEN coalesce(v_sd, p_today) ELSE p_today END);
    ef := ef || (CASE WHEN v_prog = 100 THEN v_ed ELSE NULL END);   -- done keep their actual end
    ls := ls || NULL::date;  lf := lf || NULL::date;                      -- pre-size (array lower bound stays 1)
    par := par || 0;  is_sum := is_sum || false;  depth := depth || 0;
  END LOOP;

  FOR r IN SELECT task_id, predecessor_id, lag_days, link_type FROM job_task_links WHERE job_id = p_job_id LOOP
    t := array_position(ids, r.task_id); p := array_position(ids, r.predecessor_id);
    IF t IS NOT NULL AND p IS NOT NULL THEN
      m := m + 1; lt := lt || t; lp := lp || p; llag := llag || coalesce(r.lag_days, 0);
      lty := lty || (CASE WHEN r.link_type IN ('SS', 'FF', 'SF') THEN r.link_type ELSE 'FS' END);   -- missing / unknown = FS
      -- undated tasks with a link take part in the pass (dur 1, start today); done undated stay out
      IF NOT (done[t] AND endd[t] IS NULL) THEN sched[t] := true; END IF;
      IF NOT (done[p] AND endd[p] IS NULL) THEN sched[p] := true; END IF;
    END IF;
  END LOOP;

  FOR i IN 1..n LOOP
    IF sched[i] AND ef[i] IS NULL THEN ef[i] := es[i] + rem[i]; END IF;
  END LOOP;

  -- hierarchy: parent index per task (0 = none; unknown / other-job / self parent ignored)
  FOR i IN 1..n LOOP
    IF pids[i] IS NOT NULL THEN
      k := array_position(ids, pids[i]);
      IF k IS NOT NULL AND k <> i THEN par[i] := k; END IF;
    END IF;
  END LOOP;
  FOR i IN 1..n LOOP                                -- cut a parent cycle: drop the edge that closes the loop
    seen := ARRAY[i]; k := i;
    WHILE par[k] <> 0 LOOP
      nx := par[k];
      IF nx = ANY (seen) THEN par[k] := 0; EXIT; END IF;
      seen := seen || nx; k := nx;
    END LOOP;
  END LOOP;
  FOR i IN 1..n LOOP IF par[i] <> 0 THEN is_sum[par[i]] := true; END IF; END LOOP;
  FOR i IN 1..n LOOP
    k := par[i];
    WHILE k <> 0 LOOP depth[i] := depth[i] + 1; k := par[k]; END LOOP;
  END LOOP;
  -- summaries, deepest first, so a parent derives from finished children
  sd := ARRAY(SELECT g.ix FROM generate_series(1, n) AS g(ix) WHERE is_sum[g.ix] ORDER BY depth[g.ix] DESC, g.ix);
  FOR i IN 1..n LOOP IF is_sum[i] THEN sumids := sumids || ids[i]; END IF; END LOOP;
  FOREACH s IN ARRAY sd LOOP
    v_all := true; v_any := false;
    FOR c IN 1..n LOOP
      IF par[c] = s THEN
        IF NOT done[c] THEN v_all := false; END IF;
        IF sched[c] THEN v_any := true; END IF;
      END IF;
    END LOOP;
    done[s] := v_all; sched[s] := v_any;
  END LOOP;

  -- forward pass (relaxation over links; a pass that does not settle stops, like JS). A summary predecessor uses its derived
  -- start/end; a link INTO a summary constrains every leaf of it for FS/SS and is ignored for FF/SF.
  pass := 0;
  LOOP
    v_changed := false;
    FOREACH s IN ARRAY sd LOOP                      -- deriveFwd: summary span = min start / max end of its scheduled kids
      e0 := NULL; f0 := NULL;
      FOR c IN 1..n LOOP
        IF par[c] = s AND sched[c] THEN
          IF e0 IS NULL OR es[c] < e0 THEN e0 := es[c]; END IF;
          IF f0 IS NULL OR ef[c] > f0 THEN f0 := ef[c]; END IF;
        END IF;
      END LOOP;
      IF e0 IS NOT NULL THEN es[s] := e0; ef[s] := f0; END IF;
    END LOOP;
    FOR j IN 1..m LOOP
      t := lt[j]; p := lp[j]; ty := lty[j];
      IF NOT (sched[t] AND sched[p] AND ef[p] IS NOT NULL) THEN CONTINUE; END IF;
      IF is_sum[t] AND ty NOT IN ('FS', 'SS') THEN CONTINUE; END IF;
      c_lo := CASE WHEN is_sum[t] THEN 1 ELSE t END; c_hi := CASE WHEN is_sum[t] THEN n ELSE t END;
      FOR c IN c_lo..c_hi LOOP
        IF is_sum[t] THEN                           -- targets = the leaf descendants of the summary t
          IF is_sum[c] THEN CONTINUE; END IF;
          k := par[c]; WHILE k <> 0 AND k <> t LOOP k := par[k]; END LOOP;
          IF k <> t THEN CONTINUE; END IF;
        END IF;
        IF NOT sched[c] OR done[c] THEN CONTINUE; END IF;
        cand := CASE ty WHEN 'FS' THEN ef[p] + llag[j]
                        WHEN 'SS' THEN es[p] + llag[j]
                        WHEN 'FF' THEN ef[p] + llag[j] - rem[c]
                        ELSE           es[p] + llag[j] - rem[c] END;
        IF cand > es[c] THEN es[c] := cand; ef[c] := cand + rem[c]; v_changed := true; END IF;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
    pass := pass + 1;
    IF pass > n + 1 THEN EXIT; END IF;
  END LOOP;
  FOREACH s IN ARRAY sd LOOP                        -- deriveFwd once more, on the settled values
    e0 := NULL; f0 := NULL;
    FOR c IN 1..n LOOP
      IF par[c] = s AND sched[c] THEN
        IF e0 IS NULL OR es[c] < e0 THEN e0 := es[c]; END IF;
        IF f0 IS NULL OR ef[c] > f0 THEN f0 := ef[c]; END IF;
      END IF;
    END LOOP;
    IF e0 IS NOT NULL THEN es[s] := e0; ef[s] := f0; END IF;
  END LOOP;

  SELECT max(ef[g.ix]) INTO v_fe FROM generate_subscripts(ef, 1) AS g(ix) WHERE sched[g.ix] AND NOT is_sum[g.ix];
  v_deadline := coalesce(v_due, v_fe);

  -- backward pass (incomplete leaves only; a summary derives from its incomplete kids)
  FOR i IN 1..n LOOP
    IF sched[i] AND NOT done[i] AND NOT is_sum[i] THEN lf[i] := v_deadline; ls[i] := v_deadline - rem[i]; END IF;
  END LOOP;
  pass := 0;
  LOOP
    v_changed := false;
    FOREACH s IN ARRAY sd LOOP                      -- deriveBwd: min late start / max late finish of incomplete scheduled kids
      b0 := NULL; f0 := NULL;
      FOR c IN 1..n LOOP
        IF par[c] = s AND sched[c] AND NOT done[c] THEN
          IF b0 IS NULL OR ls[c] < b0 THEN b0 := ls[c]; END IF;
          IF f0 IS NULL OR lf[c] > f0 THEN f0 := lf[c]; END IF;
        END IF;
      END LOOP;
      IF b0 IS NOT NULL THEN ls[s] := b0; lf[s] := f0; END IF;
    END LOOP;
    FOR j IN 1..m LOOP
      t := lt[j]; p := lp[j]; ty := lty[j];         -- t = successor, p = predecessor
      IF NOT (sched[t] AND sched[p] AND NOT done[t] AND NOT done[p]) THEN CONTINUE; END IF;
      IF ls[t] IS NULL OR lf[t] IS NULL THEN CONTINUE; END IF;
      IF is_sum[p] AND ty NOT IN ('FS', 'FF') THEN CONTINUE; END IF;
      c_lo := CASE WHEN is_sum[p] THEN 1 ELSE p END; c_hi := CASE WHEN is_sum[p] THEN n ELSE p END;
      FOR c IN c_lo..c_hi LOOP
        IF is_sum[p] THEN                           -- targets = the leaf descendants of the summary p
          IF is_sum[c] THEN CONTINUE; END IF;
          k := par[c]; WHILE k <> 0 AND k <> p LOOP k := par[k]; END LOOP;
          IF k <> p THEN CONTINUE; END IF;
        END IF;
        IF NOT sched[c] OR done[c] THEN CONTINUE; END IF;
        cand := CASE ty WHEN 'FS' THEN ls[t] - llag[j]
                        WHEN 'FF' THEN lf[t] - llag[j]
                        WHEN 'SS' THEN ls[t] - llag[j] + rem[c]
                        ELSE           lf[t] - llag[j] + rem[c] END;
        IF cand < lf[c] THEN lf[c] := cand; ls[c] := cand - rem[c]; v_changed := true; END IF;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
    pass := pass + 1;
    IF pass > n + 1 THEN EXIT; END IF;
  END LOOP;

  -- slack and critical set: slack <= 0; if the deadline is later than the forecast (min slack > 0) the min-slack path.
  -- Summaries are never critical and never late on their own.
  SELECT min(ls[g.ix] - es[g.ix]) INTO v_minslack FROM generate_subscripts(ls, 1) AS g(ix)
   WHERE sched[g.ix] AND NOT done[g.ix] AND NOT is_sum[g.ix];
  FOR i IN 1..n LOOP
    -- late critical: an incomplete critical task, or incomplete milestone, whose end_date is already past
    IF NOT is_sum[i] AND NOT done[i] AND endd[i] IS NOT NULL AND endd[i] < p_today
       AND ((sched[i] AND (ls[i] - es[i]) <= GREATEST(0, v_minslack)) OR ms[i]) THEN
      v_late := true; v_late_days := GREATEST(v_late_days, p_today - endd[i]);
    END IF;
  END LOOP;

  -- overall and planned today, by the X1 rule (summaries carry weight 0: leaves only), via the X20 helpers; 2 dp
  SELECT COALESCE(ROUND(SUM(w * progress) / NULLIF(SUM(w), 0), 2), 0),
         COALESCE(ROUND(SUM(w * job_task_planned_pct(baseline_start, baseline_end, start_date, end_date, p_today))
                        / NULLIF(SUM(w), 0), 2), 0)
    INTO v_overall, v_planned
    FROM (SELECT id, job_task_weight(is_milestone, weight, start_date, end_date) AS w, progress,
                 baseline_start, baseline_end, start_date, end_date
            FROM job_tasks WHERE job_id = p_job_id) x
   WHERE w > 0 AND NOT (x.id = ANY (sumids));

  SELECT EXISTS (SELECT 1 FROM job_tasks WHERE job_id = p_job_id AND baseline_locked_at IS NOT NULL) INTO v_has_bl;
  SELECT coalesce(max(baseline_end), v_due) INTO v_base_end FROM job_tasks WHERE job_id = p_job_id;
  v_slip := CASE WHEN v_fe IS NOT NULL AND v_base_end IS NOT NULL THEN v_fe - v_base_end END;
  v_gap  := CASE WHEN v_has_bl THEN v_overall - v_planned END;

  v_status := CASE
    WHEN v_jstatus IN ('Completed', 'Invoiced', 'Closed') THEN 'Complete'
    WHEN v_jstatus = 'On Hold' THEN 'On hold'
    WHEN coalesce(v_slip, 0) > k_late_days OR v_late_days > k_late_days THEN 'Late'
    WHEN coalesce(v_slip, 0) BETWEEN 1 AND k_late_days OR coalesce(v_gap, 0) < -k_gap_pts OR v_late THEN 'At risk'
    ELSE 'On track' END;

  status := v_status; forecast_end := v_fe; slip_days := v_slip;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION job_schedule_status(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_schedule_status(uuid, date) TO authenticated;
