-- job_tasks: planned tasks per work order, drives the per-job Gantt ("Schedule & Tasks" card).
-- Deliberately has NO created_by column: sibling tables disagree on whether it points at
-- auth.users(id) or erp_users(id) (see handoff Session 49/PO incident); we don't need it here.

CREATE TABLE job_tasks (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   uuid         NOT NULL REFERENCES companies(id),
  job_id       uuid         NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order   int          NOT NULL DEFAULT 0,
  task_name    text         NOT NULL DEFAULT '',
  start_date   date,
  end_date     date,
  progress     int          NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  assignee     text,
  depends_on   uuid         REFERENCES job_tasks(id) ON DELETE SET NULL,
  created_at   timestamptz  NOT NULL DEFAULT now(),
  updated_at   timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT job_tasks_dates_chk CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
);

CREATE INDEX idx_job_tasks_job_id         ON job_tasks (job_id);
CREATE INDEX idx_job_tasks_company_job    ON job_tasks (company_id, job_id);
CREATE INDEX idx_job_tasks_depends_on     ON job_tasks (depends_on);

ALTER TABLE job_tasks ENABLE ROW LEVEL SECURITY;

-- Read: anyone in the company. Use IN (SELECT my_company_ids()), not = ANY() (fails on this project).
CREATE POLICY "job_tasks members read" ON job_tasks
  FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()));

-- Write: company members who hold ops:work-orders:write.
CREATE POLICY "job_tasks writers insert" ON job_tasks
  FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));

CREATE POLICY "job_tasks writers update" ON job_tasks
  FOR UPDATE TO authenticated
  USING      (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));

CREATE POLICY "job_tasks writers delete" ON job_tasks
  FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
