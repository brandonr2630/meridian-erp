-- Committed fixture for concurrency.sh: one job with 20 phases and 20 tasks, no uids yet.
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000c0','c1000000-0000-0000-0000-000000000001','WO-CONC','Open');
INSERT INTO job_phases (company_id, job_id, sort_order, name)
  SELECT 'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000c0', g, 'P' || g FROM generate_series(1, 20) g;
INSERT INTO job_tasks (company_id, job_id, sort_order, task_name)
  SELECT 'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000c0', g, 'T' || g FROM generate_series(1, 20) g;
