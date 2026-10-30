-- Rollback of 202610271100_a2a_status.sql: restores the exact Phase A body of job_schedule_status (link types and hierarchy ignored again).
-- The body below is copied verbatim from supabase/migrations/202610210600_phase_a_sql.sql (checked by supabase/tests/a2a_status/30_rollback.sql).
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
  lt int[] := '{}'; lp int[] := '{}'; llag int[] := '{}';
  r record; v_changed boolean; cand date; v_deadline date; v_fe date; v_minslack int;
  v_overall numeric; v_planned numeric; v_has_bl boolean; v_base_end date; v_slip int; v_gap numeric;
  v_late boolean := false; v_late_days int := 0; v_status text; v_dur int; v_prog int;
BEGIN
  SELECT j.status, j.due_date INTO v_jstatus, v_due FROM jobs j WHERE j.id = p_job_id;
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
  v_deadline := coalesce(v_due, v_fe);

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
-- r4 M1(b): the saturating day-add helper the new body used (nothing else calls it)
DROP FUNCTION IF EXISTS job_sched_dadd(date, bigint);
