-- D0c (bills family): company- and permission-scoped RLS for bill_edit_events and bill_lines_archive.
--
-- Before: both tables carry the legacy PERMISSIVE policy "authenticated users full access" (FOR ALL TO authenticated
-- USING (true) WITH CHECK (true)); D0a only added the RESTRICTIVE active-staff gate (d0_staff_only / d0_no_anon, untouched here).
-- So every active staff member of any company could read, rewrite and delete the edit history of every company's bills.
--
-- After (all policies TO authenticated; the D0a restrictive pair still ANDs on top):
--   bill_edit_events  (bill_id -> bills.company_id)
--     SELECT  finance:ap:read AND the bill belongs to one of the caller's companies
--     INSERT  admin (admin:users or admin:settings: the UI gate isAdmin() for Edit Bill) AND edited_by = auth.uid()
--             AND the bill belongs to one of the caller's companies
--     UPDATE / DELETE  none (audit history is append-only; the ERP never updates or deletes these rows directly)
--   bill_lines_archive (edit_event_id -> bill_edit_events.bill_id -> bills.company_id)
--     SELECT  finance:ap:read AND the parent event's bill is in one of the caller's companies
--     INSERT  admin AND the parent event was written by the caller AND its bill is in one of the caller's companies
--     UPDATE / DELETE  none
--   Deleting a draft bill still removes its history: the FK ON DELETE CASCADE runs as the table owner, not as the caller.
--
-- Company scope is the same helper the bills table itself uses (my_company_ids()); the sub-selects on bills / bill_edit_events
-- run under the caller's own RLS, so a row whose parent is invisible to the caller stays invisible.
-- Idempotent: safe to run twice. Rollback: supabase/rollbacks/202610210500_d0c_bills_down.sql

-- ── bill_edit_events ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "authenticated users full access" ON public.bill_edit_events;
DROP POLICY IF EXISTS d0c_bill_edit_events_select ON public.bill_edit_events;
DROP POLICY IF EXISTS d0c_bill_edit_events_insert ON public.bill_edit_events;

CREATE POLICY d0c_bill_edit_events_select ON public.bill_edit_events
  FOR SELECT TO authenticated
  USING (
    (SELECT public.user_has_perm('finance:ap:read'))
    AND bill_id IN (SELECT b.id FROM public.bills b WHERE b.company_id IN (SELECT public.my_company_ids()))
  );

CREATE POLICY d0c_bill_edit_events_insert ON public.bill_edit_events
  FOR INSERT TO authenticated
  WITH CHECK (
    ((SELECT public.user_has_perm('admin:users')) OR (SELECT public.user_has_perm('admin:settings')))
    AND edited_by = (SELECT auth.uid())
    AND bill_id IN (SELECT b.id FROM public.bills b WHERE b.company_id IN (SELECT public.my_company_ids()))
  );

-- UPDATE: none. DELETE: none. (append-only audit history)

-- ── bill_lines_archive ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "authenticated users full access" ON public.bill_lines_archive;
DROP POLICY IF EXISTS d0c_bill_lines_archive_select ON public.bill_lines_archive;
DROP POLICY IF EXISTS d0c_bill_lines_archive_insert ON public.bill_lines_archive;

CREATE POLICY d0c_bill_lines_archive_select ON public.bill_lines_archive
  FOR SELECT TO authenticated
  USING (
    (SELECT public.user_has_perm('finance:ap:read'))
    AND edit_event_id IN (
      SELECT e.id FROM public.bill_edit_events e
      WHERE e.bill_id IN (SELECT b.id FROM public.bills b WHERE b.company_id IN (SELECT public.my_company_ids()))
    )
  );

CREATE POLICY d0c_bill_lines_archive_insert ON public.bill_lines_archive
  FOR INSERT TO authenticated
  WITH CHECK (
    ((SELECT public.user_has_perm('admin:users')) OR (SELECT public.user_has_perm('admin:settings')))
    AND edit_event_id IN (
      SELECT e.id FROM public.bill_edit_events e
      WHERE e.edited_by = (SELECT auth.uid())
        AND e.bill_id IN (SELECT b.id FROM public.bills b WHERE b.company_id IN (SELECT public.my_company_ids()))
    )
  );

-- UPDATE: none. DELETE: none. (archive rows are immutable history)
