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
    'job_tasks_baseline_guard,job_tasks_company_guard,job_tasks_parent_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
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
  PERFORM t_expect('counter: a first use that fits exactly up to the cap continues after the highest stored uid: 100000000', sched_next_uids(jz, c1, 1)::text, '{100000000}');
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

ROLLBACK;
