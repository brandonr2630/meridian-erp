-- Differential test: job_schedule_status (new) against job_schedule_status_old (the pre-change body, loaded by diff-vs-old.sh).
-- pg_temp-free on purpose (psql session); builds jobs in the stub schema and compares row-for-row. Prints DIFF lines and a summary.
CREATE OR REPLACE FUNCTION public.zz_mkjob(p_seed int, p_mode int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE jid uuid := gen_random_uuid(); n int; i int; ids uuid[] := '{}'; x uuid; pr int; sd date; ed date; k int; a int; b int; ty text[] := ARRAY['FS','SS','FF','SF'];
  co constant uuid := 'c1000000-0000-0000-0000-000000000001'; nl int; r double precision; ms boolean;
BEGIN
  PERFORM setseed((p_seed % 100000) / 100000.0);
  n := 3 + floor(random() * (CASE WHEN p_mode = 2 THEN 24 ELSE 14 END))::int;
  INSERT INTO jobs (id, company_id, job_no, status, due_date)
  VALUES (jid, co, 'ZZ-' || substr(jid::text, 1, 8), 'In Progress', CASE WHEN random() < 0.3 THEN DATE '2026-03-02' + floor(random() * 60)::int END);
  FOR i IN 1..n LOOP
    x := gen_random_uuid(); ids := ids || x;
    sd := CASE WHEN random() < 0.12 THEN NULL ELSE DATE '2026-02-20' + floor(random() * 25)::int END;
    ed := CASE WHEN sd IS NULL THEN CASE WHEN random() < 0.3 THEN DATE '2026-03-10' END ELSE sd + floor(random() * 9)::int END;
    r := random(); ms := random() < 0.08; IF ms THEN ed := sd; END IF;
    INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, is_milestone)
    VALUES (x, co, jid, floor(random() * 40)::int, 'T' || i, sd, ed,
            CASE WHEN r < 0.55 THEN 0 WHEN r < 0.7 THEN 50 WHEN r < 0.82 THEN 100 ELSE floor(random() * 100)::int END, ms);
  END LOOP;
  PERFORM set_config('session_replication_role', 'replica', true);       -- parents may cycle / point at itself: inject without the guards
  FOR i IN 1..n LOOP
    r := random();
    pr := CASE WHEN p_mode = 0 THEN NULL                                  -- flat (no hierarchy)
               WHEN r < 0.45 THEN NULL
               WHEN r < 0.9 THEN CASE WHEN p_mode = 3 THEN 1 + floor(random() * n)::int ELSE greatest(1, i - 1 - floor(random() * 3)::int) END   -- usually an earlier task
               ELSE 1 + floor(random() * n)::int END;                     -- any task (cycles, self)
    IF pr IS NOT NULL THEN UPDATE job_tasks SET parent_task_id = ids[pr] WHERE id = ids[i]; END IF;
  END LOOP;
  PERFORM set_config('session_replication_role', 'origin', true);
  -- r3d M2: links between a task and its own ancestor / descendant are now refused by job_task_links_hierarchy_guard; the differential test must
  -- still compare graphs that already contain them (planted data), so only that trigger is off while the links are generated.
  ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_z_hierarchy_guard;
  nl := floor(random() * (n * 1.6))::int;
  FOR i IN 1..nl LOOP
    a := 1 + floor(random() * n)::int; b := 1 + floor(random() * n)::int;
    IF p_mode = 2 AND random() < 0.5 THEN a := least(a, b); b := greatest(a, b) + 0; IF b > n THEN b := n; END IF; END IF;   -- reversed-ish chains: successor index < predecessor index
    IF a = b THEN CONTINUE; END IF;
    BEGIN
      INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
      VALUES (co, jid, ids[a], ids[b], floor(random() * 9)::int - 3, ty[1 + floor(random() * 4)::int]);
    EXCEPTION WHEN OTHERS THEN NULL;                                       -- cycle / duplicate refused by the guards
    END;
  END LOOP;
  ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_z_hierarchy_guard;
  RETURN jid;
END $$;

DO $$
DECLARE s int; md int; jid uuid; o record; w record; today date; tot int := 0; bad int := 0; cyc int := 0; sm int := 0;
BEGIN
  FOR md IN 0..4 LOOP
    FOR s IN 1..(CASE WHEN md = 0 THEN 40 ELSE :N END) LOOP
      jid := public.zz_mkjob(s * 7 + md, md);
      FOR today IN SELECT d FROM unnest(ARRAY[DATE '2026-03-02', DATE '2026-03-12']) AS d LOOP
        SELECT * INTO o FROM job_schedule_status_old(jid, today);
        SELECT * INTO w FROM job_schedule_status(jid, today);
        tot := tot + 1;
        IF o IS DISTINCT FROM w THEN bad := bad + 1; RAISE NOTICE 'DIFF seed % mode % today %: old % / % / %  new % / % / %', s, md, today, o.status, o.forecast_end, o.slip_days, w.status, w.forecast_end, w.slip_days; END IF;
      END LOOP;
      IF EXISTS (SELECT 1 FROM job_tasks c WHERE c.job_id = jid AND EXISTS (SELECT 1 FROM job_tasks p WHERE p.parent_task_id = c.id)) THEN sm := sm + 1; END IF;
      DELETE FROM job_task_links WHERE job_id = jid; DELETE FROM job_tasks WHERE job_id = jid; DELETE FROM jobs WHERE id = jid;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'DIFFTEST compared % evaluations (% jobs with a summary), % differences', tot, sm, bad;
  IF bad > 0 THEN RAISE EXCEPTION 'DIFFTEST FAILED'; END IF;
END $$;
