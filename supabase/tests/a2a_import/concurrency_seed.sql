-- Committed fixture for concurrency.sh: one job with 1 phase and 2 tasks, imported through the RPC (needs 10_stub_extra.sql helpers).
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000d0','c1000000-0000-0000-0000-000000000001','WO-ICONC','Open');
SELECT public.t_imp('authenticated', public.t_u('ops'), 'b1000000-0000-0000-0000-0000000000d0', 'append',
  public.t_pl(jsonb_build_array(public.t_ph(1, 'P')), jsonb_build_array(public.t_tk(2, 'B1', 1), public.t_tk(3, 'B2', 1)), NULL)) LIKE 'ok:%' AS seeded \gset
DO $$
BEGIN
  IF (SELECT count(*) FROM job_tasks WHERE job_id = 'b1000000-0000-0000-0000-0000000000d0') <> 2 THEN RAISE EXCEPTION 'seed failed'; END IF;
END $$;
