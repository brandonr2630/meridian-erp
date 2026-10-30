-- AFTER the a2a_schema migration: link_type, msp_uid and the task hierarchy guards. One transaction, rolled back.
-- Every check prints NOTICE 'PASS ...'. SQLSTATEs: A2H01 parent in another job/company, A2H02 cycle, A2H03 depth cap,
-- A2H04 self-parent, A2H05 job/company change on a task that has a parent or children, A2H06 parent does not exist.
-- Depth: a phase is level 1, tasks nest below it, max level is 6 => a task chain is at most 5 tasks deep.
BEGIN;

CREATE FUNCTION pg_temp.tid(n int) RETURNS uuid LANGUAGE sql IMMUTABLE AS
  $f$ SELECT ('f3000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $f$;
-- try(sql): 'ok' or the SQLSTATE; msg(sql): the error message ('ok' when it succeeds)
CREATE FUNCTION pg_temp.try(p text) RETURNS text LANGUAGE plpgsql AS
  $f$ BEGIN EXECUTE p; RETURN 'ok'; EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END $f$;
CREATE FUNCTION pg_temp.msg(p text) RETURNS text LANGUAGE plpgsql AS
  $f$ BEGIN EXECUTE p; RETURN 'ok'; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $f$;
-- ins(n, job, parent, company): insert task n (parent NULL = root); mv(n, parent): re-parent task n; par(n): parent as text
CREATE FUNCTION pg_temp.ins(n int, job uuid, par int DEFAULT NULL, comp uuid DEFAULT 'c1000000-0000-0000-0000-000000000001')
RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO job_tasks (id, company_id, job_id, task_name, parent_task_id)
  VALUES (pg_temp.tid(n), comp, job, 't' || n, CASE WHEN par IS NULL THEN NULL ELSE pg_temp.tid(par) END);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END $f$;
CREATE FUNCTION pg_temp.mv(n int, par int) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  UPDATE job_tasks SET parent_task_id = CASE WHEN par IS NULL THEN NULL ELSE pg_temp.tid(par) END WHERE id = pg_temp.tid(n);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END $f$;
CREATE FUNCTION pg_temp.par(n int) RETURNS text LANGUAGE sql AS
  $f$ SELECT coalesce((SELECT parent_task_id::text FROM job_tasks WHERE id = pg_temp.tid(n)), 'null') $f$;
CREATE FUNCTION pg_temp.lnk(t int, pr int, lt text DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  IF lt IS NULL THEN
    INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
    SELECT company_id, job_id, pg_temp.tid(t), pg_temp.tid(pr) FROM job_tasks WHERE id = pg_temp.tid(t);
  ELSE
    INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type)
    SELECT company_id, job_id, pg_temp.tid(t), pg_temp.tid(pr), lt FROM job_tasks WHERE id = pg_temp.tid(t);
  END IF;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END $f$;

-- lt(n): link_type of the link whose task is n (plpgsql so it sees rows written earlier in the same statement)
CREATE FUNCTION pg_temp.lt(n int) RETURNS text LANGUAGE plpgsql AS
  $f$ BEGIN RETURN (SELECT link_type FROM job_task_links WHERE task_id = pg_temp.tid(n)); END $f$;

-- ===== fixtures =====
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b3000000-0000-0000-0000-00000000000a','c1000000-0000-0000-0000-000000000001','WO-S0A','Open'),
 ('b3000000-0000-0000-0000-00000000000b','c1000000-0000-0000-0000-000000000001','WO-S0B','Open'),
 ('b3000000-0000-0000-0000-00000000000c','c1000000-0000-0000-0000-000000000001','WO-S0C','Open'),
 ('b3000000-0000-0000-0000-00000000000d','c1000000-0000-0000-0000-000000000001','WO-S0D','Open'),
 ('b3000000-0000-0000-0000-00000000000e','c1000000-0000-0000-0000-000000000001','WO-S0E','Open'),
 ('b3000000-0000-0000-0000-00000000000f','c1000000-0000-0000-0000-000000000001','WO-S0F','Open'),
 ('b3000000-0000-0000-0000-000000000010','c1000000-0000-0000-0000-000000000001','WO-S10','Open');

-- ===== 1. structure =====
DO $$
BEGIN
  PERFORM t_expect('struct: link_type text NOT NULL DEFAULT FS',
    (SELECT data_type || '/' || is_nullable || '/' || column_default FROM information_schema.columns
      WHERE table_schema='public' AND table_name='job_task_links' AND column_name='link_type'), 'text/NO/''FS''::text');
  PERFORM t_expect('struct: msp_uid integer on both tables, nullable',
    (SELECT string_agg(table_name || ':' || data_type || ':' || is_nullable, ',' ORDER BY table_name) FROM information_schema.columns
      WHERE table_schema='public' AND table_name IN ('job_phases','job_tasks') AND column_name='msp_uid'),
    'job_phases:integer:YES,job_tasks:integer:YES');
  PERFORM t_expect('struct: parent_task_id uuid nullable',
    (SELECT data_type || '/' || is_nullable FROM information_schema.columns
      WHERE table_schema='public' AND table_name='job_tasks' AND column_name='parent_task_id'), 'uuid/YES');
  PERFORM t_expect('struct: parent_task_id FK is ON DELETE SET NULL',
    (SELECT confdeltype::text FROM pg_constraint WHERE conrelid='public.job_tasks'::regclass AND contype='f'
       AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid='public.job_tasks'::regclass AND attname='parent_task_id')]), 'n');
  PERFORM t_expect('struct: job_tasks triggers',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal),
    'job_tasks_baseline_guard,job_tasks_company_guard,job_tasks_msp_uid_guard,job_tasks_parent_guard,job_tasks_parent_link_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
  PERFORM t_expect('struct: parent guard is BEFORE INSERT OR UPDATE OF parent_task_id, job_id, company_id',
    (SELECT (pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE OF parent_task_id, job_id, company_id ON%')::text
       FROM pg_trigger WHERE tgname='job_tasks_parent_guard'), 'true');
  PERFORM t_expect('struct: one parent guard function',
    (SELECT count(*)::text FROM pg_proc WHERE proname='job_tasks_parent_guard'), '1');
  PERFORM t_expect('struct: msp_uid and parent indexes exist',
    (SELECT count(*)::text FROM pg_indexes WHERE indexname IN ('job_phases_msp_uid_uq','job_tasks_msp_uid_uq','job_tasks_parent_idx')), '3');
END $$;

-- ===== 2. N2: existing rows unchanged =====
DO $$
BEGIN
  PERFORM t_expect('legacy: no existing task has a parent or an msp_uid',
    (SELECT count(*)::text FROM job_tasks WHERE parent_task_id IS NOT NULL OR msp_uid IS NOT NULL), '0');
  PERFORM t_expect('legacy: existing links are FS and still 3',
    (SELECT count(*)::text || '/' || min(link_type) || '/' || max(link_type) FROM job_task_links), '3/FS/FS');
END $$;

-- ===== 3. hierarchy: valid shapes, self, missing, cross job/company (job A) =====
DO $$
BEGIN
  PERFORM t_expect('hier: root task inserts', pg_temp.ins(1, 'b3000000-0000-0000-0000-00000000000a'), 'ok');
  PERFORM t_expect('hier: child under root inserts', pg_temp.ins(2, 'b3000000-0000-0000-0000-00000000000a', 1), 'ok');
  PERFORM t_expect('hier: grandchild inserts', pg_temp.ins(3, 'b3000000-0000-0000-0000-00000000000a', 2), 'ok');
  PERFORM t_expect('hier: parent stored', (pg_temp.par(3) = pg_temp.tid(2)::text)::text, 'true');
  PERFORM t_expect('hier: second child of same parent ok', pg_temp.ins(6, 'b3000000-0000-0000-0000-00000000000a', 1), 'ok');
  PERFORM t_expect('hier: self-parent on insert -> A2H04', pg_temp.ins(4, 'b3000000-0000-0000-0000-00000000000a', 4), 'A2H04');
  PERFORM t_expect('hier: self-parent on update -> A2H04', pg_temp.mv(1, 1), 'A2H04');
  PERFORM t_expect('hier: nonexistent parent on insert -> A2H06', pg_temp.ins(5, 'b3000000-0000-0000-0000-00000000000a', 999), 'A2H06');
  PERFORM t_expect('hier: nonexistent parent on update -> A2H06', pg_temp.mv(1, 999), 'A2H06');
  PERFORM t_expect('hier: root in another job inserts', pg_temp.ins(10, 'b3000000-0000-0000-0000-00000000000b'), 'ok');
  PERFORM t_expect('hier: parent in another job on insert -> A2H01', pg_temp.ins(11, 'b3000000-0000-0000-0000-00000000000a', 10), 'A2H01');
  PERFORM t_expect('hier: parent in another job on update -> A2H01', pg_temp.mv(3, 10), 'A2H01');
  -- the parent guard's own company rule is defence in depth behind job_schedule_company_guard (A2C01), which fires first: switch that one off here
  ALTER TABLE job_tasks DISABLE TRIGGER job_tasks_company_guard;
  PERFORM t_expect('hier: same job, other company on insert -> A2H01',
    pg_temp.ins(13, 'b3000000-0000-0000-0000-00000000000a', 1, 'c2000000-0000-0000-0000-000000000002'), 'A2H01');
  PERFORM t_expect('hier: same job, other company on update -> A2H01',
    pg_temp.ins(14, 'b3000000-0000-0000-0000-00000000000a', NULL, 'c2000000-0000-0000-0000-000000000002') || '/' || pg_temp.mv(14, 1), 'ok/A2H01');
  ALTER TABLE job_tasks ENABLE TRIGGER job_tasks_company_guard;
  PERFORM t_expect('hier: rejected inserts left no row',
    (SELECT count(*)::text FROM job_tasks WHERE id IN (pg_temp.tid(4), pg_temp.tid(5), pg_temp.tid(11), pg_temp.tid(13))), '0');
  PERFORM t_expect('hier: failed updates left parents unchanged',
    pg_temp.par(1) || '/' || (pg_temp.par(3) = pg_temp.tid(2)::text)::text || '/' || pg_temp.par(14), 'null/true/null');
  PERFORM t_expect('hier: distinct messages (job vs cycle vs self)',
    (pg_temp.msg('UPDATE job_tasks SET parent_task_id = pg_temp.tid(10) WHERE id = pg_temp.tid(3)') LIKE '%same job%')::text
    || (pg_temp.msg('UPDATE job_tasks SET parent_task_id = pg_temp.tid(3) WHERE id = pg_temp.tid(1)') LIKE '%cycle%')::text
    || (pg_temp.msg('UPDATE job_tasks SET parent_task_id = pg_temp.tid(1) WHERE id = pg_temp.tid(1)') LIKE '%own parent%')::text, 'truetruetrue');
END $$;

-- ===== 4. cycles (job A: 1 <- 2 <- 3, and 6 under 1) =====
DO $$
BEGIN
  PERFORM t_expect('cycle: 2-node (root under its child) -> A2H02', pg_temp.mv(1, 2), 'A2H02');
  PERFORM t_expect('cycle: 3-node (root under grandchild) -> A2H02', pg_temp.mv(1, 3), 'A2H02');
  PERFORM t_expect('cycle: middle under its child -> A2H02', pg_temp.mv(2, 3), 'A2H02');
  PERFORM t_expect('cycle: failed moves left the tree intact',
    pg_temp.par(1) || '/' || (pg_temp.par(2) = pg_temp.tid(1)::text)::text || '/' || (pg_temp.par(3) = pg_temp.tid(2)::text)::text, 'null/true/true');
  PERFORM t_expect('cycle: sibling under sibling is fine', pg_temp.mv(6, 3), 'ok');
  PERFORM t_expect('cycle: ... and now the old ancestor cannot go under it -> A2H02', pg_temp.mv(1, 6), 'A2H02');
END $$;

-- ===== 5. depth cap: a chain of at most 5 tasks (job C) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-00000000000c';
BEGIN
  PERFORM t_expect('depth: levels 2..5 insert', pg_temp.ins(21, j) || pg_temp.ins(22, j, 21) || pg_temp.ins(23, j, 22) || pg_temp.ins(24, j, 23), 'okokokok');
  PERFORM t_expect('depth: the 5th task in a chain (level 6) is allowed', pg_temp.ins(25, j, 24), 'ok');
  PERFORM t_expect('depth: the 6th task in a chain on insert -> A2H03', pg_temp.ins(26, j, 25), 'A2H03');
  PERFORM t_expect('depth: a root moved under the deepest on update -> A2H03', pg_temp.ins(27, j) || '/' || pg_temp.mv(27, 25), 'ok/A2H03');
  PERFORM t_expect('depth: the 4th level can still take a child (4 -> 5)', pg_temp.ins(28, j, 23), 'ok');
  PERFORM t_expect('depth: rejected rows left nothing behind',
    (SELECT count(*)::text FROM job_tasks WHERE id = pg_temp.tid(26)) || '/' || pg_temp.par(27), '0/null');
  PERFORM t_expect('depth: a non-hierarchy update on the deepest task is not blocked',
    pg_temp.try('UPDATE job_tasks SET progress = 50, task_name = ''renamed'' WHERE id = pg_temp.tid(25)'), 'ok');
END $$;

-- ===== 6. re-parenting checks the deepest descendant of the moved subtree (job D) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-00000000000d';
BEGIN
  -- chain C: 31 <- 32 <- 33 (3 deep). S: 41 <- 42 (height 2). S2: 51 <- 52 <- 53 (height 3).
  -- S3: 61 with leaf 62 and 63 <- 64, so its deep branch is the later sibling (height 3).
  PERFORM t_expect('subtree: chain and subtrees build',
    pg_temp.ins(31, j) || pg_temp.ins(32, j, 31) || pg_temp.ins(33, j, 32) || pg_temp.ins(41, j) || pg_temp.ins(42, j, 41)
    || pg_temp.ins(51, j) || pg_temp.ins(52, j, 51) || pg_temp.ins(53, j, 52)
    || pg_temp.ins(61, j) || pg_temp.ins(62, j, 61) || pg_temp.ins(63, j, 61) || pg_temp.ins(64, j, 63), 'okokokokokokokokokokokok');
  PERFORM t_expect('subtree: height 3 under depth 3 (6) -> A2H03', pg_temp.mv(51, 33), 'A2H03');
  PERFORM t_expect('subtree: branching subtree, deep branch is the later sibling -> A2H03', pg_temp.mv(61, 33), 'A2H03');
  PERFORM t_expect('subtree: rejected moves left the subtrees detached', pg_temp.par(51) || '/' || pg_temp.par(61), 'null/null');
  PERFORM t_expect('subtree: height 2 under depth 3 (5) is allowed', pg_temp.mv(41, 33), 'ok');
  PERFORM t_expect('subtree: the moved subtree is now at its cap: a child of 42 -> A2H03', pg_temp.ins(43, j, 42), 'A2H03');
  PERFORM t_expect('subtree: height 3 under depth 2 (5) is allowed', pg_temp.mv(51, 32), 'ok');
  PERFORM t_expect('subtree: branching subtree under depth 2 (5) is allowed', pg_temp.mv(61, 32), 'ok');
  PERFORM t_expect('subtree: and a child under the new deepest -> A2H03', pg_temp.ins(54, j, 53), 'A2H03');
  PERFORM t_expect('subtree: moving the now-attached subtree one level deeper -> A2H03', pg_temp.mv(51, 33), 'A2H03');
  PERFORM t_expect('subtree: unparenting is always allowed', pg_temp.mv(41, NULL) || pg_temp.par(41), 'oknull');
  PERFORM t_expect('subtree: after unparenting 42 has room again', pg_temp.ins(43, j, 42), 'ok');
END $$;

-- ===== 7. parent delete promotes children (ON DELETE SET NULL passes the guard) (job E) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-00000000000e';
BEGIN
  PERFORM t_expect('delete: chain builds', pg_temp.ins(71, j) || pg_temp.ins(72, j, 71) || pg_temp.ins(73, j, 72), 'okokok');
  PERFORM t_expect('delete: removing the middle task succeeds', pg_temp.try('DELETE FROM job_tasks WHERE id = pg_temp.tid(72)'), 'ok');
  PERFORM t_expect('delete: the child became a root, the rest stands',
    pg_temp.par(73) || '/' || (SELECT count(*)::text FROM job_tasks WHERE id IN (pg_temp.tid(71), pg_temp.tid(73))), 'null/2');
  PERFORM t_expect('delete: the promoted child can be re-parented', pg_temp.mv(73, 71), 'ok');
END $$;

-- ===== 8. job_id / company_id change on a task in a hierarchy is rejected (job F; target job B) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-00000000000f';
BEGIN
  PERFORM t_expect('jobchg: fixtures', pg_temp.ins(81, j) || pg_temp.ins(82, j, 81) || pg_temp.ins(83, j), 'okokok');
  PERFORM t_expect('jobchg: a task with a parent cannot change job -> A2H05',
    pg_temp.try('UPDATE job_tasks SET job_id = ''b3000000-0000-0000-0000-00000000000b'' WHERE id = pg_temp.tid(82)'), 'A2H05');
  PERFORM t_expect('jobchg: a task with children cannot change job -> A2H05',
    pg_temp.try('UPDATE job_tasks SET job_id = ''b3000000-0000-0000-0000-00000000000b'' WHERE id = pg_temp.tid(81)'), 'A2H05');
  ALTER TABLE job_tasks DISABLE TRIGGER job_tasks_company_guard;   -- the new row-company trigger would answer first
  PERFORM t_expect('jobchg: a task with children cannot change company -> A2H05',
    pg_temp.try('UPDATE job_tasks SET company_id = ''c2000000-0000-0000-0000-000000000002'' WHERE id = pg_temp.tid(81)'), 'A2H05');
  ALTER TABLE job_tasks ENABLE TRIGGER job_tasks_company_guard;
  PERFORM t_expect('jobchg: moving to a new job while detaching in the same statement is still rejected (detach first) -> A2H05',
    pg_temp.try('UPDATE job_tasks SET job_id = ''b3000000-0000-0000-0000-00000000000b'', parent_task_id = NULL WHERE id = pg_temp.tid(82)'), 'A2H05');
  PERFORM t_expect('jobchg: a plain task (no parent, no children) can change job',
    pg_temp.try('UPDATE job_tasks SET job_id = ''b3000000-0000-0000-0000-00000000000b'' WHERE id = pg_temp.tid(83)'), 'ok');
  PERFORM t_expect('jobchg: detach first, then the move works',
    pg_temp.mv(82, NULL) || pg_temp.try('UPDATE job_tasks SET job_id = ''b3000000-0000-0000-0000-00000000000b'' WHERE id = pg_temp.tid(82)'), 'okok');
  PERFORM t_expect('jobchg: re-asserting the same job on a child is not a change',
    pg_temp.mv(82, NULL) || pg_temp.ins(84, j) || pg_temp.ins(85, j, 84)
    || pg_temp.try('UPDATE job_tasks SET job_id = job_id, company_id = company_id WHERE id = pg_temp.tid(85)'), 'okokokok');
  PERFORM t_expect('jobchg: re-setting the same parent is fine', pg_temp.mv(85, 84), 'ok');
END $$;

-- ===== 9. phase_id is NOT enforced against the parent's phase (ruling) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-000000000010';
BEGIN
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
   ('f4000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001', j, 10, 'PA'),
   ('f4000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001', j, 20, 'PB');
  INSERT INTO job_tasks (id, company_id, job_id, task_name, phase_id)
  VALUES (pg_temp.tid(101),'c1000000-0000-0000-0000-000000000001', j, 'p', 'f4000000-0000-0000-0000-000000000001');
  PERFORM t_expect('phase: a child in another phase than its parent is accepted',
    pg_temp.try('INSERT INTO job_tasks (id, company_id, job_id, task_name, phase_id, parent_task_id) VALUES (pg_temp.tid(102), ''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-000000000010'', ''c'', ''f4000000-0000-0000-0000-000000000002'', pg_temp.tid(101))'), 'ok');
END $$;

-- ===== 10. msp_uid uniqueness is per (job, table) =====
DO $$
BEGIN
  PERFORM t_expect('msp: task uid 5 in job A', pg_temp.try('UPDATE job_tasks SET msp_uid = 5 WHERE id = pg_temp.tid(1)'), 'ok');
  PERFORM t_expect('msp: duplicate task uid in the same job -> 23505', pg_temp.try('UPDATE job_tasks SET msp_uid = 5 WHERE id = pg_temp.tid(2)'), '23505');
  PERFORM t_expect('msp: a different uid in the same job is fine', pg_temp.try('UPDATE job_tasks SET msp_uid = 6 WHERE id = pg_temp.tid(2)'), 'ok');
  PERFORM t_expect('msp: the same uid in another job is fine', pg_temp.try('UPDATE job_tasks SET msp_uid = 5 WHERE id = pg_temp.tid(10)'), 'ok');
  PERFORM t_expect('msp: duplicate on insert -> 23505',
    pg_temp.try('INSERT INTO job_tasks (company_id, job_id, task_name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000a'', ''dup'', 5)'), '23505');
  PERFORM t_expect('msp: many NULL uids coexist in a job',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = 'b3000000-0000-0000-0000-00000000000a' AND msp_uid IS NULL), '3');
  PERFORM t_expect('msp: uid 0 rejected -> 23514', pg_temp.try('UPDATE job_tasks SET msp_uid = 0 WHERE id = pg_temp.tid(3)'), '23514');
  PERFORM t_expect('msp: negative uid rejected -> 23514', pg_temp.try('UPDATE job_tasks SET msp_uid = -3 WHERE id = pg_temp.tid(3)'), '23514');
  -- phases
  PERFORM t_expect('msp: phase uid 5 in job A', pg_temp.try('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000a'', ''ph1'', 5)'), 'ok');
  PERFORM t_expect('msp: duplicate phase uid in the same job -> 23505',
    pg_temp.try('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000a'', ''ph2'', 5)'), '23505');
  PERFORM t_expect('msp: the same phase uid in another job is fine',
    pg_temp.try('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000b'', ''ph3'', 5)'), 'ok');
  PERFORM t_expect('msp: phase uid 0 rejected -> 23514',
    pg_temp.try('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000a'', ''ph4'', 0)'), '23514');
  PERFORM t_expect('msp: cross-table is NOT enforced here (phase 5 and task 5 coexist in job A; the RPCs own that)',
    (SELECT (SELECT count(*) FROM job_phases WHERE job_id = 'b3000000-0000-0000-0000-00000000000a' AND msp_uid = 5)::text || '/'
         || (SELECT count(*) FROM job_tasks WHERE job_id = 'b3000000-0000-0000-0000-00000000000a' AND msp_uid = 5)::text), '1/1');
  PERFORM t_expect('msp: setting a uid on a task in a hierarchy does not trip the parent guard',
    pg_temp.try('UPDATE job_tasks SET msp_uid = 7 WHERE id = pg_temp.tid(3)'), 'ok');
END $$;

-- ===== 11. link_type (job G) =====
DO $$
DECLARE j uuid := 'b3000000-0000-0000-0000-00000000000b';
BEGIN
  PERFORM t_expect('link: tasks build', pg_temp.ins(121, j) || pg_temp.ins(122, j) || pg_temp.ins(123, j) || pg_temp.ins(124, j) || pg_temp.ins(125, j)
    || pg_temp.ins(131, j) || pg_temp.ins(132, j) || pg_temp.ins(133, j), 'okokokokokokokok');
  PERFORM t_expect('link: omitted link_type defaults to FS', pg_temp.lnk(122, 121) || pg_temp.lt(122), 'okFS');
  PERFORM t_expect('link: SS accepted', pg_temp.lnk(123, 121, 'SS') || pg_temp.lt(123), 'okSS');
  PERFORM t_expect('link: FF accepted', pg_temp.lnk(124, 121, 'FF') || pg_temp.lt(124), 'okFF');
  PERFORM t_expect('link: SF accepted', pg_temp.lnk(125, 121, 'SF') || pg_temp.lt(125), 'okSF');
  PERFORM t_expect('link: explicit FS accepted', pg_temp.lnk(125, 122, 'FS'), 'ok');
  PERFORM t_expect('link: unknown type XX rejected -> 23514', pg_temp.lnk(132, 131, 'XX'), '23514');
  PERFORM t_expect('link: lowercase fs rejected -> 23514', pg_temp.lnk(132, 131, 'fs'), '23514');
  PERFORM t_expect('link: empty string rejected -> 23514', pg_temp.lnk(132, 131, ''), '23514');
  PERFORM t_expect('link: padded value rejected -> 23514', pg_temp.lnk(132, 131, 'FS '), '23514');
  PERFORM t_expect('link: NULL rejected -> 23502',
    pg_temp.try('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000b'', pg_temp.tid(132), pg_temp.tid(131), NULL)'), '23502');
  PERFORM t_expect('link: update to an invalid type rejected -> 23514',
    pg_temp.try('UPDATE job_task_links SET link_type = ''ZZ'' WHERE task_id = pg_temp.tid(122)'), '23514');
  PERFORM t_expect('link: update to a valid type works',
    pg_temp.try('UPDATE job_task_links SET link_type = ''SF'' WHERE task_id = pg_temp.tid(122)') || pg_temp.lt(122), 'okSF');
  PERFORM t_expect('link: rejected inserts left no row', (SELECT count(*)::text FROM job_task_links WHERE task_id = pg_temp.tid(132)), '0');
  PERFORM t_expect('link: legacy rows still FS',
    (SELECT count(*)::text FROM job_task_links WHERE link_type = 'FS' AND task_id IN ('d1000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000003')), '2');
  -- cycle guard (Phase A) must hold whatever the link type: 132 <- 131 (SS), 133 <- 132 (FF), then 131 <- 133 closes the loop
  PERFORM t_expect('link: non-FS chain builds', pg_temp.lnk(132, 131, 'SS') || pg_temp.lnk(133, 132, 'FF'), 'okok');
  PERFORM t_expect('link: cycle closed by an SF link -> 23514', pg_temp.lnk(131, 133, 'SF'), '23514');
  PERFORM t_expect('link: cycle closed by an FS link -> 23514', pg_temp.lnk(131, 133, 'FS'), '23514');
  PERFORM t_expect('link: cycle message names the cycle',
    (pg_temp.msg('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, link_type) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000b'', pg_temp.tid(131), pg_temp.tid(133), ''FF'')') LIKE '%dependency cycle%')::text, 'true');
  PERFORM t_expect('link: self link with a non-FS type -> 23514', pg_temp.lnk(131, 131, 'SS'), '23514');
  PERFORM t_expect('link: the rejected cycle links left no row', (SELECT count(*)::text FROM job_task_links WHERE task_id = pg_temp.tid(131)), '0');
END $$;

-- ===== 11. H1: a schedule row's company must be the company of its job (A2C01), through the REAL policies =====
-- Identities: 77777777-... = operations_tech in C2 (writer), 11111111-... = operations_tech in C1 (writer).
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; c2 constant uuid := 'c2000000-0000-0000-0000-000000000002';
  j1 constant uuid := 'b1000000-0000-0000-0000-000000000001'; j2 constant uuid := 'b2000000-0000-0000-0000-000000000002';
  w2 constant uuid := '77777777-7777-7777-7777-777777777777'; w1 constant uuid := '11111111-1111-1111-1111-111111111111';
BEGIN
  PERFORM t_expect('h1: struct: three company guard triggers exist (BEFORE INSERT OR UPDATE OF job_id, company_id)',
    (SELECT string_agg(c.relname || ':' || t.tgname, ',' ORDER BY c.relname) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      WHERE t.tgname LIKE '%company_guard' AND NOT t.tgisinternal AND (t.tgtype & 2) = 2 AND (t.tgtype & 4) = 4 AND (t.tgtype & 16) = 16),
    'job_phases:job_phases_company_guard,job_task_links:job_task_links_company_guard,job_tasks:job_tasks_company_guard');
  PERFORM t_expect('h1: struct: the guard is SECURITY DEFINER with a pinned search_path and not executable by API roles',
    (SELECT (prosecdef AND array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')::text
        || has_function_privilege('anon', oid, 'EXECUTE')::text || has_function_privilege('authenticated', oid, 'EXECUTE')::text
        || has_function_privilege('service_role', oid, 'EXECUTE')::text
       FROM pg_proc WHERE proname = 'job_schedule_company_guard'), 'truefalsefalsefalse');

  -- the attack: a C2 writer plants rows carrying a C1 job id (company_id = its own company, so the Phase A policy alone lets it through)
  PERFORM t_expect('h1: C2 writer cannot insert a job_phases row with a C1 job id',
    t_dml_api('authenticated', w2, format('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (%L, %L, ''planted'', 2000000)', c2, j1)), 'err:A2C01');
  PERFORM t_expect('h1: C2 writer cannot insert a job_tasks row with a C1 job id',
    t_dml_api('authenticated', w2, format('INSERT INTO job_tasks (company_id, job_id, task_name, msp_uid) VALUES (%L, %L, ''planted'', 2000000)', c2, j1)), 'err:A2C01');
  INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES ('f4000000-0000-0000-0000-000000000001', c1, j1, 'c1 a'), ('f4000000-0000-0000-0000-000000000002', c1, j1, 'c1 b');
  PERFORM t_expect('h1: C2 writer cannot insert a job_task_links row with a C1 job id (even with C1 task ids)',
    t_dml_api('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c2, j1,
      'f4000000-0000-0000-0000-000000000001', 'f4000000-0000-0000-0000-000000000002')), 'err:A2C01');
  PERFORM t_expect('h1: a nonexistent job id gives the same error (no probing of job ids)',
    t_dml_api('authenticated', w2, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, ''aaaaaaaa-0000-0000-0000-00000000f4f4'', ''x'')', c2)), 'err:A2C01');
  PERFORM t_expect('h1: the refusals planted nothing', (SELECT count(*)::text FROM job_phases WHERE name = 'planted') || (SELECT count(*)::text FROM job_tasks WHERE task_name = 'planted')
    || (SELECT count(*)::text FROM job_task_links WHERE job_id = j1 AND company_id = c2), '000');
  PERFORM t_expect('h1: the message names the table and does not echo ids',
    t_msg_api('authenticated', w2, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, %L, ''x'')', c2, j1)), 'job_phases row must belong to the company of its job');

  -- legit writers are not blocked
  PERFORM t_expect('h1: C2 writer inserts a phase, a task and a link in its own job',
    t_dml_api('authenticated', w2, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, %L, ''own'')', c2, j2))
    || t_dml_api('authenticated', w2, format('INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES (''f4000000-0000-0000-0000-0000000000a1'', %L, %L, ''own1''), (''f4000000-0000-0000-0000-0000000000a2'', %L, %L, ''own2'')', c2, j2, c2, j2))
    || t_dml_api('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, ''f4000000-0000-0000-0000-0000000000a2'', ''f4000000-0000-0000-0000-0000000000a1'')', c2, j2)),
    'rows:1rows:2rows:1');
  PERFORM t_expect('h1: C1 writer inserts a phase in its own job', t_dml_api('authenticated', w1, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, %L, ''own c1'')', c1, j1)), 'rows:1');
  -- updates: moving an existing row to another company's job is refused too
  PERFORM t_expect('h1: a C1 writer cannot move its own task to a C2 job id',
    t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = ''f4000000-0000-0000-0000-000000000001''', j2)), 'err:A2C01');
  PERFORM t_expect('h1: a C1 writer cannot move its own phase to a C2 job id',
    t_dml_api('authenticated', w1, format('UPDATE job_phases SET job_id = %L WHERE name = ''own c1''', j2)), 'err:A2C01');
  PERFORM t_expect('h1: a C2 writer cannot move its own link to a C1 job id',
    t_dml_api('authenticated', w2, format('UPDATE job_task_links SET job_id = %L WHERE task_id = ''f4000000-0000-0000-0000-0000000000a2''', j1)), 'err:A2C01');
  PERFORM t_expect('h1: an UPDATE that touches neither job_id nor company_id is not affected',
    t_dml_api('authenticated', w1, 'UPDATE job_tasks SET progress = 5 WHERE id = ''f4000000-0000-0000-0000-000000000001'''), 'rows:1');
  -- the owner (migrations, backfills, the import RPC) is held to the same rule
  PERFORM t_expect('h1: even the table owner cannot insert a mismatching row',
    pg_temp.try(format('INSERT INTO job_tasks (company_id, job_id, task_name) VALUES (%L, %L, ''o'')', c2, j1)), 'A2C01');
  -- the guard must work even when the writer cannot read jobs at all (RLS on jobs that hides every row): SECURITY DEFINER is load-bearing
  ALTER TABLE jobs ENABLE ROW LEVEL SECURITY;
  CREATE POLICY t_jobs_hidden ON jobs FOR SELECT TO authenticated USING (false);
  PERFORM t_expect('h1: a legit writer is not blocked when RLS hides jobs from it (definer lookup)',
    t_dml_api('authenticated', w2, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, %L, ''own rls'')', c2, j2)), 'rows:1');
  DROP POLICY t_jobs_hidden ON jobs;
  ALTER TABLE jobs DISABLE ROW LEVEL SECURITY;
  PERFORM t_expect('h1: exactly one company guard trigger per table', (SELECT count(*)::text FROM pg_trigger WHERE tgname LIKE '%company_guard' AND NOT tgisinternal), '3');
END $$;

-- ===== 11b. review r3 (LOW): job_tasks.phase_id / depends_on must stay inside the task's own job (A2C01), through the REAL policies =====
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; c2 constant uuid := 'c2000000-0000-0000-0000-000000000002';
  j1 constant uuid := 'b1000000-0000-0000-0000-000000000001'; j2 constant uuid := 'b2000000-0000-0000-0000-000000000002';
  w2 constant uuid := '77777777-7777-7777-7777-777777777777';
  ph1 constant uuid := 'f4000000-0000-0000-0000-0000000000b1'; ph2 constant uuid := 'f4000000-0000-0000-0000-0000000000b2';
  tk1 constant uuid := 'f4000000-0000-0000-0000-0000000000b3'; tk2 constant uuid := 'f4000000-0000-0000-0000-0000000000b4';
  tk3 constant uuid := 'f4000000-0000-0000-0000-0000000000b5'; tk4 constant uuid := 'f4000000-0000-0000-0000-0000000000b6';
  nox constant uuid := 'f4000000-0000-0000-0000-0000000000ff'; r text;
BEGIN
  INSERT INTO job_phases (id, company_id, job_id, name, client_visible) VALUES (ph1, c1, j1, 'r3 c1 phase', true), (ph2, c2, j2, 'r3 c2 phase', false);
  INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES (tk1, c1, j1, 'r3 c1 task'), (tk2, c2, j2, 'r3 c2 a'), (tk3, c2, j2, 'r3 c2 b');
  -- the attacks
  PERFORM t_expect('r3: C2 writer cannot point its task at a C1 phase (update)',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', ph1, tk2)), 'err:A2C01');
  PERFORM t_expect('r3: C2 writer cannot point its task at a C1 task via depends_on (update)',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET depends_on = %L WHERE id = %L', tk1, tk2)), 'err:A2C01');
  PERFORM t_expect('r3: the combined attack (phase_id and depends_on in one UPDATE) is refused',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = %L, depends_on = %L WHERE id = %L', ph1, tk1, tk2)), 'err:A2C01');
  PERFORM t_expect('r3: C2 writer cannot insert a task with a C1 phase_id',
    t_dml_api('authenticated', w2, format('INSERT INTO job_tasks (company_id, job_id, task_name, phase_id) VALUES (%L, %L, ''r3 x'', %L)', c2, j2, ph1)), 'err:A2C01');
  PERFORM t_expect('r3: C2 writer cannot insert a task with a C1 depends_on',
    t_dml_api('authenticated', w2, format('INSERT INTO job_tasks (company_id, job_id, task_name, depends_on) VALUES (%L, %L, ''r3 x'', %L)', c2, j2, tk1)), 'err:A2C01');
  PERFORM t_expect('r3: the refusals changed nothing',
    (SELECT coalesce(phase_id::text, 'null') || '/' || coalesce(depends_on::text, 'null') FROM job_tasks WHERE id = tk2)
    || (SELECT count(*)::text FROM job_tasks WHERE task_name = 'r3 x'), 'null/null0');
  PERFORM t_expect('r3: the message names the column and does not echo ids',
    t_msg_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', ph1, tk2)), 'job_tasks.phase_id must reference a phase of the same job');
  PERFORM t_expect('r3: the table owner is held to the same rule (phase and depends_on)',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', ph1, tk2)) || pg_temp.try(format('UPDATE job_tasks SET depends_on = %L WHERE id = %L', tk1, tk2)), 'A2C01A2C01');
  -- legit flows
  PERFORM t_expect('r3: C2 writer sets a same-job phase and depends_on',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = %L, depends_on = %L WHERE id = %L', ph2, tk3, tk2)), 'rows:1');
  PERFORM t_expect('r3: C2 writer inserts a task with a same-job phase and depends_on',
    t_dml_api('authenticated', w2, format('INSERT INTO job_tasks (id, company_id, job_id, task_name, phase_id, depends_on) VALUES (%L, %L, %L, ''r3 ok'', %L, %L)', tk4, c2, j2, ph2, tk3)), 'rows:1');
  PERFORM t_expect('r3: a bulk insert whose depends_on points at a later row of the same statement works',
    pg_temp.try(format('INSERT INTO job_tasks (id, company_id, job_id, task_name, depends_on) VALUES (%L, %L, %L, ''r3 s1'', %L), (%L, %L, %L, ''r3 s2'', NULL)',
      'f4000000-0000-0000-0000-0000000000c1', c2, j2, 'f4000000-0000-0000-0000-0000000000c2', 'f4000000-0000-0000-0000-0000000000c2', c2, j2)), 'ok');
  PERFORM t_expect('r3: a reference to a row that does not exist is still refused by the foreign key (23503), not by the guard',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', nox, tk2)), 'err:23503');
  PERFORM t_expect('r3: unphasing and clearing depends_on work',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET phase_id = NULL, depends_on = NULL WHERE id = %L', tk2)), 'rows:1');
  r := pg_temp.try(format('DELETE FROM job_phases WHERE id = %L', ph2));
  PERFORM t_expect('r3: deleting a phase unphases its tasks (the FK SET NULL update passes the guard)',
    r || coalesce((SELECT phase_id::text FROM job_tasks WHERE id = tk4), 'null'), 'oknull');
  r := pg_temp.try(format('DELETE FROM job_tasks WHERE id = %L', tk3));
  PERFORM t_expect('r3: deleting a depended-on task clears depends_on on its dependents',
    r || coalesce((SELECT depends_on::text FROM job_tasks WHERE id = tk4), 'null'), 'oknull');
  PERFORM t_expect('r3: an UPDATE of an unrelated column is fine',
    t_dml_api('authenticated', w2, format('UPDATE job_tasks SET progress = 7 WHERE id = %L', tk4)), 'rows:1');
  PERFORM t_expect('r3: the owner can set a same-job phase on a C1 task',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', ph1, tk1)), 'ok');
  -- same job, other company (only reachable with the phase / task row planted past its own guard): the company half of the check
  ALTER TABLE job_phases DISABLE TRIGGER job_phases_company_guard; ALTER TABLE job_tasks DISABLE TRIGGER job_tasks_company_guard;
  INSERT INTO job_phases (id, company_id, job_id, name) VALUES ('f4000000-0000-0000-0000-0000000000d1', c1, j2, 'r3 odd phase');
  INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES ('f4000000-0000-0000-0000-0000000000d2', c1, j2, 'r3 odd task'), ('f4000000-0000-0000-0000-0000000000d3', c2, j2, 'r3 legacy');
  ALTER TABLE job_phases ENABLE TRIGGER job_phases_company_guard; ALTER TABLE job_tasks ENABLE TRIGGER job_tasks_company_guard;
  PERFORM t_expect('r3: a phase of the same job but another company is refused too',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', 'f4000000-0000-0000-0000-0000000000d1', tk4)), 'A2C01');
  PERFORM t_expect('r3: a task of the same job but another company is refused too',
    pg_temp.try(format('UPDATE job_tasks SET depends_on = %L WHERE id = %L', 'f4000000-0000-0000-0000-0000000000d2', tk4)), 'A2C01');
  -- a task that moves job must not drag a reference to the old job along
  PERFORM t_expect('r3: the owner sets a same-job phase and depends_on on a C1 task',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = %L WHERE id = %L', ph1, tk1)), 'ok');
  PERFORM t_expect('r3: moving a task to another job while it keeps its phase -> A2C01',
    pg_temp.try(format('UPDATE job_tasks SET job_id = %L WHERE id = %L', 'b3000000-0000-0000-0000-00000000000a', tk1)), 'A2C01');
  PERFORM t_expect('r3: moving a task to another job while it keeps its depends_on -> A2C01',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = NULL WHERE id = %L', tk1))
    || pg_temp.try(format('INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES (%L, %L, %L, ''r3 dep'')', 'f4000000-0000-0000-0000-0000000000e1', c1, j1))
    || pg_temp.try(format('UPDATE job_tasks SET depends_on = %L WHERE id = %L', tk1, 'f4000000-0000-0000-0000-0000000000e1'))
    || pg_temp.try(format('UPDATE job_tasks SET job_id = %L WHERE id = %L', 'b3000000-0000-0000-0000-00000000000a', 'f4000000-0000-0000-0000-0000000000e1')), 'okokokA2C01');
  PERFORM t_expect('r3: ... clearing the reference first, the move works',
    pg_temp.try(format('UPDATE job_tasks SET depends_on = NULL, job_id = %L WHERE id = %L', 'b3000000-0000-0000-0000-00000000000a', 'f4000000-0000-0000-0000-0000000000e1')), 'ok');
  -- a legacy row that already points across jobs is not blocked by a write that leaves the reference alone
  ALTER TABLE job_tasks DISABLE TRIGGER job_tasks_company_guard;
  UPDATE job_tasks SET phase_id = ph1, depends_on = tk1 WHERE id = 'f4000000-0000-0000-0000-0000000000d3';
  ALTER TABLE job_tasks ENABLE TRIGGER job_tasks_company_guard;
  PERFORM t_expect('r3: a legacy cross-job row can still be updated when the reference is left alone',
    pg_temp.try(format('UPDATE job_tasks SET phase_id = phase_id, depends_on = depends_on, progress = 3 WHERE id = %L', 'f4000000-0000-0000-0000-0000000000d3')), 'ok');
  PERFORM t_expect('r3: ... but re-pointing it at another cross-job row is refused',
    pg_temp.try(format('UPDATE job_tasks SET depends_on = %L WHERE id = %L', 'f4000000-0000-0000-0000-0000000000d2', 'f4000000-0000-0000-0000-0000000000d3')), 'A2C01');
  PERFORM t_expect('r3: struct: the job_tasks guard fires on UPDATE OF job_id, company_id, phase_id, depends_on',
    (SELECT (pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE OF job_id, company_id, phase_id, depends_on ON%')::text
       FROM pg_trigger WHERE tgname = 'job_tasks_company_guard'), 'true');
END $$;

-- ===== 12. M3: msp_uid is 1..100000000 =====
DO $$
BEGIN
  INSERT INTO job_tasks (id, company_id, job_id, task_name) VALUES ('f5000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-00000000000c', 'u1');
  INSERT INTO job_phases (id, company_id, job_id, name) VALUES ('f5000000-0000-0000-0000-0000000000f1', 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-00000000000c', 'p1');
  PERFORM t_expect('m3: a task uid of 2147483647 is rejected -> 23514', pg_temp.try('UPDATE job_tasks SET msp_uid = 2147483647 WHERE id = ''f5000000-0000-0000-0000-000000000001'''), '23514');
  PERFORM t_expect('m3: a phase uid of 2147483647 is rejected -> 23514', pg_temp.try('UPDATE job_phases SET msp_uid = 2147483647 WHERE id = ''f5000000-0000-0000-0000-0000000000f1'''), '23514');
  PERFORM t_expect('m3: a task uid of 100000001 is rejected -> 23514', pg_temp.try('UPDATE job_tasks SET msp_uid = 100000001 WHERE id = ''f5000000-0000-0000-0000-000000000001'''), '23514');
  PERFORM t_expect('m3: an inserted phase uid of 100000001 is rejected -> 23514',
    pg_temp.try('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (''c1000000-0000-0000-0000-000000000001'', ''b3000000-0000-0000-0000-00000000000c'', ''big'', 100000001)'), '23514');
  PERFORM t_expect('m3: a task uid of 100000000 is accepted', pg_temp.try('UPDATE job_tasks SET msp_uid = 100000000 WHERE id = ''f5000000-0000-0000-0000-000000000001'''), 'ok');
  PERFORM t_expect('m3: a phase uid of 100000000 is accepted', pg_temp.try('UPDATE job_phases SET msp_uid = 100000000 WHERE id = ''f5000000-0000-0000-0000-0000000000f1'''), 'ok');
  PERFORM t_expect('m3: uid 1 and NULL are accepted',
    pg_temp.try('UPDATE job_tasks SET msp_uid = 1 WHERE id = ''f5000000-0000-0000-0000-000000000001''') || pg_temp.try('UPDATE job_tasks SET msp_uid = NULL WHERE id = ''f5000000-0000-0000-0000-000000000001'''), 'okok');
  PERFORM t_expect('m3: one named range constraint per table, the legacy unnamed check is gone',
    (SELECT string_agg(conrelid::regclass::text || ':' || conname, ',' ORDER BY conname) FROM pg_constraint
      WHERE contype = 'c' AND conname IN ('job_phases_msp_uid_range', 'job_tasks_msp_uid_range', 'job_phases_msp_uid_check', 'job_tasks_msp_uid_check')),
    'job_phases:job_phases_msp_uid_range,job_tasks:job_tasks_msp_uid_range');
  PERFORM t_expect('m3: the column stays integer and nullable', (SELECT string_agg(data_type || is_nullable, ',') FROM information_schema.columns
      WHERE table_schema='public' AND table_name IN ('job_phases','job_tasks') AND column_name='msp_uid'), 'integerYES,integerYES');
END $$;

-- uid counter (owner decision 2026-10-28, X26): sched_next_uids hands out numbers from a per-job counter that never goes back
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; c2 constant uuid := 'c2000000-0000-0000-0000-000000000002';
  j constant uuid := 'b5000000-0000-0000-0000-0000000f1ee1'; jn constant uuid := 'b5000000-0000-0000-0000-0000000f1ee2';
  jm constant uuid := 'b5000000-0000-0000-0000-0000000f1ee5'; jr constant uuid := 'b5000000-0000-0000-0000-0000000f1ee6';
  jp constant uuid := 'b5000000-0000-0000-0000-0000000f1ee7'; jx constant uuid := 'b5000000-0000-0000-0000-0000000f1ee8';
  jc constant uuid := 'b5000000-0000-0000-0000-0000000f1ee9'; jq constant uuid := 'b5000000-0000-0000-0000-0000000f1eea'; jz constant uuid := 'b5000000-0000-0000-0000-0000000f1eeb';
  jf constant uuid := 'b5000000-0000-0000-0000-0000000f1eec'; jg constant uuid := 'b5000000-0000-0000-0000-0000000f1eed'; jh constant uuid := 'b5000000-0000-0000-0000-0000000f1eee'; jk constant uuid := 'b5000000-0000-0000-0000-0000000f1eef'; r text;
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (j, c1, 'WO-FREE1', 'Open'), (jn, c1, 'WO-FREE2', 'Open'), (jm, c1, 'WO-FREE5', 'Open'),
    (jr, c1, 'WO-FREE6', 'Open'), (jp, c1, 'WO-FREE7', 'Open'), (jx, c1, 'WO-FREE8', 'Open'), (jc, c1, 'WO-FREE9', 'Open'), (jq, c1, 'WO-FREEA', 'Open'), (jz, c1, 'WO-FREEB', 'Open'), (jf, c1, 'WO-FREEC', 'Open'), (jg, c1, 'WO-FREED', 'Open'), (jh, c1, 'WO-FREEE', 'Open'), (jk, c1, 'WO-FREEF', 'Open');
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES ('f4000000-0000-0000-0000-0000000f1ee1', c1, j, 1, 'p', 2);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES
    ('f5000000-0000-0000-0000-0000000f1ee1', c1, j, 1, 'a', 1), ('f5000000-0000-0000-0000-0000000f1ee2', c1, j, 2, 'b', 4),
    ('f5000000-0000-0000-0000-0000000f1ee3', c1, j, 3, 'c', 100000000), ('f5000000-0000-0000-0000-0000000f1ee4', c1, j, 4, 'd', NULL);
  -- first use with a row planted at the cap: there is no room after the highest stored uid, so the counter starts at 0 and used numbers are skipped
  PERFORM t_expect('counter: a job with a row at the cap still gets numbers: the first free ones skipping 1, 2, 4 and the cap', sched_next_uids(j, c1, 3)::text, '{3,5,6}');
  PERFORM t_expect('counter: the counter moved to the last number handed out', (SELECT last_uid::text FROM job_schedule_uid_counter WHERE job_id = j), '6');
  PERFORM t_expect('counter: the next call continues above the counter (7, 8), the cap row does not move it', sched_next_uids(j, c1, 2)::text, '{7,8}');
  PERFORM t_expect('counter: zero, negative and NULL ask for nothing and move nothing',
    sched_next_uids(j, c1, 0)::text || sched_next_uids(j, c1, -2)::text || sched_next_uids(j, c1, NULL)::text || (SELECT last_uid::text FROM job_schedule_uid_counter WHERE job_id = j), '{}{}{}8');
  -- a number is never handed out twice, even when its row was deleted
  PERFORM t_expect('counter: an empty job starts at 1', sched_next_uids(jn, c1, 3)::text, '{1,2,3}');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1ef1', c1, jn, 1, 'three', 3);
  DELETE FROM job_tasks WHERE id = 'f5000000-0000-0000-0000-0000000f1ef1';
  PERFORM t_expect('counter: number 3 was handed out and its row deleted; it is not given again (X26)', sched_next_uids(jn, c1, 1)::text, '{4}');
  -- first use continues after the highest stored uid
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1ef2', c1, jm, 1, 'five', 5), ('f5000000-0000-0000-0000-0000000f1ef3', c1, jm, 2, 'nine', 9);
  PERFORM t_expect('counter: first use continues after the highest stored uid (9): 10 and 11', sched_next_uids(jm, c1, 2)::text, '{10,11}');
  -- replace: the stored rows are about to be deleted, so they are not "used"
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1ef4', c1, jr, 1, 'one', 1), ('f5000000-0000-0000-0000-0000000f1ef5', c1, jr, 2, 'cap', 100000000);
  PERFORM t_expect('counter: replace ignores the stored rows (1 and the cap): 1 and 2', sched_next_uids(jr, c1, 2, true)::text, '{1,2}');
  PERFORM t_expect('counter: replace does not take the counter back: the next replace continues at 3', sched_next_uids(jr, c1, 1, true)::text, '{3}');
  -- a stored number above the counter is skipped, not reused
  PERFORM t_expect('counter: setup (job p)', sched_next_uids(jp, c1, 1)::text, '{1}');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1ef6', c1, jp, 1, 'planted', 2);
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES ('f4000000-0000-0000-0000-0000000f1ef8', c1, jp, 1, 'planted phase', 4);
  PERFORM t_expect('counter: stored uids above the counter (task 2, phase 4) are skipped', sched_next_uids(jp, c1, 3)::text, '{3,5,6}');
  -- first use: the highest stored uid may be a phase's; and a fit that is exactly the cap still continues after it
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES ('f4000000-0000-0000-0000-0000000f1ef9', c1, jq, 1, 'phase 20', 20);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1efa', c1, jq, 1, 'five', 5);
  PERFORM t_expect('counter: first use continues after the highest stored uid even when it belongs to a phase (20): 21', sched_next_uids(jq, c1, 1)::text, '{21}');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1efb', c1, jz, 1, 'top', 99999999);
  PERFORM t_expect('counter: r3 safety net: an implausible highest uid (99999999 among 1 row) does not seed the counter: starts at 0, 99999999 is skipped: 1', sched_next_uids(jz, c1, 1)::text, '{1}');
  -- the space can really run out (only the counter can do it now, a planted uid cannot)
  INSERT INTO job_schedule_uid_counter (job_id, last_uid) VALUES (jx, 99999999);
  BEGIN PERFORM sched_next_uids(jx, c1, 2); r := 'no error'; EXCEPTION WHEN SQLSTATE '22023' THEN r := SQLERRM; END;
  PERFORM t_expect('counter: asking for more than is left raises and keeps the counter', r || '|' || (SELECT last_uid::text FROM job_schedule_uid_counter WHERE job_id = jx), 'uid space exhausted|99999999');
  PERFORM t_expect('counter: the last number (100000000) can be handed out', sched_next_uids(jx, c1, 1)::text, '{100000000}');
  BEGIN PERFORM sched_next_uids(jx, c1, 1); r := 'no error'; EXCEPTION WHEN SQLSTATE '22023' THEN r := SQLERRM; END;
  PERFORM t_expect('counter: and then the space is exhausted', r, 'uid space exhausted');
  -- only rows of the given company count when the counter starts
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1ef7', c1, jc, 1, 'c1 row', 7);
  PERFORM t_expect('counter: rows of another company id are ignored: a company that has none starts at 1', sched_next_uids(jc, c2, 2)::text, '{1,2}');
  -- rows of another company that carry this job's id (planted as the owner with the triggers off) are ignored at first use and when skipping
  SET LOCAL session_replication_role = replica;
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES ('f4000000-0000-0000-0000-0000000f1efc', c2, jf, 1, 'foreign phase', 50);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1efd', c1, jf, 1, 'own', 3);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1efe', c2, jg, 1, 'foreign task', 1);
  SET LOCAL session_replication_role = origin;
  PERFORM t_expect('counter: a foreign-company phase (uid 50) does not move the first-use counter: own max 3, next is 4', sched_next_uids(jf, c1, 1)::text, '{4}');
  INSERT INTO job_schedule_uid_counter (job_id, last_uid) VALUES (jg, 0);
  PERFORM t_expect('counter: a foreign-company task (uid 1) is not a used number of this company: 1', sched_next_uids(jg, c1, 1)::text, '{1}');
  -- a stored uid above the cap (a database that predates the range CHECK) is ignored at first use
  ALTER TABLE job_tasks DROP CONSTRAINT IF EXISTS job_tasks_msp_uid_range;
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f1eff', c1, jh, 1, 'huge', 2147483647), ('f5000000-0000-0000-0000-0000000f1f00', c1, jh, 2, 'five', 5);
  PERFORM t_expect('counter: a stored uid above the cap is ignored at first use: continues after 5', sched_next_uids(jh, c1, 1)::text, '{6}');
  -- replace with a counter that is behind the stored rows (rows numbered by hand): the stored phase does not count as used
  INSERT INTO job_schedule_uid_counter (job_id, last_uid) VALUES (jk, 0);
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES ('f4000000-0000-0000-0000-0000000f1f01', c1, jk, 1, 'hand numbered', 1);
  PERFORM t_expect('counter: replace ignores a stored phase uid ahead of the counter: 1', sched_next_uids(jk, c1, 1, true)::text, '{1}');
  PERFORM t_expect('counter: the same without replace skips it (counter is now 1, next 2)', sched_next_uids(jk, c1, 1)::text, '{2}');
  BEGIN INSERT INTO job_schedule_uid_counter (job_id, last_uid) VALUES (jq, -1); r := 'inserted'; EXCEPTION WHEN check_violation THEN r := 'check'; END;
  PERFORM t_expect('counter: a negative counter is refused', r, 'check');
  BEGIN UPDATE job_schedule_uid_counter SET last_uid = 100000001 WHERE job_id = jk; r := 'updated'; EXCEPTION WHEN check_violation THEN r := 'check'; END;
  PERFORM t_expect('counter: a counter above the cap is refused', r, 'check');
  -- the counter table and the helper are closed to every API role
  PERFORM t_expect('counter: no API role can read or write the counter table',
    (SELECT string_agg(has_table_privilege(ro, 'job_schedule_uid_counter', pv)::text, ',') FROM unnest(ARRAY['authenticated', 'anon', 'service_role']) ro, unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) pv),
    'false,false,false,false,false,false,false,false,false,false,false,false');
  PERFORM t_expect('counter: row level security is on', (SELECT relrowsecurity::text FROM pg_class WHERE oid = 'public.job_schedule_uid_counter'::regclass), 'true');
  PERFORM t_expect('counter: the helper is not callable by API roles',
    has_function_privilege('authenticated', 'sched_next_uids(uuid, uuid, integer, boolean)', 'EXECUTE')::text || has_function_privilege('anon', 'sched_next_uids(uuid, uuid, integer, boolean)', 'EXECUTE')::text, 'falsefalse');
  DELETE FROM jobs WHERE id = jx;
  PERFORM t_expect('counter: deleting the job deletes its counter row', (SELECT count(*)::text FROM job_schedule_uid_counter WHERE job_id = jx), '0');
  PERFORM t_expect('counter: the old free-uid helper is gone', (SELECT count(*)::text FROM pg_proc WHERE proname = 'sched_free_uids'), '0');

  -- L3: the jobs company guard
  BEGIN UPDATE jobs SET company_id = c2 WHERE id = j; r := 'changed'; EXCEPTION WHEN SQLSTATE 'A2C02' THEN r := 'A2C02'; END;
  PERFORM t_expect('l3: a job with schedule rows keeps its company', r, 'A2C02');
  BEGIN UPDATE jobs SET company_id = c2 WHERE id = jc; r := 'changed'; EXCEPTION WHEN SQLSTATE 'A2C02' THEN r := 'A2C02'; END;
  PERFORM t_expect('l3: ... and a job whose only rows are tasks too', r, 'A2C02');
  INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b5000000-0000-0000-0000-0000000f1ee3', c1, 'WO-FREE3', 'Open'), ('b5000000-0000-0000-0000-0000000f1ee4', c1, 'WO-FREE4', 'Open');
  BEGIN UPDATE jobs SET company_id = c2 WHERE id = 'b5000000-0000-0000-0000-0000000f1ee4'; r := 'changed'; EXCEPTION WHEN SQLSTATE 'A2C02' THEN r := 'A2C02'; END;
  PERFORM t_expect('l3: a job without schedule rows can still change company', r, 'changed');
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES ('f4000000-0000-0000-0000-0000000f1ee3', c1, 'b5000000-0000-0000-0000-0000000f1ee3', 1, 'only a phase');
  BEGIN UPDATE jobs SET company_id = c2 WHERE id = 'b5000000-0000-0000-0000-0000000f1ee3'; r := 'changed'; EXCEPTION WHEN SQLSTATE 'A2C02' THEN r := 'A2C02'; END;
  PERFORM t_expect('l3: a job with only a phase keeps its company', r, 'A2C02');
  BEGIN UPDATE jobs SET company_id = company_id WHERE id = j; r := 'ok'; EXCEPTION WHEN SQLSTATE 'A2C02' THEN r := 'A2C02'; END;
  PERFORM t_expect('l3: writing the same company back is not a change', r, 'ok');
  PERFORM t_expect('l3: the guard trigger exists and its function is not callable by API roles',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'jobs_company_change_guard') || has_function_privilege('authenticated', 'jobs_company_change_guard()', 'EXECUTE')::text, '1false');
END $$;

-- ===== 13. r3 (MEDIUM): API roles never write msp_uid; a planted value cannot lock the uid space =====
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; w1 constant uuid := '11111111-1111-1111-1111-111111111111';
  j constant uuid := 'b5000000-0000-0000-0000-0000000f3001'; jd constant uuid := 'b5000000-0000-0000-0000-0000000f3002'; jb constant uuid := 'b5000000-0000-0000-0000-0000000f3003';
  t1 constant uuid := 'f5000000-0000-0000-0000-0000000f3001'; ph constant uuid := 'f4000000-0000-0000-0000-0000000f3001'; r text;
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (j, c1, 'WO-R3U1', 'Open'), (jd, c1, 'WO-R3U2', 'Open'), (jb, c1, 'WO-R3U3', 'Open');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES (t1, c1, j, 1, 'T');
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES (ph, c1, j, 1, 'P');
  PERFORM t_expect('r3: struct: guard triggers on both tables, function not executable by API roles, invoker with pinned search_path',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname IN ('job_phases_msp_uid_guard', 'job_tasks_msp_uid_guard') AND NOT tgisinternal)
    || (SELECT (NOT prosecdef AND array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')::text
          || has_function_privilege('authenticated', oid, 'EXECUTE')::text || has_function_privilege('anon', oid, 'EXECUTE')::text
          || has_function_privilege('service_role', oid, 'EXECUTE')::text FROM pg_proc WHERE proname = 'job_schedule_msp_uid_guard'),
    '2truefalsefalsefalse');
  -- the attack: a writer (no approve needed) plants the highest allowed-by-CHECK uid
  PERFORM t_expect('r3: writer cannot plant msp_uid 99999999 on a task (UPDATE)', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET msp_uid = 99999999 WHERE id = %L', t1)), 'err:A2U01');
  PERFORM t_expect('r3: writer cannot plant msp_uid on a phase (UPDATE)', t_dml_api('authenticated', w1, format('UPDATE job_phases SET msp_uid = 99999999 WHERE id = %L', ph)), 'err:A2U01');
  PERFORM t_expect('r3: writer cannot insert a task with an msp_uid', t_dml_api('authenticated', w1, format('INSERT INTO job_tasks (company_id, job_id, task_name, msp_uid) VALUES (%L, %L, ''x'', 5)', c1, j)), 'err:A2U01');
  PERFORM t_expect('r3: writer cannot insert a phase with an msp_uid', t_dml_api('authenticated', w1, format('INSERT INTO job_phases (company_id, job_id, name, msp_uid) VALUES (%L, %L, ''x'', 5)', c1, j)), 'err:A2U01');
  UPDATE job_tasks SET msp_uid = 7 WHERE id = t1;
  PERFORM t_expect('r3: writer cannot clear or change an existing msp_uid',
    t_dml_api('authenticated', w1, format('UPDATE job_tasks SET msp_uid = NULL WHERE id = %L', t1)) || t_dml_api('authenticated', w1, format('UPDATE job_tasks SET msp_uid = 8 WHERE id = %L', t1)), 'err:A2U01err:A2U01');
  PERFORM t_expect('r3: the refusals changed nothing', (SELECT msp_uid::text FROM job_tasks WHERE id = t1) || (SELECT count(*)::text FROM job_tasks WHERE job_id = j), '71');
  -- positive: everything the UI really does keeps working
  PERFORM t_expect('r3: writer inserts a task and a phase without msp_uid', t_dml_api('authenticated', w1, format('INSERT INTO job_tasks (company_id, job_id, task_name) VALUES (%L, %L, ''ui'')', c1, j))
    || t_dml_api('authenticated', w1, format('INSERT INTO job_phases (company_id, job_id, name) VALUES (%L, %L, ''ui'')', c1, j)), 'rows:1rows:1');
  PERFORM t_expect('r3: writer edits other columns of a numbered row', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET task_name = ''renamed'', progress = 10 WHERE id = %L', t1)), 'rows:1');
  PERFORM t_expect('r3: writing the same msp_uid back is not a change', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET msp_uid = 7 WHERE id = %L', t1)), 'rows:1');
  PERFORM t_expect('r3: anon is refused too (RLS or guard, never a write)', (t_dml_api('anon', NULL, format('UPDATE job_tasks SET msp_uid = 9 WHERE id = %L', t1)) IN ('err:A2U01', 'err:42501', 'rows:0'))::text, 'true');
  PERFORM t_expect('r3: service_role is refused too', t_dml_api('service_role', NULL, format('UPDATE job_tasks SET msp_uid = 9 WHERE id = %L', t1)), 'err:A2U01');
  PERFORM t_expect('r3: the owner (definer code, DBA) can still write msp_uid', pg_temp.try(format('UPDATE job_tasks SET msp_uid = 9 WHERE id = %L', t1)), 'ok');
  -- safety net: a value planted by the owner (DBA, legacy data) cannot lock the job
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f3002', c1, jd, 1, 'planted', 99999999);
  PERFORM t_expect('r3: net: a planted 99999999 does not move the counter: numbers 1..3 are handed out', sched_next_uids(jd, c1, 3)::text, '{1,2,3}');
  PERFORM t_expect('r3: net: the counter is at 3, not at the cap', (SELECT last_uid::text FROM job_schedule_uid_counter WHERE job_id = jd), '3');
  UPDATE job_tasks SET msp_uid = NULL WHERE id = 'f5000000-0000-0000-0000-0000000f3002';
  PERFORM t_expect('r3: net: clearing the planted uid, the job keeps counting (X26: 4 next, 1..3 never again)', sched_next_uids(jd, c1, 1)::text, '{4}');
  PERFORM t_expect('r3: net: the space is not exhausted after a replace-style request either', sched_next_uids(jd, c1, 2, true)::text, '{5,6}');
  -- the net still continues after a plausible highest uid (up to 4 per row + 1000)
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f3003', c1, jb, 1, 'edge', 1004);
  PERFORM t_expect('r3: net: highest uid 1004 with 1 row (limit 4*1+1000) is plausible: continues at 1005', sched_next_uids(jb, c1, 1)::text, '{1005}');
  INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b5000000-0000-0000-0000-0000000f3004', c1, 'WO-R3U4', 'Open');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f3004', c1, 'b5000000-0000-0000-0000-0000000f3004', 1, 'edge', 1005);
  PERFORM t_expect('r3: net: highest uid 1005 with 1 row is an outlier: starts at 0, skips 1005: 1', sched_next_uids('b5000000-0000-0000-0000-0000000f3004', c1, 1)::text, '{1}');
  INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b5000000-0000-0000-0000-0000000f3005', c1, 'WO-R3U5', 'Open');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES ('f5000000-0000-0000-0000-0000000f3005', c1, 'b5000000-0000-0000-0000-0000000f3005', 1, 'edge', 1005);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES ('f5000000-0000-0000-0000-0000000f3006', c1, 'b5000000-0000-0000-0000-0000000f3005', 2, 'unnumbered');
  PERFORM t_expect('r3: net: unnumbered rows count too: highest 1005 with 2 rows (limit 1008) is plausible: 1006', sched_next_uids('b5000000-0000-0000-0000-0000000f3005', c1, 1)::text, '{1006}');
END $$;

-- ===== 14. r3d M1: a uid never travels between jobs (X26) =====
-- Moving a numbered row to another job would hand that job a uid it may already have spent (a later merge of an older file would then
-- match and overwrite the moved row). API roles: job_id may not change on a row that holds an msp_uid (A2U01); an unnumbered row may move.
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; w1 constant uuid := '11111111-1111-1111-1111-111111111111';
  ja constant uuid := 'b6000000-0000-0000-0000-0000000f4001'; jb constant uuid := 'b6000000-0000-0000-0000-0000000f4002';
  tu constant uuid := 'f6000000-0000-0000-0000-0000000f4001'; tn constant uuid := 'f6000000-0000-0000-0000-0000000f4002';
  pu constant uuid := 'f6100000-0000-0000-0000-0000000f4001'; pn constant uuid := 'f6100000-0000-0000-0000-0000000f4002';
  kids constant uuid := 'f6000000-0000-0000-0000-0000000f4003'; kidn constant uuid := 'f6000000-0000-0000-0000-0000000f4004';
  par constant uuid := 'f6000000-0000-0000-0000-0000000f4005';
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (ja, c1, 'WO-M1A', 'Open'), (jb, c1, 'WO-M1B', 'Open');
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES (tu, c1, ja, 1, 'numbered', 7), (tn, c1, ja, 2, 'plain', NULL);
  INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES (pu, c1, ja, 1, 'numbered phase', 8), (pn, c1, ja, 2, 'plain phase', NULL);
  PERFORM t_expect('m1: struct: both msp_uid guards also fire on job_id changes',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname IN ('job_phases_msp_uid_guard', 'job_tasks_msp_uid_guard')
        AND pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE OF msp_uid, job_id ON%'), '2');
  -- the attack
  PERFORM t_expect('m1: writer cannot move a numbered task to another job', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, tu)), 'err:A2U01');
  PERFORM t_expect('m1: writer cannot move a numbered phase to another job', t_dml_api('authenticated', w1, format('UPDATE job_phases SET job_id = %L WHERE id = %L', jb, pu)), 'err:A2U01');
  PERFORM t_expect('m1: service_role cannot either (task and phase)',
    t_dml_api('service_role', NULL, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, tu)) || t_dml_api('service_role', NULL, format('UPDATE job_phases SET job_id = %L WHERE id = %L', jb, pu)), 'err:A2U01err:A2U01');
  PERFORM t_expect('m1: moving and clearing the uid in one statement is refused too',
    t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L, msp_uid = NULL WHERE id = %L', jb, tu)), 'err:A2U01');
  PERFORM t_expect('m1: the refusals changed nothing', (SELECT job_id::text || msp_uid::text FROM job_tasks WHERE id = tu) || (SELECT job_id::text || msp_uid::text FROM job_phases WHERE id = pu), ja::text || '7' || ja::text || '8');
  -- positive
  PERFORM t_expect('m1: a task and a phase WITHOUT a uid can still move (the export numbers them in the new job)',
    t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, tn)) || t_dml_api('authenticated', w1, format('UPDATE job_phases SET job_id = %L WHERE id = %L', jb, pn)), 'rows:1rows:1');
  PERFORM t_expect('m1: ... and they are in the new job', (SELECT job_id::text FROM job_tasks WHERE id = tn) || (SELECT job_id::text FROM job_phases WHERE id = pn), jb::text || jb::text);
  PERFORM t_expect('m1: a no-op job_id write on a numbered row passes (task and phase)',
    t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', ja, tu)) || t_dml_api('authenticated', w1, format('UPDATE job_phases SET job_id = job_id WHERE id = %L', pu)), 'rows:1rows:1');
  PERFORM t_expect('m1: other columns of a numbered row still edit freely', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET task_name = ''n2'', progress = 5 WHERE id = %L', tu)), 'rows:1');
  PERFORM t_expect('m1: the owner (definer code, DBA) can still move a numbered row', pg_temp.try(format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, tu)), 'ok');
  UPDATE job_tasks SET job_id = ja WHERE id = tu;
  -- A2H05 interplay: a task with a parent/children cannot change job. Both guards refuse; the uid guard runs first for a numbered one.
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES (par, c1, ja, 5, 'parent', NULL);
  INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid, parent_task_id) VALUES (kids, c1, ja, 6, 'kid with uid', 21, par), (kidn, c1, ja, 7, 'kid no uid', NULL, par);
  PERFORM t_expect('m1: A2H05 kept: an unnumbered child cannot move (hierarchy guard)', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, kidn)), 'err:A2H05');
  PERFORM t_expect('m1: a numbered child is refused by the uid guard first (A2U01)', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, kids)), 'err:A2U01');
  PERFORM t_expect('m1: an unnumbered parent with children cannot move (A2H05)', t_dml_api('authenticated', w1, format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, par)), 'err:A2H05');
  PERFORM t_expect('m1: the owner moving a numbered child is still stopped by A2H05', pg_temp.try(format('UPDATE job_tasks SET job_id = %L WHERE id = %L', jb, kids)), 'A2H05');
  PERFORM t_expect('m1: nothing moved', (SELECT count(*)::text FROM job_tasks WHERE id IN (par, kids, kidn, tu) AND job_id = ja), '4');
END $$;

-- ===== 15. r3d M2: no link between a task and its own ancestor / descendant (keeps job_schedule_status linear) =====
-- SQLSTATEs: A2L01 a link (insert / retarget) would join a task and its own ancestor or descendant; A2L02 a re-parenting would make an
-- existing link do so. Pre-existing (DBA-planted) links of that kind stay valid: only a NEW relation is refused.
-- Hierarchy: S(7001) > K(7002) > G(7003); S > K2(7006); X(7004), Y(7005) are roots.
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; w1 constant uuid := '11111111-1111-1111-1111-111111111111';
  jm constant uuid := 'b3000000-0000-0000-0000-000000000020'; jo constant uuid := 'b3000000-0000-0000-0000-000000000021'; r text;
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (jm, c1, 'WO-M2A', 'Open'), (jo, c1, 'WO-M2B', 'Open');
  PERFORM pg_temp.ins(7001, jm); PERFORM pg_temp.ins(7002, jm, 7001); PERFORM pg_temp.ins(7003, jm, 7002);
  PERFORM pg_temp.ins(7004, jm); PERFORM pg_temp.ins(7005, jm); PERFORM pg_temp.ins(7006, jm, 7001); PERFORM pg_temp.ins(7020, jo);
  PERFORM t_expect('m2: struct: link trigger BEFORE INSERT OR UPDATE OF task_id, predecessor_id, job_id; parent trigger BEFORE UPDATE OF parent_task_id',
    (SELECT count(*)::text FROM pg_trigger WHERE (tgname = 'job_task_links_z_hierarchy_guard' AND tgrelid = 'public.job_task_links'::regclass
        AND pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE OF task_id, predecessor_id, job_id ON%')
       OR (tgname = 'job_tasks_parent_link_guard' AND tgrelid = 'public.job_tasks'::regclass AND pg_get_triggerdef(oid) LIKE '%BEFORE UPDATE OF parent_task_id ON%')), '2');
  PERFORM t_expect('m2: struct: both functions pinned search_path, not callable by API roles',
    (SELECT string_agg(prosecdef::text || (array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')::text
        || has_function_privilege('authenticated', oid, 'EXECUTE')::text || has_function_privilege('anon', oid, 'EXECUTE')::text
        || has_function_privilege('service_role', oid, 'EXECUTE')::text, ',' ORDER BY proname)
       FROM pg_proc WHERE proname IN ('job_task_links_hierarchy_guard', 'job_tasks_parent_link_guard')), 'truetruefalsefalsefalse,truetruefalsefalsefalse');
  -- link insert
  PERFORM t_expect('m2: link S after its own child K -> A2L01', pg_temp.lnk(7001, 7002), 'A2L01');
  PERFORM t_expect('m2: link child K after its own summary S -> A2L01', pg_temp.lnk(7002, 7001), 'A2L01');
  PERFORM t_expect('m2: link S after its grandchild G -> A2L01', pg_temp.lnk(7001, 7003), 'A2L01');
  PERFORM t_expect('m2: link grandchild G after S -> A2L01 (typed link too)', pg_temp.lnk(7003, 7001, 'SS'), 'A2L01');
  PERFORM t_expect('m2: link K after its child G -> A2L01', pg_temp.lnk(7002, 7003, 'FF'), 'A2L01');
  PERFORM t_expect('m2: the refused links left no row', (SELECT count(*)::text FROM job_task_links WHERE job_id = jm), '0');
  PERFORM t_expect('m2: the error says what is wrong', (pg_temp.msg('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (''' || c1 || ''', ''' || jm || ''', pg_temp.tid(7001), pg_temp.tid(7002))') LIKE '%own ancestor or descendant%')::text, 'true');
  PERFORM t_expect('m2: the writer role is refused the same way', t_dml_api('authenticated', w1,
    format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jm, pg_temp.tid(7001), pg_temp.tid(7003))), 'err:A2L01');
  -- links that stay allowed
  PERFORM t_expect('m2: link from an outside task into a summary stays allowed', pg_temp.lnk(7001, 7004), 'ok');
  PERFORM t_expect('m2: link from a summary to an outside task stays allowed', pg_temp.lnk(7005, 7001), 'ok');
  PERFORM t_expect('m2: link from a leaf under a summary to an outside task stays allowed', pg_temp.lnk(7003, 7004), 'ok');
  PERFORM t_expect('m2: link between siblings stays allowed', pg_temp.lnk(7006, 7002), 'ok');
  -- r4: K2 is already after K (the siblings link above) and G is K's child, so "G after K2" would close the loop G -> K -> K2 -> G through the
  -- hierarchy (A2L03, see section 16); the other direction, "K2 after G", is only a second constraint on K2 and stays allowed.
  PERFORM t_expect('m2: link between cousins (K2 after G) stays allowed', pg_temp.lnk(7006, 7003, 'SF'), 'ok');
  PERFORM t_expect('m2: link between two roots stays allowed', pg_temp.lnk(7005, 7004), 'ok');
  -- a link across jobs is still refused by the older checks, not masked by this guard
  PERFORM t_expect('m2: link to a task of another job is still refused (23514)', pg_temp.lnk(7001, 7020), '23514');
  -- link update (retargeting)
  PERFORM pg_temp.lnk(7006, 7004);
  PERFORM t_expect('m2: update: pointing a link at the task''s own parent -> A2L01',
    pg_temp.try('UPDATE job_task_links SET predecessor_id = pg_temp.tid(7001) WHERE task_id = pg_temp.tid(7006) AND predecessor_id = pg_temp.tid(7004)'), 'A2L01');
  PERFORM pg_temp.lnk(7005, 7002);
  PERFORM t_expect('m2: update: moving a link to a task that is the predecessor''s child -> A2L01',
    pg_temp.try('UPDATE job_task_links SET task_id = pg_temp.tid(7003) WHERE task_id = pg_temp.tid(7005) AND predecessor_id = pg_temp.tid(7002)'), 'A2L01');
  -- r4: Y(7005) is after S(7001), so K2 (a child of S) after Y would close S -> Y -> K2 -> S: that retarget is A2L03 (section 16). A really unrelated root is fine.
  PERFORM pg_temp.ins(7009, jm);
  PERFORM t_expect('m2: update: retargeting to an unrelated task is allowed',
    pg_temp.try('UPDATE job_task_links SET predecessor_id = pg_temp.tid(7009) WHERE task_id = pg_temp.tid(7006) AND predecessor_id = pg_temp.tid(7004)'), 'ok');
  PERFORM t_expect('m2: update: lag / type edits are allowed', pg_temp.try('UPDATE job_task_links SET lag_days = 3, link_type = ''FF'' WHERE task_id = pg_temp.tid(7006)'), 'ok');
  -- a link planted by a DBA (trigger off) stays valid and editable; only moving it onto another related pair is refused
  ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_z_hierarchy_guard;
  PERFORM pg_temp.lnk(7003, 7001);
  ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_z_hierarchy_guard;
  PERFORM t_expect('m2: planted G-after-S link exists', (SELECT count(*)::text FROM job_task_links WHERE task_id = pg_temp.tid(7003) AND predecessor_id = pg_temp.tid(7001)), '1');
  PERFORM t_expect('m2: a planted link can still have its lag and type edited',
    pg_temp.try('UPDATE job_task_links SET lag_days = 2, link_type = ''SS'' WHERE task_id = pg_temp.tid(7003) AND predecessor_id = pg_temp.tid(7001)'), 'ok');
  PERFORM t_expect('m2: ... and a no-op rewrite of its endpoints passes',
    pg_temp.try('UPDATE job_task_links SET task_id = task_id, predecessor_id = predecessor_id WHERE task_id = pg_temp.tid(7003) AND predecessor_id = pg_temp.tid(7001)'), 'ok');
  PERFORM t_expect('m2: ... but retargeting it onto another related pair is refused',
    pg_temp.try('UPDATE job_task_links SET predecessor_id = pg_temp.tid(7002) WHERE task_id = pg_temp.tid(7003) AND predecessor_id = pg_temp.tid(7001)'), 'A2L01');
  -- re-parenting (A2L02)
  PERFORM t_expect('m2: reparent: Y under S while S is linked to Y -> A2L02', pg_temp.mv(7005, 7001), 'A2L02');
  PERFORM t_expect('m2: reparent: X under G while S and G are linked to X -> A2L02', pg_temp.mv(7004, 7003), 'A2L02');
  PERFORM t_expect('m2: reparent: K (with its child G) under X while G is linked to X -> A2L02', pg_temp.mv(7002, 7004), 'A2L02');
  PERFORM t_expect('m2: reparent: K2 under K while K2 is linked to K -> A2L02', pg_temp.mv(7006, 7002), 'A2L02');
  PERFORM pg_temp.ins(7008, jm); PERFORM pg_temp.lnk(7008, 7001);
  PERFORM t_expect('m2: reparent: task linked to S moved under G (S is only the grandparent chain: G > K > S) -> A2L02', pg_temp.mv(7008, 7003), 'A2L02');
  PERFORM t_expect('m2: reparent: ... and under K2 (S is its parent) -> A2L02; under the unlinked root Y it is fine', pg_temp.mv(7008, 7006) || '/' || pg_temp.mv(7008, 7005), 'A2L02/ok');
  PERFORM t_expect('m2: reparent: the refusals changed nothing', pg_temp.par(7005) || pg_temp.par(7004) || (pg_temp.par(7002) = pg_temp.tid(7001)::text)::text || (pg_temp.par(7006) = pg_temp.tid(7001)::text)::text, 'nullnulltruetrue');
  PERFORM t_expect('m2: reparent: the writer role is refused too', t_dml_api('authenticated', w1,
    format('UPDATE job_tasks SET parent_task_id = %L WHERE id = %L', pg_temp.tid(7003), pg_temp.tid(7004))), 'err:A2L02');
  PERFORM t_expect('m2: reparent: cycle and depth errors keep their own codes (the parent guard runs first)',
    pg_temp.mv(7001, 7003) || '/' || pg_temp.mv(7001, 7002), 'A2H02/A2H02');
  PERFORM t_expect('m2: reparent: an unlinked task moves freely (under G, to the root, under K2)',
    pg_temp.ins(7007, jm) || pg_temp.mv(7007, 7003) || pg_temp.mv(7007, NULL) || pg_temp.mv(7007, 7006), 'okokokok');
  PERFORM t_expect('m2: ... and is then covered by the link guard (A2L01 for a link to its new parent)', pg_temp.lnk(7007, 7006), 'A2L01');
  PERFORM t_expect('m2: reparent: detaching to the root is always allowed', pg_temp.mv(7006, NULL) || pg_temp.mv(7006, 7001), 'okok');
  -- only a NEW relation counts: G was already below the (planted) linked S; moving it from K up to S adds no ancestor, and back adds K only
  PERFORM t_expect('m2: reparent: G from K up to S adds no new ancestor of the planted pair -> allowed', pg_temp.mv(7003, 7001), 'ok');
  PERFORM t_expect('m2: reparent: G back under K adds only K (not linked to G) -> allowed', pg_temp.mv(7003, 7002), 'ok');
  PERFORM t_expect('m2: deleting a parent promotes its children and is never refused',
    pg_temp.try('DELETE FROM job_tasks WHERE id = pg_temp.tid(7002)') || pg_temp.par(7003), 'oknull');
END $$;

-- ===== 16. r4 M1: no link / re-parenting may close a cycle THROUGH the hierarchy (A2L03) =====
-- job_schedule_status carries values along links, kid -> summary (derive) and summary -> kids (inherit). S > X with Y after S and X after Y gives
-- S -> Y -> X -> S: the status function can never settle (slow cyclic path, runaway dates, "date out of range"). Both link and re-parent guards
-- therefore refuse any write that closes such a loop, whatever the link types. SQLSTATE A2L03 (class A2, "link"). Removing a kid or a link, or editing
-- lag / type, can never create a cycle (the guard works on a superset graph, see sched_flow_reach), so those stay unguarded.
CREATE FUNCTION pg_temp.api_err(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL SESSION AUTHORIZATION authenticator';
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'ok';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN SQLSTATE || ' ' || SQLERRM;
  END;
END $f$;
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; w1 constant uuid := '11111111-1111-1111-1111-111111111111';
  ja constant uuid := 'b3000000-0000-0000-0000-000000000030'; jb constant uuid := 'b3000000-0000-0000-0000-000000000031';
  jc constant uuid := 'b3000000-0000-0000-0000-000000000032'; jd constant uuid := 'b3000000-0000-0000-0000-000000000033';
  je constant uuid := 'b3000000-0000-0000-0000-000000000034'; ty text; i int;
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (ja, c1, 'WO-R4A', 'Open'), (jb, c1, 'WO-R4B', 'Open'), (jc, c1, 'WO-R4C', 'Open'),
                                                           (jd, c1, 'WO-R4D', 'Open'), (je, c1, 'WO-R4E', 'Open');
  -- ---- the reviewer's repro: tasks S, X (child of S), Y; "Y after S" is fine, then "X after Y" closes S -> Y -> X -> S
  PERFORM pg_temp.ins(8001, ja); PERFORM pg_temp.ins(8002, ja, 8001); PERFORM pg_temp.ins(8003, ja);
  PERFORM t_expect('r4: struct: the guard function is SECURITY DEFINER, pinned search_path, not callable by API roles',
    (SELECT string_agg(prosecdef::text || (array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%')::text
        || has_function_privilege('authenticated', oid, 'EXECUTE')::text || has_function_privilege('anon', oid, 'EXECUTE')::text
        || has_function_privilege('service_role', oid, 'EXECUTE')::text, ',' ORDER BY proname)
       FROM pg_proc WHERE proname IN ('sched_flow_reach', 'sched_flow_on_cycle')), 'truetruefalsefalsefalse,truetruefalsefalsefalse');
  PERFORM t_expect('r4: repro: Y after S is accepted', pg_temp.lnk(8003, 8001), 'ok');
  PERFORM t_expect('r4: repro: then X (a child of S) after Y is refused: A2L03', pg_temp.lnk(8002, 8003), 'A2L03');
  PERFORM t_expect('r4: repro: the writer role is refused the same way', t_dml_api('authenticated', w1,
    format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, ja, pg_temp.tid(8002), pg_temp.tid(8003))), 'err:A2L03');
  PERFORM t_expect('r4: repro: the error says what is wrong',
    (pg_temp.msg('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (''' || c1 || ''', ''' || ja || ''', pg_temp.tid(8002), pg_temp.tid(8003))') LIKE '%dependency cycle through the task hierarchy%')::text, 'true');
  PERFORM t_expect('r4: repro: the refused link left no row', (SELECT count(*)::text FROM job_task_links WHERE job_id = ja), '1');
  -- every link type, both ends (the guard works on a superset of the forward and backward graphs of job_schedule_status)
  FOREACH ty IN ARRAY ARRAY['FS', 'SS', 'FF', 'SF'] LOOP
    PERFORM t_expect('r4: repro, type ' || ty || ': X after Y refused', pg_temp.lnk(8002, 8003, ty), 'A2L03');
  END LOOP;
  -- the same loop from the other side: Y after X, then S after Y
  PERFORM pg_temp.ins(8011, jb); PERFORM pg_temp.ins(8012, jb, 8011); PERFORM pg_temp.ins(8013, jb);
  PERFORM t_expect('r4: variant: Y after the child X is accepted', pg_temp.lnk(8013, 8012), 'ok');
  PERFORM t_expect('r4: variant: then the summary S after Y is refused: A2L03', pg_temp.lnk(8011, 8013), 'A2L03');
  PERFORM t_expect('r4: variant: ... for every link type', pg_temp.lnk(8011, 8013, 'SS') || pg_temp.lnk(8011, 8013, 'FF') || pg_temp.lnk(8011, 8013, 'SF'), 'A2L03A2L03A2L03');
  -- the inherit edges reach grandchildren: S' > K' > G', Y after G', then S' after Y closes N(S') -> N(K') -> G' -> Y -> N(S')
  PERFORM pg_temp.ins(8016, jb); PERFORM pg_temp.ins(8017, jb, 8016); PERFORM pg_temp.ins(8018, jb, 8017); PERFORM pg_temp.ins(8019, jb);
  PERFORM t_expect('r4: variant: Y after a grandchild is accepted, then the grandparent after Y is refused (A2L03)',
    pg_temp.lnk(8019, 8018) || pg_temp.lnk(8016, 8019), 'okA2L03');
  -- nested summaries: S > K > X, Y outside
  PERFORM pg_temp.ins(8021, jc); PERFORM pg_temp.ins(8022, jc, 8021); PERFORM pg_temp.ins(8023, jc, 8022); PERFORM pg_temp.ins(8024, jc);
  PERFORM t_expect('r4: nested: Y after the grandparent S is accepted', pg_temp.lnk(8024, 8021), 'ok');
  PERFORM t_expect('r4: nested: the grandchild X after Y is refused', pg_temp.lnk(8023, 8024), 'A2L03');
  PERFORM t_expect('r4: nested: so is the middle summary K after Y', pg_temp.lnk(8022, 8024), 'A2L03');
  PERFORM t_expect('r4: nested: Y after the grandchild X as well is fine (a second predecessor of Y)', pg_temp.lnk(8024, 8023), 'ok');
  PERFORM t_expect('r4: nested: ... but now S after Y closes S -> Y -> S through its own kid: refused', pg_temp.lnk(8021, 8024), '23514');   -- a plain link cycle: Phase A no_cycle answers first (S -> Y exists)
  -- links that stay allowed: plain chains, kid -> outside, outside -> kid, siblings, two summaries
  PERFORM pg_temp.ins(8031, jd); PERFORM pg_temp.ins(8032, jd, 8031); PERFORM pg_temp.ins(8033, jd, 8031); PERFORM pg_temp.ins(8034, jd);
  PERFORM pg_temp.ins(8035, jd); PERFORM pg_temp.ins(8036, jd, 8035); PERFORM pg_temp.ins(8037, jd);
  PERFORM t_expect('r4: allowed: a kid after an outside task', pg_temp.lnk(8032, 8034), 'ok');
  PERFORM t_expect('r4: allowed: an outside task after a kid', pg_temp.lnk(8037, 8033), 'ok');
  PERFORM t_expect('r4: allowed: a sibling after a sibling', pg_temp.lnk(8033, 8032), 'ok');
  PERFORM t_expect('r4: allowed: one summary after another summary (S2 after S1)', pg_temp.lnk(8035, 8031), 'ok');
  PERFORM t_expect('r4: allowed: a kid of S2 after a kid of S1', pg_temp.lnk(8036, 8032, 'SS'), 'ok');
  PERFORM t_expect('r4: allowed: an outside task after S2 and after S1', pg_temp.lnk(8037, 8035) || pg_temp.lnk(8037, 8031), 'okok');
  -- re-parenting
  PERFORM pg_temp.ins(8041, je); PERFORM pg_temp.ins(8042, je); PERFORM pg_temp.ins(8043, je); PERFORM pg_temp.ins(8044, je);
  PERFORM pg_temp.lnk(8043, 8041);                                                -- Y after S
  PERFORM pg_temp.lnk(8042, 8043);                                                -- X after Y
  PERFORM t_expect('r4: reparent: X under S would close S -> Y -> X -> S: refused A2L03', pg_temp.mv(8042, 8041), 'A2L03');
  -- a moved task's OLD parent edges do not count: P1 > X, P2 -> L -> P1 (L after P2, P1 after L): P2 reaches N(P1) -> X only through the old position of X
  PERFORM pg_temp.ins(8071, je); PERFORM pg_temp.ins(8072, je, 8071); PERFORM pg_temp.ins(8073, je); PERFORM pg_temp.ins(8074, je);
  PERFORM pg_temp.lnk(8074, 8073); PERFORM pg_temp.lnk(8071, 8074);
  PERFORM t_expect('r4: reparent: moving X from P1 to P2 is judged without X''s old position under P1: allowed', pg_temp.mv(8072, 8073), 'ok');
  -- node kinds matter: P > K, X after K, P has a long chain after it (forward side > 40 nodes, so the backward side decides): X under P is fine although
  -- the backward walk from X meets N(P) (the kid K inherits P's constraints) and P itself is a different node
  PERFORM pg_temp.ins(8081, je); PERFORM pg_temp.ins(8082, je, 8081); PERFORM pg_temp.ins(8083, je);
  PERFORM pg_temp.ins(8301, je); PERFORM pg_temp.lnk(8301, 8081);
  FOR i IN 2..25 LOOP PERFORM pg_temp.ins(8300 + i, je); PERFORM pg_temp.lnk(8300 + i, 8300 + i - 1); END LOOP;
  PERFORM pg_temp.lnk(8083, 8082);
  PERFORM t_expect('r4: reparent: X (after P''s kid K) under P is allowed although the backward walk passes N(P)', pg_temp.mv(8083, 8081), 'ok');
  PERFORM t_expect('r4: reparent: the writer role is refused the same way', t_dml_api('authenticated', w1,
    format('UPDATE job_tasks SET parent_task_id = %L WHERE id = %L', pg_temp.tid(8041), pg_temp.tid(8042))), 'err:A2L03');
  PERFORM t_expect('r4: reparent: the refusal changed nothing', pg_temp.par(8042), 'null');
  PERFORM t_expect('r4: reparent: S under X would close it too (through Y): refused A2L03', pg_temp.mv(8041, 8042), 'A2L03');
  PERFORM t_expect('r4: reparent: Y under S is A2L02 (a link joins them), not masked', pg_temp.mv(8043, 8041), 'A2L02');
  PERFORM t_expect('r4: reparent: under an unrelated task is fine; so is detaching', pg_temp.mv(8042, 8044) || pg_temp.mv(8042, NULL), 'okok');
  PERFORM pg_temp.ins(8045, je, 8041);                                            -- Z, a second child of S: only "Z after Y" would close the loop
  PERFORM t_expect('r4: reparent: a task that is only linked to Y (Y after Z) can move under S?  Y -> S is not an edge: allowed',
    pg_temp.ins(8046, je) || pg_temp.lnk(8043, 8046) || pg_temp.mv(8046, 8041), 'okokok');
  -- retargeting a stored link
  PERFORM pg_temp.ins(8047, je); PERFORM pg_temp.lnk(8047, 8044);
  PERFORM t_expect('r4: update: retargeting "X after unrelated" to "X after Y" (X a child of S, Y after S) is refused A2L03',
    pg_temp.ins(8048, je, 8041) || pg_temp.lnk(8048, 8044) || pg_temp.try('UPDATE job_task_links SET predecessor_id = pg_temp.tid(8043) WHERE task_id = pg_temp.tid(8048)'), 'okokA2L03');
  -- the link being rewritten does not count as an edge of the graph: B > D (D a kid of B), A after B, E after A; rewriting "A after B" into "D after E" leaves
  -- D -> B (derive), A -> E and E -> D: acyclic. With the old row still counted B -> A would make D -> B -> A -> E -> D a loop.
  PERFORM pg_temp.ins(8061, je); PERFORM pg_temp.ins(8062, je, 8061); PERFORM pg_temp.ins(8063, je); PERFORM pg_temp.ins(8064, je);
  PERFORM pg_temp.lnk(8063, 8061); PERFORM pg_temp.lnk(8064, 8063);
  PERFORM t_expect('r4: update: a rewrite is judged without the row it replaces',
    pg_temp.try('UPDATE job_task_links SET task_id = pg_temp.tid(8062), predecessor_id = pg_temp.tid(8064) WHERE task_id = pg_temp.tid(8063) AND predecessor_id = pg_temp.tid(8061)'), 'ok');
  PERFORM t_expect('r4: update: lag / type edits stay allowed', pg_temp.try('UPDATE job_task_links SET lag_days = 4, link_type = ''SF'' WHERE task_id = pg_temp.tid(8048)'), 'ok');
  PERFORM t_expect('r4: removing a kid / a link never needs the guard: delete the kid, then the link',
    pg_temp.try('DELETE FROM job_tasks WHERE id = pg_temp.tid(8045)') || pg_temp.try('DELETE FROM job_task_links WHERE task_id = pg_temp.tid(8043)'), 'okok');
END $$;

-- ---- one write that is a cycle only because of a PLANTED (DBA / legacy) loop stays allowed: the job is cyclic already
DO $$
DECLARE c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; jp constant uuid := 'b3000000-0000-0000-0000-000000000035';
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (jp, c1, 'WO-R4P', 'Open');
  PERFORM pg_temp.ins(8051, jp); PERFORM pg_temp.ins(8052, jp, 8051); PERFORM pg_temp.ins(8053, jp);
  ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_z_hierarchy_guard;
  PERFORM pg_temp.lnk(8053, 8051); PERFORM pg_temp.lnk(8052, 8053);               -- the planted loop S -> Y -> X -> S
  ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_z_hierarchy_guard;
  PERFORM t_expect('r4: planted loop: it exists and the guard is on again',
    (SELECT count(*)::text FROM job_task_links WHERE job_id = jp) || (SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'job_task_links_z_hierarchy_guard'), '2O');
  PERFORM t_expect('r4: planted loop: lag / type edits of its links pass', pg_temp.try('UPDATE job_task_links SET lag_days = 1, link_type = ''SS'' WHERE job_id = ''' || jp || ''''), 'ok');
  PERFORM t_expect('r4: planted loop: an unrelated task can be added and linked (new links that close nothing)',
    pg_temp.ins(8054, jp) || pg_temp.lnk(8054, 8053), 'okok');
  PERFORM t_expect('r4: planted loop: a task can be added under X, which lies on the loop through the derive edge (exempt)', pg_temp.ins(8059, jp) || pg_temp.mv(8059, 8052), 'okok');
  -- a planted PURE link loop (A after B, B after A: the Phase A trigger is off too); a task moved under A is not what makes the job cyclic
  PERFORM pg_temp.ins(8056, jp); PERFORM pg_temp.ins(8057, jp); PERFORM pg_temp.ins(8058, jp);
  ALTER TABLE job_task_links DISABLE TRIGGER job_task_links_no_cycle;
  PERFORM pg_temp.lnk(8056, 8057); PERFORM pg_temp.lnk(8057, 8056);
  ALTER TABLE job_task_links ENABLE TRIGGER job_task_links_no_cycle;
  PERFORM t_expect('r4: planted loop: a task can be added under A, which lies on a planted link loop (exempt, through the link successors)', pg_temp.mv(8058, 8056), 'ok');
  PERFORM t_expect('r4: planted loop: a NEW link that closes another loop is still refused (Q, a kid of S, after Z)', pg_temp.ins(8055, jp, 8051) || pg_temp.lnk(8055, 8054), 'okA2L03');
  PERFORM t_expect('r4: planted loop: detaching X breaks the loop; putting it back would close it again, and the guard is exact once more: A2L03',
    pg_temp.mv(8052, NULL) || pg_temp.mv(8052, 8051), 'okA2L03');
END $$;

-- ---- the reviewer's 2001-task scale: S with 1000 kids chained against their direction, 1000 outsiders before S; then the two links of the repro
-- (fixture rows go in with the triggers off: they are valid, acyclic data, and on a fresh database the Phase A link-cycle trigger alone needs ~25 s
-- for these 2000 links, which says nothing about the guards; then the guards are on again for the probes)
SET LOCAL session_replication_role = replica;
INSERT INTO jobs (id, company_id, job_no, status) VALUES ('b3000000-0000-0000-0000-000000000036', 'c1000000-0000-0000-0000-000000000001', 'WO-R4S', 'Open');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  VALUES (pg_temp.tid(100001), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 1, 'S');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, parent_task_id)
  SELECT pg_temp.tid(100000 + g), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', g, 'K' || g, pg_temp.tid(100001) FROM generate_series(2, 1001) g;
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  SELECT pg_temp.tid(200000 + g), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 2000 + g, 'O' || g FROM generate_series(1, 1000) g;
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  VALUES (pg_temp.tid(300001), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 5000, 'Y');
-- a second long chain Q1 -> ... -> Q1100 that ends in S (S after Q1100): "Q1 after a kid of S" is a loop whose forward AND backward regions both exceed
-- the bounded searches (2000 nodes), so only the final unbounded walk can see it
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  SELECT pg_temp.tid(400000 + g), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 6000 + g, 'Q' || g FROM generate_series(1, 1100) g;
ANALYZE job_tasks;
CREATE TEMP TABLE r4_t0 AS SELECT clock_timestamp() AS t0;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
  SELECT 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(100000 + g), pg_temp.tid(100000 + g + 1) FROM generate_series(2, 1000) g;
ANALYZE job_task_links;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
  SELECT 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(100001), pg_temp.tid(200000 + g) FROM generate_series(1, 1000) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
  SELECT 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(400000 + g + 1), pg_temp.tid(400000 + g) FROM generate_series(1, 1099) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id)
  VALUES ('c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(100001), pg_temp.tid(401100));
-- a summary X with 60 kids, Z after kid 2 of X, S2 after Z: moving X under S2 closes S2 -> ... the loop is only visible from the (small) backward side
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name)
  VALUES (pg_temp.tid(500001), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 7000, 'X'),
         (pg_temp.tid(500100), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 7100, 'Z'),
         (pg_temp.tid(500101), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 7101, 'S2');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, parent_task_id)
  SELECT pg_temp.tid(500000 + g), 'c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', 7000 + g, 'XK' || g, pg_temp.tid(500001) FROM generate_series(2, 61) g;
INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(500100), pg_temp.tid(500002)),
  ('c1000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000036', pg_temp.tid(500101), pg_temp.tid(500100));
SET LOCAL session_replication_role = origin;
DO $$
DECLARE v_ms numeric;
BEGIN
  PERFORM t_expect('r4: scale 2001 tasks: the fixture job holds 3165 tasks and 3101 links',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = 'b3000000-0000-0000-0000-000000000036') || '/' || (SELECT count(*)::text FROM job_task_links WHERE job_id = 'b3000000-0000-0000-0000-000000000036'), '3165/3101');
  PERFORM t_expect('r4: scale 2001 tasks: Y after S accepted', pg_temp.lnk(300001, 100001), 'ok');
  PERFORM t_expect('r4: scale 2001 tasks: the last kid after Y refused A2L03', pg_temp.lnk(101001, 300001), 'A2L03');
  PERFORM t_expect('r4: scale 2001 tasks: so is the first kid', pg_temp.lnk(100002, 300001), 'A2L03');
  PERFORM t_expect('r4: scale 2001 tasks: an outside task after Y is fine',
    pg_temp.ins(300002, 'b3000000-0000-0000-0000-000000000036') || pg_temp.lnk(300002, 300001), 'okok');
  PERFORM t_expect('r4: scale: a fresh task before S (S after F) is accepted (the forward side is large, the backward side is one node)',
    pg_temp.ins(300003, 'b3000000-0000-0000-0000-000000000036') || pg_temp.lnk(100001, 300003), 'okok');
  PERFORM t_expect('r4: scale: Q1 after a kid of S closes Q1 -> ... -> Q1100 -> S -> kid -> Q1 (both searches exceed their bound; the unbounded walk decides): A2L03',
    pg_temp.lnk(400001, 100500), 'A2L03');
  PERFORM t_expect('r4: scale: S after Y2 where Y2 is after a kid of S: the forward side is huge, the backward side decides (hit): A2L03',
    pg_temp.ins(300004, 'b3000000-0000-0000-0000-000000000036') || pg_temp.lnk(300004, 100500) || pg_temp.lnk(100001, 300004), 'okokA2L03');
  PERFORM t_expect('r4: scale: S after a summary P whose kid Q is after a kid of S (backward walk through derive and inherit): A2L03',
    pg_temp.ins(300005, 'b3000000-0000-0000-0000-000000000036') || pg_temp.ins(300006, 'b3000000-0000-0000-0000-000000000036', 300005)
      || pg_temp.lnk(300006, 100500) || pg_temp.lnk(100001, 300005), 'okokokA2L03');
  PERFORM t_expect('r4: scale: moving X (60 kids) under S2 closes a loop that only the backward search sees (the forward side exceeds its bound): A2L03', pg_temp.mv(500001, 500101), 'A2L03');
  PERFORM t_expect('r4: scale: a link rewritten from "P after a kid of S" to "S after P" is judged without the row it replaces (backward side decides)',
    pg_temp.ins(300007, 'b3000000-0000-0000-0000-000000000036') || pg_temp.lnk(300007, 100500)
      || pg_temp.try('UPDATE job_task_links SET task_id = pg_temp.tid(100001), predecessor_id = pg_temp.tid(300007) WHERE task_id = pg_temp.tid(300007) AND predecessor_id = pg_temp.tid(100500)'), 'okokok');
  v_ms := extract(epoch FROM clock_timestamp() - (SELECT t0 FROM r4_t0)) * 1000;
  PERFORM t_expect('r4: scale 2001 tasks: 1999 links and the 4 probes with the guards on took under 60 s (' || round(v_ms) || ' ms)', (v_ms < 60000)::text, 'true');
END $$;

-- ===== 17. r4 LOW: a writer of another company learns nothing about the hierarchy of a company it does not belong to =====
-- The link triggers run in name order: company_guard, job_task_links_no_cycle (invoker, RLS), then job_task_links_z_hierarchy_guard (definer). A C2
-- writer that sends a link row with company_id / job_id of C1 must get the SAME error for a related and an unrelated pair of C1 tasks.
DO $$
DECLARE
  c1 constant uuid := 'c1000000-0000-0000-0000-000000000001'; c2 constant uuid := 'c2000000-0000-0000-0000-000000000002';
  w1 constant uuid := '11111111-1111-1111-1111-111111111111'; w2 constant uuid := '77777777-7777-7777-7777-777777777777';
  jx constant uuid := 'b3000000-0000-0000-0000-000000000037'; rel text; unrel text; rel2 text; unrel2 text; rel3 text; unrel3 text;
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (jx, c1, 'WO-R4X', 'Open');
  PERFORM pg_temp.ins(8101, jx); PERFORM pg_temp.ins(8102, jx, 8101); PERFORM pg_temp.ins(8103, jx);     -- S, its kid K, unrelated U
  PERFORM pg_temp.lnk(8103, 8101);                                                                        -- U after S, so "K after U" would be A2L03 for a C1 writer
  PERFORM t_expect('r4 low: trigger order: no_cycle fires before the definer hierarchy guard',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'public.job_task_links'::regclass AND NOT tgisinternal
        AND tgname IN ('job_task_links_no_cycle', 'job_task_links_z_hierarchy_guard', 'job_task_links_company_guard')),
    'job_task_links_company_guard,job_task_links_no_cycle,job_task_links_z_hierarchy_guard');
  -- controls: a member of C1 gets the specific errors
  PERFORM t_expect('r4 low: control: a C1 writer gets A2L01 for a related pair', left(pg_temp.api_err('authenticated', w1,
    format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8101), pg_temp.tid(8102))), 5), 'A2L01');
  PERFORM t_expect('r4 low: control: a C1 writer gets A2L03 for the hierarchy loop', left(pg_temp.api_err('authenticated', w1,
    format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8102), pg_temp.tid(8103))), 5), 'A2L03');
  -- the attack: C2 writer, rows carrying C1's company and job
  rel := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8101), pg_temp.tid(8102)));
  unrel := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8102), pg_temp.tid(8103) ));
  rel2 := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8102), pg_temp.tid(8101)));
  unrel2 := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c1, jx, pg_temp.tid(8103), pg_temp.tid(8102)));
  PERFORM t_expect('r4 low: a C2 writer sending C1 rows gets 23514 for a related pair (S after its kid)', left(rel, 5), '23514');
  PERFORM t_expect('r4 low: ... and the identical error for the hierarchy-loop pair', unrel, rel);
  PERFORM t_expect('r4 low: ... and for the kid-after-S pair (A2L01 for a member)', rel2, rel);
  PERFORM t_expect('r4 low: ... and for an unrelated pair', unrel2, rel);
  -- own company id on C1 tasks: the company guard answers (the same for every pair)
  rel3 := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c2, jx, pg_temp.tid(8101), pg_temp.tid(8102)));
  unrel3 := pg_temp.api_err('authenticated', w2, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L, %L, %L, %L)', c2, jx, pg_temp.tid(8102), pg_temp.tid(8103)));
  PERFORM t_expect('r4 low: a C2 writer sending its own company id on C1 tasks: A2C01, identical for related and unrelated pairs', left(rel3, 5) || (rel3 = unrel3)::text, 'A2C01true');
  PERFORM t_expect('r4 low: the same through an UPDATE of a link the writer cannot see changes nothing',
    t_dml_api('authenticated', w2, format('UPDATE job_task_links SET predecessor_id = %L WHERE task_id = %L', pg_temp.tid(8102), pg_temp.tid(8103))), 'rows:0');
END $$;

ROLLBACK;
