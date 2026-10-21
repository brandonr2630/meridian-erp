# Phase D — Client portal

*Status: draft for review, round 2 · 2026-10-19 · applies the consistency and security reviews and the orchestrator's live read-only queries (`live-facts.md`). Depends on Phases A–C and on the blocking prerequisite D0.*

> **Amendment 2026-10-21 (from the A2 owner decisions, O6).** (1) Clients **see baseline dates**: `portal_schedule` already returns `baseline_start`/`baseline_end` and the page draws a ghost bar, so the portal side stands; the A2 download contract now includes Baseline 0. (2) **New hard gate: a release / user agreement.** Access to project data requires the client to have accepted the current agreement version. The agreement restricts use of the information in legal proceedings, and **ownership stays with Q2 Machines**. Mechanism (design only, no SQL yet): a versioned agreement table (text, SHA-256 of the text, effective and retired dates), a per-client-user acceptance record (user, agreement version, time, text hash), a `portal_accept_agreement` RPC, `portal_me` reporting `agreement_required`, and a central check that makes every `portal_*` data RPC and the schedule download refuse until the current version is accepted. Acceptances and client exports are audited. Today `accepted_at` only records the first sign-in; it is not an agreement. The wording belongs to the owner's lawyer (see open questions 9 and 10). Tracked in the A2 spec as rule X29 and open point N8.

## Goal and scope

Give named representatives of a Q2 Machines client a read-mostly, per-project portal. It is a **separate flat-file app** on its own subdomain, on the same Supabase project as the ERP (contract D3). It shows the mockup's Overview, Schedule, Quality, Documents, Messages and Team screens for the jobs a client has been granted. Clients can take four actions, each through a narrow `SECURITY DEFINER` RPC: respond to a hold point, approve or reject a drawing revision, send a message, and mark messages read. Staff invite clients, reply and revoke access inside the ERP. Clients are notified by email (a new portal edge function on the existing Resend path) and in the app.

This is the only phase with an external trust boundary, so the spec is a security design resting on five decisions:

1. **A client is a Supabase Auth user with no `erp_users` row.** A client JWT is an ordinary `authenticated` JWT, and the design assumes the client calls REST, RPC and Storage endpoints directly. The portal UI is never a control.
2. **Access is granted only through `project_clients`**: one row per auth user per job, with status, expiry and revocation. `portal_my_job_ids()` is the only place a grant becomes a set of job ids, and every `portal_*` function re-checks it on every call.
3. **Clients get no base-table grants and no RLS policies on A–C tables.** They read through `SECURITY DEFINER` `portal_*` **functions** (X15) that return a fixed column whitelist filtered on `client_visible = true`. There are no `portal_*` views.
4. **D0 ships first.** Live today, 21 tables plus `notification_types` carry identity-free policies, and the `job-drawings` storage policies check only `bucket_id`. Any client login would therefore read and write job costs and every company's drawings. D0 closes this before any client account exists.
5. **Clients never touch Storage directly.** Files are served only as 300-second signed URLs minted by the `portal-file-url` edge function (service role) for client-visible files in granted jobs. After D0a, the tenant-scoped storage policies match staff only, and a RESTRICTIVE staff-only policy denies every other JWT on the ERP buckets.

## Out of scope

- Client self-signup, OAuth, social login and SSO. Accounts are created only by staff invite.
- Client uploads, message attachments, and editing or deleting messages (staff can hide abusive ones).
- **Client sign-off of ITP items** (X8). Staff record ITP results; `portal_quality` returns ITP rows with `can_respond = false` as a documented non-feature.
- Any commercial data: quotes, invoices, costs, rates, payment terms, POs. A–C tables have no cost columns, and no portal function touches the commercial columns of `jobs`.
- Staff impersonation of clients. Staff test with a dedicated test client on a test job.
- Offline mode, push notifications, realtime. Messages are polled.
- Making `user_has_perm()` company-scoped ERP-wide (recorded under "Risks").
- Column-level separation of costs inside `*_entries` (staff who can see a work order still see its costs, as today).

## Data model

### D0 — Prerequisite: legacy hardening (blocking)

D0 is the **sanctioned exception to contract rule 1** (section 5, "no destructive change to a table the ERP currently reads"; see OV section 7 correction). It replaces policies on tables the ERP reads, so it is staged, verified with real non-privileged users, and ships the exact rollback SQL per stage.

**Live findings (orchestrator, read-only, 2026-10-19).**

| Area | Live state | D0 action |
|---|---|---|
| Public tables, RLS off (Q-A) | none | keep at zero (acceptance gate) |
| Views without `security_invoker` (Q-B) | none | keep at zero |
| Identity-free permissive policies (Q-C) | 21 tables with `"authenticated users full access"` (`FOR ALL TO authenticated USING (true) WITH CHECK (true)`): `bill_edit_events, bill_lines_archive, config_consumables, config_equipment, config_fuel, config_hardware, config_labour, config_materials, config_qc_checklists, config_tasks, config_tooling, consumable_entries, employees, equipment_entries, hardware_entries, job_audit_log, jobs, labour_entries, material_entries, subcontractor_entries, tooling_entries`; plus `notification_types` (`notif_types_read`, SELECT, `USING (true)`) | D0a restrictive staff-only policy on all 22; D0c replaces each with scoped policies |
| Storage policies | `Authenticated logo upload` (INSERT, `bucket_id = 'company-logos'`); `job-drawings auth read` / `auth upload` / `auth delete` (bucket-only). **No UPDATE policy.** No tenant scoping. Any authenticated JWT can list, read, upload and delete every company's drawings and upload logos. | D0a replaces all four, adds restrictive staff-only and anon-deny policies |
| Definer functions (Q-D) | 5: `is_company_admin(uuid)` (`public, pg_temp`; EXECUTE to PUBLIC, anon); `next_job_no()` (`public`; PUBLIC, anon); `is_super_admin()` (no search_path); `my_company_ids()` (no search_path); `user_has_perm(text)` (`public`) | revoke anon/PUBLIC, staff check in `next_job_no`, pin `public, pg_temp` on all via `ALTER FUNCTION ... SET search_path`. **No body change:** the live `my_company_ids()`, `is_super_admin()` and `user_has_perm()` already filter `is_active` (verified, live-facts 11) |
| Auth users (Q-E) | 4, all with an active `erp_users` row; 0 anonymous, 0 banned | restrictive policy locks out nobody today |
| Roles | `postgres`, `service_role` have BYPASSRLS; `authenticated`, `anon` do not | edge functions (service role) and owner-run definer functions are unaffected |
| Extensions | `pg_cron`, `pg_net`, `pg_graphql` **not installed** | no GraphQL surface today; portal-notify (and C, B4) need pg_cron + pg_net: enabled by the owner in the dashboard at prerequisite step 0 (X23), before A and C |
| GUC spoofing (Q-I) | no `authenticated`-callable function uses `set_config` or dynamic `EXECUTE` | basis for the `app.portal_rpc` guard (X6) |

**`job-drawings` object paths (verified in `index.html` `jcUploadDrawingPdf`).** The ERP has one upload path, and it builds `storage_key = <company_id>/<job_id>/<epoch>-<safe_name>`, stores the same string in `job_drawings.storage_key`, and signs and deletes by that key. The tenant policies therefore key on the first path segment, and add the permission check from X23: `ops:work-orders:read` to view, `ops:work-orders:write` to upload, company admin to delete. For safety they also accept any object whose name equals a `job_drawings.storage_key` row in one of the caller's companies (legacy fallback for SELECT and DELETE only). That way no existing download can break, even if Q-S1 finds a non-conforming object, and **no objects are moved**. Logos are uploaded as `<company_id|new>-<epoch>.<ext>` at the bucket root and served through the public URL, which does not pass through RLS.

**Stages.**

- **D0a** (`YYYYMMDDHHMM_d0a_staff_only_storage.sql`, first in the X16 order, one migration):
  - `is_erp_staff()`.
  - RESTRICTIVE `d0_staff_only` (`TO authenticated`) plus RESTRICTIVE `d0_no_anon` (`TO anon USING (false)`) on the 22 tables. A separate anon policy is used because `is_erp_staff()` is not executable by anon (M4).
  - The storage replacement and restrictive storage policies.
  - The function hardening (REVOKE, `ALTER FUNCTION ... SET search_path`, `next_job_no` staff check). No `is_active` change: the live helpers already filter it.
  - The audit-log index used by portal rate limits.
  - Restrictive policies are ANDed with the permissive ones, so active staff keep exactly what they have now. Everyone without an active `erp_users` row (clients, removed staff, stray users) gets nothing.
- **D0b** (code, same PR window; no migration): edge function `erp-user-access`. It replaces `toggleUserActive` / `removeUser` in `index.html`, which today only flip `is_active` or delete the `erp_users` row and leave a working Supabase login.
  - The caller is verified via `/auth/v1/user` and must pass `is_company_admin(c)` (called with the caller's JWT) for every company the target belongs to, or `is_super_admin()`.
  - **Deactivate**: `is_active = false`, then `auth.admin.updateUserById(id, {ban_duration: '876000h'})`, which also kills refresh tokens.
  - **Activate**: unban, then `is_active = true`.
  - **Remove**: ban first, then delete the `erp_users` row. The auth user stays banned, so it can never become a client-shaped identity.
  - The function writes a `job_audit_log` row (`job_id NULL`, `action_type 'staff.access.*'`).
- **D0c** (`YYYYMMDDHHMM_d0c_rls_<family>.sql`, one PR per family, a few days apart, after A–C per X16): replace each identity-free policy with company-scoped ones. Order: `job_audit_log` → `*_entries` → `jobs` → `employees`, `config_*`, `notification_types` → bill tables.
  - SELECT is company-scoped. Writes use the atom `index.html` already checks before showing the control.
  - **`job_audit_log` is owned by D0c only** (consistency #15; B4 defers). Its insert policy accepts the ERP's own path, which posts `user_id: currentUser.auth_user_id` (equal to `auth.uid()`; `index.html` lines ~8194 and ~8341).
  - The same PR makes the job-delete handler `await` its audit insert *before* `sbDelete('jobs')`. Today it fires without waiting, which would race the job-scoped check.
- **Verification per stage**: a real `operations_tech` and a `viewer` open, edit and save a work order, upload and view a drawing PDF, open Job Config, and an ERP-company admin changes a logo. Then run the client sweep ("Test plan"). Only then move on.
- **Rollback**: each stage's `-- down` restores the exact prior policies (texts above).

```sql
-- ── D0 inventory (read-only). Results as of 2026-10-19 are in the findings table. ──
-- Q-A: public tables with RLS disabled.                        Live: 0 rows.
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity;

-- Q-B: views readable by authenticated that are not security_invoker.   Live: 0 rows.
SELECT c.relname, c.relkind, c.reloptions FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('v','m')
  AND has_table_privilege('authenticated', c.oid, 'SELECT')
  AND NOT coalesce(c.reloptions && ARRAY['security_invoker=true','security_invoker=on'], false);

-- Q-C: permissive policies with no identity predicate (public + storage).
-- Live: 26 rows = 21 "authenticated users full access" + notif_types_read + the 4 bucket-only storage policies.
SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check FROM pg_policies
WHERE schemaname IN ('public','storage') AND permissive = 'PERMISSIVE'
  AND coalesce(qual,'') || ' ' || coalesce(with_check,'')
      !~* '(auth\.uid|my_company_ids|is_super_admin|is_company_admin|user_has_perm|is_erp_staff|erp_users|portal_)';

-- Q-D (the definer sweep; A, B and C reference it by this name, inventory Q-A..Q-E, Q-R, Q-S1; X23): every SECURITY DEFINER function, its search_path and EXECUTE grantees.
-- Live: 5 rows (is_company_admin, next_job_no executable by PUBLIC and anon; is_super_admin, my_company_ids without search_path).
SELECT p.oid::regprocedure, p.proconfig, p.proowner::regrole,
       (SELECT array_agg(CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END)
          FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE a.privilege_type = 'EXECUTE') AS exec_by
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef ORDER BY 1;

-- Q-E: auth users without an active erp_users row and without a live portal grant (counts). Live: 4 users, 0 / 0 / 0 / 0.
SELECT count(*) AS auth_users,
       count(*) FILTER (WHERE eu.id IS NULL) AS no_erp_row,
       count(*) FILTER (WHERE eu.is_active = false) AS inactive_erp_row,
       count(*) FILTER (WHERE u.is_anonymous) AS anonymous,
       count(*) FILTER (WHERE u.banned_until > now()) AS banned
FROM auth.users u LEFT JOIN public.erp_users eu ON eu.auth_user_id = u.id;

-- Q-R (stage-1 gate): Q-C public tables lacking either restrictive companion. Expect 0 rows after D0a.
SELECT DISTINCT p.tablename FROM pg_policies p
WHERE p.schemaname = 'public' AND p.permissive = 'PERMISSIVE'
  AND coalesce(p.qual,'') || ' ' || coalesce(p.with_check,'')
      !~* '(auth\.uid|my_company_ids|is_super_admin|is_company_admin|user_has_perm|is_erp_staff|erp_users|portal_)'
  AND (NOT EXISTS (SELECT 1 FROM pg_policies r WHERE r.schemaname = 'public' AND r.tablename = p.tablename
                   AND r.policyname = 'd0_staff_only' AND r.permissive = 'RESTRICTIVE')
    OR NOT EXISTS (SELECT 1 FROM pg_policies r WHERE r.schemaname = 'public' AND r.tablename = p.tablename
                   AND r.policyname = 'd0_no_anon' AND r.permissive = 'RESTRICTIVE'));

-- Q-S1 (pre-flight for storage): job-drawings objects whose first two path segments are not <company>/<job of that company>,
-- and job_drawings rows whose storage_key prefix differs from the row's company. Expected 0 / 0 (single upload path);
-- non-zero results are still served by the legacy fallback below, so this is informational, not blocking.
SELECT count(*) AS total,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM public.jobs j
                         WHERE j.id::text = (storage.foldername(o.name))[2]
                           AND j.company_id::text = (storage.foldername(o.name))[1])) AS nonconforming
FROM storage.objects o WHERE o.bucket_id = 'job-drawings';
SELECT count(*) AS key_prefix_mismatch FROM public.job_drawings d
WHERE d.storage_key IS NOT NULL AND split_part(d.storage_key, '/', 1) <> d.company_id::text;

-- Drawing atom coverage (pre-flight for the permission-checked storage policies, X23). Lists every role with its active
-- user count and whether it holds the read / write atoms. Roles with users but no read atom lose drawing view when D0a
-- applies; confirm that is intended (viewer and operations_tech hold read, per the review's atom table) before applying.
SELECT r.name, r.permissions ? 'ops:work-orders:read' AS has_read, r.permissions ? 'ops:work-orders:write' AS has_write,
       count(DISTINCT eu.id) FILTER (WHERE eu.is_active) AS active_users
FROM erp_roles r
LEFT JOIN erp_user_company_roles ucr ON ucr.role_id = r.id
LEFT JOIN erp_users eu ON eu.id = ucr.user_id
GROUP BY r.name, r.permissions ORDER BY r.name;

-- ── D0a (up) ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_erp_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM erp_users eu WHERE eu.auth_user_id = auth.uid() AND eu.is_active);
$$;
REVOKE ALL ON FUNCTION public.is_erp_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_erp_staff() TO authenticated;

-- Restrictive companions on the 22 live tables. Hard-coded from Q-C (all exist live) and guarded with to_regclass,
-- so a table dropped before deployment is skipped, not fatal. Re-run Q-C first; any new row must be added here.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','jobs','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types']
  LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE 'D0a: % not found, skipped', t;
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS d0_staff_only ON public.%I', t);
    EXECUTE format('CREATE POLICY d0_staff_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated '
                   'USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()))', t);
    EXECUTE format('DROP POLICY IF EXISTS d0_no_anon ON public.%I', t);
    EXECUTE format('CREATE POLICY d0_no_anon ON public.%I AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false)', t);
  END LOOP;
END $$;

-- Storage: replace the bucket-only policies with tenant-scoped, permission-checked staff policies (X17b, X23):
-- company membership PLUS ops:work-orders:read (select) / ops:work-orders:write (insert) / company admin (delete).
-- Regression check before applying: run the "drawing atom coverage" query in the pre-flight block; any active
-- role that uses the drawings UI today but lacks the read or write atom is listed there and must be resolved first.
DROP POLICY IF EXISTS "job-drawings auth read"   ON storage.objects;
DROP POLICY IF EXISTS "job-drawings auth upload" ON storage.objects;
DROP POLICY IF EXISTS "job-drawings auth delete" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated logo upload" ON storage.objects;

CREATE POLICY d0_drawings_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-drawings' AND public.user_has_perm('ops:work-orders:read') AND (
          (storage.foldername(name))[1] IN (SELECT c::text FROM public.my_company_ids() c)
       OR EXISTS (SELECT 1 FROM public.job_drawings d                  -- legacy fallback: exact key match
                   WHERE d.storage_key = storage.objects.name AND d.company_id IN (SELECT public.my_company_ids()))));
CREATE POLICY d0_drawings_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-drawings'
              AND public.user_has_perm('ops:work-orders:write')
              AND (storage.foldername(name))[1] IN (SELECT c::text FROM public.my_company_ids() c)
              AND EXISTS (SELECT 1 FROM public.jobs j            -- inside subqueries, always qualify storage.objects.name
                           WHERE j.id::text = (storage.foldername(storage.objects.name))[2]
                             AND j.company_id::text = (storage.foldername(storage.objects.name))[1]));
CREATE POLICY d0_drawings_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'job-drawings' AND (
          EXISTS (SELECT 1 FROM public.companies co             -- unqualified "name" would bind to companies.name
                   WHERE co.id::text = (storage.foldername(storage.objects.name))[1] AND public.is_company_admin(co.id))
       OR EXISTS (SELECT 1 FROM public.job_drawings d
                   WHERE d.storage_key = storage.objects.name AND public.is_company_admin(d.company_id))));
-- No UPDATE policy (none exists today): overwriting an existing object stays impossible for every JWT, so an issued
-- PDF cannot be swapped under a pending client approval. The ERP should drop its 'x-upsert: true' header (keys are unique).

CREATE POLICY d0_logos_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'company-logos' AND (
          public.is_super_admin()
       OR CASE WHEN name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-'
               THEN public.is_company_admin(left(name, 36)::uuid) ELSE false END));
-- 'new-<epoch>' names (logo chosen before the company row exists) therefore need super_admin, who creates companies.

-- Restrictive guards on the ERP buckets (job-updates is Phase C's bucket; naming it here is harmless before it exists).
CREATE POLICY d0_storage_staff_only ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
  USING (bucket_id NOT IN ('job-drawings','company-logos','job-updates') OR (SELECT public.is_erp_staff()))
  WITH CHECK (bucket_id NOT IN ('job-drawings','company-logos','job-updates') OR (SELECT public.is_erp_staff()));
CREATE POLICY d0_storage_no_anon ON storage.objects AS RESTRICTIVE FOR ALL TO anon
  USING (bucket_id NOT IN ('job-drawings','company-logos','job-updates'))
  WITH CHECK (bucket_id NOT IN ('job-drawings','company-logos','job-updates'));
-- Public logo URLs (/object/public/...) do not evaluate RLS and keep working.

-- Definer function hardening. search_path pinning only: the live bodies of my_company_ids(), is_super_admin() and
-- user_has_perm() ALREADY filter erp_users.is_active (live-facts 11), so no body is rebuilt and no is_active
-- change is made. ALTER FUNCTION keeps owner, grants and bodies exactly as they are.
ALTER FUNCTION public.my_company_ids()   SET search_path = public, pg_temp;
ALTER FUNCTION public.is_super_admin()   SET search_path = public, pg_temp;
ALTER FUNCTION public.user_has_perm(text) SET search_path = public, pg_temp;   -- L6
ALTER FUNCTION public.next_job_no()      SET search_path = public, pg_temp;
-- next_job_no(): CREATE OR REPLACE with the live body, adding as its first statement:
--   IF NOT public.is_erp_staff() THEN RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501'; END IF;
REVOKE ALL ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) TO authenticated;

-- Supports per-user rate limiting by portal RPCs (additive, no behaviour change).
CREATE INDEX IF NOT EXISTS job_audit_log_user_created_idx ON job_audit_log (user_id, created_at DESC);

-- -- down (D0a), in reverse:
-- DROP INDEX IF EXISTS job_audit_log_user_created_idx;
-- GRANT EXECUTE ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) TO PUBLIC, anon;
-- restore next_job_no from the definition pasted in the PR; ALTER FUNCTION public.my_company_ids() RESET search_path; (same for is_super_admin();
-- user_has_perm(text) and next_job_no() return to their prior 'public' setting).
-- DROP POLICY IF EXISTS d0_storage_no_anon, d0_storage_staff_only, d0_logos_insert, d0_drawings_delete, d0_drawings_insert, d0_drawings_select ON storage.objects;   (one statement per policy)
-- CREATE POLICY "Authenticated logo upload" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'company-logos');
-- CREATE POLICY "job-drawings auth read"   ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'job-drawings');
-- CREATE POLICY "job-drawings auth upload" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'job-drawings');
-- CREATE POLICY "job-drawings auth delete" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'job-drawings');
-- loop: DROP POLICY IF EXISTS d0_no_anon / d0_staff_only ON public.<each of the 22 tables>;
-- DROP FUNCTION IF EXISTS public.is_erp_staff();   (only after Phase D is rolled back; D depends on it)

-- ── D0c examples (one family per PR; atoms must match the index.html UI gates) ──
-- job_audit_log (first family). ERP insert path: user_id = currentUser.auth_user_id (= auth.uid()).
DROP POLICY IF EXISTS "authenticated users full access" ON job_audit_log;
CREATE POLICY d0_audit_select ON job_audit_log FOR SELECT TO authenticated
  USING (job_id IN (SELECT j.id FROM jobs j WHERE j.company_id IN (SELECT my_company_ids()))
         OR (job_id IS NULL AND is_super_admin()));
CREATE POLICY d0_audit_insert ON job_audit_log FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid()
              AND (job_id IS NULL OR job_id IN (SELECT j.id FROM jobs j WHERE j.company_id IN (SELECT my_company_ids()))));
CREATE POLICY d0_audit_no_update ON job_audit_log FOR UPDATE TO authenticated USING (false);
CREATE POLICY d0_audit_no_delete ON job_audit_log FOR DELETE TO authenticated USING (false);

DROP POLICY IF EXISTS "authenticated users full access" ON labour_entries;
CREATE POLICY d0_labour_select ON labour_entries FOR SELECT TO authenticated
  USING (job_id IN (SELECT j.id FROM jobs j WHERE j.company_id IN (SELECT my_company_ids())));
CREATE POLICY d0_labour_write ON labour_entries FOR ALL TO authenticated
  USING (job_id IN (SELECT j.id FROM jobs j WHERE j.company_id IN (SELECT my_company_ids()))
         AND user_has_perm('ops:work-orders:write'))
  WITH CHECK (job_id IN (SELECT j.id FROM jobs j WHERE j.company_id IN (SELECT my_company_ids()))
              AND user_has_perm('ops:work-orders:write'));
-- Same shape for material/consumable/equipment/hardware/tooling/subcontractor_entries.
-- jobs: company_id IN (SELECT my_company_ids()) for SELECT, plus ops:work-orders:write for writes.
-- config_*: SELECT is_erp_staff(); writes admin:settings OR ops:work-orders:write (catalog submit path).
-- notification_types: DROP POLICY notif_types_read; CREATE POLICY d0_notif_types_read ... FOR SELECT TO authenticated USING ((SELECT is_erp_staff())).
-- bill_edit_events / bill_lines_archive: scope through bills.company_id, finance:ap:read / finance:ap:write.
-- -- down (each D0c family): DROP the d0_* policies of that family, then
-- CREATE POLICY "authenticated users full access" ON <table> FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- (notification_types: CREATE POLICY notif_types_read ON notification_types FOR SELECT TO authenticated USING (true);)
```

### D1 — Phase D tables

`project_clients` is the grant table: one row per client user per job. It links the person to the customer `contacts` row (and optionally a `contact_persons` row) because `jobs.customer` is free text. `project_messages` holds one thread per job and is entirely client-facing (no internal notes, so no `client_visible` flag). `project_message_reads` holds one read watermark per reader per job.

**FK and retention choices.**
- `job_id` keeps `ON DELETE CASCADE` (contract rule 2). A `BEFORE DELETE` retention trigger on `project_clients` and `project_messages` makes any cascade from a job hard-delete fail (`portal:retention_hold`), so jobs with portal history cannot be deleted while the "job + 7 years" retention runs (L5). Purging is an operator action.
- **`updated_at` exception to X16:** `project_clients.updated_at` is set by the single `project_clients_guard` BEFORE trigger (`NEW.updated_at := now()`), not by `set_updated_at()`, so that one trigger owns the row and there is no trigger-ordering question. `project_messages` and `project_message_reads` use `set_updated_at()` as X16 requires.
- Staff and auth deletions use `SET NULL`, and the sender check tolerates a NULL sender id after deletion, so today's "Remove user" can never fail on a check violation (M3).

```sql
CREATE TABLE project_clients (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id         uuid NOT NULL REFERENCES companies(id),
  job_id             uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  auth_user_id       uuid REFERENCES auth.users(id) ON DELETE SET NULL,   -- set at insert by portal-invite; NULL only after auth-user deletion
  contact_id         uuid NOT NULL REFERENCES contacts(id),
  contact_person_id  uuid REFERENCES contact_persons(id) ON DELETE SET NULL,
  email              text NOT NULL CHECK (email = lower(btrim(email)) AND char_length(email) BETWEEN 3 AND 254 AND position('@' in email) > 1),
  display_name       text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 80),
  project_title      text NOT NULL CHECK (char_length(btrim(project_title)) BETWEEN 1 AND 120),
  client_role        text NOT NULL DEFAULT 'viewer' CHECK (client_role IN ('viewer','approver')),
  status             text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','active','suspended','revoked')),
  invited_by         uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  invited_at         timestamptz NOT NULL DEFAULT now(),
  invite_count       integer NOT NULL DEFAULT 1 CHECK (invite_count BETWEEN 1 AND 10),
  accepted_at        timestamptz,
  expires_at         timestamptz NOT NULL,     -- cap (<= now() + 366 days at each write) enforced by the guard trigger
  revoked_at         timestamptz,
  revoked_by         uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  revoke_reason      text CHECK (revoke_reason IS NULL OR char_length(revoke_reason) <= 500),
  notify_mode        text NOT NULL DEFAULT 'immediate' CHECK (notify_mode IN ('immediate','daily','off')),
  last_notified_at   timestamptz,
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_clients_revoked_chk CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
  CONSTRAINT project_clients_expiry_chk  CHECK (expires_at > invited_at)
);
CREATE INDEX project_clients_job_idx         ON project_clients (job_id);
CREATE INDEX project_clients_company_job_idx ON project_clients (company_id, job_id);
CREATE INDEX project_clients_user_idx        ON project_clients (auth_user_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX project_clients_live_user_uq  ON project_clients (job_id, auth_user_id) WHERE revoked_at IS NULL AND auth_user_id IS NOT NULL;
CREATE UNIQUE INDEX project_clients_live_email_uq ON project_clients (job_id, email) WHERE revoked_at IS NULL;

CREATE TABLE project_messages (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id               uuid NOT NULL REFERENCES companies(id),
  job_id                   uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sender_kind              text NOT NULL CHECK (sender_kind IN ('client','staff','system')),
  sender_auth_user_id      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  sender_erp_user_id       uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  sender_project_client_id uuid REFERENCES project_clients(id) ON DELETE SET NULL,
  sender_display_name      text NOT NULL CHECK (char_length(sender_display_name) BETWEEN 1 AND 80),
  body                     text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
  client_msg_id            uuid NOT NULL,
  hidden_at                timestamptz,
  hidden_by                uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  hidden_reason            text CHECK (hidden_reason IS NULL OR char_length(hidden_reason) <= 300),
  staff_notified_at        timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_messages_idem_uq UNIQUE (sender_auth_user_id, client_msg_id),
  -- Each kind forbids the *other* kind's sender id; its own id may become NULL after an FK SET NULL (M3).
  CONSTRAINT project_messages_sender_chk CHECK (
    (sender_kind = 'client' AND sender_erp_user_id IS NULL) OR
    (sender_kind = 'staff'  AND sender_project_client_id IS NULL) OR
    (sender_kind = 'system' AND sender_erp_user_id IS NULL AND sender_project_client_id IS NULL))
);
CREATE INDEX project_messages_job_idx         ON project_messages (job_id, created_at DESC);
CREATE INDEX project_messages_company_job_idx ON project_messages (company_id, job_id);
CREATE INDEX project_messages_sender_idx      ON project_messages (sender_auth_user_id, created_at DESC);

CREATE TABLE project_message_reads (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id           uuid NOT NULL REFERENCES companies(id),
  job_id               uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  reader_auth_user_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reader_kind          text NOT NULL CHECK (reader_kind IN ('client','staff')),
  last_read_at         timestamptz NOT NULL,
  last_read_message_id uuid REFERENCES project_messages(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT project_message_reads_uq UNIQUE (job_id, reader_auth_user_id)
);
CREATE INDEX project_message_reads_job_idx         ON project_message_reads (job_id);
CREATE INDEX project_message_reads_company_job_idx ON project_message_reads (company_id, job_id);

-- Integrity guard. Definer so it can read auth.users and erp_users. "Service context" = a request whose JWT role is
-- service_role, or a session with no JWT (operator SQL); a client or staff JWT cannot forge that claim.
CREATE OR REPLACE FUNCTION public.portal_trg_project_clients_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_service boolean := coalesce(auth.jwt() ->> 'role', 'service_role') = 'service_role';
  v_erase   boolean := v_service AND coalesce(current_setting('app.portal_erase', true), '') = '1';
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT v_service THEN RAISE EXCEPTION 'portal:insert_via_invite_only'; END IF;
    IF NEW.auth_user_id IS NULL THEN RAISE EXCEPTION 'portal:auth_user_required'; END IF;
    SELECT j.company_id INTO NEW.company_id FROM jobs j WHERE j.id = NEW.job_id;
    IF NEW.company_id IS NULL THEN RAISE EXCEPTION 'portal:invalid_job'; END IF;
    IF NOT EXISTS (SELECT 1 FROM contacts c WHERE c.id = NEW.contact_id AND c.company_id = NEW.company_id) THEN
      RAISE EXCEPTION 'portal:contact_company_mismatch';
    END IF;
  ELSE
    IF OLD.status = 'revoked' AND NEW.status <> 'revoked' THEN RAISE EXCEPTION 'portal:revocation_is_final'; END IF;
    IF NEW.job_id <> OLD.job_id OR NEW.company_id <> OLD.company_id OR NEW.contact_id <> OLD.contact_id
       OR NEW.invited_at <> OLD.invited_at
       OR (NEW.invited_by IS DISTINCT FROM OLD.invited_by AND NEW.invited_by IS NOT NULL)        -- SET NULL allowed
       OR (NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id AND NEW.auth_user_id IS NOT NULL)  -- SET NULL allowed
       OR (NEW.email <> OLD.email AND NOT v_erase)
       OR (NEW.invite_count <> OLD.invite_count AND NOT v_service) THEN
      RAISE EXCEPTION 'portal:immutable_column';
    END IF;
    IF NEW.status <> OLD.status AND NEW.status <> 'revoked' AND NOT v_service AND NOT (
         (OLD.status = 'invited' AND NEW.status = 'active' AND NEW.auth_user_id = auth.uid())        -- acceptance in portal_me
      OR (OLD.status IN ('invited','active','suspended') AND NEW.status IN ('active','suspended')
          AND is_erp_staff())) THEN                                                                -- staff suspend / resume
      RAISE EXCEPTION 'portal:invalid_status_change';
    END IF;
  END IF;
  -- M2: a bound auth user must own the grant's email and must never be staff.
  IF NEW.auth_user_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id) THEN
    IF EXISTS (SELECT 1 FROM erp_users eu WHERE eu.auth_user_id = NEW.auth_user_id) THEN
      RAISE EXCEPTION 'portal:staff_account_cannot_be_client';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = NEW.auth_user_id AND lower(u.email) = NEW.email) THEN
      RAISE EXCEPTION 'portal:email_mismatch';
    END IF;
  END IF;
  -- Consistency #22: expiry cap is relative to now(), so long jobs can be extended repeatedly.
  IF (TG_OP = 'INSERT' OR NEW.expires_at IS DISTINCT FROM OLD.expires_at) AND NOT v_erase
     AND (NEW.expires_at <= now() OR NEW.expires_at > now() + interval '366 days') THEN
    RAISE EXCEPTION 'portal:invalid_expiry';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER project_clients_guard BEFORE INSERT OR UPDATE ON project_clients
  FOR EACH ROW EXECUTE FUNCTION portal_trg_project_clients_guard();

-- Retention hold (L5): blocks direct deletes and job hard-delete cascades. Purge = operator SQL with app.portal_purge = '1'.
CREATE OR REPLACE FUNCTION public.portal_trg_retention_hold()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('app.portal_purge', true), '') = '1'
     AND coalesce(auth.jwt() ->> 'role', 'service_role') = 'service_role' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'portal:retention_hold' USING ERRCODE = '23503',
    HINT = 'This work order has client portal history. Close it instead of deleting it.';
END $$;
CREATE TRIGGER project_clients_retention  BEFORE DELETE ON project_clients  FOR EACH ROW EXECUTE FUNCTION portal_trg_retention_hold();
CREATE TRIGGER project_messages_retention BEFORE DELETE ON project_messages FOR EACH ROW EXECUTE FUNCTION portal_trg_retention_hold();
CREATE TRIGGER project_messages_touch     BEFORE UPDATE ON project_messages FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER project_message_reads_touch BEFORE UPDATE ON project_message_reads FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE ALL ON FUNCTION public.portal_trg_project_clients_guard(), public.portal_trg_retention_hold() FROM PUBLIC, anon, authenticated;
```

### D2 — Internal helpers (no client execute)

```sql
-- Grants as seen from an arbitrary uid (service-role paths). Never executable by API roles.
CREATE OR REPLACE FUNCTION public.portal_job_ids_for(p_uid uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT pc.job_id FROM project_clients pc
  WHERE p_uid IS NOT NULL AND pc.auth_user_id = p_uid
    AND pc.status = 'active' AND pc.revoked_at IS NULL AND pc.expires_at > now()
    AND NOT EXISTS (SELECT 1 FROM erp_users eu WHERE eu.auth_user_id = p_uid);
$$;

-- The caller's granted jobs. Anyone with an erp_users row (active or not) gets an empty set.
CREATE OR REPLACE FUNCTION public.portal_my_job_ids()
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT portal_job_ids_for(auth.uid()); $$;

-- The caller's live grant for a job, or a uniform not_found (no existence oracle).
CREATE OR REPLACE FUNCTION public.portal_require_grant(p_job_id uuid, p_min_role text DEFAULT 'viewer')
RETURNS project_clients LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  SELECT pc.* INTO g FROM project_clients pc
  WHERE pc.job_id = p_job_id AND pc.auth_user_id = auth.uid() AND pc.job_id IN (SELECT portal_my_job_ids());
  IF NOT FOUND THEN RAISE EXCEPTION 'portal:not_found' USING ERRCODE = 'P0002'; END IF;
  IF p_min_role = 'approver' AND g.client_role <> 'approver' THEN
    RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN g;
END $$;

-- Sliding-window rate limit. The advisory lock serialises concurrent calls per user and action (L1).
CREATE OR REPLACE FUNCTION public.portal_rate_check(p_action_prefix text, p_max int, p_window interval)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE n int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('portal:' || coalesce(auth.uid()::text, '-') || ':' || p_action_prefix));
  IF p_action_prefix = 'portal.message' THEN
    SELECT count(*) INTO n FROM project_messages
    WHERE sender_auth_user_id = auth.uid() AND created_at > now() - p_window;
  ELSE
    SELECT count(*) INTO n FROM job_audit_log
    WHERE user_id = auth.uid() AND action_type LIKE p_action_prefix || '%' AND created_at > now() - p_window;
  END IF;
  IF n >= p_max THEN RAISE EXCEPTION 'portal:rate_limited' USING ERRCODE = 'P0001'; END IF;
END $$;

-- Single audit writer; username is always populated (consistency #26). job_audit_log has no company_id column.
CREATE OR REPLACE FUNCTION public.portal_audit(p_job_id uuid, p_actor text, p_action text, p_description text, p_meta jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
  SELECT j.id, j.job_no, auth.uid(), left(coalesce(nullif(p_actor, ''), 'portal'), 80), p_action, left(p_description, 500),
         coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('company_id', j.company_id, 'channel', 'portal')
  FROM jobs j WHERE j.id = p_job_id;
$$;

-- Plain-text sanitiser: strips C0 controls (except tab/newline), DEL and bidi overrides; trims.
CREATE OR REPLACE FUNCTION public.portal_clean_text(p text, p_max int)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT nullif(left(btrim(regexp_replace(coalesce(p, ''), '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F‪-‮⁦-⁩]', '', 'g')), p_max), '');
$$;

-- Staff check for staff-side RPCs (user_has_perm is not company-scoped, so membership is tested separately).
CREATE OR REPLACE FUNCTION public.portal_staff_can(p_company_id uuid, p_perm text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT is_erp_staff() AND p_company_id IN (SELECT my_company_ids()) AND user_has_perm(p_perm);
$$;

-- In-app staff notification (X14): dotted type, job number in title. Recipients: active inviters of live grants
-- plus staff who posted on the thread in 60 days.
CREATE OR REPLACE FUNCTION public.portal_notify_staff(p_job_id uuid, p_type text, p_title text, p_body text)
RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  INSERT INTO erp_notifications (company_id, user_id, type, title, body)
  SELECT DISTINCT j.company_id, eu.id, p_type, left(j.job_no || ' · ' || p_title, 200), left(p_body, 200)
  FROM jobs j
  CROSS JOIN LATERAL (SELECT pc.invited_by AS uid FROM project_clients pc WHERE pc.job_id = j.id AND pc.revoked_at IS NULL
                      UNION
                      SELECT m.sender_erp_user_id FROM project_messages m
                       WHERE m.job_id = j.id AND m.sender_kind = 'staff' AND m.created_at > now() - interval '60 days') r
  JOIN erp_users eu ON eu.id = r.uid AND eu.is_active
  WHERE j.id = p_job_id;
$$;

-- Approvals require TOTP (aal2) once this returns true. STABLE, not IMMUTABLE, so flipping it by
-- CREATE OR REPLACE is never constant-folded into cached plans (L8).
CREATE OR REPLACE FUNCTION public.portal_cfg_require_mfa_for_approvals()
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$ SELECT false; $$;

-- Service role only: auth uid for an email (portal-invite). Avoids paging the admin user list.
CREATE OR REPLACE FUNCTION public.portal_auth_uid_for_email(p_email text)
RETURNS TABLE (auth_user_id uuid, is_staff boolean) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT u.id, EXISTS (SELECT 1 FROM erp_users eu WHERE eu.auth_user_id = u.id)
  FROM auth.users u WHERE lower(u.email) = lower(btrim(p_email));
$$;

REVOKE ALL ON FUNCTION public.portal_job_ids_for(uuid), public.portal_my_job_ids(),
  public.portal_require_grant(uuid, text), public.portal_rate_check(text, int, interval),
  public.portal_audit(uuid, text, text, text, jsonb), public.portal_clean_text(text, int),
  public.portal_staff_can(uuid, text), public.portal_notify_staff(uuid, text, text, text),
  public.portal_cfg_require_mfa_for_approvals(), public.portal_auth_uid_for_email(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_auth_uid_for_email(text) TO service_role;
```

### D3 — Client read RPCs

All of these are `SECURITY DEFINER`, use `SET search_path = public, pg_temp`, and declare an explicit `RETURNS TABLE`.

**Cast policy (#25):** every returned column is cast explicitly to its declared type (`::text`, `::int`, `::numeric`, `::date`, `::timestamptz`). A type change in A–C then coerces or fails loudly on the sweep's first call, instead of silently drifting.

D3a depends only on live tables and D1 and ships in `portal_core`. D3b reads A–C and ships in `portal_reads`, after A–C. The column names are those of the round-2 A–C drafts.

- `companies.trading_name`, `companies.name`, `companies.logo_url` and `erp_users.full_name` are read by `index.html` today. They are repo-verified, not DB-verified.
- `job_tasks.progress` is live `integer`.

```sql
-- D3a. Projects the caller can open (picker + login gate), with unread counts. Also records acceptance.
CREATE OR REPLACE FUNCTION public.portal_me()
RETURNS TABLE (job_id uuid, job_no text, project_title text, status_label text,
               client_role text, display_name text, notify_mode text, unread_count int, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Alias required: OUT params (expires_at, notify_mode, ...) would otherwise be ambiguous.
  UPDATE project_clients pcu SET last_seen_at = now(),
         status = CASE WHEN pcu.status = 'invited' THEN 'active' ELSE pcu.status END,
         accepted_at = coalesce(pcu.accepted_at, now())
  WHERE pcu.auth_user_id = auth.uid() AND pcu.revoked_at IS NULL AND pcu.status IN ('invited','active')
    AND pcu.expires_at > now()
    AND (pcu.status = 'invited' OR pcu.last_seen_at IS NULL OR pcu.last_seen_at < now() - interval '5 minutes');
  RETURN QUERY
  SELECT pc.job_id, j.job_no::text, pc.project_title,
         (CASE j.status WHEN 'Received' THEN 'Not started' WHEN 'In Progress' THEN 'In progress'
                        WHEN 'On Hold' THEN 'On hold' WHEN 'Closed' THEN 'Closed' ELSE 'Completed' END)::text,
         pc.client_role, pc.display_name, pc.notify_mode,
         (SELECT count(*)::int FROM project_messages m
           LEFT JOIN project_message_reads r ON r.job_id = m.job_id AND r.reader_auth_user_id = auth.uid()
           WHERE m.job_id = pc.job_id AND m.hidden_at IS NULL AND m.sender_kind <> 'client'
             AND m.created_at > coalesce(r.last_read_at, '-infinity')),
         pc.expires_at
  FROM project_clients pc JOIN jobs j ON j.id = pc.job_id
  WHERE pc.auth_user_id = auth.uid() AND pc.job_id IN (SELECT portal_my_job_ids())
  ORDER BY j.job_no;
END $$;

-- Staff appear as first name plus "Q2 Machines" (X10; the stored sender_display_name is the first name only).
CREATE OR REPLACE FUNCTION public.portal_messages(p_job_id uuid, p_before timestamptz DEFAULT NULL, p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, created_at timestamptz, sender_kind text, sender_display_name text, is_mine boolean, body text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT m.id, m.created_at, m.sender_kind,
         (CASE WHEN m.sender_kind = 'staff' THEN m.sender_display_name || ' · Q2 Machines' ELSE m.sender_display_name END)::text,
         coalesce(m.sender_auth_user_id = auth.uid(), false),
         (CASE WHEN m.hidden_at IS NULL THEN m.body ELSE '[message removed by Q2 Machines]' END)::text
  FROM project_messages m
  WHERE m.job_id = p_job_id AND (p_before IS NULL OR m.created_at < p_before)
  ORDER BY m.created_at DESC
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 100);
END $$;

-- Team card: active client reps on this job, and Q2 staff who invited or posted in 90 days.
-- Staff: first name and role label only (X10); never email or phone.
CREATE OR REPLACE FUNCTION public.portal_team(p_job_id uuid)
RETURNS TABLE (member_kind text, display_name text, role_label text, is_primary_contact boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT 'client'::text, pc.display_name, initcap(pc.client_role)::text, false
    FROM project_clients pc
   WHERE pc.job_id = p_job_id AND pc.status = 'active' AND pc.revoked_at IS NULL AND pc.expires_at > now()
  UNION ALL
  SELECT 'q2'::text, coalesce(nullif(split_part(coalesce(eu.full_name, ''), ' ', 1), ''), 'Q2')::text,
         (CASE WHEN bool_or(pc2.id IS NOT NULL) THEN 'Q2 project contact' ELSE 'Q2 project team' END)::text,
         coalesce(bool_or(pc2.id IS NOT NULL), false)
    FROM erp_users eu
    LEFT JOIN project_clients pc2 ON pc2.job_id = p_job_id AND pc2.invited_by = eu.id AND pc2.revoked_at IS NULL
   WHERE eu.is_active
     AND (pc2.id IS NOT NULL OR eu.id IN (SELECT m.sender_erp_user_id FROM project_messages m
                                           WHERE m.job_id = p_job_id AND m.created_at > now() - interval '90 days'))
   GROUP BY eu.id, eu.full_name;
END $$;

-- D3b. A–C readers (portal_reads migration).
CREATE OR REPLACE FUNCTION public.portal_project_header(p_job_id uuid)
RETURNS TABLE (job_id uuid, job_no text, project_title text, status_label text, company_name text,
               company_logo_url text, last_activity_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  g := portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT j.id, j.job_no::text, g.project_title,
         (CASE j.status WHEN 'Received' THEN 'Not started' WHEN 'In Progress' THEN 'In progress'
                        WHEN 'On Hold' THEN 'On hold' WHEN 'Closed' THEN 'Closed' ELSE 'Completed' END)::text,
         coalesce(c.trading_name, c.name)::text, c.logo_url::text,
         greatest((SELECT max(t.updated_at) FROM job_tasks t WHERE t.job_id = j.id AND job_task_client_visible(t.id)),
                  (SELECT max(u.published_at) FROM job_updates u WHERE u.job_id = j.id AND u.client_visible),
                  (SELECT max(m.created_at) FROM project_messages m WHERE m.job_id = j.id AND m.hidden_at IS NULL))::timestamptz
  FROM jobs j JOIN companies c ON c.id = j.company_id
  WHERE j.id = p_job_id;
END $$;

-- KPI strip. Progress and schedule come from the latest client_visible snapshot (X2: stored by C, A's labels;
-- D never recomputes). schedule_status is one of A's five labels (X21): 'On track' | 'At risk' | 'Late' | 'Complete' |
-- 'On hold', plus the D-only display state 'Not published' when no snapshot is client-visible. ITP counts follow X8: passed / (status <> 'na'), waived shown separately.
CREATE OR REPLACE FUNCTION public.portal_project_kpis(p_job_id uuid)
RETURNS TABLE (actual_pct numeric, planned_pct numeric, as_of date, schedule_status text, forecast_handover date,
               planned_handover date, slip_days int, itp_passed int, itp_waived int, itp_total int,
               hold_points_awaiting int, open_ncrs int, documents_awaiting int, unread_messages int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_act numeric; v_plan numeric; v_asof date; v_status text; v_fend date; v_slip int;
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  SELECT ps.actual_pct, ps.planned_pct, ps.snapshot_date, ps.schedule_status, ps.forecast_end, ps.slip_days
    INTO v_act, v_plan, v_asof, v_status, v_fend, v_slip
    FROM job_progress_snapshots ps WHERE ps.job_id = p_job_id AND ps.client_visible
    ORDER BY ps.snapshot_date DESC LIMIT 1;
  RETURN QUERY SELECT
    v_act::numeric, v_plan::numeric, v_asof::date,
    coalesce(v_status, 'Not published')::text,                 -- five labels from A (X21) | 'Not published' (D-only)
    v_fend::date,
    (CASE WHEN v_slip IS NULL THEN NULL ELSE v_fend - v_slip END)::date,   -- X21: planned handover is NULL when slip is NULL; never coalesce(slip, 0)
    v_slip::int,
    (SELECT count(*)::int FROM job_itp_items i WHERE i.job_id = p_job_id AND i.client_visible AND i.status = 'passed'),
    (SELECT count(*)::int FROM job_itp_items i WHERE i.job_id = p_job_id AND i.client_visible AND i.status = 'waived'),
    (SELECT count(*)::int FROM job_itp_items i WHERE i.job_id = p_job_id AND i.client_visible AND i.status <> 'na'),
    (SELECT count(*)::int FROM job_hold_points h WHERE h.job_id = p_job_id AND h.client_visible AND h.state = 'notified' AND h.witness_party = 'client'),
    (SELECT count(*)::int FROM job_ncrs n WHERE n.job_id = p_job_id AND n.client_visible AND n.status NOT IN ('closed','cancelled')),
    (SELECT count(*)::int FROM job_drawings d WHERE d.job_id = p_job_id AND d.client_visible AND NOT d.archived AND d.status = 'for_approval'),
    (SELECT count(*)::int FROM project_messages m
       LEFT JOIN project_message_reads r ON r.job_id = m.job_id AND r.reader_auth_user_id = auth.uid()
      WHERE m.job_id = p_job_id AND m.hidden_at IS NULL AND m.sender_kind <> 'client'
        AND m.created_at > coalesce(r.last_read_at, '-infinity'));
END $$;

-- Grouped Gantt rows. No links are returned: the portal Gantt shows critical colouring only, no dependency arrows (#29).
-- X22: a task row appears only if A's job_task_client_visible(task_id) is true (task visible AND (phase NULL OR phase
-- visible)), the same predicate C's job_planned_curve(..., client_only) uses, so the Gantt and planned curve share a basis.
CREATE OR REPLACE FUNCTION public.portal_schedule(p_job_id uuid)
RETURNS TABLE (row_type text, id uuid, phase_id uuid, name text, sort_order int, start_date date, end_date date,
               baseline_start date, baseline_end date, progress int, is_milestone boolean, is_critical boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT 'phase'::text, p.id, NULL::uuid, p.name::text, p.sort_order::int, NULL::date, NULL::date, NULL::date, NULL::date,
         NULL::int, false, false
    FROM job_phases p WHERE p.job_id = p_job_id AND p.client_visible
  UNION ALL
  SELECT (CASE WHEN t.is_milestone THEN 'milestone' ELSE 'task' END)::text, t.id,
         t.phase_id, t.task_name::text, t.sort_order::int,       -- phase_id is NULL or a visible phase by the predicate
         t.start_date::date, t.end_date::date, t.baseline_start::date, t.baseline_end::date, t.progress::int,
         t.is_milestone, t.is_critical
    FROM job_tasks t
   WHERE t.job_id = p_job_id AND job_task_client_visible(t.id);
END $$;

-- Actual history (stored snapshots).
CREATE OR REPLACE FUNCTION public.portal_progress_curve(p_job_id uuid)
RETURNS TABLE (snapshot_date date, planned_pct numeric, actual_pct numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY SELECT ps.snapshot_date::date, ps.planned_pct::numeric, ps.actual_pct::numeric
    FROM job_progress_snapshots ps WHERE ps.job_id = p_job_id AND ps.client_visible ORDER BY ps.snapshot_date;
END $$;

-- Full planned S-curve (X3), wrapping C's job_planned_curve with p_client_only = true over the visible tasks'
-- baseline range, weekly points plus the end date. Returns nothing until staff publish at least one snapshot.
CREATE OR REPLACE FUNCTION public.portal_planned_curve(p_job_id uuid)
RETURNS TABLE (curve_date date, planned_pct numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_from date; v_to date;
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  IF NOT EXISTS (SELECT 1 FROM job_progress_snapshots ps WHERE ps.job_id = p_job_id AND ps.client_visible) THEN RETURN; END IF;
  SELECT min(coalesce(t.baseline_start, t.start_date)), max(coalesce(t.baseline_end, t.end_date)) INTO v_from, v_to
    FROM job_tasks t WHERE t.job_id = p_job_id AND job_task_client_visible(t.id) AND NOT t.is_milestone;   -- X22 predicate
  IF v_from IS NULL OR v_to IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT c.d::date, c.planned_pct::numeric
    FROM job_planned_curve(p_job_id, v_from, v_to, true) c
   WHERE (c.d - v_from) % 7 = 0 OR c.d = least(v_to, v_from + 800)
   ORDER BY c.d;
END $$;

-- Site & workshop feed. Photo ids only (images via portal-file-url). Author: first name + label (X10).
-- Ordering and paging use coalesce(published_at, created_at), so a row published by a direct PATCH that left
-- published_at NULL still sorts and pages correctly (C also stamps published_at by trigger; this is belt and braces).
CREATE OR REPLACE FUNCTION public.portal_updates(p_job_id uuid, p_before timestamptz DEFAULT NULL, p_limit int DEFAULT 20)
RETURNS TABLE (id uuid, kind text, title text, body text, occurred_on date, published_at timestamptz,
               author_first_name text, author_label text, photo_ids uuid[], photo_captions text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT u.id, u.kind::text, u.title::text, u.body::text, u.occurred_on::date, u.published_at::timestamptz,
         coalesce(nullif(split_part(coalesce(eu.full_name, ''), ' ', 1), ''), 'Q2')::text, 'Q2 project team'::text,
         coalesce(array_agg(ph.id ORDER BY ph.sort_order) FILTER (WHERE ph.id IS NOT NULL), '{}'),
         coalesce(array_agg(ph.caption::text ORDER BY ph.sort_order) FILTER (WHERE ph.id IS NOT NULL), '{}')
  FROM job_updates u
  LEFT JOIN erp_users eu ON eu.id = u.published_by
  LEFT JOIN job_update_photos ph ON ph.update_id = u.id AND ph.client_visible
  WHERE u.job_id = p_job_id AND u.client_visible
    AND (p_before IS NULL OR coalesce(u.published_at, u.created_at) < p_before)
  GROUP BY u.id, eu.full_name
  ORDER BY coalesce(u.published_at, u.created_at) DESC, u.id
  LIMIT least(greatest(coalesce(p_limit, 20), 1), 50);
END $$;

-- Quality tab: three lists, discriminated by list_type. ITP rows are read-only for clients (X8: can_respond is
-- always false; staff record results). Never internal_notes, root_cause, waiver_ref or staff ids.
-- Columns follow B's final client whitelist (B "What Phase B guarantees for Phase D"): hold points hp_no, title, state,
-- witness_date, response, response_note; NCRs ncr_no, title, severity, status, corrective_action, action_due.
-- severity applies to NCR rows, response to hold-point rows, action_due to NCR rows; NULL elsewhere.
-- Re-read B's whitelist when B changes: if B drops any of these columns, drop it here too.
CREATE OR REPLACE FUNCTION public.portal_quality(p_job_id uuid)
RETURNS TABLE (list_type text, id uuid, ref text, title text, status text, detail text,
               event_date timestamptz, responder_name text, can_respond boolean,
               severity text, response text, action_due date)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  g := portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT 'itp'::text, i.id, i.item_no::text, i.description::text, i.status::text, i.result_notes::text,
         i.signed_off_at::timestamptz, NULL::text, false, NULL::text, NULL::text, NULL::date
    FROM job_itp_items i WHERE i.job_id = p_job_id AND i.client_visible
  UNION ALL
  SELECT 'hold_point'::text, h.id, h.hp_no::text, h.title::text, h.state::text, h.response_note::text,
         h.witness_date::timestamptz, h.responded_client_name::text,
         (g.client_role = 'approver' AND h.state = 'notified' AND h.witness_party = 'client'),
         NULL::text, h.response::text, NULL::date
    FROM job_hold_points h WHERE h.job_id = p_job_id AND h.client_visible
  UNION ALL
  SELECT 'ncr'::text, n.id, n.ncr_no::text, n.title::text, n.status::text, n.corrective_action::text,
         n.raised_at::timestamptz, NULL::text, false, n.severity::text, NULL::text, n.action_due::date
    FROM job_ncrs n WHERE n.job_id = p_job_id AND n.client_visible;
END $$;

-- Documents register (X9): issued, for_approval, approved, rejected, and superseded (history, labelled). Never draft.
CREATE OR REPLACE FUNCTION public.portal_documents(p_job_id uuid)
RETURNS TABLE (id uuid, doc_type text, drawing_no text, drawing_title text, revision_no text, issued_at timestamptz,
               status text, requires_client_approval boolean, approved_by_client_name text, approved_at timestamptz,
               approval_note text, has_file boolean, can_decide boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  g := portal_require_grant(p_job_id, 'viewer');
  RETURN QUERY
  SELECT d.id, d.doc_type::text, d.drawing_no::text, d.drawing_title::text, d.revision_no::text, d.issued_at::timestamptz,
         d.status::text, d.requires_client_approval, d.approved_by_client_name::text, d.approved_at::timestamptz,
         d.approval_note::text, d.storage_key IS NOT NULL,
         (g.client_role = 'approver' AND d.status = 'for_approval' AND d.requires_client_approval)
  FROM job_drawings d
  WHERE d.job_id = p_job_id AND d.client_visible AND NOT d.archived
    AND d.status IN ('issued','for_approval','approved','rejected','superseded')
  ORDER BY d.drawing_no, d.revision_no::text DESC;
END $$;
```

### D4 — Client write RPCs

Every write follows the same pattern:
1. Validate the input shape.
2. Fetch and lock the target **joined to the caller's granted jobs** (I1), so an unauthorized row is never locked, and an unknown or unauthorized row gives the same `not_found`.
3. Check the role.
4. Return an idempotent replay unchanged.
5. Rate limit.
6. Mutate.
7. Audit (`job_audit_log`, `portal.*`).
8. Notify staff in-app (`portal.*` types, X14).
9. Return a minimal result.

Decision RPCs set `app.portal_rpc` transaction-locally. B's guard triggers are SECURITY INVOKER and honour it only when `current_user <> 'authenticated'` (X6). B's `quality_audit` skips when the flag is set, so the `portal.*` row is the single audit row per decision (#26).

```sql
-- portal_core
CREATE OR REPLACE FUNCTION public.portal_send_message(p_job_id uuid, p_body text, p_client_msg_id uuid)
RETURNS TABLE (id uuid, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients; v_body text := portal_clean_text(p_body, 4000); v_id uuid; v_at timestamptz;
BEGIN
  IF p_client_msg_id IS NULL OR v_body IS NULL OR char_length(coalesce(p_body, '')) > 8000 THEN
    RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023';
  END IF;
  g := portal_require_grant(p_job_id, 'viewer');
  SELECT m.id, m.created_at INTO v_id, v_at FROM project_messages m
   WHERE m.sender_auth_user_id = auth.uid() AND m.client_msg_id = p_client_msg_id;
  IF FOUND THEN RETURN QUERY SELECT v_id, v_at; RETURN; END IF;            -- idempotent replay
  PERFORM portal_rate_check('portal.message', 20, interval '10 minutes');
  PERFORM portal_rate_check('portal.message', 200, interval '1 day');
  INSERT INTO project_messages (company_id, job_id, sender_kind, sender_auth_user_id, sender_project_client_id,
                                sender_display_name, body, client_msg_id)
  VALUES (g.company_id, p_job_id, 'client', auth.uid(), g.id, g.display_name, v_body, p_client_msg_id)
  RETURNING project_messages.id, project_messages.created_at INTO v_id, v_at;
  PERFORM portal_notify_staff(p_job_id, 'portal.message.from_client', 'Client message', g.display_name);
  PERFORM portal_audit(p_job_id, g.display_name, 'portal.message.sent', 'Client message', jsonb_build_object('message_id', v_id));
  RETURN QUERY SELECT v_id, v_at;
END $$;

CREATE OR REPLACE FUNCTION public.portal_mark_read(p_job_id uuid, p_message_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients; v_at timestamptz;
BEGIN
  g := portal_require_grant(p_job_id, 'viewer');
  SELECT m.created_at INTO v_at FROM project_messages m WHERE m.id = p_message_id AND m.job_id = p_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'portal:not_found' USING ERRCODE = 'P0002'; END IF;
  INSERT INTO project_message_reads (company_id, job_id, reader_auth_user_id, reader_kind, last_read_at, last_read_message_id)
  VALUES (g.company_id, p_job_id, auth.uid(), 'client', v_at, p_message_id)
  ON CONFLICT (job_id, reader_auth_user_id) DO UPDATE
    SET last_read_at = greatest(project_message_reads.last_read_at, EXCLUDED.last_read_at),   -- monotonic, idempotent
        last_read_message_id = CASE WHEN EXCLUDED.last_read_at > project_message_reads.last_read_at
                                    THEN EXCLUDED.last_read_message_id ELSE project_message_reads.last_read_message_id END;
END $$;

CREATE OR REPLACE FUNCTION public.portal_set_notify_mode(p_job_id uuid, p_mode text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  IF p_mode NOT IN ('immediate','daily','off') THEN RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023'; END IF;
  g := portal_require_grant(p_job_id, 'viewer');
  UPDATE project_clients SET notify_mode = p_mode WHERE project_clients.id = g.id;
  PERFORM portal_audit(p_job_id, g.display_name, 'portal.prefs', 'Notification mode ' || p_mode, NULL);
END $$;

-- portal_reads. Hold point: notified -> witnessed (accepted) | waived (waived) | planned (rejected), per Phase B.
CREATE OR REPLACE FUNCTION public.portal_respond_hold_point(p_hold_point_id uuid, p_decision text, p_note text)
RETURNS TABLE (id uuid, state text, response text, responded_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE h job_hold_points; g project_clients; v_note text := portal_clean_text(p_note, 2000);
BEGIN
  IF p_decision NOT IN ('accepted','rejected','waived') OR (p_decision = 'rejected' AND v_note IS NULL) THEN
    RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023';
  END IF;
  SELECT hp.* INTO h FROM job_hold_points hp
   WHERE hp.id = p_hold_point_id AND hp.client_visible AND hp.witness_party = 'client'
     AND hp.job_id IN (SELECT portal_my_job_ids())
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'portal:not_found' USING ERRCODE = 'P0002'; END IF;
  g := portal_require_grant(h.job_id, 'approver');
  IF portal_cfg_require_mfa_for_approvals() AND coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' THEN
    RAISE EXCEPTION 'portal:mfa_required' USING ERRCODE = '42501';
  END IF;
  IF h.responded_client_user = auth.uid() AND h.response = p_decision AND h.state <> 'notified' THEN
    RETURN QUERY SELECT h.id, h.state::text, h.response::text, h.responded_at; RETURN;   -- idempotent replay
  END IF;
  IF h.state <> 'notified' THEN RAISE EXCEPTION 'portal:conflict' USING ERRCODE = '40001'; END IF;
  PERFORM portal_rate_check('portal.decision', 30, interval '1 hour');
  PERFORM set_config('app.portal_rpc', '1', true);
  UPDATE job_hold_points SET
    state = CASE p_decision WHEN 'accepted' THEN 'witnessed' WHEN 'waived' THEN 'waived' ELSE 'planned' END,
    response = p_decision, response_note = v_note, responded_at = now(),
    responded_client_user = auth.uid(), responded_client_name = g.display_name
  WHERE job_hold_points.id = h.id
  RETURNING * INTO h;
  PERFORM set_config('app.portal_rpc', '', true);
  PERFORM portal_audit(h.job_id, g.display_name, 'portal.decision.hold_point',
                       'Hold point ' || h.hp_no || ' ' || p_decision, jsonb_build_object('hold_point_id', h.id));
  PERFORM portal_notify_staff(h.job_id, 'portal.decision.from_client', 'Hold point ' || h.hp_no || ' ' || p_decision, g.display_name);
  RETURN QUERY SELECT h.id, h.state::text, h.response::text, h.responded_at;
END $$;

-- Drawing decision. p_expected_revision pins the revision the client was shown.
CREATE OR REPLACE FUNCTION public.portal_decide_drawing(p_drawing_id uuid, p_expected_revision text, p_decision text, p_note text)
RETURNS TABLE (id uuid, status text, approved_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE d job_drawings; g project_clients; v_note text := portal_clean_text(p_note, 2000);
BEGIN
  IF p_decision NOT IN ('approved','rejected') OR (p_decision = 'rejected' AND v_note IS NULL) THEN
    RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023';
  END IF;
  SELECT dr.* INTO d FROM job_drawings dr
   WHERE dr.id = p_drawing_id AND dr.client_visible AND NOT dr.archived
     AND dr.job_id IN (SELECT portal_my_job_ids())
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'portal:not_found' USING ERRCODE = 'P0002'; END IF;
  g := portal_require_grant(d.job_id, 'approver');
  IF portal_cfg_require_mfa_for_approvals() AND coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' THEN
    RAISE EXCEPTION 'portal:mfa_required' USING ERRCODE = '42501';
  END IF;
  IF d.approved_by_client_user = auth.uid() AND d.status = p_decision THEN
    RETURN QUERY SELECT d.id, d.status::text, d.approved_at; RETURN;          -- idempotent replay
  END IF;
  IF d.status <> 'for_approval' OR NOT d.requires_client_approval
     OR d.revision_no::text IS DISTINCT FROM p_expected_revision THEN
    RAISE EXCEPTION 'portal:conflict' USING ERRCODE = '40001';
  END IF;
  PERFORM portal_rate_check('portal.decision', 30, interval '1 hour');
  PERFORM set_config('app.portal_rpc', '1', true);
  UPDATE job_drawings SET status = p_decision, approved_at = now(), approved_by_client_user = auth.uid(),
         approved_by_client_name = g.display_name, approval_note = v_note
   WHERE job_drawings.id = d.id RETURNING * INTO d;
  PERFORM set_config('app.portal_rpc', '', true);
  PERFORM portal_audit(d.job_id, g.display_name, 'portal.decision.drawing',
                       d.drawing_no || ' rev ' || coalesce(d.revision_no::text, '-') || ' ' || p_decision,
                       jsonb_build_object('drawing_id', d.id, 'revision_no', d.revision_no::text));
  PERFORM portal_notify_staff(d.job_id, 'portal.decision.from_client',
                              d.drawing_no || ' rev ' || coalesce(d.revision_no::text, '-') || ' ' || p_decision, g.display_name);
  RETURN QUERY SELECT d.id, d.status::text, d.approved_at;
END $$;
```

### D5 — Staff and service-role RPCs

All staff RPCs authorize with `portal_staff_can(<company derived from the row>, <atom>)` and return a uniform `forbidden` for unknown and unauthorized ids. All except `portal_authorize_file` and `portal_erase_client` ship in `portal_core`.

```sql
-- Thin authorization RPC for portal-invite (M5): company is derived from the job server-side, never from the request.
-- Also enforces the 20-invites-per-hour staff limit.
CREATE OR REPLACE FUNCTION public.portal_staff_can_invite(p_job_id uuid)
RETURNS TABLE (company_id uuid, job_no text, inviter_erp_user_id uuid, inviter_first_name text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE j jobs; me erp_users;
BEGIN
  SELECT * INTO j FROM jobs WHERE jobs.id = p_job_id;
  IF NOT FOUND OR NOT portal_staff_can(j.company_id, 'portal:invite') THEN
    RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501';
  END IF;
  PERFORM portal_rate_check('portal.access.invited', 20, interval '1 hour');
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  RETURN QUERY SELECT j.company_id, j.job_no::text, me.id, split_part(coalesce(me.full_name, ''), ' ', 1)::text;
END $$;

CREATE OR REPLACE FUNCTION public.portal_staff_extend(p_grant_id uuid, p_expires_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients; me erp_users;
BEGIN
  SELECT * INTO g FROM project_clients WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND OR NOT portal_staff_can(g.company_id, 'portal:invite') THEN RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501'; END IF;
  IF g.revoked_at IS NOT NULL OR p_expires_at <= now() OR p_expires_at > now() + interval '365 days' THEN
    RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  UPDATE project_clients SET expires_at = p_expires_at WHERE id = g.id;
  PERFORM portal_audit(g.job_id, me.full_name, 'portal.access.extended', 'Extended ' || g.email || ' to ' || p_expires_at::date,
                       jsonb_build_object('grant_id', g.id));
END $$;

CREATE OR REPLACE FUNCTION public.portal_staff_send_message(p_job_id uuid, p_body text, p_client_msg_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE j jobs; me erp_users; v_body text := portal_clean_text(p_body, 4000); v_id uuid;
BEGIN
  SELECT * INTO j FROM jobs WHERE jobs.id = p_job_id;
  IF NOT FOUND OR NOT portal_staff_can(j.company_id, 'portal:messages:reply') THEN
    RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501';
  END IF;
  IF v_body IS NULL OR p_client_msg_id IS NULL THEN RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023'; END IF;
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  INSERT INTO project_messages (company_id, job_id, sender_kind, sender_auth_user_id, sender_erp_user_id,
                                sender_display_name, body, client_msg_id)
  VALUES (j.company_id, j.id, 'staff', auth.uid(), me.id,
          left(coalesce(nullif(split_part(coalesce(me.full_name, ''), ' ', 1), ''), 'Q2'), 80), v_body, p_client_msg_id)
  ON CONFLICT (sender_auth_user_id, client_msg_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT m.id INTO v_id FROM project_messages m WHERE m.sender_auth_user_id = auth.uid() AND m.client_msg_id = p_client_msg_id;
  ELSE
    PERFORM portal_audit(j.id, me.full_name, 'portal.message.staff_sent', 'Staff message', jsonb_build_object('message_id', v_id));
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.portal_staff_mark_read(p_job_id uuid, p_message_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE m project_messages;
BEGIN
  SELECT * INTO m FROM project_messages WHERE id = p_message_id AND job_id = p_job_id;
  IF NOT FOUND OR NOT portal_staff_can(m.company_id, 'portal:read') THEN RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501'; END IF;
  INSERT INTO project_message_reads (company_id, job_id, reader_auth_user_id, reader_kind, last_read_at, last_read_message_id)
  VALUES (m.company_id, m.job_id, auth.uid(), 'staff', m.created_at, m.id)
  ON CONFLICT (job_id, reader_auth_user_id) DO UPDATE
    SET last_read_at = greatest(project_message_reads.last_read_at, EXCLUDED.last_read_at);
END $$;

CREATE OR REPLACE FUNCTION public.portal_staff_hide_message(p_message_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE m project_messages; me erp_users;
BEGIN
  SELECT * INTO m FROM project_messages WHERE id = p_message_id FOR UPDATE;
  IF NOT FOUND OR NOT portal_staff_can(m.company_id, 'portal:messages:reply') THEN RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501'; END IF;
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  UPDATE project_messages SET hidden_at = now(), hidden_reason = portal_clean_text(p_reason, 300), hidden_by = me.id
   WHERE id = m.id AND hidden_at IS NULL;
  PERFORM portal_audit(m.job_id, me.full_name, 'portal.message.hidden', 'Message hidden', jsonb_build_object('message_id', m.id));
END $$;

CREATE OR REPLACE FUNCTION public.portal_staff_revoke(p_grant_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients; me erp_users;
BEGIN
  SELECT * INTO g FROM project_clients WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND OR NOT portal_staff_can(g.company_id, 'portal:invite') THEN RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501'; END IF;
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  UPDATE project_clients SET status = 'revoked', revoked_at = now(), revoke_reason = portal_clean_text(p_reason, 500), revoked_by = me.id
   WHERE id = g.id AND revoked_at IS NULL;
  PERFORM portal_audit(g.job_id, me.full_name, 'portal.access.revoked', 'Revoked ' || g.email, jsonb_build_object('grant_id', g.id));
END $$;

-- Company kill switch (company admin). Global kill switch = the L3 REVOKE script (rollout).
CREATE OR REPLACE FUNCTION public.portal_staff_revoke_all(p_company_id uuid, p_reason text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE n int; me erp_users;
BEGIN
  IF NOT (is_erp_staff() AND (is_company_admin(p_company_id) OR is_super_admin())) THEN
    RAISE EXCEPTION 'portal:forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO me FROM erp_users WHERE auth_user_id = auth.uid();
  UPDATE project_clients SET status = 'revoked', revoked_at = now(), revoke_reason = left('KILL SWITCH: ' || coalesce(p_reason, ''), 500),
         revoked_by = me.id
   WHERE company_id = p_company_id AND revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO job_audit_log (job_id, user_id, username, action_type, description, metadata)
  VALUES (NULL, auth.uid(), left(me.full_name, 80), 'portal.kill_switch', 'Revoked ' || n || ' portal grants',
          jsonb_build_object('company_id', p_company_id, 'channel', 'portal'));
  RETURN n;
END $$;

-- portal_reads, service role only (portal-file-url). Storage objects the given client may view.
CREATE OR REPLACE FUNCTION public.portal_authorize_file(p_auth_user_id uuid, p_kind text, p_ids uuid[])
RETURNS TABLE (id uuid, bucket text, object_path text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE n int;
BEGIN
  IF p_kind NOT IN ('drawing','photo','thumb') OR coalesce(array_length(p_ids, 1), 0) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'portal:invalid_input' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('portal:file:' || p_auth_user_id::text));
  SELECT count(*) INTO n FROM job_audit_log
   WHERE user_id = p_auth_user_id AND action_type = 'portal.file.signed' AND created_at > now() - interval '10 minutes';
  IF n >= 60 THEN RAISE EXCEPTION 'portal:rate_limited' USING ERRCODE = 'P0001'; END IF;
  IF p_kind = 'drawing' THEN
    RETURN QUERY SELECT d.id, 'job-drawings'::text, d.storage_key::text FROM job_drawings d
      WHERE d.id = ANY(p_ids) AND d.client_visible AND NOT d.archived AND d.storage_key IS NOT NULL
        AND d.status IN ('issued','for_approval','approved','rejected','superseded')
        AND d.job_id IN (SELECT portal_job_ids_for(p_auth_user_id));
  ELSE
    RETURN QUERY SELECT ph.id, 'job-updates'::text, (CASE WHEN p_kind = 'thumb' THEN ph.thumb_key ELSE ph.storage_key END)::text
      FROM job_update_photos ph JOIN job_updates u ON u.id = ph.update_id
      WHERE ph.id = ANY(p_ids) AND ph.client_visible AND u.client_visible
        AND ph.job_id IN (SELECT portal_job_ids_for(p_auth_user_id));
  END IF;
  INSERT INTO job_audit_log (job_id, user_id, username, action_type, description, metadata)
  VALUES (NULL, p_auth_user_id, 'portal', 'portal.file.signed', p_kind, jsonb_build_object('ids', to_jsonb(p_ids), 'channel', 'portal'));
END $$;

-- portal_core, service role only. Erasure on request (M3): pseudonymise, revoke; the caller then deletes the auth user
-- (FKs set to NULL; message rows and decision audit rows are kept, pseudonymised).
CREATE OR REPLACE FUNCTION public.portal_erase_client(p_grant_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g project_clients;
BEGIN
  SELECT * INTO g FROM project_clients WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'portal:not_found' USING ERRCODE = 'P0002'; END IF;
  PERFORM set_config('app.portal_erase', '1', true);
  UPDATE project_clients SET display_name = 'Former client representative', email = 'erased+' || id || '@invalid',
         status = 'revoked', revoked_at = coalesce(revoked_at, now()), revoke_reason = coalesce(revoke_reason, 'erasure')
   WHERE id = g.id;
  UPDATE project_messages SET sender_display_name = 'Former client representative' WHERE sender_project_client_id = g.id;
  UPDATE job_audit_log SET username = 'Former client representative'
   WHERE user_id = g.auth_user_id AND action_type LIKE 'portal.%';
  PERFORM set_config('app.portal_erase', '', true);
END $$;
```

### D6 — Notification types and permission atoms

`notification_types.recipient` is constrained to `direct | role:admin | owner`. Portal rows use `direct` and are delivered only by the new `portal-notify` function, never by `send-notification`.
- Templates carry no message bodies, no internal text and no amounts.
- `portal-notify` HTML-escapes every interpolated value.
- Keys are dotted (X14) and the same keys are used as `erp_notifications.type` for in-app staff rows.
- The invite link is valid for **1 hour**, matching the Email OTP expiry of 3600 s (L3).

```sql
INSERT INTO notification_types (event_key, label, subject_tpl, body_html, recipient) VALUES
('portal.invite',               'Portal invitation (client)',         'You have been invited to follow {{job_no}}', '<p>Hi {{recipient_name}},</p><p>{{company_name}} has invited you to follow project <strong>{{job_no}} · {{project_title}}</strong>.</p><p><a href="{{accept_url}}">Accept invitation</a> (link valid for 1 hour, single use; ask your Q2 contact to resend if it expires).</p>', 'direct'),
('portal.access.granted',       'Portal access granted (client)',     'New project available: {{job_no}}',          '<p>Hi {{recipient_name}},</p><p>You now have access to <strong>{{job_no}} · {{project_title}}</strong>.</p><p><a href="{{portal_url}}">Open the project portal</a></p>', 'direct'),
('portal.message.to_client',    'New message from Q2 (client)',       'New message on {{job_no}}',                  '<p>Hi {{recipient_name}},</p><p>You have {{count}} new message(s) on <strong>{{job_no}}</strong>.</p><p><a href="{{portal_url}}">Read in the portal</a></p><p style="font-size:12px;color:#888"><a href="{{unsubscribe_url}}">Change email notifications</a></p>', 'direct'),
('portal.action.required',      'Client action required (client)',    'Action needed on {{job_no}}',                '<p>Hi {{recipient_name}},</p><p>{{count}} item(s) on <strong>{{job_no}}</strong> await your response (hold points or drawing approvals).</p><p><a href="{{portal_url}}">Review in the portal</a></p><p style="font-size:12px;color:#888"><a href="{{unsubscribe_url}}">Change email notifications</a></p>', 'direct'),
('portal.digest.daily',         'Daily project digest (client)',      'Daily update: {{job_no}}',                   '<p>Hi {{recipient_name}},</p><p>Since yesterday on <strong>{{job_no}}</strong>: {{summary_line}}.</p><p><a href="{{portal_url}}">Open the project portal</a></p><p style="font-size:12px;color:#888"><a href="{{unsubscribe_url}}">Change email notifications</a></p>', 'direct'),
('portal.message.from_client',  'Client message received (staff)',   'Client message on {{job_no}}',               '<p>Hi {{recipient_name}},</p><p><strong>{{sender_name}}</strong> sent a message on {{job_no}}.</p><p>Log in to Meridian ERP to reply.</p>', 'direct'),
('portal.decision.from_client', 'Client decision recorded (staff)',   'Client {{decision}}: {{item_ref}} on {{job_no}}', '<p>Hi {{recipient_name}},</p><p><strong>{{sender_name}}</strong> recorded <strong>{{decision}}</strong> on {{item_ref}} ({{job_no}}).</p><p>Log in to Meridian ERP to review.</p>', 'direct')
ON CONFLICT (event_key) DO NOTHING;

-- Atoms (X11): erp_roles.permissions is a JSON object {atom: true} (live, all 7 roles); user_has_perm has no
-- super_admin wildcard. Role names are the exact live values (live-facts 13): super_admin, company_admin,
-- finance_manager, sales_rep, operations_tech, viewer, and 'Office Admin' (capital O and A, a space).
UPDATE erp_roles SET permissions = permissions || jsonb_build_object('portal:read', true, 'portal:invite', true, 'portal:messages:reply', true)
 WHERE name IN ('super_admin','company_admin','Office Admin');
UPDATE erp_roles SET permissions = permissions || jsonb_build_object('portal:read', true, 'portal:messages:reply', true)
 WHERE name = 'operations_tech';
UPDATE erp_roles SET permissions = permissions || jsonb_build_object('portal:read', true)
 WHERE name IN ('sales_rep','viewer');

-- Post-seed assertion 1 (in the migration): fail loudly if any role literal matched no row, so a wrong name can never
-- silently skip a role (an UPDATE that matches 0 rows is not an error).
DO $$
BEGIN
  IF (SELECT count(*) FROM erp_roles WHERE name IN ('super_admin','company_admin','Office Admin') AND permissions ? 'portal:invite') <> 3
     OR (SELECT count(*) FROM erp_roles WHERE name = 'operations_tech' AND permissions ? 'portal:messages:reply') <> 1
     OR (SELECT count(*) FROM erp_roles WHERE name IN ('sales_rep','viewer') AND permissions ? 'portal:read') <> 2 THEN
    RAISE EXCEPTION 'D6: portal atoms did not reach every intended role; check erp_roles.name literals';
  END IF;
END $$;

-- Post-seed assertion 2 (run and paste in the PR): the roles holding each portal atom. Expected sets (order irrelevant):
--   portal:read           = Office Admin, company_admin, operations_tech, sales_rep, super_admin, viewer   (6; not finance_manager)
--   portal:invite         = Office Admin, company_admin, super_admin                                       (3)
--   portal:messages:reply = Office Admin, company_admin, operations_tech, super_admin                      (4)
SELECT a.atom, array_agg(r.name ORDER BY r.name) AS roles
FROM erp_roles r CROSS JOIN LATERAL jsonb_object_keys(r.permissions) AS a(atom)
WHERE a.atom LIKE 'portal:%' GROUP BY a.atom ORDER BY a.atom;
-- -- down: UPDATE erp_roles SET permissions = permissions - 'portal:read' - 'portal:invite' - 'portal:messages:reply';
```

### D7 — Grants (split by migration, consistency #14)

```sql
-- ── in YYYYMMDDHHMM_d_portal_core.sql (functions defined in that file only) ──
REVOKE ALL ON FUNCTION
  public.portal_me(), public.portal_messages(uuid, timestamptz, int), public.portal_team(uuid),
  public.portal_send_message(uuid, text, uuid), public.portal_mark_read(uuid, uuid), public.portal_set_notify_mode(uuid, text),
  public.portal_staff_can_invite(uuid), public.portal_staff_extend(uuid, timestamptz),
  public.portal_staff_send_message(uuid, text, uuid), public.portal_staff_mark_read(uuid, uuid),
  public.portal_staff_hide_message(uuid, text), public.portal_staff_revoke(uuid, text),
  public.portal_staff_revoke_all(uuid, text), public.portal_erase_client(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.portal_me(), public.portal_messages(uuid, timestamptz, int), public.portal_team(uuid),
  public.portal_send_message(uuid, text, uuid), public.portal_mark_read(uuid, uuid), public.portal_set_notify_mode(uuid, text),
  public.portal_staff_can_invite(uuid), public.portal_staff_extend(uuid, timestamptz),
  public.portal_staff_send_message(uuid, text, uuid), public.portal_staff_mark_read(uuid, uuid),
  public.portal_staff_hide_message(uuid, text), public.portal_staff_revoke(uuid, text),
  public.portal_staff_revoke_all(uuid, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.portal_erase_client(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.portal_erase_client(uuid) TO service_role;

-- ── in YYYYMMDDHHMM_d_portal_reads.sql (after A, B, C) ──
REVOKE ALL ON FUNCTION
  public.portal_project_header(uuid), public.portal_project_kpis(uuid), public.portal_schedule(uuid),
  public.portal_progress_curve(uuid), public.portal_planned_curve(uuid), public.portal_updates(uuid, timestamptz, int),
  public.portal_quality(uuid), public.portal_documents(uuid),
  public.portal_respond_hold_point(uuid, text, text), public.portal_decide_drawing(uuid, text, text, text),
  public.portal_authorize_file(uuid, text, uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.portal_project_header(uuid), public.portal_project_kpis(uuid), public.portal_schedule(uuid),
  public.portal_progress_curve(uuid), public.portal_planned_curve(uuid), public.portal_updates(uuid, timestamptz, int),
  public.portal_quality(uuid), public.portal_documents(uuid),
  public.portal_respond_hold_point(uuid, text, text), public.portal_decide_drawing(uuid, text, text, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.portal_authorize_file(uuid, text, uuid[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.portal_authorize_file(uuid, text, uuid[]) TO service_role;
```

### D8 — Down

```sql
-- -- down (Phase D; reverse order; D0 has its own down and is NOT rolled back with D)
-- portal_reads:
-- DROP FUNCTION IF EXISTS public.portal_authorize_file(uuid, text, uuid[]), public.portal_decide_drawing(uuid, text, text, text),
--   public.portal_respond_hold_point(uuid, text, text), public.portal_documents(uuid), public.portal_quality(uuid),
--   public.portal_updates(uuid, timestamptz, int), public.portal_planned_curve(uuid), public.portal_progress_curve(uuid),
--   public.portal_schedule(uuid), public.portal_project_kpis(uuid), public.portal_project_header(uuid);
-- portal_core:
-- UPDATE erp_roles SET permissions = permissions - 'portal:read' - 'portal:invite' - 'portal:messages:reply';
-- DELETE FROM notification_types WHERE event_key LIKE 'portal.%';
-- DROP FUNCTION IF EXISTS public.portal_erase_client(uuid), public.portal_staff_revoke_all(uuid, text),
--   public.portal_staff_revoke(uuid, text), public.portal_staff_hide_message(uuid, text), public.portal_staff_mark_read(uuid, uuid),
--   public.portal_staff_send_message(uuid, text, uuid), public.portal_staff_extend(uuid, timestamptz), public.portal_staff_can_invite(uuid),
--   public.portal_set_notify_mode(uuid, text), public.portal_mark_read(uuid, uuid), public.portal_send_message(uuid, text, uuid),
--   public.portal_team(uuid), public.portal_messages(uuid, timestamptz, int), public.portal_me(),
--   public.portal_auth_uid_for_email(text), public.portal_cfg_require_mfa_for_approvals(), public.portal_notify_staff(uuid, text, text, text),
--   public.portal_staff_can(uuid, text), public.portal_clean_text(text, int), public.portal_audit(uuid, text, text, text, jsonb),
--   public.portal_rate_check(text, int, interval), public.portal_require_grant(uuid, text), public.portal_my_job_ids(),
--   public.portal_job_ids_for(uuid);
-- DROP TABLE needs the retention hold lifted first: drop the retention triggers, then
-- DROP TABLE IF EXISTS project_message_reads; DROP TABLE IF EXISTS project_messages; DROP TABLE IF EXISTS project_clients;
-- DROP FUNCTION IF EXISTS public.portal_trg_retention_hold(), public.portal_trg_project_clients_guard();
-- Auth: ban or delete the client auth users created by portal-invite (list them from project_clients first).
-- job_audit_log rows with action_type LIKE 'portal.%' are kept as history.
```

## RLS and permissions

**Identity separation (live-verified where marked).**
- `my_company_ids()`, `user_has_perm(text)`, `is_company_admin(uuid)` and `is_super_admin()` all key on `erp_users.auth_user_id = auth.uid()`. A client has no `erp_users` row, so all four return empty or false and no staff policy matches a client (X6).
- `my_company_ids()`, `is_super_admin()` and `user_has_perm()` already require `erp_users.is_active` (live-verified; D0a only pins their `search_path`). A deactivated staff member therefore already loses REST access as well as the UI. `erp-user-access` additionally bans the auth user, which kills the session and refresh tokens too.
- Staff and client identities are kept mutually exclusive in four places:
  - the `project_clients` trigger rejects staff auth ids;
  - `portal_job_ids_for` returns nothing for any uid with an `erp_users` row;
  - `portal-invite` refuses staff emails;
  - `create-erp-user` gains the reverse check (an email with a live grant is refused).
- **No `erp_roles` "client" role is seeded**: a role needs an `erp_users` row, which is exactly what must not exist.

**Policies on D tables** (staff-only; a client matches none). Direct writes are minimal:
- **Inserts**: grants are created only by `portal-invite` (service role). Messages and read watermarks are written only by RPCs.
- **Updates**: staff may PATCH only a column whitelist (M2, #24). The trigger polices the status transitions within it, and the identity columns cannot be updated by any API role.
- **Deletes**: none; the retention hold applies.

```sql
ALTER TABLE project_clients       ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_message_reads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON project_clients, project_messages, project_message_reads FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON project_clients, project_messages, project_message_reads FROM authenticated;
GRANT UPDATE (display_name, project_title, client_role, contact_person_id, status) ON project_clients TO authenticated;

CREATE POLICY pc_select ON project_clients FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('portal:read'));
CREATE POLICY pc_insert ON project_clients FOR INSERT TO authenticated WITH CHECK (false);      -- portal-invite (service role) only
CREATE POLICY pc_update ON project_clients FOR UPDATE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('portal:invite') AND (SELECT is_erp_staff()))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('portal:invite') AND (SELECT is_erp_staff()));
CREATE POLICY pc_delete ON project_clients FOR DELETE TO authenticated USING (false);           -- retention

CREATE POLICY pm_select ON project_messages FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('portal:read'));
CREATE POLICY pm_insert ON project_messages FOR INSERT TO authenticated WITH CHECK (false);  -- RPC only
CREATE POLICY pm_update ON project_messages FOR UPDATE TO authenticated USING (false);       -- RPC only
CREATE POLICY pm_delete ON project_messages FOR DELETE TO authenticated USING (false);       -- never

CREATE POLICY pmr_select ON project_message_reads FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('portal:read'));
CREATE POLICY pmr_insert ON project_message_reads FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY pmr_update ON project_message_reads FOR UPDATE TO authenticated USING (false);
CREATE POLICY pmr_delete ON project_message_reads FOR DELETE TO authenticated USING (false);
```

**Why functions, not views.**
- A `security_invoker` view runs as the client. It would need client SELECT grants and client-aware RLS on every A–C base table, which spreads client logic through staff policies.
- A definer view bypasses RLS and is exposed by PostgREST as a filterable table that is easy to over-select.
- `SECURITY DEFINER` functions with `RETURNS TABLE(...)` give a typed whitelist, a per-call grant check, a job id parameter and error control.
- Every portal function pins `search_path = public, pg_temp`, is owned by `postgres` (BYPASSRLS, live), and has EXECUTE revoked from `PUBLIC` and `anon`. Internal and service-only functions are revoked from `authenticated` as well. Q-D is re-run after each migration (X13). Ownership matters: B's guards (X6) trust `app.portal_rpc` only when `current_user <> 'authenticated'`, which holds inside a definer only because the owner is `postgres`. This is asserted, not assumed, by the owner check in acceptance criterion 13 (migrations are applied as `postgres`; if the migration role differs, add `ALTER FUNCTION ... OWNER TO postgres` per function).

**Exclusion list: never in any client-callable `portal_*` function** (enforced by `scripts/check-portal-sql.mjs`):
- `jobs` commercial and internal fields: the quoted amount, misc amount and costing notes columns; `customer`, `contact`, `email`, `priority`, `created_by`, `overdue_notified_at`, and the `qc_state`, `drawings`, `specs` and `reports` jsonb columns.
- Any column ending in `_ttd`, or containing `rate`, `cost` or `price`; the payment-terms and customer-PO columns.
- All `*_entries`, `config_*`, `invoices`, `quotations`, `purchase_orders`, `bills`, `employees` and `labour_*` tables.
- `job_tasks.assignee`; `internal_notes`, `root_cause`, `waiver_ref` wherever they occur.
- Staff email, phone or full surname. Staff appear as first name plus role label (X10).
- `storage_key` values (only the `IS NOT NULL` test; values only in service-only `portal_authorize_file`).
- Other jobs or customers: every query filters on the granted `job_id`.

**Permission atoms (seeded in D6; add a "Client Portal" row to `PERMISSION_MATRIX`).** `portal:publish` is **dropped** (X5). Publishing A–C rows is governed by A's shared `job_visibility_guard()`, and `project_title` is edited under `portal:invite`.

| Atom | Grants | super_admin | company_admin | Office Admin | operations_tech | sales_rep | finance_manager | viewer |
|---|---|---|---|---|---|---|---|---|
| `portal:read` | Client portal card, grants, thread, read receipts | yes | yes | yes | yes | yes | no | yes |
| `portal:invite` | Invite, resend, extend, suspend, revoke; edit name/title/role | yes | yes | yes | no | no | no | no |
| `portal:messages:reply` | Post and hide messages | yes | yes | yes | yes | no | no | no |

The kill switch (`portal_staff_revoke_all`) needs `is_company_admin()` and has no separate atom.

## Staff UI (ERP)

All of this goes in `index.html`, and every string is rendered through `escHTML`.

- **Work order → "Client portal" card** (`portal:read`). A table of grants shows name, email, role, status chip (Invited/Active/Suspended/Revoked/Expired), last seen, expires and email mode. Actions (`portal:invite`):
  - **Invite** modal: contact (picker over the current company's `contacts`), person (`contact_persons`; prefills name and email), role, expiry (default job `due_date` + 90 days, at most today + 365), project title (prefilled from the first line of `jobs.description`; staff confirm because the client sees it). Submits to `portal-invite`.
  - **Resend** (`portal-invite {grant_id}`, invited grants only), **Extend** (`portal_staff_extend`), **Suspend/Resume** (PATCH `status`), **Edit** name/title/role (PATCH), **Revoke** with a reason (`portal_staff_revoke`).
  - A "Visible to client" summary: counts of `client_visible` rows per A–C table, linking to the A–C cards.
- **Work order → "Client messages" card** (`portal:read`).
  - Shows the thread with a "Seen by {name}" receipt computed from each client's watermark.
  - The composer (`portal:messages:reply`) calls `portal_staff_send_message`; "Hide" calls `portal_staff_hide_message`.
  - The topbar notification panel handles `type LIKE 'portal.%'` (navigate to the job). `markNotifRead` currently assumes `crm-tasks` and must branch on type.
- **Job delete.** When the delete fails with `portal:retention_hold`, show "This work order has client portal history and cannot be deleted. Set it to Closed instead." D0c already makes the audit insert awaited before the delete.
- **Settings → Client portal** (`portal:invite`): every grant in the current company with filters, the portal audit feed (`job_audit_log` where `action_type LIKE 'portal.%'`), and the company **kill switch** (company admin, typed confirmation).
- **Settings → Users**: Deactivate, Activate and Remove call the new `erp-user-access` edge function (D0b) instead of direct PATCH or DELETE.
- **Edge function `portal-invite`** (pseudo-code; verify-JWT on; CORS allowlist = ERP origin):
  1. Verify the caller via `GET /auth/v1/user`.
  2. With the caller's JWT, call `rpc/portal_staff_can_invite {p_job_id}`. It returns `company_id` derived from `jobs` server-side (the request never supplies a company), the caller's `erp_users.id` and first name. It raises `forbidden` or `rate_limited` otherwise.
  3. Normalise the email. With the service role, call `portal_auth_uid_for_email`. If `is_staff`, refuse with "staff accounts cannot be clients".
  4. **Existing auth user**: insert the grant (service role) with `auth_user_id` = that uid and `invited_by` = the caller's erp id, then send `portal.access.granted`.
  5. **New user**: `auth.admin.generateLink({type:'invite', email})` → `data.user.id` and `data.properties.hashed_token`. Insert the grant with `auth_user_id = data.user.id` **at insert** (#21). The trigger checks that the auth email matches the row email and that the uid is not staff. If the insert fails, delete the just-created auth user. Then email `https://projects.q2m.io/#/accept?th=<hashed_token>&t=invite` (`portal.invite`).
  6. **Resend** (`{grant_id}`): authorise via step 2 on the grant's job. Allowed only for `status = 'invited'` and `invite_count < 10`. Increment `invite_count` with the service role and issue a fresh link.
  7. Write a `portal.access.invited` / `portal.access.resent` audit row with `user_id` = the caller's uid and username = the caller's name.
- **Existing functions.**
  - `send-notification` must reject `event_key LIKE 'portal.%'` on its non-cron path and HTML-escape context values (it interpolates them raw today).
  - `create-erp-user` gains the reverse identity check. **Pull the deployed source (`get_edge_function`) into the repo before editing** (L9). The repo copy reads the dropped `erp_users.role`, so it differs from what is deployed.

## Client-facing surface

**App.** A new repo, `brandonr2630/meridian-project`, cloned to `Projects/meridian-project/`. It must not be a sub-folder of `meridian-erp`, because the shared workflow rsyncs every changed file into the ERP document root. Files:
- `index.html`, `.htaccess`, `robots.txt` (`Disallow: /`), `manifest.webmanifest`.
- `css/tokens.css` (light green tokens: `--pp-bg #f6faf6`, `--pp-surface #ffffff`, `--pp-primary #2f7d4f`, `--pp-primary-soft #e3f1e7`, `--pp-text #1d2b22`, `--pp-warn #b7791f`, `--pp-danger #b42318`) and `css/portal.css`.
- `js/config.js` (Supabase URL and **anon key only**) and `js/api.js` (fetch wrapper; auth refresh; maps `portal:*` errors to fixed strings).
- `js/auth.js`, `js/router.js` (hash routes), and `js/dom.js` (an `el()` builder that only sets `textContent`; `innerHTML` is banned outside static templates).
- `js/gantt.js` (a copy of the Phase A renderer, with dependency arrows disabled) and `js/views/*.js`.

There are no CDN scripts. The deploy is a caller workflow `uses: brandonr2630/projects/.github/workflows/deploy.yml@master` with `deploy_dir` set to the subdomain's document root (confirm the path in cPanel). The first deploy uses `workflow_dispatch`, because the shared workflow deploys changed files only.

**Subdomain options:**
- `projects.q2m.io` (recommended): client brand, matches the mockup, and its origin is separate from the ERP, so the token stores are isolated.
- `portal.q2m.io` or `clients.q2m.io`.
- `projects.terranresources.com` (wrong brand for Q2 clients).

**Security headers** (in `.htaccess` via mod_headers, plus `Options -Indexes` and an HTTPS redirect):

| Header | Value |
|---|---|
| Content-Security-Policy | `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob: https://fcagxvjxfqqkmuposmcb.supabase.co; connect-src https://fcagxvjxfqqkmuposmcb.supabase.co; font-src 'self'; manifest-src 'self'; frame-src https://fcagxvjxfqqkmuposmcb.supabase.co; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'; require-trusted-types-for 'script'` |
| Strict-Transport-Security | `max-age=31536000` |
| X-Content-Type-Options / Referrer-Policy | `nosniff` / `no-referrer` |
| X-Frame-Options / COOP | `DENY` / `same-origin` |
| Permissions-Policy | `camera=(), microphone=(), geolocation=(), payment=()` |
| X-Robots-Tag | `noindex, nofollow` |
| Cache-Control (html, js, css) | `no-cache` |

**Auth flows.**
- **Accept invite.** `#/accept` reads `th` from the fragment and shows "Accept invitation for {email}". Only a click POSTs `/auth/v1/verify {type:'invite', token_hash}`, so link scanners cannot burn the single-use token. The page then drops the fragment (`history.replaceState`) and the client sets a password. Links expire after 1 hour (Email OTP expiry 3600 s); expired links show "Ask your Q2 contact to resend".
- **Passwords.** Minimum 12 characters, letters and digits required.
- **MFA.** TOTP enrolment is offered after first login. Approvals require `aal2` once `portal_cfg_require_mfa_for_approvals()` returns true.
- **Login.** Email and password; the portal UI offers no magic link.
- **Recovery.** Through `portal-recover` (`generateLink(type:'recovery')`, token-hash link). It always returns 200 and is limited to 3 requests per email per hour.
- **Sessions.** Kept in `localStorage` under `mp_session`, with a 30-minute idle logout. Logout calls `/auth/v1/logout` and clears storage.
- **Login gate.** If `portal_me()` returns zero rows, the app shows "You don't have access to any active projects" and signs the user out.

**Screens** (wireframe; each element names its source):
- **Login and accept**: logo, email, password, "Forgot password", MFA step. Source: Supabase Auth.
- **Project picker** (more than one grant): one card per project with job no, title, status chip and unread badge. Source: `portal_me()`.
- **Header**: project title and number, status chip, "Updated {relative time}", company logo. Source: `portal_project_header`.
- **Sidebar**: Overview, Schedule, Quality, Documents, Messages (unread badge from `portal_me().unread_count`), Team. Under 760 px it becomes a bottom tab bar, with Team in an overflow menu.
- **Overview**:
  - KPI strip (`portal_project_kpis`):
    - Overall progress: `actual_pct`, "as of `as_of`".
    - Schedule: `schedule_status` as a chip mapping all five of A's labels (X21): **On track** (green), **At risk** (amber), **Late** (red), **Complete** (green, no forecast line) and **On hold** (grey, no forecast line); "Not published" (neutral) is a D-only display state shown when no snapshot is visible. Shows forecast handover `forecast_handover` against planned `planned_handover` and "`slip_days` days late" when positive. `planned_handover` is NULL when slip is unknown, and then only the forecast date (or nothing) is shown, never a planned date equal to the forecast.
    - ITP: "`itp_passed` of `itp_total` passed", plus "`itp_waived` waived" when non-zero.
    - Hold points awaiting (`hold_points_awaiting`) and Open NCRs (`open_ncrs`).
  - An "Action needed" panel: rows where `portal_quality.can_respond` or `portal_documents.can_decide` is true.
  - Mini progress curve: planned line from `portal_planned_curve` (full S-curve, including future dates) and actual points from `portal_progress_curve`.
  - The latest three updates (`portal_updates`, limit 3), with thumbnails from `portal-file-url {kind:'thumb'}`. The author shows as "{first name} · Q2 project team".
- **Schedule**: a read-only grouped Gantt (`portal_schedule`) with phase headers, milestone diamonds, a today line, **critical tasks coloured** (no dependency arrows), and a ghost baseline bar. On phones it falls back to a list.
- **Quality** (`portal_quality`):
  - ITP table: ref, description, status, result date; read-only.
  - Hold points: ref, title, state, witness date, response (`response`, with the note in `detail`). Where `can_respond` is true there are **Accept / Reject / Waive** buttons, with a note box that is mandatory for Reject; they call `portal_respond_hold_point`.
  - NCRs: ref, title, severity chip (`severity`), status, corrective action, action due date (`action_due`, shown as overdue when past and the NCR is open).
- **Documents** (`portal_documents`):
  - Register columns: number, title, revision, type, issued date, status, approval. Statuses are labelled; superseded revisions are greyed and labelled "Superseded".
  - "View" calls `portal-file-url {kind:'drawing'}` and opens the 300-second URL in a new tab.
  - Where `can_decide` is true there are **Approve / Reject** buttons. They pass the displayed `revision_no` as `p_expected_revision`.
- **Messages** (`portal_messages`):
  - Newest at the bottom; Q2 messages are badged.
  - Polled every 30 s while visible and every 5 min otherwise. Opening the thread calls `portal_mark_read` with the newest id.
  - The composer is a textarea with a 4000-character counter and a `client_msg_id` per draft, and calls `portal_send_message`.
  - Bodies are rendered with `textContent` and `white-space: pre-wrap`; links are not auto-linked.
- **Team** (`portal_team`): client representatives, and the Q2 team as first name plus "Q2 project contact" or "Q2 project team". No email or phone.
- **Settings** (account menu): email mode per project (`portal_set_notify_mode`), MFA enrol/remove, change password.

**Service worker: none in v1.** Cached authenticated responses on shared devices are a leak. The manifest is kept for "add to home screen".

**Notifications (X14).**
- **Client in-app**: unread badges and the "Action needed" panel, derived from live state. There is no client notifications table.
- **Client email**: `portal-notify` runs on pg_cron every 5 minutes. **Live: `pg_cron` and `pg_net` are not installed**; the owner enables both in the dashboard at prerequisite step 0 (X23, before A and C) and D's rollout only references that step. The service-role key is read from Supabase Vault and never inlined in `cron.job`. It sends:
  - `portal.message.to_client` and `portal.action.required` to `immediate` recipients for items newer than `last_notified_at`, at most one email per client per job per 15 minutes. Action watermarks are B's `job_hold_points.notified_at` and `job_drawings.approval_requested_at`.
  - `portal.digest.daily` at 11:00 UTC (07:00 Port of Spain) to `daily` recipients.
  - It stamps `last_notified_at` and logs to `notification_log` (`recipient_id` null, `recipient_email` set).
  - Every client email links to portal Settings and carries a `List-Unsubscribe` header pointing to `portal-unsubscribe` (an HMAC-signed grant id plus expiry; sets `notify_mode = 'off'`). `off` silences email only, and the ERP card shows staff "email off".
- **Staff**:
  - In-app rows are written synchronously by `portal_notify_staff`, with `type` = `portal.message.from_client` or `portal.decision.from_client` and title "{job_no} · …".
  - Emails with the same keys come from the cron, using `project_messages.staff_notified_at` and the `portal.decision.*` audit rows as watermarks, and are filtered by `notification_preferences`.
  - B's `hold_point.responded` and `document.approval_requested` are not written for client-originated events.

## Migration and rollout

Migration names and order follow X16 and X23 (`supabase/migrations/YYYYMMDDHHMM_<slug>.sql`). Strict order: **D0a, A, B, C, D0c, D core, D reads, B4**, preceded by owner prerequisite step 0.

0. **Owner prerequisite (dashboard, once, before A and C; X23).** Enable `pg_cron` and `pg_net` and store the service-role key in Supabase Vault. Every migration then uses only `CREATE EXTENSION IF NOT EXISTS`. Phase D does **not** enable them later: `portal-notify` scheduling (step 7) and B4 (step 8) reference this step. The auth checklist below is a pre-pilot gate, not part of step 0.
1. **`d0a_staff_only_storage`** (separate PR, blocking, first).
   - Paste the Q-A..Q-E, Q-S1 and drawing-atom-coverage output and the live `pg_get_functiondef` of the five helpers into the PR.
   - Apply D0a. Verify Q-R = 0 and the D0 acceptance criteria.
   - Run the staff regression: an `operations_tech` and a `viewer` work-order round trip, drawing upload and view, Job Config, and a logo change by a company admin.
   - Then ship **D0b**: `erp-user-access` plus the `index.html` user-management change. Run Q-E: every auth user without an active `erp_users` row and without a live grant must be banned.
   - If `CREATE POLICY` on `storage.objects` is refused for the migration role, apply the storage statements in the SQL editor as `postgres`. The policy texts are unchanged.
2. **A**, per its spec. Re-run Q-D after it.
3. **B**, applied after A (developed in parallel, but its visibility triggers call A's guard). Re-run Q-D.
4. **C**, after A; needs the step-0 extensions. Re-run Q-D.
5. **`d0c_rls_<family>`**, one PR per family, in the order in D0. Verify each with real non-privileged users before the next. All families must be done before step 6.
6. **`d_portal_core`**: D1, D2, D3a, D4 messages and prefs, D5 except `portal_authorize_file`, D6 (notification types and atoms), policies, core grants. Needs `is_erp_staff()` and `set_updated_at()`.
7. **`d_portal_reads`**: D3b, `portal_respond_hold_point`, `portal_decide_drawing`, `portal_authorize_file`, reads grants. Needs A, B and C applied (A's `job_task_client_visible` and `job_schedule_status`, C's snapshot columns). Then:
   - confirm the step-0 extensions and Vault key are in place (nothing is enabled here);
   - deploy `portal-invite`, `portal-recover`, `portal-file-url`, `portal-notify` and `portal-unsubscribe`, each with a CORS allowlist (no `*`) and verify-JWT on, except `portal-unsubscribe` (HMAC);
   - schedule `portal-notify`.
8. **B4 NCR overdue cron** (last, per X16 and X23), with the step-0 Vault key. The 2026-06-22 overdue-cron migration was never applied live (pg_cron absent), so no inlined key exists today. Any future cron job must use Vault (L10).

**Pre-pilot gate: owner dashboard checklist** (not readable from SQL; every item ticked in the pilot PR):
- **Auth → Providers**:
  - "Allow new users to sign up" **OFF**. This is critical: otherwise anyone can mint an `authenticated` JWT.
  - Anonymous sign-ins OFF.
  - Email: confirm email ON, secure email change ON, secure password change ON.
  - Phone, OAuth/social and SAML off.
- **Auth → Passwords**: minimum length 12 with character classes; leaked-password protection (advisor flags it disabled; Pro).
- **Auth → Email/OTP**: Email OTP expiration **3600 s** (L3; matches the invite copy).
- **Auth → Sessions**: refresh-token rotation ON with reuse interval; JWT expiry ≤ 3600 s.
- **Auth → URL configuration**: redirect allowlist only the ERP origin and `https://projects.q2m.io/**`; no localhost, no broad wildcards.
- **Auth → MFA**: TOTP on, phone MFA off.
- **Auth → Rate limits**: tighten email sends, token verifications and sign-ins per IP.
- **Auth → Hooks**: confirm no custom access-token hook adds claims that any policy trusts.
- **Auth → Email templates**: invite and recovery use `{{ .TokenHash }}` links, not `{{ .ConfirmationURL }}`.
- **API settings**: exposed schemas = `public` only. `pg_graphql` is not installed live; keep it that way.
- **Storage**:
  - `job-drawings` is private.
  - `company-logos` allows only image/png, jpeg and webp (no SVG or HTML), with a size limit.
  - The policies tab shows only the D0a policies for these buckets.
- **Edge functions**: verify-JWT on for every function except `portal-unsubscribe`; deployed source matches the repo (L9).
- **Security Advisor**: clear `function_search_path_mutable`, anon-executable definer functions, `auth_leaked_password_protection`, `auth_otp_long_expiry`, `auth_insufficient_mfa_options`.
- **Auth → Users**: removed and deactivated staff are banned; no anonymous users.
- **DNS**: SPF, DKIM and DMARC on q2m.io for the Resend sender.

**Staging.** The staging project is parked on the free-plan cap (handoff Session 52). Recommended: upgrade to Pro before the pilot. Otherwise dark-launch on production with a synthetic "Portal Test Co" company, job and test clients, and put the subdomain behind cPanel Directory Privacy until the pilot.

**Pilot.** One real client, one job, at most two client users (one approver), four weeks. Staff review the portal audit feed daily. Exit: the acceptance criteria plus zero sweep findings.

**Kill switches** (fastest last):
- L1: revoke one grant.
- L2: `portal_staff_revoke_all(company)`.
- L3: `supabase/ops/portal-kill.sql` (`REVOKE EXECUTE` on every client `portal_*` function from `authenticated`) plus swapping `.htaccess` to a maintenance page.
- L4: ban the client auth users through the admin API, which also blocks refresh.

**Monitoring.**
- The weekly client sweep.
- Q-A..Q-D weekly; any new row fails the run.
- A daily report of `portal.*` audit counts per user, rate-limit hits and grants expiring within 14 days.
- Auth logs for failed logins.
- A check that `project_clients.auth_user_id` never intersects `erp_users.auth_user_id`.

**Privacy.**
- Client PII held: name, email, messages, decisions, last-seen, plus Auth logs (IP and user agent).
- Retention: grants and messages for the life of the job plus 7 years, enforced by the retention hold. Client auth users are deleted 90 days after their last grant ends; FKs are set to NULL and the rows stay.
- Erasure on request: `portal_erase_client(grant)` (service role) pseudonymises the grant, the messages and the portal audit usernames and revokes the grant. The auth user is then deleted.
- A short privacy notice is linked from the login page.

## Test plan

- **Client sweep** (`scripts/portal-sweep.mjs`, before the pilot and weekly). Fixture: test client A has a grant on job J1 in company C1; J2 belongs to the same customer with no grant; J3 is in company C2; client B is on J2.
  - **REST**: as A, read the `/rest/v1/` OpenAPI. GET `?limit=1` on **every** exposed table and view must return `[]` or 401/403; POST, PATCH and DELETE with `{}` must fail. This includes the 22 D0 tables and the D tables (A cannot even read its own `project_clients` row directly).
  - **RPC**: call every `/rpc/*` granted to `authenticated` with J2 and J3 ids and expect `portal:not_found` with an identical body. Staff RPCs, including `portal_staff_can_invite`, return `forbidden`. `next_job_no` returns 42501.
  - **Anon**: as anon, `next_job_no` and `is_company_admin` are denied (D0a) and every table returns `[]`/401.
  - **Storage**: as A, list, sign, upload and delete in `job-drawings`, `job-updates` and `company-logos` are all denied, as are upload and upsert of a logo.
  - **`portal-file-url`**: ids from J2, a non-visible drawing and an archived one are omitted.
  - **Other functions**: `send-notification`, `create-erp-user` and `erp-user-access` called with A's JWT return 403.
  - **GraphQL**: `/graphql/v1` returns 404 (extension absent).
  - **Revocation**: repeat with A revoked; data access is denied on the next call even with an unexpired JWT.
- **D0 storage and identity tests** (staff, before and after D0a):
  - Permission checks (X23): a C1 member whose role lacks `ops:work-orders:read` cannot view a C1 drawing; one lacking `ops:work-orders:write` cannot upload; a C1 member without company admin cannot delete.
  - A C1 staff member with the atoms can upload under `<C1>/<J1>/`, view and (as company admin) delete. The same member cannot sign or delete `<C2>/…`, and cannot upload under `<C1>/<J3>/` (wrong company job) or under `<C2>/…`.
  - A legacy object whose key lacks a company prefix but matches a `job_drawings.storage_key` stays viewable.
  - A non-admin cannot upload a logo for a company; a super admin can upload `new-…`.
  - Overwriting an existing drawing object fails for everyone.
  - Deactivated staff via `erp-user-access`: the next REST call returns no company data and token refresh fails (banned). Removed staff: login fails.
- **SQL whitelist CI** (`scripts/check-portal-sql.mjs`, on every PR touching `supabase/migrations`):
  - It extracts each function named in the D7 `GRANT ... TO authenticated` blocks, except `portal_staff_*`.
  - It fails on `_ttd\b|\brate_\w*|\w*_rate\b|\bcost\w*|\bprice\w*|payment_terms|customer_po|costing_notes|internal_notes|root_cause|waiver_ref|storage_key(?!\s+IS\s+NOT\s+NULL)|\bassignee\b|\.email\b|\bphone\b|full_name(?!,\s*''\),\s*' ',\s*1)` in every checked function.
  - Separately it fails on the wildcard patterns `\bSELECT\s+\*|\w+\.\*` in every checked function **except `portal_respond_hold_point` and `portal_decide_drawing`**. These two are explicitly exempt from the wildcard rule only, because they lock and update a whole row into a typed record (`SELECT hp.*` / `SELECT dr.*` ... `FOR UPDATE`, `RETURNING *`) and return only their fixed `RETURNS TABLE` columns (id, state/status, response, timestamps) which never include a row field outside the whitelist. They stay subject to the full column-name rule above and to the `RETURNS TABLE` column check below. The exemption is by function name in `scripts/check-portal-sql.mjs`, so a third function using `x.*` still fails.
  - It fails if a checked function's `RETURNS TABLE` columns differ from the whitelist recorded next to it in the script (so adding a column to `portal_quality`, such as `severity`, is a reviewed change).
  - It fails on any excluded table name.
  - It fails if any portal function lacks `SECURITY DEFINER` plus `SET search_path`, or a matching `REVOKE … FROM PUBLIC, anon`.
- **RPC unit tests** (SQL, as the test client via `set_config('request.jwt.claims', …)` in a rolled-back transaction):
  - Idempotent replay of message, hold point and drawing returns the same row. A stale `p_expected_revision` raises a conflict. A viewer responding raises forbidden.
  - The 21st message in 10 minutes is rate limited, also when 25 calls run in parallel (advisory lock).
  - Control and bidi characters are stripped; a 4001-character body is rejected.
  - A decision writes exactly one audit row (`portal.decision.*`, username = client display name) and no `quality_audit` row (#26). It also writes one `erp_notifications` row per recipient with a dotted type and the job number in the title.
  - `portal_project_kpis` returns the latest visible snapshot's `schedule_status`, `forecast_end` and `slip_days` unchanged, and ITP counts per X8 (fixture: 3 passed, 1 waived, 1 na, 1 pending → 3 / 5, waived 1).
  - `portal_project_kpis` maps all five labels: fixtures with snapshots stored as On track, At risk, Late, Complete and On hold return exactly those strings; no client-visible snapshot returns 'Not published'. A snapshot with `slip_days` NULL returns `planned_handover` NULL (not equal to the forecast).
  - `portal_schedule` and `portal_planned_curve` share the X22 predicate: a visible task in a non-visible phase appears in neither; a visible task with no phase appears in both.
  - `portal_quality` returns `severity` and `action_due` on NCR rows and `response` on hold-point rows, NULL on the others.
  - `portal_updates` with a client-visible row whose `published_at` is NULL (direct PATCH) sorts by `created_at` and pages without skipping or repeating it.
  - `portal_planned_curve` returns nothing before a snapshot is published, then weekly points ending at the baseline end.
  - `project_clients`:
    - Inserting with an authenticated JWT fails; a staff auth id or an email/uid mismatch raises.
    - PATCHing `auth_user_id`, `email`, `expires_at`, `invite_count` or `revoked_at` as staff is denied by column privileges.
    - `status` `active → suspended` works for staff; `invited → active` by staff is rejected.
    - Extend beyond now() + 365 days is rejected; a repeated extend on a 2-year job succeeds.
  - Removing a staff member who sent messages succeeds (sender id set to NULL, no check violation).
  - Deleting a job with a grant raises `portal:retention_hold`.
  - `portal_erase_client` pseudonymises and then succeeds in deleting the auth user.
- **Abuse and penetration (manual, before the pilot):**
  - XSS payloads in message bodies, display names and project titles, in both apps.
  - Invite link replay, and an invite link opened in another browser after acceptance.
  - An expired invite (over 1 hour).
  - Session fixation via pre-seeded `localStorage`.
  - Clickjacking; CSP violations during a full click-through.
  - A message flood and a signed-URL flood.
  - Timing and enumeration of `/auth/v1/recover` and `portal-recover`.
  - An insider binding attempt: staff PATCH `auth_user_id` to another client's uid.
- **Staff regression after each D0 stage:** an `operations_tech` and a `viewer` complete a work-order edit, Job Config, the Gantt, drawing upload and view; a company admin changes a logo.

## Risks

- **D0 is the real risk.** Restrictive policies cannot reduce what active staff see. Two things can still block a role: a D0c policy with the wrong atom, and the storage tenant policies if Q-S1 reveals an unexpected key layout (the legacy fallback covers reads and deletes, not new uploads). Mitigations: staged per family, real-user tests and rollback SQL per stage.
- **`app.portal_rpc` trust (X6).** B's guards are SECURITY INVOKER and accept the flag only when `current_user <> 'authenticated'`. Inside D's definer RPCs `current_user` is the owner; on direct PostgREST access it is `authenticated`.
  - Live: no function callable by `authenticated` uses `set_config` or dynamic SQL, and pg_graphql is absent.
  - The weekly Q-I-style check must stay empty; adding any such function reopens this.
  - The erasure and purge flags additionally require a service-role or no-JWT context.
- **`user_has_perm` is not company-scoped.** It is always paired with `my_company_ids()` and the row's company; fix it ERP-wide later.
- **Revocation latency.** Data stops on the next RPC call. Signed URLs live up to 300 s. Ban (L4) for immediate session death.
- **Native OTP and recovery remain callable (L2, accepted).** With the Email provider on, `/auth/v1/otp` and `/auth/v1/recover` work with the anon key whatever the portal UI offers. Inbox compromise therefore yields a session without the password. Accepted for the pilot. Mitigations: tight Auth rate limits, 1-hour OTP expiry, `aal2` for approvals at general availability, and the decision audit trail.
- **A–C column drift.** D3b binds to the A–C drafts. plpgsql resolves columns at first call, so the sweep must run right after `d_portal_reads`. The explicit casts turn type drift into loud errors.
- **Retention hold vs operations.** Jobs with portal history can no longer be hard-deleted from the ERP (by design, L5). Test data needs the purge procedure.
- **Email deliverability and spoofing.** SPF, DKIM and DMARC are in the pre-pilot gate.
- **Existing edge functions decode the JWT `sub` without verifying it** and rely on PostgREST to reject forged tokens; portal functions verify via `/auth/v1/user`. The shared deploy workflow uses `StrictHostKeyChecking=no`; pin the host key (low).
- **Sequential job numbers** (`WO-###`) reveal order volume to a client (I2, accepted; the header leads with `project_title`).

## Open questions

1. **Upgrade the Supabase org to Pro** (staging, leaked-password protection, session time-boxing)? *Default: yes, before the pilot; otherwise dark-launch on prod.*
2. **Subdomain?** *Default: `projects.q2m.io`.*
3. **MFA for approvers?** *Default: optional during the pilot; required (`aal2`) for approval RPCs from general availability.*
4. **Where does the client-facing project name live?** *Default: `project_clients.project_title`, set at invite; move to a `jobs` column only if a phase that owns `jobs` adds one.*
5. **Invite link lifetime.** 1 hour (L3) may be short for clients. *Default: keep 3600 s and rely on Resend. Revisit if the pilot shows expired-link friction; never exceed 86400 s.*
6. **Staff role labels.** *Default: two relationship labels ("Q2 project contact" for the inviter, "Q2 project team" otherwise). A per-staff job title can be added later as an ERP field.*
7. **Do clients see staff read receipts?** *Default: staff see client receipts; clients do not see staff receipts.*
8. **Message retention?** *Default: life of the job plus 7 years; client auth accounts deleted 90 days after their last grant ends.*
9. **Release agreement: text and legal effect.** *Default: the owner's lawyer drafts it; the system stores versioned text with its hash and requires re-acceptance on each new version.* Open: whether a clause restricting use in legal proceedings is enforceable in the owner's jurisdiction, and what a client who declines can see (default: nothing).
10. **Who must accept?** *Default: every client user, individually, on first sign-in and again after each new version; an approver cannot accept for a viewer.*

## Acceptance criteria

1. **D0 inventory gates** (baseline 2026-10-19: Q-A 0, Q-B 0, Q-C 26 rows, Q-D 5 functions, Q-E 4/0/0/0/0).
   - After D0a: Q-A = 0 and Q-B = 0. Q-R = 0, meaning all 22 tables carry `d0_staff_only` and `d0_no_anon`. Q-C returns no `storage` rows.
   - Q-D lists 6 functions (the 5 plus `is_erp_staff`). None is executable by `PUBLIC` or `anon`, and all have `search_path=public, pg_temp`.
   - `next_job_no()` raises 42501 for a non-staff JWT.
   - After all D0c families: Q-C = 0 rows.
2. **D0 storage.** The 4 legacy storage policies are gone. As a client or anon JWT, every list, sign, upload and delete on `job-drawings`, `company-logos` and `job-updates` is denied. Staff can access only their companies' drawing paths and only with the X23 atoms (`ops:work-orders:read` to view, `ops:work-orders:write` to upload, company admin to delete). Q-S1's legacy objects stay downloadable. No UPDATE policy exists on `storage.objects` for these buckets.
3. **D0 identity.** A deactivated staff member gets no company rows over REST and cannot refresh a session; a removed one cannot log in. The ERP's own `job_audit_log` inserts (`job_saved`, `job_deleted`) succeed under `d0_audit_insert`.
4. **Auth gate.** Public sign-up and anonymous sign-ins are off. The only way to create a client is `portal-invite`, which derives the company from the job, binds `auth_user_id` at insert, and refuses staff emails.
5. **Scoping.** A client sees exactly the `client_visible` rows of granted jobs and nothing for any other job id, existing or not (identical error). `check-portal-sql.mjs` passes: no client-callable `portal_*` function references a cost, commercial, internal-note or staff-contact column.
6. **Consistency with A–C.** Status and forecast equal the stored snapshot values in A's labels. ITP counts follow X8. Documents include superseded history and never drafts. There is no client ITP action. The portal Gantt colours critical tasks and draws no arrows.
7. **Decisions.** Hold-point responses and drawing decisions are idempotent, revision-pinned, rate limited and authorized before locking. Each writes exactly one `portal.*` audit row (username populated) and `portal.decision.from_client` in-app rows titled with the job number.
8. **Messages.** Messages round-trip between portal and ERP with unread counts. A `<script>` payload renders as text in both apps; bodies over 4000 characters are rejected. Removing a staff sender does not fail.
9. **Grants.** Grants cannot be inserted by any API role; identity columns cannot be changed by staff. Extend works repeatedly within now() + 365 days. Job hard-delete with portal history is blocked. Erasure pseudonymises.
10. **Files.** Signed URLs are minted only by `portal-file-url` and expire in 300 s.
11. **Revocation.** Revoking a grant blocks data on the next call. The company kill switch revokes every grant in one action, and the L3 script has been rehearsed on dark-launch data.
12. **Email.** Portal emails carry no message content, honour `notify_mode`, have a working unsubscribe link, and state a 1-hour invite validity that matches the 3600 s OTP setting.
13. **Function ownership (X6 dependency).** Every `portal_*` function is owned by `postgres`: `SELECT proname, proowner::regrole FROM pg_proc WHERE proname LIKE 'portal\_%'` returns `postgres` on every row (checked after `d_portal_core` and again after `d_portal_reads`, and by the weekly Q-D run). Any other owner fails the gate, because B's `app.portal_rpc` bypass relies on `current_user <> 'authenticated'` inside the definers.
14. **Role seed.** The D6 post-seed assertion passes and its role listing matches the expected sets exactly, with `Office Admin` (capital O and A, a space) present on `portal:read`, `portal:invite` and `portal:messages:reply`.
15. **Prerequisites and order.** Step 0 (pg_cron, pg_net, Vault key) is done before A and C, and the migrations were applied in the order D0a, A, B, C, D0c, D core, D reads, B4.
16. **Pre-pilot gate.** Every owner dashboard checklist item is ticked in the pilot PR. Security headers score A on securityheaders.com, with no CSP violations during a full click-through on desktop and on a 375 px phone.
