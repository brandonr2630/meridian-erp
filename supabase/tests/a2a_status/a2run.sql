-- pg_temp.a2run(case json): seeds a job + tasks (+ parents injected with triggers off) + links, returns pg_temp.st() = 'rows:status|forecast|slip'
CREATE FUNCTION pg_temp.a2run(j jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE jid uuid := gen_random_uuid(); keys text[] := '{}'; uu uuid[] := '{}'; t jsonb; l jsonb; x uuid; bs date; be date;
  co constant uuid := 'c1000000-0000-0000-0000-000000000001';
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status, due_date)
  VALUES (jid, co, 'A2-' || substr(jid::text, 1, 8), coalesce(j->'job'->>'status', 'Open'), (j->'job'->>'due_date')::date);
  PERFORM set_config('app.baseline_rpc', 'on', true);
  FOR t IN SELECT * FROM jsonb_array_elements(j->'tasks') LOOP
    x := gen_random_uuid(); keys := keys || (t->>'key'); uu := uu || x;
    bs := (t->>'baseline_start')::date; be := (t->>'baseline_end')::date;
    INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, is_milestone, weight, baseline_start, baseline_end, baseline_locked_at)
    VALUES (x, co, jid, (t->>'sort_order')::int, t->>'key', (t->>'start_date')::date, (t->>'end_date')::date, coalesce((t->>'progress')::int, 0),
            coalesce((t->>'is_milestone')::boolean, false), (t->>'weight')::numeric, bs, be,
            CASE WHEN coalesce((j->>'baselineLocked')::boolean, false) AND (bs IS NOT NULL OR be IS NOT NULL) THEN now() END);
  END LOOP;
  PERFORM set_config('app.baseline_rpc', 'off', true);
  -- parents last, with triggers and FK checks off, so a parent cycle (which a guard may refuse) can be injected directly
  PERFORM set_config('session_replication_role', 'replica', true);
  FOR t IN SELECT * FROM jsonb_array_elements(j->'tasks') LOOP
    IF t->>'parent' IS NOT NULL THEN
      UPDATE job_tasks SET parent_task_id = CASE WHEN t->>'parent' = '@other' THEN 'f1000000-0000-0000-0000-0000000000a9'::uuid
                                                 ELSE uu[array_position(keys, t->>'parent')] END
       WHERE id = uu[array_position(keys, t->>'key')];
    END IF;
  END LOOP;
  PERFORM set_config('session_replication_role', 'origin', true);
  -- r3d M2: job_task_links_hierarchy_guard refuses a link between a task and its own ancestor / descendant, but job_schedule_status must keep
  -- giving the same answer for such links already stored (DBA-planted / legacy data): the harness plants them with ONLY that trigger off
  ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_z_hierarchy_guard;
  FOR l IN SELECT * FROM jsonb_array_elements(coalesce(j->'links', '[]'::jsonb)) LOOP
    INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days, link_type)
    VALUES (co, jid, uu[array_position(keys, l->>'task')], uu[array_position(keys, l->>'pred')], coalesce((l->>'lag')::int, 0), coalesce(l->>'type', 'FS'));
  END LOOP;
  ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_z_hierarchy_guard;
  RETURN pg_temp.st(jid::text, (j->>'today')::date);
END $$;
-- a task in ANOTHER job, used as a foreign parent
INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b1000000-0000-0000-0000-0000000e9999', 'c1000000-0000-0000-0000-000000000001', 'WO-S9999', 'Open');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date)
VALUES ('f1000000-0000-0000-0000-0000000000a9', 'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000e9999', 1, 'foreign', '2026-03-01', '2026-03-05');
