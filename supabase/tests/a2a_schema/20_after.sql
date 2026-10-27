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
    'job_tasks_baseline_guard,job_tasks_parent_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
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
  PERFORM t_expect('hier: same job, other company on insert -> A2H01',
    pg_temp.ins(13, 'b3000000-0000-0000-0000-00000000000a', 1, 'c2000000-0000-0000-0000-000000000002'), 'A2H01');
  PERFORM t_expect('hier: same job, other company on update -> A2H01',
    pg_temp.ins(14, 'b3000000-0000-0000-0000-00000000000a', NULL, 'c2000000-0000-0000-0000-000000000002') || '/' || pg_temp.mv(14, 1), 'ok/A2H01');
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
  PERFORM t_expect('jobchg: a task with children cannot change company -> A2H05',
    pg_temp.try('UPDATE job_tasks SET company_id = ''c2000000-0000-0000-0000-000000000002'' WHERE id = pg_temp.tid(81)'), 'A2H05');
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

ROLLBACK;
