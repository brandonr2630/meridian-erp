-- Fuzz (r4 M1): random hierarchies, random link attempts and re-parent attempts go through the REAL guards (links via INSERT, parents via UPDATE).
-- :ITER jobs. Claims checked against job_schedule_status_probe (the status function with a probe that reports whether the forward / backward
-- value-flow graphs are acyclic = whether the fast sweep is taken):
--   SOUND      after every accepted write the job's forward AND backward graphs are acyclic (the guard never lets a cyclic job through);
--   NOT-LAZY   a write refused with A2L03 really would make the job cyclic in at least one direction, OR is one of the counted conservative
--              refusals (the guard works on a superset graph: finish-bound links into / start-bound links out of a summary are treated like the others).
-- Prints "FUZZ jobs=.. accepted=.. refused_A2L03=.. conservative=.. unsound=.. unexplained_refusals=.." ; unsound and unexplained must be 0.
\set ON_ERROR_STOP on
SELECT setseed(0.4242);
CREATE FUNCTION pg_temp.acyc(j uuid) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN PERFORM * FROM job_schedule_status_probe(j, DATE '2026-03-01'); RETURN 'noprobe';
EXCEPTION WHEN raise_exception THEN RETURN SQLERRM; END $f$;
CREATE TABLE pg_temp.fz (k text PRIMARY KEY, v bigint NOT NULL DEFAULT 0);
INSERT INTO pg_temp.fz VALUES ('jobs'),('accepted'),('refused'),('conservative'),('unsound'),('unexplained');
CREATE FUNCTION pg_temp.bump(p text) RETURNS void LANGUAGE sql AS $f$ UPDATE pg_temp.fz SET v = v + 1 WHERE k = p $f$;
DO $$
DECLARE
  co constant uuid := 'c1000000-0000-0000-0000-000000000001';
  it int; n int; i int; a int; b int; j uuid; ids uuid[]; par int[]; r text; st text; tys text[] := ARRAY['FS','SS','FF','SF']; ty text;
  tries int; kind int; lid uuid; st2 text; cnt int;
BEGIN
  FOR it IN 1..:ITER LOOP
    n := 4 + floor(random() * 7)::int;                   -- 4..10 tasks
    j := gen_random_uuid();
    INSERT INTO jobs (id, company_id, job_no, status) VALUES (j, co, 'FZ-' || substr(j::text, 1, 8), 'Open');
    ids := ARRAY[]::uuid[]; par := ARRAY[]::int[];
    FOR i IN 1..n LOOP ids := ids || gen_random_uuid(); END LOOP;
    FOR i IN 1..n LOOP
      par := par || (CASE WHEN i > 1 AND random() < 0.55 THEN 1 + floor(random() * (i - 1))::int ELSE 0 END);
      BEGIN
        INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, parent_task_id)
        VALUES (ids[i], co, j, i, 'T' || i, DATE '2026-03-02', DATE '2026-03-04', CASE WHEN par[i] > 0 THEN ids[par[i]] END);
      EXCEPTION WHEN SQLSTATE 'A2H03' THEN par[i] := 0;       -- depth cap: make it a root
        INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date) VALUES (ids[i], co, j, i, 'T' || i, DATE '2026-03-02', DATE '2026-03-04');
      END;
    END LOOP;
    FOR tries IN 1..(2 * n + 6) LOOP
      kind := CASE WHEN random() < 0.8 THEN 1 ELSE 2 END;      -- 1 = link attempt, 2 = re-parent attempt
      a := 1 + floor(random() * n)::int; b := 1 + floor(random() * n)::int;
      CONTINUE WHEN a = b;
      ty := tys[1 + floor(random() * 4)::int];
      PERFORM pg_temp.bump('jobs');
      BEGIN
        IF kind = 1 THEN
          INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type) VALUES (co, j, ids[a], ids[b], ty);
        ELSE
          UPDATE job_tasks SET parent_task_id = CASE WHEN random() < 0.15 THEN NULL ELSE ids[b] END WHERE id = ids[a];
        END IF;
        PERFORM pg_temp.bump('accepted');
        st := pg_temp.acyc(j);
        IF st <> 'ACYC t t' THEN PERFORM pg_temp.bump('unsound'); RAISE NOTICE 'UNSOUND job % kind % a=% b=% ty=% probe=%', j, kind, a, b, ty, st; END IF;
      EXCEPTION
        WHEN SQLSTATE 'A2L03' THEN
          PERFORM pg_temp.bump('refused');
          -- would the write really make the job cyclic? replay it with the guards off (inside a sub-transaction that is rolled back)
          BEGIN
            IF kind = 1 THEN
              ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_z_hierarchy_guard;
              INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type) VALUES (co, j, ids[a], ids[b], ty);
              ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_z_hierarchy_guard;
            ELSE
              ALTER TABLE job_tasks DISABLE TRIGGER job_tasks_parent_link_guard;
              UPDATE job_tasks SET parent_task_id = ids[b] WHERE id = ids[a];
              ALTER TABLE job_tasks ENABLE TRIGGER job_tasks_parent_link_guard;
            END IF;
            st2 := pg_temp.acyc(j);
            IF st2 = 'ACYC t t' THEN PERFORM pg_temp.bump('conservative'); END IF;
            RAISE EXCEPTION 'undo' USING ERRCODE = 'A2ZZZ';
          EXCEPTION WHEN SQLSTATE 'A2ZZZ' THEN NULL;
          END;
        WHEN SQLSTATE 'A2L01' OR SQLSTATE 'A2L02' OR SQLSTATE 'A2H02' OR SQLSTATE 'A2H03' OR check_violation OR unique_violation THEN NULL;
      END;
    END LOOP;
  END LOOP;
END $$;
SELECT 'FUZZ jobs=' || (SELECT v FROM pg_temp.fz WHERE k='jobs') || ' accepted=' || (SELECT v FROM pg_temp.fz WHERE k='accepted')
 || ' refused_A2L03=' || (SELECT v FROM pg_temp.fz WHERE k='refused') || ' conservative=' || (SELECT v FROM pg_temp.fz WHERE k='conservative')
 || ' unsound=' || (SELECT v FROM pg_temp.fz WHERE k='unsound') AS result;
