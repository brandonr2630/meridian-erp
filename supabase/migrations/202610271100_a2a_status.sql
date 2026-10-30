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
--   * r3 performance (behaviour-preserving). A link into a summary used to re-scan every task, with a parent-chain walk, per link and per pass,
--     and a chain listed against its direction needs ~n passes: a writer could make the function exceed statement_timeout (601 tasks / 599
--     links: 13 s). Now: kids / leaf-range tables are built once; when the value-flow graph of a direction is acyclic the fixpoint is unique and
--     ONE sweep in topological order computes it (links into a summary are folded into a per-summary bound that its leaves inherit); when it
--     is cyclic (only possible through the hierarchy, e.g. a leaf linked to its own summary) the original pass loop runs unchanged, with exact
--     ascending-leaf-order semantics kept and an exact prune (a bound already applied to every leaf of a summary is not re-applied).
--     Tests: tests/a2a_status/{bench-summary-links.sh,diff-vs-old.sh,pin-old.sh}, pinned r3 cases in 20_after.sql.
-- r4 M1(b) safety net: day arithmetic that cannot raise. A graph that never settles (a leaf linked to its own summary through the hierarchy: the
-- link guards refuse new ones, DBA-planted / legacy data can still hold them) makes the cyclic fallback below add rem + lag to a date on every
-- pass; with a few thousand tasks the dates ran past the end of the date range and the function raised 22008 "date out of range" for the whole job
-- (dashboard, nightly snapshot). job_sched_dadd(d, n) is d + n, SATURATING at the ends of the date range: 5874897-12-31 and 4714-11-24 BC.
-- It equals d + n whenever that is in range, so every graph that evaluated without error before gives exactly the same answer; only a graph that
-- used to raise now returns dates that sit on that bound (a forward runaway can end at forecast_end 5874897-12-31, a backward one at 4714-11-24 BC).
CREATE OR REPLACE FUNCTION job_sched_dadd(p_d date, p_n bigint) RETURNS date
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_n >= 0
              THEN CASE WHEN p_n > DATE '5874897-12-31' - p_d THEN DATE '5874897-12-31' ELSE p_d + p_n::integer END
              ELSE CASE WHEN -p_n > p_d - DATE '4714-11-24 BC' THEN DATE '4714-11-24 BC' ELSE p_d + p_n::integer END END $$;
REVOKE ALL ON FUNCTION job_sched_dadd(date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_sched_dadd(date, bigint) TO authenticated, service_role;

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
  jj int; ne int; nd int; dr int; e int; v int; qq int; qh int; qt int; nl int; sp int;                       -- r3 helpers
  kc int[]; kst int[]; kl int[]; lo int[]; hi int[]; lv int[]; stk int[]; kp int[]; lpos int[]; okp boolean[]; stamp int[]; cand1 date; candc date;
  esrc int[]; edst int[]; indeg int[]; ocnt int[]; ost int[]; oe int[]; q int[]; ford int[]; bord int[]; acyc_f boolean; acyc_b boolean;
  fps int[]; fpl int[]; bss int[]; bsl int[]; ownf date[]; effo date[]; ownb date[]; effb date[]; fapp date[]; bapp date[];
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
    IF sched[i] AND ef[i] IS NULL THEN ef[i] := job_sched_dadd(es[i], rem[i]); END IF;
  END LOOP;

  -- hierarchy: parent index per task (0 = none; unknown / other-job / self parent ignored)
  FOR i IN 1..n LOOP
    IF pids[i] IS NOT NULL THEN
      k := array_position(ids, pids[i]);
      IF k IS NOT NULL AND k <> i THEN par[i] := k; END IF;
    END IF;
  END LOOP;
  okp := array_fill(false, ARRAY[n]); stamp := array_fill(0, ARRAY[n]);
  FOR i IN 1..n LOOP                                -- cut a parent cycle: drop the edge that closes the loop (a chain already known to reach a root is not walked again: linear)
    IF okp[i] THEN CONTINUE; END IF;
    stamp[i] := i; k := i;
    WHILE par[k] <> 0 LOOP
      nx := par[k];
      IF okp[nx] THEN EXIT; END IF;
      IF stamp[nx] = i THEN par[k] := 0; EXIT; END IF;
      stamp[nx] := i; k := nx;
    END LOOP;
    k := i;
    WHILE k <> 0 AND NOT okp[k] LOOP okp[k] := true; k := par[k]; END LOOP;
  END LOOP;
  FOR i IN 1..n LOOP IF par[i] <> 0 THEN is_sum[par[i]] := true; END IF; END LOOP;
  -- r3 summary perf: kids of every task (CSR, ascending index) and, per task, the contiguous range lo..hi of its LEAF descendants in
  -- the leaf list lv (depth-first order), so "every leaf under summary t" is a slice, not a scan of all tasks with a parent-chain walk.
  kc := array_fill(0, ARRAY[n + 1]); kst := array_fill(0, ARRAY[n + 1]); kl := array_fill(0, ARRAY[n]);
  FOR i IN 1..n LOOP IF par[i] <> 0 THEN kc[par[i]] := kc[par[i]] + 1; END IF; END LOOP;
  kst[1] := 1;
  FOR i IN 1..n LOOP kst[i + 1] := kst[i] + kc[i]; kc[i] := 0; END LOOP;
  FOR i IN 1..n LOOP IF par[i] <> 0 THEN kl[kst[par[i]] + kc[par[i]]] := i; kc[par[i]] := kc[par[i]] + 1; END IF; END LOOP;
  lo := array_fill(0, ARRAY[n]); hi := array_fill(0, ARRAY[n]); lv := array_fill(0, ARRAY[n]); lpos := array_fill(0, ARRAY[n]);
  stk := array_fill(0, ARRAY[n]); kp := array_fill(0, ARRAY[n]); nl := 0;
  FOR i IN 1..n LOOP
    IF par[i] <> 0 THEN CONTINUE; END IF;
    sp := 1; stk[1] := i; lo[i] := nl + 1; kp[i] := kst[i];
    IF NOT is_sum[i] THEN nl := nl + 1; lv[nl] := i; lpos[i] := nl; END IF;
    WHILE sp > 0 LOOP
      k := stk[sp];
      IF kp[k] < kst[k + 1] THEN
        c := kl[kp[k]]; kp[k] := kp[k] + 1;
        sp := sp + 1; stk[sp] := c; kp[c] := kst[c]; lo[c] := nl + 1; depth[c] := depth[k] + 1;
        IF NOT is_sum[c] THEN nl := nl + 1; lv[nl] := c; lpos[c] := nl; END IF;
      ELSE
        hi[k] := nl; sp := sp - 1;
      END IF;
    END LOOP;
  END LOOP;
  -- summaries, deepest first, so a parent derives from finished children
  sd := ARRAY(SELECT g.ix FROM generate_series(1, n) AS g(ix) WHERE is_sum[g.ix] ORDER BY depth[g.ix] DESC, g.ix);
  FOR i IN 1..n LOOP IF is_sum[i] THEN sumids := sumids || ids[i]; END IF; END LOOP;
  FOREACH s IN ARRAY sd LOOP
    v_all := true; v_any := false;
    FOR jj IN kst[s]..kst[s + 1] - 1 LOOP
      c := kl[jj];
      IF NOT done[c] THEN v_all := false; END IF;
      IF sched[c] THEN v_any := true; END IF;
    END LOOP;
    done[s] := v_all; sched[s] := v_any;
  END LOOP;

  -- r3 order: links by predecessor (fps/fpl) and by successor (bss/bsl), CSR.
  fps := array_fill(0, ARRAY[n + 1]); fpl := array_fill(0, ARRAY[m]); bss := array_fill(0, ARRAY[n + 1]); bsl := array_fill(0, ARRAY[m]);
  ocnt := array_fill(0, ARRAY[n + 1]);
  FOR j IN 1..m LOOP ocnt[lp[j]] := ocnt[lp[j]] + 1; END LOOP;
  fps[1] := 1;
  FOR i IN 1..n LOOP fps[i + 1] := fps[i] + ocnt[i]; ocnt[i] := 0; END LOOP;
  FOR j IN 1..m LOOP fpl[fps[lp[j]] + ocnt[lp[j]]] := j; ocnt[lp[j]] := ocnt[lp[j]] + 1; END LOOP;
  ocnt := array_fill(0, ARRAY[n + 1]);
  FOR j IN 1..m LOOP ocnt[lt[j]] := ocnt[lt[j]] + 1; END LOOP;
  bss[1] := 1;
  FOR i IN 1..n LOOP bss[i + 1] := bss[i] + ocnt[i]; ocnt[i] := 0; END LOOP;
  FOR j IN 1..m LOOP bsl[bss[lt[j]] + ocnt[lt[j]]] := j; ocnt[lt[j]] := ocnt[lt[j]] + 1; END LOOP;

  -- r3 order: the value-flow graph of each pass direction, nodes 1..n = a task (a summary: its derived span) and n+s = the constraints
  -- that links INTO summary s put on all its leaves. Forward edges: predecessor -> successor (-> n+s when the successor is a summary and
  -- the type is start-bound), kid -> summary (derive), n+s -> every kid (leaf kid, or n+kid for a summary kid). Backward: successor ->
  -- predecessor (FS/FF into a summary predecessor), the same derive and inherit edges. Acyclic => the fixpoint is unique and one sweep in
  -- topological order computes it exactly (the n+1 pass cut-off cannot fire: the longest chain has <= n+1 edges). Cyclic (a leaf
  -- linked to its own summary: reachable through the hierarchy) => the original pass loop below, so non-settling values are unchanged.
  nd := 2 * n;
  esrc := array_fill(0, ARRAY[GREATEST(m + 2 * n, 1)]); edst := array_fill(0, ARRAY[GREATEST(m + 2 * n, 1)]);
  FOR dr IN 1..2 LOOP
    ne := 0;
    FOR j IN 1..m LOOP
      IF dr = 1 THEN s := lt[j]; c := lp[j]; ty := lty[j]; v_ok := NOT is_sum[s] OR ty IN ('FS', 'SS');   -- s = target, c = source
      ELSE           s := lp[j]; c := lt[j]; ty := lty[j]; v_ok := NOT is_sum[s] OR ty IN ('FS', 'FF'); END IF;
      IF v_ok THEN ne := ne + 1; esrc[ne] := c; edst[ne] := CASE WHEN is_sum[s] THEN n + s ELSE s END; END IF;
    END LOOP;
    FOR i IN 1..n LOOP
      IF par[i] <> 0 THEN
        ne := ne + 1; esrc[ne] := i; edst[ne] := par[i];
        ne := ne + 1; esrc[ne] := n + par[i]; edst[ne] := CASE WHEN is_sum[i] THEN n + i ELSE i END;
      END IF;
    END LOOP;
    indeg := array_fill(0, ARRAY[GREATEST(nd, 1)]); ocnt := array_fill(0, ARRAY[GREATEST(nd, 1) + 1]);
    ost := array_fill(0, ARRAY[GREATEST(nd, 1) + 1]); oe := array_fill(0, ARRAY[GREATEST(ne, 1)]); q := array_fill(0, ARRAY[GREATEST(nd, 1)]);
    FOR e IN 1..ne LOOP indeg[edst[e]] := indeg[edst[e]] + 1; ocnt[esrc[e]] := ocnt[esrc[e]] + 1; END LOOP;
    ost[1] := 1;
    FOR i IN 1..nd LOOP ost[i + 1] := ost[i] + ocnt[i]; ocnt[i] := 0; END LOOP;
    FOR e IN 1..ne LOOP oe[ost[esrc[e]] + ocnt[esrc[e]]] := edst[e]; ocnt[esrc[e]] := ocnt[esrc[e]] + 1; END LOOP;
    qt := 0;                                                                              -- Kahn's algorithm
    FOR i IN 1..nd LOOP IF indeg[i] = 0 THEN qt := qt + 1; q[qt] := i; END IF; END LOOP;
    qh := 1;
    WHILE qh <= qt LOOP
      i := q[qh]; qh := qh + 1;
      FOR e IN ost[i]..ost[i + 1] - 1 LOOP
        indeg[oe[e]] := indeg[oe[e]] - 1;
        IF indeg[oe[e]] = 0 THEN qt := qt + 1; q[qt] := oe[e]; END IF;
      END LOOP;
    END LOOP;
    IF dr = 1 THEN ford := q[1:qt]; acyc_f := (qt = nd); ELSE bord := q[1:qt]; acyc_b := (qt = nd); END IF;
  END LOOP;

  -- forward pass. A summary predecessor uses its derived start/end; a link INTO a summary constrains every leaf of it for FS/SS and is
  -- ignored for FF/SF.
  IF acyc_f THEN
    -- one sweep in topological order. A node is final when reached: a leaf has received every link and every ancestor-summary
    -- constraint (effo, own link constraints of the summary maxed with its parent's), a summary derives from its kids (deriveFwd).
    ownf := array_fill(NULL::date, ARRAY[n]); effo := array_fill(NULL::date, ARRAY[n]);
    FOREACH v IN ARRAY ford LOOP
      IF v > n THEN
        s := v - n;
        IF is_sum[s] THEN
          effo[s] := ownf[s];
          IF par[s] <> 0 THEN
            IF effo[par[s]] IS NOT NULL AND (effo[s] IS NULL OR effo[par[s]] > effo[s]) THEN effo[s] := effo[par[s]]; END IF;
          END IF;
        END IF;
        CONTINUE;
      END IF;
      IF is_sum[v] THEN
        e0 := NULL; f0 := NULL;
        FOR jj IN kst[v]..kst[v + 1] - 1 LOOP
          c := kl[jj];
          IF sched[c] THEN
            IF e0 IS NULL OR es[c] < e0 THEN e0 := es[c]; END IF;
            IF f0 IS NULL OR ef[c] > f0 THEN f0 := ef[c]; END IF;
          END IF;
        END LOOP;
        IF e0 IS NOT NULL THEN es[v] := e0; ef[v] := f0; END IF;
      ELSIF par[v] <> 0 AND sched[v] AND NOT done[v] THEN
        IF effo[par[v]] > es[v] THEN es[v] := effo[par[v]]; ef[v] := job_sched_dadd(es[v], rem[v]); END IF;
      END IF;
      FOR jj IN fps[v]..fps[v + 1] - 1 LOOP           -- the links that have v as predecessor
        j := fpl[jj]; t := lt[j]; ty := lty[j];
        IF NOT (sched[t] AND sched[v] AND ef[v] IS NOT NULL) THEN CONTINUE; END IF;
        IF is_sum[t] AND ty NOT IN ('FS', 'SS') THEN CONTINUE; END IF;
        cand := CASE ty WHEN 'FS' THEN job_sched_dadd(ef[v], llag[j])
                        WHEN 'SS' THEN job_sched_dadd(es[v], llag[j])
                        WHEN 'FF' THEN job_sched_dadd(ef[v], llag[j]::bigint - rem[t])
                        ELSE           job_sched_dadd(es[v], llag[j]::bigint - rem[t]) END;
        IF is_sum[t] THEN
          IF ownf[t] IS NULL OR cand > ownf[t] THEN ownf[t] := cand; END IF;
        ELSIF NOT done[t] AND cand > es[t] THEN
          es[t] := cand; ef[t] := job_sched_dadd(cand, rem[t]);
        END IF;
      END LOOP;
    END LOOP;
  ELSE
    fapp := array_fill(NULL::date, ARRAY[n]);       -- fapp[t]: a constraint already applied to ALL leaves of summary t (they are all >= it: starts only grow)
    pass := 0;
    LOOP
      v_changed := false;
      FOREACH s IN ARRAY sd LOOP                    -- deriveFwd: summary span = min start / max end of its scheduled kids
        e0 := NULL; f0 := NULL;
        FOR jj IN kst[s]..kst[s + 1] - 1 LOOP
          c := kl[jj];
          IF sched[c] THEN
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
        c_lo := CASE WHEN is_sum[t] THEN lo[t] ELSE 1 END; c_hi := CASE WHEN is_sum[t] THEN hi[t] ELSE 1 END;
        c := CASE WHEN is_sum[t] THEN lv[c_lo] ELSE t END;
        cand := CASE ty WHEN 'FS' THEN job_sched_dadd(ef[p], llag[j])
                        WHEN 'SS' THEN job_sched_dadd(es[p], llag[j])
                        WHEN 'FF' THEN job_sched_dadd(ef[p], llag[j]::bigint - rem[c])
                        ELSE           job_sched_dadd(es[p], llag[j]::bigint - rem[c]) END;   -- for a summary target (FS/SS only) the value does not depend on the leaf
        IF is_sum[t] AND fapp[t] IS NOT NULL AND cand <= fapp[t] THEN CONTINUE; END IF;
        cand1 := cand;                              -- the value the leaves AFTER p (higher index) see, when p is itself one of the leaves
        IF is_sum[t] AND NOT is_sum[p] AND lpos[p] BETWEEN c_lo AND c_hi AND NOT done[p] AND cand > es[p] THEN
          e0 := es[p]; f0 := ef[p]; es[p] := cand; ef[p] := job_sched_dadd(cand, rem[p]); v_changed := true;
          cand1 := job_sched_dadd(cand, CASE ty WHEN 'FS' THEN ef[p] - f0 ELSE es[p] - e0 END);
        END IF;
        FOR qq IN c_lo..c_hi LOOP                   -- leaves in ascending index order matter only through p, handled above
          c := CASE WHEN is_sum[t] THEN lv[qq] ELSE t END;
          IF NOT sched[c] OR done[c] THEN CONTINUE; END IF;
          candc := CASE WHEN c > p THEN cand1 ELSE cand END;
          IF candc > es[c] THEN es[c] := candc; ef[c] := job_sched_dadd(candc, rem[c]); v_changed := true; END IF;
        END LOOP;
        IF is_sum[t] THEN fapp[t] := cand; END IF;
      END LOOP;
      EXIT WHEN NOT v_changed;
      pass := pass + 1;
      IF pass > n + 1 THEN EXIT; END IF;
    END LOOP;
    FOREACH s IN ARRAY sd LOOP                      -- deriveFwd once more, on the settled values
      e0 := NULL; f0 := NULL;
      FOR jj IN kst[s]..kst[s + 1] - 1 LOOP
        c := kl[jj];
        IF sched[c] THEN
          IF e0 IS NULL OR es[c] < e0 THEN e0 := es[c]; END IF;
          IF f0 IS NULL OR ef[c] > f0 THEN f0 := ef[c]; END IF;
        END IF;
      END LOOP;
      IF e0 IS NOT NULL THEN es[s] := e0; ef[s] := f0; END IF;
    END LOOP;
  END IF;

  SELECT max(ef[g.ix]) INTO v_fe FROM generate_subscripts(ef, 1) AS g(ix) WHERE sched[g.ix] AND NOT is_sum[g.ix];
  v_deadline := coalesce(v_due, v_fe);

  -- backward pass (incomplete leaves only; a summary derives from its incomplete kids)
  FOR i IN 1..n LOOP
    IF sched[i] AND NOT done[i] AND NOT is_sum[i] THEN lf[i] := v_deadline; ls[i] := job_sched_dadd(v_deadline, -rem[i]); END IF;
  END LOOP;
  IF acyc_b THEN
    -- one sweep in topological order of the backward graph (see the forward sweep): a task is final when reached.
    ownb := array_fill(NULL::date, ARRAY[n]); effb := array_fill(NULL::date, ARRAY[n]);
    FOREACH v IN ARRAY bord LOOP
      IF v > n THEN
        s := v - n;
        IF is_sum[s] THEN
          effb[s] := ownb[s];
          IF par[s] <> 0 THEN
            IF effb[par[s]] IS NOT NULL AND (effb[s] IS NULL OR effb[par[s]] < effb[s]) THEN effb[s] := effb[par[s]]; END IF;
          END IF;
        END IF;
        CONTINUE;
      END IF;
      IF is_sum[v] THEN                             -- deriveBwd: min late start / max late finish of incomplete scheduled kids
        b0 := NULL; f0 := NULL;
        FOR jj IN kst[v]..kst[v + 1] - 1 LOOP
          c := kl[jj];
          IF sched[c] AND NOT done[c] THEN
            IF b0 IS NULL OR ls[c] < b0 THEN b0 := ls[c]; END IF;
            IF f0 IS NULL OR lf[c] > f0 THEN f0 := lf[c]; END IF;
          END IF;
        END LOOP;
        IF b0 IS NOT NULL THEN ls[v] := b0; lf[v] := f0; END IF;
      ELSIF par[v] <> 0 AND sched[v] AND NOT done[v] THEN
        IF effb[par[v]] < lf[v] THEN lf[v] := effb[par[v]]; ls[v] := job_sched_dadd(lf[v], -rem[v]); END IF;
      END IF;
      FOR jj IN bss[v]..bss[v + 1] - 1 LOOP         -- the links that have v as successor
        j := bsl[jj]; p := lp[j]; ty := lty[j];
        IF NOT (sched[v] AND sched[p] AND NOT done[v] AND NOT done[p]) THEN CONTINUE; END IF;
        IF ls[v] IS NULL OR lf[v] IS NULL THEN CONTINUE; END IF;
        IF is_sum[p] AND ty NOT IN ('FS', 'FF') THEN CONTINUE; END IF;
        cand := CASE ty WHEN 'FS' THEN job_sched_dadd(ls[v], -llag[j]::bigint)
                        WHEN 'FF' THEN job_sched_dadd(lf[v], -llag[j]::bigint)
                        WHEN 'SS' THEN job_sched_dadd(ls[v], rem[p] - llag[j]::bigint)
                        ELSE           job_sched_dadd(lf[v], rem[p] - llag[j]::bigint) END;
        IF is_sum[p] THEN
          IF ownb[p] IS NULL OR cand < ownb[p] THEN ownb[p] := cand; END IF;
        ELSIF cand < lf[p] THEN
          lf[p] := cand; ls[p] := job_sched_dadd(cand, -rem[p]);
        END IF;
      END LOOP;
    END LOOP;
  ELSE
    bapp := array_fill(NULL::date, ARRAY[n]);       -- bapp[p]: a constraint already applied to ALL leaves of summary p (their late finish is <= it)
    pass := 0;
    LOOP
      v_changed := false;
      FOREACH s IN ARRAY sd LOOP                    -- deriveBwd: min late start / max late finish of incomplete scheduled kids
        b0 := NULL; f0 := NULL;
        FOR jj IN kst[s]..kst[s + 1] - 1 LOOP
          c := kl[jj];
          IF sched[c] AND NOT done[c] THEN
            IF b0 IS NULL OR ls[c] < b0 THEN b0 := ls[c]; END IF;
            IF f0 IS NULL OR lf[c] > f0 THEN f0 := lf[c]; END IF;
          END IF;
        END LOOP;
        IF b0 IS NOT NULL THEN ls[s] := b0; lf[s] := f0; END IF;
      END LOOP;
      FOR j IN 1..m LOOP
        t := lt[j]; p := lp[j]; ty := lty[j];       -- t = successor, p = predecessor
        IF NOT (sched[t] AND sched[p] AND NOT done[t] AND NOT done[p]) THEN CONTINUE; END IF;
        IF ls[t] IS NULL OR lf[t] IS NULL THEN CONTINUE; END IF;
        IF is_sum[p] AND ty NOT IN ('FS', 'FF') THEN CONTINUE; END IF;
        c_lo := CASE WHEN is_sum[p] THEN lo[p] ELSE 1 END; c_hi := CASE WHEN is_sum[p] THEN hi[p] ELSE 1 END;
        c := CASE WHEN is_sum[p] THEN lv[c_lo] ELSE p END;
        cand := CASE ty WHEN 'FS' THEN job_sched_dadd(ls[t], -llag[j]::bigint)
                        WHEN 'FF' THEN job_sched_dadd(lf[t], -llag[j]::bigint)
                        WHEN 'SS' THEN job_sched_dadd(ls[t], rem[c] - llag[j]::bigint)
                        ELSE           job_sched_dadd(lf[t], rem[c] - llag[j]::bigint) END;   -- for a summary predecessor (FS/FF only) the value does not depend on the leaf
        IF is_sum[p] AND bapp[p] IS NOT NULL AND cand >= bapp[p] THEN CONTINUE; END IF;
        cand1 := cand;                              -- the value the leaves AFTER t (higher index) see, when t is itself one of the leaves
        IF is_sum[p] AND NOT is_sum[t] AND lpos[t] BETWEEN c_lo AND c_hi AND cand < lf[t] THEN
          e0 := ls[t]; f0 := lf[t]; lf[t] := cand; ls[t] := job_sched_dadd(cand, -rem[t]); v_changed := true;
          cand1 := job_sched_dadd(cand, CASE ty WHEN 'FS' THEN ls[t] - e0 ELSE lf[t] - f0 END);
        END IF;
        FOR qq IN c_lo..c_hi LOOP
          c := CASE WHEN is_sum[p] THEN lv[qq] ELSE p END;
          IF NOT sched[c] OR done[c] THEN CONTINUE; END IF;
          candc := CASE WHEN c > t THEN cand1 ELSE cand END;
          IF candc < lf[c] THEN lf[c] := candc; ls[c] := job_sched_dadd(candc, -rem[c]); v_changed := true; END IF;
        END LOOP;
        IF is_sum[p] THEN bapp[p] := cand; END IF;
      END LOOP;
      EXIT WHEN NOT v_changed;
      pass := pass + 1;
      IF pass > n + 1 THEN EXIT; END IF;
    END LOOP;
  END IF;

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
