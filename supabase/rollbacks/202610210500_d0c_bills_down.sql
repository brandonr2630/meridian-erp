-- Rollback for 202610210500_d0c_bills.sql: restore the exact legacy policy on both tables and drop the d0c_ policies.
-- (d0_staff_only / d0_no_anon from D0a are untouched.)
DROP POLICY IF EXISTS d0c_bill_edit_events_select ON public.bill_edit_events;
DROP POLICY IF EXISTS d0c_bill_edit_events_insert ON public.bill_edit_events;
DROP POLICY IF EXISTS d0c_bill_lines_archive_select ON public.bill_lines_archive;
DROP POLICY IF EXISTS d0c_bill_lines_archive_insert ON public.bill_lines_archive;

DROP POLICY IF EXISTS "authenticated users full access" ON public.bill_edit_events;
CREATE POLICY "authenticated users full access" ON public.bill_edit_events FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "authenticated users full access" ON public.bill_lines_archive;
CREATE POLICY "authenticated users full access" ON public.bill_lines_archive FOR ALL TO authenticated USING (true) WITH CHECK (true);
