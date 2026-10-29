-- Session A of concurrency.sh: an approver previews (reads based_on while B's edit is still uncommitted), then replaces the schedule.
SELECT clock_timestamp() AS t0 \gset
BEGIN;
SELECT public.t_based('b1000000-0000-0000-0000-0000000000d0') AS based \gset
SELECT public.t_imp('authenticated', public.t_u('ops'), 'b1000000-0000-0000-0000-0000000000d0', 'replace',
  public.t_pl('[]', jsonb_build_array(public.t_tk(1, 'New')), 'b1000000-0000-0000-0000-0000000000d0', jsonb_build_object('based_on', :'based')),
  'new programme') AS res \gset
COMMIT;
SELECT 'A result ' || :'res';
SELECT 'A waited_ms ' || (extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000)::int;
