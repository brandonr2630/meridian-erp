# Phase B — Quality: ITP, hold points, NCRs, document approvals

*Status: draft for review · 2026-10-19 · depends on 00-overview.md (decisions D1-D5 and cross-phase decisions X1-X23 apply); applied strictly AFTER Phase A (B's visibility triggers call A's `job_visibility_guard()`); B may be developed in parallel with A*

## Goal and scope

Give staff one place per job (project) to plan, execute and evidence quality, and to run document approvals, with the data shaped so Phase D can expose a client-safe subset through `portal_*` functions (Phase D) without schema change.

In scope:

1. **Inspection and test plan (ITP)**: per-job list of inspection/test items with sign-off (who, when, result), generated from the existing QC catalogue or entered manually.
2. **Hold points**: a state machine (planned, notified, witnessed or waived, released) with a witness request, a witness date, and a response. Staff act in Phase B; the client acts in Phase D. Columns and states exist now.
3. **NCRs**: open, corrective action, verification, closed; severity minor/major/critical; links to task, ITP item, hold point and drawing.
4. **Document register**: `job_drawings` is generalised (type, status, issue date, client-approval flag, supersedes). Specs and reports currently held as JSONB on `jobs` are registered here.
5. **KPI view** feeding the four mockup tiles: "Inspection & test plans: 11 / 16 signed off", "Awaiting your approval: 2 hold points (1 drawing · 1 inspection)", "Open NCRs: 1 minor, closed this month: 2", "Documents issued: 38 latest revs, 3 new this week".
6. Audit trail, numbering, notifications and new permission atoms.

Verified live facts this spec relies on (2026-10-19):

- `job_drawings` columns: `id, job_id, company_id, drawing_no, drawing_title, revision_no, date, source (default 'Client'), storage_key, archived, archived_at, archived_by, created_at, updated_at, created_by`. FKs: `created_by` and `archived_by` -> `erp_users(id)`; `job_id` -> `jobs(id)` ON DELETE CASCADE. Policies: any company member may INSERT and UPDATE; SELECT is members for non-archived rows, admins for all; DELETE admins on archived rows only.
- `job_audit_log` columns: `id, job_id (FK jobs, SET NULL), job_no, user_id (FK auth.users, SET NULL), username, action_type, description, metadata jsonb, created_at`. It has **no `company_id`** and a single policy `FOR ALL USING (true) WITH CHECK (true)`.
- `sequence_counters`: `id, company_id, sequence_type, prefix, last_number, padding`, UNIQUE `(company_id, sequence_type)`. Live rows are payment/bill/receipt. There is no RPC that increments it; `next_job_no()` uses a separate Postgres sequence.
- `erp_notifications`: `id, company_id, user_id (FK erp_users), type, title, body, task_id (FK crm_tasks), is_read, created_at`. No job column. `notification_types(event_key, label, subject_tpl, body_html, recipient, enabled)` with CHECK `recipient IN ('direct','role:admin','owner')`.
- `config_qc_checklists`: `id, checklist_item, job_type, sort_order, status, is_active, submitted_by, created_at, updated_at`. Currently **0 rows**. `jobs.qc_state` is a positional JSONB array `[{item, state: 'pass'|'fail'|''}]`, written by the job form (`jcBuildQCChecklist`, restore loop matches by index).
- Specs and reports on `jobs` are JSONB rows with no file attachment (`Spec No, Spec Title, Revision No, Date Received, Source`; `ref, title`).
- Live types relied on: `job_drawings.revision_no` is **text**, `job_drawings.drawing_no` text, `job_drawings.date` date; `job_tasks.progress` integer; `erp_users.full_name` text and `erp_users.auth_user_id` uuid. `erp_roles.permissions` is a JSON **object** `{atom: true}` for all 7 roles (`jsonb_typeof = object`, verified live), so `permissions || jsonb_build_object(...)` is the correct merge. The trigger function `set_updated_at()` (no arguments, returns trigger) already exists in `public` and is reused.
- Roles in `erp_roles` today: super_admin, company_admin, operations_tech, viewer, finance_manager, sales_rep, Office Admin. `ops:work-orders:read|write|approve` exist.

## Out of scope

- Client login, client-side actions, the `portal_*` views and messages (Phase D). Phase B only defines the columns and states they will use.
- Client sign-off of ITP items (not a feature, decision X8: staff record results, on the client's behalf if needed).
- The `job_audit_log` RLS fix and `job-drawings` storage hardening (owned by Phase D0, decision X12).
- Photos and evidence upload for ITP items (Phase C owns photo storage; Phase B stores a free-text `evidence_ref`).
- Rebuilding the shop-floor QC checkbox UI, or deleting `qc_state`, `specs`, `reports` JSONB.
- Document file storage changes: the `job-drawings` bucket (PDF, 20 MB) is reused as is.
- Supplier NCRs against purchase orders, calibration registers, and e-signature legal compliance.

## Data model

### Design decisions

- **ITP generation**: *copy-on-generate*. A "Generate ITP" action copies approved, active `config_qc_checklists` rows for the job's `job_type` (plus `job_type = 'All'`) into `job_itp_items` with `source='template'` and `template_id` set. The catalogue stays the template store; per-job items are independent after copy so later catalogue edits never rewrite signed-off history.
- **Bridge from `qc_state` (no breakage)**: the legacy QC grid and `jobs.qc_state` remain untouched and keep working. A one-time "Import legacy QC" button converts `qc_state` entries on a job into ITP items (`source='qc_import'`; `pass` becomes `passed`, `fail` becomes `failed`, blank `pending`; sign-off by left null, `result_notes='Imported from legacy QC checklist'`). There is **no dual write**. Once a job has any ITP item, the job form hides the legacy grid for that job (data remains in `qc_state`, read-only). Jobs without ITP items behave exactly as today.
- **ITP counting rule (canonical, decision X8)**: numerator = items with `status = 'passed'`; `waived` items are shown separately and never counted as signed off; denominator = items with `status <> 'na'`. Phase D follows this rule.
- **Hold point vs ITP item**: a hold point is a gate. It optionally points at an ITP item (`itp_item_id`) so the item's sign-off can be blocked until release (UI warning in Phase B, not a DB block).
- **Document types**: generalise `job_drawings` with `doc_type` (drawing, specification, report, datasheet, other) rather than a new table; reserved-table rules forbid another table. JSONB specs/reports are backfilled once into `job_drawings` rows with null `storage_key`; the ERP form switches to reading the register; JSONB is left in place for rollback.
- **Client-visible flag**: every new table has `client_visible boolean not null default false`. Phase D functions must filter on it. Flipping it is gated by Phase A's shared `job_visibility_guard()` (decision X5; B does not define its own publish check, see Publish rule below). Internal-only text lives in separate `internal_notes` columns that portal views never select.
- **Audit**: DB triggers write `job_audit_log` rows (user id from `auth.uid()`, `username` from `erp_users.full_name`), so the trail does not depend on UI code. Action types: `itp_signed`, `hold_point_state`, `ncr_state`, `document_status`; visibility flips are logged as `visibility_changed` by `job_visibility_guard()`. When `app.portal_rpc` is set the Phase D RPC already writes its own audit row, so `quality_audit()` skips to avoid duplicates.
- **Publish rule (decision X5)**: setting `client_visible = true` on `job_itp_items`, `job_hold_points`, `job_ncrs` or `job_drawings` is enforced by Phase A's shared `job_visibility_guard()` (needs `ops:work-orders:approve` OR the table's domain atom: `quality:docs:issue` for documents; `quality:itp:sign`, `quality:hold:manage`, `quality:ncr:write` for ITP, hold points and NCRs). B attaches that function as a trigger with its two arguments (see Dependency and attach contract) and does not redefine it. Editing the client-facing text columns of a row that is already visible (ITP `description`, `acceptance_criteria`, `result_notes`; hold point `title`, `description`, `response_note`; NCR `title`, `description`, `corrective_action`; document `drawing_no`, `drawing_title`, `revision_no`) auto-unpublishes it (`client_visible` back to false) through the same function. **Dependency and attach contract (decision X19)**: `job_visibility_guard()` is created by Phase A's migration, so B is applied strictly AFTER A (B stays one migration file; it may be developed in parallel). B attaches the guard `BEFORE INSERT OR UPDATE` with exactly two trigger arguments, `TG_ARGV[0]` = comma-separated wording columns and `TG_ARGV[1]` = domain atom: ITP `('description,acceptance_criteria,result_notes','quality:itp:sign')`, hold points `('title,description,response_note','quality:hold:manage')`, NCRs `('title,description,corrective_action','quality:ncr:write')`, documents `('drawing_no,drawing_title,revision_no','quality:docs:issue')`. Wording columns are exactly the client-whitelisted text columns; status, dates and internal columns never unpublish.
- **Numbering**: NCR numbers are company-wide through `sequence_counters` (`sequence_type='ncr'`, prefix `NCR`, padding 4), allocated by a SECURITY DEFINER function using an atomic UPDATE. The function is trigger-only: `REVOKE ALL ... FROM PUBLIC, anon, authenticated` (decision X13), otherwise any JWT could burn numbers or create counter rows for any company through `/rpc`. Hold point numbers (`HP-01`) and ITP item numbers are per-job, UI-suggested, unique per job.
- **Creator columns**: omitted deliberately (FK targets are inconsistent). Actors are recorded as `*_by uuid REFERENCES erp_users(id)` for staff actions and `*_client_user uuid REFERENCES auth.users(id)` for client actions on hold points and documents (verified targets). ITP items carry no client actor (decision X8).

### Migration (up)

```sql
-- ============ shared helpers ============
-- updated_at uses the existing public.set_updated_at() (decision X16); no new helper is created.

CREATE OR REPLACE FUNCTION quality_next_no(p_company uuid, p_type text, p_prefix text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v int; pad int; pre text;
BEGIN
  INSERT INTO sequence_counters (company_id, sequence_type, prefix, last_number, padding)
  VALUES (p_company, p_type, p_prefix, 0, 4)
  ON CONFLICT (company_id, sequence_type) DO NOTHING;
  UPDATE sequence_counters SET last_number = COALESCE(last_number, 0) + 1
   WHERE company_id = p_company AND sequence_type = p_type
  RETURNING last_number, padding, prefix INTO v, pad, pre;
  RETURN pre || '-' || lpad(v::text, COALESCE(pad, 4), '0');
END $$;
-- trigger-only (decision X13): not an RPC. It is called only from job_ncrs_set_no(), which is SECURITY DEFINER
-- (owner keeps EXECUTE), so the INVOKER guards and the revoked grants do not conflict.
REVOKE ALL ON FUNCTION quality_next_no(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- ============ job_itp_items ============
CREATE TABLE job_itp_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       uuid NOT NULL REFERENCES companies(id),
  job_id           uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order       integer NOT NULL DEFAULT 0,
  item_no          text,
  description      text NOT NULL,
  inspection_type  text NOT NULL DEFAULT 'inspect'
                   CHECK (inspection_type IN ('inspect','test','witness','review')),
  acceptance_criteria text,
  reference_doc    text,
  source           text NOT NULL DEFAULT 'manual'
                   CHECK (source IN ('manual','template','qc_import')),
  template_id      uuid REFERENCES config_qc_checklists(id) ON DELETE SET NULL,
  task_id          uuid REFERENCES job_tasks(id) ON DELETE SET NULL,
  status           text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','passed','failed','waived','na')),
  signed_off_by    uuid REFERENCES erp_users(id),   -- staff inspector who recorded the result
  signed_off_at    timestamptz,
  witness_required boolean NOT NULL DEFAULT false,
  result_notes     text,            -- client-safe
  internal_notes   text,            -- staff only
  evidence_ref     text,
  client_visible   boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_itp_items_signed_chk CHECK (
    status IN ('pending') OR signed_off_at IS NOT NULL OR source = 'qc_import'),
  CONSTRAINT job_itp_items_job_item_uq UNIQUE (job_id, item_no)
);
CREATE INDEX job_itp_items_job_idx ON job_itp_items (job_id);
CREATE INDEX job_itp_items_company_job_idx ON job_itp_items (company_id, job_id);

-- ============ job_hold_points ============
CREATE TABLE job_hold_points (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       uuid NOT NULL REFERENCES companies(id),
  job_id           uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  hp_no            text NOT NULL,
  title            text NOT NULL,
  description      text,
  itp_item_id      uuid REFERENCES job_itp_items(id) ON DELETE SET NULL,
  task_id          uuid REFERENCES job_tasks(id) ON DELETE SET NULL,
  state            text NOT NULL DEFAULT 'planned'
                   CHECK (state IN ('planned','notified','witnessed','waived','released')),
  witness_party    text NOT NULL DEFAULT 'client'
                   CHECK (witness_party IN ('client','internal','third_party')),
  planned_date     date,
  notified_at      timestamptz,
  notified_by      uuid REFERENCES erp_users(id),
  witness_date     timestamptz,     -- requested inspection date shown on the tile
  response         text CHECK (response IN ('accepted','rejected','waived')),
  responded_at     timestamptz,
  responded_by     uuid REFERENCES erp_users(id),          -- staff recording on client's behalf
  responded_client_user uuid REFERENCES auth.users(id),    -- Phase D
  responded_client_name text,
  response_note    text,            -- client-safe
  waiver_ref       text,            -- written waiver reference required to waive
  released_at      timestamptz,
  released_by      uuid REFERENCES erp_users(id),
  internal_notes   text,
  client_visible   boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_hold_points_job_hp_uq UNIQUE (job_id, hp_no),
  CONSTRAINT job_hold_points_notified_chk CHECK (state = 'planned' OR notified_at IS NOT NULL),
  CONSTRAINT job_hold_points_released_chk CHECK (state <> 'released' OR released_at IS NOT NULL)
);
CREATE INDEX job_hold_points_job_idx ON job_hold_points (job_id);
CREATE INDEX job_hold_points_company_job_idx ON job_hold_points (company_id, job_id);

-- ============ job_ncrs ============
CREATE TABLE job_ncrs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       uuid NOT NULL REFERENCES companies(id),
  job_id           uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  ncr_no           text NOT NULL,   -- set by trigger, e.g. NCR-0007
  title            text NOT NULL,
  description      text,
  severity         text NOT NULL DEFAULT 'minor' CHECK (severity IN ('minor','major','critical')),
  status           text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','corrective_action','verification','closed','cancelled')),
  origin           text NOT NULL DEFAULT 'internal' CHECK (origin IN ('internal','client','supplier')),
  raised_at        timestamptz NOT NULL DEFAULT now(),
  raised_by        uuid REFERENCES erp_users(id),
  task_id          uuid REFERENCES job_tasks(id) ON DELETE SET NULL,
  itp_item_id      uuid REFERENCES job_itp_items(id) ON DELETE SET NULL,
  hold_point_id    uuid REFERENCES job_hold_points(id) ON DELETE SET NULL,
  drawing_id       uuid REFERENCES job_drawings(id) ON DELETE SET NULL,
  root_cause       text,            -- staff only
  corrective_action text,           -- client-safe summary
  action_owner     uuid REFERENCES erp_users(id),
  action_due       date,
  action_done_at   timestamptz,
  verified_by      uuid REFERENCES erp_users(id),
  verified_at      timestamptz,
  closed_by        uuid REFERENCES erp_users(id),
  closed_at        timestamptz,
  internal_notes   text,
  client_visible   boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT job_ncrs_no_uq UNIQUE (company_id, ncr_no),
  CONSTRAINT job_ncrs_closed_chk CHECK (status <> 'closed' OR (verified_at IS NOT NULL AND closed_at IS NOT NULL))
);
CREATE INDEX job_ncrs_job_idx ON job_ncrs (job_id);
CREATE INDEX job_ncrs_company_job_idx ON job_ncrs (company_id, job_id);

CREATE OR REPLACE FUNCTION job_ncrs_set_no() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.ncr_no IS NULL OR NEW.ncr_no = '' THEN
    NEW.ncr_no := quality_next_no(NEW.company_id, 'ncr', 'NCR');
  END IF;
  RETURN NEW;
END $$;
-- ncr_no is NOT NULL: the client sends '' and the BEFORE INSERT trigger replaces it.
-- trigger-only definer: not an RPC (decision X13)
REVOKE ALL ON FUNCTION job_ncrs_set_no() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER job_ncrs_set_no_trg BEFORE INSERT ON job_ncrs
  FOR EACH ROW EXECUTE FUNCTION job_ncrs_set_no();

CREATE TRIGGER job_itp_items_upd BEFORE UPDATE ON job_itp_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER job_hold_points_upd BEFORE UPDATE ON job_hold_points
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER job_ncrs_upd BEFORE UPDATE ON job_ncrs
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============ state machines + permission guards (BEFORE UPDATE) ============
-- Phase D SECURITY DEFINER RPCs set: SELECT set_config('app.portal_rpc','1', true) to act as the client.
-- The guards below are SECURITY INVOKER (decision X6, revised): they only call user_has_perm(), which is itself
-- SECURITY DEFINER. Inside them current_user is the real caller role: 'authenticated' on a direct REST call,
-- the function owner inside a Phase D SECURITY DEFINER RPC. The portal bypass therefore requires BOTH the GUC
-- AND current_user <> 'authenticated'; a REST client cannot satisfy the second condition.
CREATE OR REPLACE FUNCTION job_hold_points_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE portal boolean := COALESCE(current_setting('app.portal_rpc', true), '') = '1' AND current_user <> 'authenticated';
BEGIN
  -- migrations/backfills run as postgres/supabase_admin (unreachable from PostgREST, whose session_user is authenticator; decision X19)
  IF session_user IN ('postgres','supabase_admin') THEN RETURN NEW; END IF;
  IF NEW.state IS DISTINCT FROM OLD.state THEN
    IF NOT (
      (OLD.state = 'planned'  AND NEW.state IN ('notified','waived')) OR
      (OLD.state = 'notified' AND NEW.state IN ('witnessed','waived','planned')) OR
      (OLD.state IN ('witnessed','waived') AND NEW.state = 'released')
    ) THEN
      RAISE EXCEPTION 'Illegal hold point transition % -> %', OLD.state, NEW.state;
    END IF;
    IF NOT portal AND NOT user_has_perm('quality:hold:manage') THEN
      RAISE EXCEPTION 'quality:hold:manage required';
    END IF;
    IF NEW.state = 'waived' AND COALESCE(NEW.waiver_ref, '') = '' AND NOT portal THEN
      RAISE EXCEPTION 'waiver_ref required to waive a hold point';
    END IF;
    -- (re-)notify starts a fresh request: clear any previous response (e.g. after a client rejection)
    IF NEW.state = 'notified' THEN
      NEW.response := NULL; NEW.response_note := NULL; NEW.responded_at := NULL;
      NEW.responded_by := NULL; NEW.responded_client_user := NULL; NEW.responded_client_name := NULL;
    END IF;
  ELSIF OLD.state = 'released' THEN
    RAISE EXCEPTION 'Released hold points are immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER job_hold_points_guard_trg BEFORE UPDATE ON job_hold_points
  FOR EACH ROW EXECUTE FUNCTION job_hold_points_guard();

CREATE OR REPLACE FUNCTION job_ncrs_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF session_user IN ('postgres','supabase_admin') THEN RETURN NEW; END IF;   -- migrations/backfills (decision X19)
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
      (OLD.status = 'open'              AND NEW.status IN ('corrective_action','cancelled')) OR
      (OLD.status = 'corrective_action' AND NEW.status IN ('verification','cancelled')) OR
      (OLD.status = 'verification'      AND NEW.status IN ('closed','corrective_action'))
    ) THEN
      RAISE EXCEPTION 'Illegal NCR transition % -> %', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'closed' THEN
      IF NOT user_has_perm('quality:ncr:close') THEN RAISE EXCEPTION 'quality:ncr:close required'; END IF;
      IF NEW.severity IN ('major','critical') AND NOT user_has_perm('ops:work-orders:approve') THEN
        RAISE EXCEPTION 'ops:work-orders:approve required to close major/critical NCR';
      END IF;
    END IF;
  ELSIF OLD.status IN ('closed','cancelled') THEN
    RAISE EXCEPTION 'Closed NCRs are immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER job_ncrs_guard_trg BEFORE UPDATE ON job_ncrs
  FOR EACH ROW EXECUTE FUNCTION job_ncrs_guard();

-- sign-off columns on ITP items require quality:itp:sign (staff only; no portal bypass, decision X8)
CREATE OR REPLACE FUNCTION job_itp_items_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF session_user IN ('postgres','supabase_admin') THEN RETURN NEW; END IF;   -- migrations/backfills (decision X19)
  IF (NEW.status, NEW.signed_off_by, NEW.signed_off_at)
     IS DISTINCT FROM (OLD.status, OLD.signed_off_by, OLD.signed_off_at)
     AND NOT user_has_perm('quality:itp:sign') THEN
    RAISE EXCEPTION 'quality:itp:sign required';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER job_itp_items_guard_trg BEFORE UPDATE ON job_itp_items
  FOR EACH ROW EXECUTE FUNCTION job_itp_items_guard();

-- ============ audit trail (job_audit_log has no company_id; keyed by job) ============
CREATE OR REPLACE FUNCTION quality_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_job_no text; v_user text; v_type text; v_desc text; v_old text; v_new text;
BEGIN
  -- Phase D RPCs write their own portal.* audit row; skip to avoid duplicates. (quality_audit is SECURITY DEFINER because it
-- writes job_audit_log; this skip is only de-duplication, not a security decision.)
  IF COALESCE(current_setting('app.portal_rpc', true), '') = '1' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'job_itp_items' THEN
      v_old := OLD.status; v_new := NEW.status; v_type := 'itp_signed';
      v_desc := 'ITP ' || COALESCE(NEW.item_no, '') || ' ' || v_old || ' -> ' || v_new;
    ELSIF TG_TABLE_NAME = 'job_hold_points' THEN
      v_old := OLD.state; v_new := NEW.state; v_type := 'hold_point_state';
      v_desc := 'Hold point ' || NEW.hp_no || ' ' || v_old || ' -> ' || v_new;
    ELSIF TG_TABLE_NAME = 'job_ncrs' THEN
      v_old := OLD.status; v_new := NEW.status; v_type := 'ncr_state';
      v_desc := NEW.ncr_no || ' ' || v_old || ' -> ' || v_new;
    ELSE
      v_old := OLD.status; v_new := NEW.status; v_type := 'document_status';
      v_desc := 'Document ' || COALESCE(NEW.drawing_no, '') || ' ' || COALESCE(v_old, '') || ' -> ' || COALESCE(v_new, '');
    END IF;
    IF v_old IS NOT DISTINCT FROM v_new THEN RETURN NEW; END IF;
  ELSIF TG_TABLE_NAME = 'job_drawings' THEN
    v_type := 'document_created'; v_desc := 'Document ' || COALESCE(NEW.drawing_no, '') || ' created'; v_new := 'created';
  ELSE
    v_type := TG_TABLE_NAME || '_created'; v_desc := 'Created ' || TG_TABLE_NAME;
    v_new := 'created';
  END IF;
  SELECT job_no INTO v_job_no FROM jobs WHERE id = NEW.job_id;
  SELECT full_name INTO v_user FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1;
  INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description, metadata)
  VALUES (NEW.job_id, v_job_no, auth.uid(), v_user, v_type, v_desc,
          jsonb_build_object('table', TG_TABLE_NAME, 'row_id', NEW.id, 'from', v_old, 'to', v_new));
  RETURN NEW;
END $$;
-- trigger-only definer: not an RPC (decision X13)
REVOKE ALL ON FUNCTION quality_audit() FROM PUBLIC, anon, authenticated;
-- publish gate + unpublish-on-edit: Phase A's shared function, attached with its two-argument contract (decisions X5, X19)
-- TG_ARGV[0] = wording columns (auto-unpublish on edit), TG_ARGV[1] = domain atom (decision X19). Requires Phase A applied first.
CREATE TRIGGER job_itp_items_visibility BEFORE INSERT OR UPDATE ON job_itp_items
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('description,acceptance_criteria,result_notes', 'quality:itp:sign');
CREATE TRIGGER job_hold_points_visibility BEFORE INSERT OR UPDATE ON job_hold_points
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('title,description,response_note', 'quality:hold:manage');
CREATE TRIGGER job_ncrs_visibility BEFORE INSERT OR UPDATE ON job_ncrs
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('title,description,corrective_action', 'quality:ncr:write');

CREATE TRIGGER job_itp_items_audit AFTER INSERT OR UPDATE ON job_itp_items FOR EACH ROW EXECUTE FUNCTION quality_audit();
CREATE TRIGGER job_hold_points_audit AFTER INSERT OR UPDATE ON job_hold_points FOR EACH ROW EXECUTE FUNCTION quality_audit();
CREATE TRIGGER job_ncrs_audit AFTER INSERT OR UPDATE ON job_ncrs FOR EACH ROW EXECUTE FUNCTION quality_audit();

-- ============ ALTER job_drawings (document register) ============
ALTER TABLE job_drawings
  ADD COLUMN doc_type text NOT NULL DEFAULT 'drawing'
      CHECK (doc_type IN ('drawing','specification','report','datasheet','other')),
  ADD COLUMN status text NOT NULL DEFAULT 'draft'
      CHECK (status IN ('draft','issued','for_approval','approved','rejected','superseded')),
  ADD COLUMN issued_at timestamptz,
  ADD COLUMN issued_by uuid REFERENCES erp_users(id),
  ADD COLUMN requires_client_approval boolean NOT NULL DEFAULT false,
  ADD COLUMN approval_requested_at timestamptz,
  ADD COLUMN approved_by_client_user uuid REFERENCES auth.users(id),
  ADD COLUMN approved_by_client_name text,
  ADD COLUMN approved_at timestamptz,
  ADD COLUMN approval_note text,
  ADD COLUMN supersedes uuid REFERENCES job_drawings(id) ON DELETE SET NULL,
  ADD COLUMN legacy_source text,       -- 'specs' | 'reports' when backfilled from jobs JSONB
  ADD COLUMN client_visible boolean NOT NULL DEFAULT false;

-- existing rows with a stored file were already "in circulation": register them as issued
UPDATE job_drawings
   SET status = 'issued', issued_at = COALESCE(date::timestamptz, created_at)
 WHERE storage_key IS NOT NULL AND status = 'draft';

CREATE INDEX job_drawings_company_job_status_idx ON job_drawings (company_id, job_id, status);

CREATE OR REPLACE FUNCTION job_drawings_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  portal boolean := COALESCE(current_setting('app.portal_rpc', true), '') = '1' AND current_user <> 'authenticated';
  issuer boolean := user_has_perm('quality:docs:issue');
BEGIN
  -- migrations/backfills (e.g. the legacy specs/reports backfill inserting status='issued') must not be downgraded (decision X19)
  IF session_user IN ('postgres','supabase_admin') THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    -- the existing policy lets any member INSERT: force a safe row unless the caller can issue
    IF NOT issuer AND NOT portal THEN
      NEW.status := 'draft';
      NEW.client_visible := false;
      NEW.requires_client_approval := false;
      NEW.issued_at := NULL; NEW.issued_by := NULL; NEW.supersedes := NULL;
      NEW.approval_requested_at := NULL; NEW.approved_by_client_user := NULL;
      NEW.approved_by_client_name := NULL; NEW.approved_at := NULL; NEW.approval_note := NULL;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: status/issue/visibility columns need the issue atom
  IF (NEW.status, NEW.issued_at, NEW.requires_client_approval, NEW.client_visible, NEW.supersedes)
     IS DISTINCT FROM (OLD.status, OLD.issued_at, OLD.requires_client_approval, OLD.client_visible, OLD.supersedes)
     AND NOT portal AND NOT issuer THEN
    RAISE EXCEPTION 'quality:docs:issue required to change document status';
  END IF;
  -- approval columns: only the Phase D RPC path (GUC) or quality:docs:issue
  IF (NEW.approval_requested_at, NEW.approved_by_client_user, NEW.approved_by_client_name, NEW.approved_at, NEW.approval_note)
     IS DISTINCT FROM (OLD.approval_requested_at, OLD.approved_by_client_user, OLD.approved_by_client_name, OLD.approved_at, OLD.approval_note)
     AND NOT portal AND NOT issuer THEN
    RAISE EXCEPTION 'approval columns are writable only through the portal approval RPC or with quality:docs:issue';
  END IF;
  IF NEW.status = 'approved' AND OLD.status <> 'approved' AND NEW.approved_at IS NULL THEN
    RAISE EXCEPTION 'approved_at required';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER job_drawings_guard_trg BEFORE INSERT OR UPDATE ON job_drawings
  FOR EACH ROW EXECUTE FUNCTION job_drawings_guard();
-- publish gate (domain atom quality:docs:issue) + unpublish-on-edit of drawing_no/drawing_title/revision_no: Phase A's shared function
CREATE TRIGGER job_drawings_visibility BEFORE INSERT OR UPDATE ON job_drawings
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('drawing_no,drawing_title,revision_no', 'quality:docs:issue');
CREATE TRIGGER job_drawings_audit AFTER INSERT OR UPDATE ON job_drawings
  FOR EACH ROW EXECUTE FUNCTION quality_audit();
-- Existing job_drawings RLS (member insert/update, admin delete archived) is left as is.

-- ============ KPI view (staff only, security_invoker: caller's RLS applies) ============
-- itp_total / itp_signed follow the canonical rule: denominator status<>'na', numerator 'passed'.
CREATE VIEW job_quality_summary WITH (security_invoker = true) AS
SELECT j.id AS job_id, j.company_id,
  (SELECT count(*) FROM job_itp_items i WHERE i.job_id = j.id AND i.status <> 'na') AS itp_total,
  (SELECT count(*) FROM job_itp_items i WHERE i.job_id = j.id AND i.status = 'passed') AS itp_signed,
  (SELECT count(*) FROM job_hold_points h WHERE h.job_id = j.id AND h.state = 'notified') AS hp_awaiting,
  (SELECT count(*) FROM job_drawings d WHERE d.job_id = j.id AND d.status = 'for_approval' AND NOT d.archived) AS docs_awaiting,
  (SELECT count(*) FROM job_ncrs n WHERE n.job_id = j.id AND n.status IN ('open','corrective_action','verification')) AS ncr_open,
  (SELECT count(*) FROM job_ncrs n WHERE n.job_id = j.id AND n.severity = 'minor' AND n.status IN ('open','corrective_action','verification')) AS ncr_open_minor,
  (SELECT count(*) FROM job_ncrs n WHERE n.job_id = j.id AND n.status = 'closed' AND n.closed_at >= date_trunc('month', now())) AS ncr_closed_month,
  (SELECT count(*) FROM job_drawings d WHERE d.job_id = j.id AND NOT d.archived AND d.status IN ('issued','for_approval','approved')) AS docs_latest,
  (SELECT count(*) FROM job_drawings d WHERE d.job_id = j.id AND NOT d.archived AND d.issued_at >= now() - interval '7 days') AS docs_new_week
FROM jobs j;

-- ============ RLS ============
ALTER TABLE job_itp_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "job_itp_items members read" ON job_itp_items FOR SELECT
  USING (company_id IN (SELECT my_company_ids()));
CREATE POLICY "job_itp_items writers insert" ON job_itp_items FOR INSERT
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:itp:write'));
CREATE POLICY "job_itp_items writers update" ON job_itp_items FOR UPDATE
  USING (company_id IN (SELECT my_company_ids())
         AND (user_has_perm('quality:itp:write') OR user_has_perm('quality:itp:sign')))
  WITH CHECK (company_id IN (SELECT my_company_ids())
         AND (user_has_perm('quality:itp:write') OR user_has_perm('quality:itp:sign')));
CREATE POLICY "job_itp_items writers delete" ON job_itp_items FOR DELETE
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:itp:write') AND status = 'pending');

ALTER TABLE job_hold_points ENABLE ROW LEVEL SECURITY;
CREATE POLICY "job_hold_points members read" ON job_hold_points FOR SELECT
  USING (company_id IN (SELECT my_company_ids()));
CREATE POLICY "job_hold_points managers insert" ON job_hold_points FOR INSERT
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:hold:manage'));
CREATE POLICY "job_hold_points managers update" ON job_hold_points FOR UPDATE
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:hold:manage'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:hold:manage'));
CREATE POLICY "job_hold_points managers delete" ON job_hold_points FOR DELETE
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:hold:manage') AND state = 'planned');

ALTER TABLE job_ncrs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "job_ncrs members read" ON job_ncrs FOR SELECT
  USING (company_id IN (SELECT my_company_ids()));
CREATE POLICY "job_ncrs writers insert" ON job_ncrs FOR INSERT
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:ncr:write'));
CREATE POLICY "job_ncrs writers update" ON job_ncrs FOR UPDATE
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:ncr:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('quality:ncr:write'));
CREATE POLICY "job_ncrs admins delete" ON job_ncrs FOR DELETE
  USING (company_id IN (SELECT my_company_ids()) AND is_company_admin(company_id) AND status = 'cancelled');

-- ============ permission atoms (additive jsonb merge) ============
-- erp_roles.permissions is a JSON object {atom: true} (verified live); user_has_perm has no super_admin
-- wildcard, so every atom is seeded explicitly (decision X11). Reversed in the -- down block.
UPDATE erp_roles SET permissions = permissions || jsonb_build_object(
  'quality:itp:write', true, 'quality:itp:sign', true, 'quality:hold:manage', true,
  'quality:ncr:write', true, 'quality:ncr:close', true, 'quality:docs:issue', true)
 WHERE name IN ('super_admin','company_admin');
UPDATE erp_roles SET permissions = permissions || jsonb_build_object(
  'quality:itp:write', true, 'quality:itp:sign', true, 'quality:hold:manage', true,
  'quality:ncr:write', true, 'quality:docs:issue', true)
 WHERE name = 'operations_tech';

-- ============ notification types ============
-- Staff-only quality.* keys. Client-originated decisions (hold point response, document approval)
-- use Phase D's portal.* keys; B defines no competing keys for them (decision X14).
-- erp_notifications.type = event_key; the job number goes in the title.
INSERT INTO notification_types (event_key, label, subject_tpl, body_html, recipient) VALUES
 ('quality.hold_point_notified', 'Hold point notified', 'Hold point {{hp_no}} notified on {{job_no}}', '<p>{{title}} is awaiting witness on {{witness_date}}.</p>', 'role:admin'),
 ('quality.ncr_raised', 'NCR raised', '{{ncr_no}} ({{severity}}) raised on {{job_no}}', '<p>{{title}}</p>', 'role:admin'),
 ('quality.ncr_action_overdue', 'NCR corrective action overdue', '{{ncr_no}} action overdue on {{job_no}}', '<p>{{title}} was due {{action_due}}.</p>', 'direct')
ON CONFLICT (event_key) DO NOTHING;

-- -- down (run in reverse order; all additive, nothing outside Phase B is touched)
-- DROP VIEW IF EXISTS job_quality_summary;
-- DROP TRIGGER IF EXISTS job_drawings_audit ON job_drawings;
-- DROP TRIGGER IF EXISTS job_drawings_visibility ON job_drawings;
-- DROP TRIGGER IF EXISTS job_itp_items_visibility ON job_itp_items; DROP TRIGGER IF EXISTS job_hold_points_visibility ON job_hold_points; DROP TRIGGER IF EXISTS job_ncrs_visibility ON job_ncrs;
-- DROP TRIGGER IF EXISTS job_drawings_guard_trg ON job_drawings;
-- ALTER TABLE job_drawings DROP COLUMN client_visible, DROP COLUMN legacy_source, DROP COLUMN supersedes,
--   DROP COLUMN approval_note, DROP COLUMN approved_at, DROP COLUMN approved_by_client_name,
--   DROP COLUMN approved_by_client_user, DROP COLUMN approval_requested_at,
--   DROP COLUMN requires_client_approval, DROP COLUMN issued_by, DROP COLUMN issued_at,
--   DROP COLUMN status, DROP COLUMN doc_type;
-- DROP TABLE IF EXISTS job_ncrs; DROP TABLE IF EXISTS job_hold_points; DROP TABLE IF EXISTS job_itp_items;
-- DROP FUNCTION IF EXISTS job_drawings_guard(), job_itp_items_guard(), job_ncrs_guard(), job_hold_points_guard(),
--   job_ncrs_set_no(), quality_audit(), quality_next_no(uuid,text,text);
-- (set_updated_at() and job_visibility_guard() are shared and are NOT dropped here.)
-- DELETE FROM notification_types WHERE event_key IN ('quality.hold_point_notified','quality.ncr_raised','quality.ncr_action_overdue');
-- UPDATE erp_roles SET permissions = permissions - 'quality:itp:write' - 'quality:itp:sign' - 'quality:hold:manage'
--   - 'quality:ncr:write' - 'quality:ncr:close' - 'quality:docs:issue';
-- (the quality:* atoms are removed by the UPDATE above; job_audit_log rows and sequence_counters 'ncr' rows are kept as history.)
```

### Lifecycles

**Hold point**: `planned` (staff creates, optionally links ITP item and task) -> `notified` (staff sends the witness request with `witness_date`; sets `client_visible=true` if the client is the witness) -> `witnessed` (response `accepted`) or `waived` (response `waived`, or staff waiver with `waiver_ref`) -> `released` (staff, work may proceed). A client `rejected` response returns the state to `planned` with `response_note` and prompts an NCR. Re-notifying (`planned` -> `notified`) resets `response`, `response_note` and all `responded_*` columns so stale answers never show. Release and waive are terminal-safe: released rows are immutable.

**NCR**: `open` -> `corrective_action` (owner and due date set) -> `verification` (action done) -> `closed` (verifier recorded; major/critical additionally require `ops:work-orders:approve`). Verification may bounce back to `corrective_action`. `cancelled` is allowed before verification (raised in error).

**ITP item sign-off**: `pending` -> `passed` | `failed` | `waived` | `na`. Staff record the inspector in `signed_off_by`; if the client witnessed the test, staff record the result on the client's behalf and note the witness in `result_notes` (decision X8: no client sign-off columns or RPC exist). A `failed` item prompts "Raise NCR" prefilled with `itp_item_id`.

**Document**: `draft` -> `issued` (sets `issued_at`/`issued_by`) -> optionally `for_approval` (if `requires_client_approval`, sets `approval_requested_at`) -> `approved` | `rejected`. Approval columns are written only by Phase D's RPC (GUC path) or by staff holding `quality:docs:issue`. A new revision row sets `supersedes` to the previous row, which flips to `superseded` and **keeps** its `client_visible` value (decision X9: superseded rows stay visible to clients for history, labelled). Statuses map to mockup chips: Approved, For your approval, Issued.

## RLS and permissions

- All three tables: RLS enabled; SELECT for company members (matching `job_tasks`); writes require the new atoms (policies above). `user_has_perm` is not company-scoped, so every policy pairs it with `company_id IN (SELECT my_company_ids())`.
- Column-level rules RLS cannot express are enforced by `BEFORE UPDATE` triggers (state machine, sign-off, close, document status). Triggers are SECURITY DEFINER, but `user_has_perm()` reads `auth.uid()`, so it evaluates the caller. The hold point and document guards (SECURITY INVOKER) honour an `app.portal_rpc` transaction setting that only Phase D SECURITY DEFINER RPCs set, so the client path never needs staff atoms. ITP guards have no such bypass.
- `job_drawings` existing policies are unchanged. They let any member INSERT and UPDATE any column, so the guard trigger (now `BEFORE INSERT OR UPDATE`) is what stops a viewer from inserting an already-approved or client-visible drawing, forging `approved_by_client_*` / `approved_at` / `approval_note`, or marking a drawing approved.
- **The `app.portal_rpc` control (decision X6, revised)**: the four guard functions (`job_hold_points_guard`, `job_ncrs_guard`, `job_itp_items_guard`, `job_drawings_guard`) are `SECURITY INVOKER`; they need only `user_has_perm()`, which is itself SECURITY DEFINER and reads `auth.uid()`. The portal bypass is `current_setting('app.portal_rpc', true) = '1' AND current_user <> 'authenticated'`: inside a Phase D SECURITY DEFINER RPC `current_user` is the function owner, while on a direct REST call it is `authenticated`, so setting the GUC alone is not enough. Further layers: clients have no `erp_users` row, so `my_company_ids()` is empty and every Phase B policy denies them; Phase D0 adds the restrictive `is_erp_staff()` policy; PostgREST only calls exposed-schema functions and cannot set arbitrary GUCs. Verified live (2026-10-19): no function callable by `authenticated` uses `set_config` or dynamic SQL, so no RPC lets a caller set the GUC inside a definer context; `set_config` is executable by PUBLIC only at the SQL level (not exposed via REST). Residual risk: a future staff-callable SECURITY DEFINER function that calls `set_config('app.portal_rpc',...)` or runs dynamic SQL would reopen the bypass; the Q-D definer sweep (inventory queries Q-A..Q-E) must be re-run after every migration to catch that.
- **New atoms and roles** (verified against live `erp_roles`):

| Atom | super_admin | company_admin | operations_tech | viewer | finance_manager | sales_rep | Office Admin |
|---|---|---|---|---|---|---|---|
| `quality:itp:write` (create/edit items) | yes | yes | yes | no | no | no | no |
| `quality:itp:sign` | yes | yes | yes | no | no | no | no |
| `quality:hold:manage` (notify/witness/waive/release) | yes | yes | yes | no | no | no | no |
| `quality:ncr:write` (raise/progress) | yes | yes | yes | no | no | no | no |
| `quality:ncr:close` | yes | yes | no | no | no | no | no |
| `quality:docs:issue` (issue/request approval/supersede) | yes | yes | yes | no | no | no | no |

All other roles read quality data through company membership but cannot write. Viewing needs no new atom.

- **Pre-existing exposure, owned by Phase D0 (decision X12)**: `job_audit_log` allows every authenticated user to read and write every row (`USING true`, no `company_id`). Phase B writes into it, so quality events are visible across companies until D0 replaces the policy. B does **not** change that policy; B depends on D0 for it and only requires that D0 verify the ERP's own audit insert path (and B's SECURITY DEFINER `quality_audit()` triggers) still work after the change. `config_qc_checklists` has the same `true` policy; low risk, covered by D0's sweep.

## Staff UI (ERP)

A new **Quality** card in the job form (`index.html`, placed after "Schedule & Tasks"), visible to anyone with `ops:work-orders:read`; controls render only when the matching atom is held (use `canAny`-style helpers, e.g. `canQuality('itp:sign')`). Inline-save rows (insert on add, PATCH on change), `escHTML` on every string.

```
Quality
+-- KPI strip (job_quality_summary row for jcCurrentJobId)
|   [ITP  itp_signed / itp_total signed off] [Awaiting approval  hp_awaiting+docs_awaiting
|    (hp_awaiting hold points · docs_awaiting drawing)] [Open NCRs ncr_open (ncr_open_minor minor) · closed this month ncr_closed_month]
|   [Documents issued docs_latest latest revs · docs_new_week new this week]
+-- ITP table (job_itp_items order sort_order)
|   # item_no | Description | Type | Acceptance | Status chip | Signed by/at | [Sign: Pass/Fail/Waive/N/A]
|   Buttons: [+ Item] [Generate from template] [Import legacy QC] [Raise NCR] on failed rows
|   Sign dialog: result, notes (result_notes, incl. client witness name if applicable), evidence_ref; shown only with quality:itp:sign
+-- Hold points (job_hold_points)
|   HP-02 title | linked ITP item | state chip | witness_date | response | [Notify] [Record response] [Waive (waiver_ref)] [Release]
|   Buttons follow the state machine: only legal next actions render
+-- NCRs (job_ncrs)
|   ncr_no | title | severity chip | status chip | owner | due | links (task / ITP / drawing) | [Advance]
|   Edit drawer: description, root_cause, corrective_action, owner, due, verification, internal_notes, client_visible
+-- Documents (existing Drawings register, extended)
    Doc no | Title | Rev | Type | Status chip | Issued at | Needs client approval | [Issue] [Request approval] [New revision]
    Specs / Reports tables become filtered views of the same register (doc_type) once backfilled.
```

Bindings: ITP and hold point rows to their tables by `job_id`; "Generate from template" calls `sbGet('config_qc_checklists','status=eq.approved&is_active=eq.true&job_type=in.(<type>,All)')` then bulk `sbPost`. "Import legacy QC" reads `jobs.qc_state`. NCR number is read back from the insert response (`ncr_no` sent as empty string). The Work Orders list gets an optional "Quality" column showing `ncr_open` and `hp_awaiting` from `job_quality_summary`.

Notifications: on hold point notify and NCR raise the client code inserts `erp_notifications` rows (`user_id` = target `erp_users.id`, `type` = the staff-only `quality.*` event key, job number in the title since the table has no job column, `task_id` null) and relies on the existing email delivery for the `notification_types` rows added above. Notifying the **client** of a hold point or a document for approval, and notifying staff of a client's decision, are Phase D's `portal.*` events (driven from `job_hold_points.notified_at` and `job_drawings.approval_requested_at`); B defines no keys for them. `quality.ncr_action_overdue` is evaluated by a pg_cron job following the `20260622_pg_cron_overdue_notifications.sql` pattern (separate small migration in rollout step 4).

## Client-facing surface

None in Phase B: no client login exists yet, and no client-readable object is created. What Phase B guarantees for Phase D (D reads only through `portal_*` functions, e.g. `portal_quality` and `portal_documents`, filtering `client_visible = true`):

- Hold points: `hp_no, title, state, witness_date, response, response_note`; actions via RPC (accept, reject, waive) that set `app.portal_rpc`, write `responded_client_user/name` and move `notified` -> `witnessed|waived|planned`. Never `internal_notes`, `waiver_ref`, internal user ids.
- Documents: `drawing_no, drawing_title, revision_no, doc_type, status, issued_at, requires_client_approval` where `client_visible` and status in issued, for_approval, approved, rejected, superseded (never draft; superseded rows keep their `client_visible` value and are labelled; decision X9); approval via RPC; file access by a signed URL generated server-side for that row only.
- NCRs: only `client_visible` rows, columns `ncr_no, title, severity, status, corrective_action, action_due`; never `root_cause`, `internal_notes`, `raised_by`. **Decision (round 2):** staff intend clients to see `severity` and `action_due` (only NCRs staff chose to publish are shown, and the due date is the commitment on display). Phase D's `portal_quality` MUST therefore return NCR `severity` and `action_due`, and hold point `response`; they are listed explicitly here as part of the client-facing surface.
- ITP items: `item_no, description, status, signed_off_at, result_notes` where `client_visible`. Read-only for the client: there is no client sign-off (decision X8). Tile counts use the canonical rule (numerator `passed`, denominator `status <> 'na'`).
- Aggregates for the four tiles can be recomputed in a `portal_*` function (`portal_project_kpis`) counting only `client_visible` rows (the internal `job_quality_summary` must not be exposed, since it counts hidden rows). No cost columns exist in any Phase B table.

## Migration and rollout

1. **B1 (schema)**: apply the migration above to a branch DB, then production, as `supabase/migrations/YYYYMMDDHHMM_b_quality.sql` (timestamped name, decision X16). B is applied strictly AFTER Phase A (decision X23): the four `*_visibility` triggers call A's `job_visibility_guard()`. B may be developed in parallel, but its branch-DB test run needs A's migration applied first. Fully additive; existing screens keep working because new `job_drawings` columns have defaults. Run the legacy-source backfill (specs/reports JSONB -> `job_drawings` rows with `doc_type`, `legacy_source`, `status='issued'`) as a separate, idempotent script keyed by `(job_id, legacy_source, ref)`, executed as postgres/supabase_admin so the guards' `session_user` exemption preserves `status='issued'` (a PostgREST/staff-JWT run would be forced to draft).
2. **B2 (ERP UI, read paths)**: Quality card with KPI strip, ITP, hold points, NCRs; permission-gated controls.
3. **B3 (bridge)**: Generate-from-template and Import-legacy-QC; hide the legacy QC grid on jobs that have ITP items. Specs/Reports registers read from `job_drawings` when backfilled rows exist, else from JSONB.
4. **B4** (`YYYYMMDDHHMM_b4_ncr_overdue_cron.sql`, last in the order of decision X16): overdue NCR pg_cron notification only. The `job_audit_log` policy fix is **not** part of B; it belongs to Phase D0 (decision X12), which B depends on before any client login exists.
Rollback: hide the card; run the commented `-- down`. Because JSONB sources and `qc_state` are never modified, no data is lost by rolling back.

## Test plan

- Migration on a branch DB: apply, run `-- down`, re-apply; confirm existing job form saves drawings and QC unchanged.
- RLS with real users (not service role): operations_tech can create/sign/notify; viewer can SELECT but INSERT/UPDATE fails on all three tables; a user from company B sees zero rows of company A; viewer cannot flip a drawing to `approved` (trigger error).
- **Forged INSERT on `job_drawings`** (as viewer or sales_rep): INSERT with `client_visible=true, status='approved'` (and separately `'for_approval'`, `requires_client_approval=true`, `approved_by_client_name='X'`, `approved_at=now()`, `approval_note='x'`) succeeds only as a draft: the row stores `status='draft', client_visible=false, requires_client_approval=false` and null approval columns. The same INSERT as operations_tech (holds `quality:docs:issue`) keeps the values. UPDATE of any approval column as viewer raises; the same with `app.portal_rpc='1'` set in a test transaction succeeds (simulating the D RPC).
- Publish gate (guards attached with their two arguments, decision X19): flipping `client_visible=true` on an ITP item, hold point, NCR or document as a user lacking both `ops:work-orders:approve` and the domain atom fails via `job_visibility_guard()`; each flip writes a `visibility_changed` audit row.
- **Wording edit unpublishes**: for each of the four tables, editing a wording column of a visible row (ITP `result_notes`, hold point `response_note`, NCR `corrective_action`, document `drawing_title`) as a staff user sets `client_visible=false` and writes a `visibility_changed` row (reason `wording_edited`); editing a non-wording column (ITP `internal_notes`, NCR `status`) leaves it visible.
- **Domain atom publishes without approve**: a user holding `quality:docs:issue` (resp. `quality:itp:sign`, `quality:hold:manage`, `quality:ncr:write`) but NOT `ops:work-orders:approve` can set `client_visible=true` on the matching table and cannot on the other tables.
- **Migration/backfill exemption**: an INSERT of a `job_drawings` row with `status='issued'` as `postgres` (SQL editor / migration) keeps `status='issued'` and is not downgraded; the same INSERT through a staff JWT lacking `quality:docs:issue` is forced to draft. Likewise a postgres-session UPDATE of a hold point/NCR/ITP row skips the state-machine and permission guards.
- `quality_next_no`, `job_ncrs_set_no` and `quality_audit` are not callable: `SELECT` of each as `anon` and as `authenticated` (via `/rpc`) returns permission denied, while an NCR insert by a writer still gets a number.
- Hold point re-notify after a client `rejected` response clears `response`, `response_note` and all `responded_*` columns.
- Duplicate audit: with `app.portal_rpc='1'` set, a hold point transition adds no `quality_audit` row; without it, exactly one row with `username` = `erp_users.full_name`.
- Bypass needs both conditions: as an `authenticated` REST client with `app.portal_rpc` forced to '1' (e.g. a test that sets it in the same SQL session before a direct UPDATE under `SET ROLE authenticated`), a hold point or drawing approval change is still rejected; only a test SECURITY DEFINER wrapper owned by the function owner may pass.
- State machine: every illegal transition raises; `released` and `closed` rows reject edits; waive without `waiver_ref` fails; closing a major NCR as a user lacking `ops:work-orders:approve` fails.
- Numbering: two concurrent NCR inserts get distinct numbers; first NCR for a company creates the `sequence_counters` row.
- Audit: each transition adds one `job_audit_log` row with the correct `job_no`, user and from/to metadata.
- KPI view numbers on a seed job reproduce the mockup (11/16, 2 awaiting, 1 minor open and 2 closed this month, 38 latest, 3 new); a seed with `waived` and `na` items proves numerator = `passed`, denominator excludes `na`.
- Bridge: Generate from template with an empty catalogue shows a clear empty state; Import legacy QC maps pass/fail/blank correctly and is idempotent (second run adds nothing).
- Security: `escHTML` on all rendered strings; `client_visible` defaults false on every insert path.

## Risks

- **`user_has_perm` is not company-scoped**: a user with the atom in one company passes the perm check in another, but `my_company_ids()` still scopes rows. Acceptable, same as `job_tasks`.
- **`job_audit_log` `true` policy** leaks quality events across companies and to future client users (see RLS section); fixed by Phase D0, which B depends on before Phase D.
- **Dual sources of truth** (`qc_state` vs ITP). Mitigated by hiding the legacy grid once ITP items exist and no sync.
- **Guard triggers (SECURITY INVOKER) depend on `user_has_perm()` (a SECURITY DEFINER helper) evaluating the caller via `auth.uid()`**; verify in the branch test before relying on it. The `app.portal_rpc` GUC alone is not trusted: the bypass also requires `current_user <> 'authenticated'`, true only inside Phase D SECURITY DEFINER RPCs (decision X6, revised). The residual risk is a future staff-callable SECURITY DEFINER function that sets the GUC or runs dynamic SQL (none exists today, verified live); keep the Q-D definer sweep in every migration review. Phase D must keep the client path RPC-only and keep D0's `is_erp_staff()` restrictive policy.
- `config_qc_checklists` is empty live, so template generation yields nothing until the catalogue is seeded.
- Backfilled legacy documents have no files; the register must tolerate null `storage_key`.
- Status backfill assumption: legacy drawings with a stored file become `issued` (see Open questions).

## Open questions

1. **Seed ITP template with inspection type and hold-point flag?** Adding `inspection_type` / `is_hold_point` to `config_qc_checklists` alters a table outside Phase B's reservation. Default: do not alter in Phase B; users add hold points manually per job; revisit with a ITP-template table in a later phase.
2. **Should received client drawings (`source='Client'`) count as "issued"?** Default: backfill all drawings that have a stored file to `issued`, and have the Documents KPI count only non-draft, non-archived rows; staff can bulk-set `client_visible` afterwards.
3. **Who closes minor NCRs?** Default: `quality:ncr:close` is admin-only (company_admin, super_admin) for all severities; revisit if operations_tech must close minors, in which case grant the atom and keep the major/critical approval requirement.
4. **Block job completion with open NCRs or unreleased hold points?** Default: warn on status change to Completed, do not block.
5. **Should a separate `job_documents` table replace the `doc_type` generalisation?** Default: no, keep one register in `job_drawings` (reserved-table rule); revisit only if document metadata diverges.
6. **Stop writing specs/reports JSONB after backfill?** Default: keep dual-readable for one release, then ERP writes only the register; JSONB never dropped in Phase B.
7. **ITP sign-off count: settled (decision X8).** Numerator `passed`; `waived` shown separately; denominator `status <> 'na'`. Retained here only as a record.
8. **Hold point rejection by the client**: default returns to `planned` and prompts an NCR rather than introducing a `rejected` state.

## Acceptance criteria

1. Migration applies cleanly on a branch DB and `-- down` restores the prior schema; existing drawing and QC features work unchanged.
2. `job_itp_items`, `job_hold_points`, `job_ncrs` exist with RLS and four policies each; a non-privileged test user is blocked as specified in the test plan.
3. Hold point and NCR state machines enforce only the transitions above; waive requires `waiver_ref`; closing requires verification and permission.
4. `job_drawings` has doc type, status, issue, approval, supersedes and `client_visible` columns; status changes and approval columns require `quality:docs:issue` (or the Phase D RPC path), and INSERT is forced to a safe draft for other callers; legacy specs/reports are registered with `doc_type`.
5. The Quality card shows the four KPI tiles, ITP table with sign-off, hold point actions, NCR list and the extended document register, bound as described; controls respect the new atoms.
6. Generate-from-template and Import-legacy-QC work and are idempotent; legacy QC grid still works on jobs without ITP items.
7. Every transition writes one `job_audit_log` row (none duplicated when `app.portal_rpc` is set); NCR numbers come from `sequence_counters` without duplicates and `quality_next_no`, `job_ncrs_set_no` and `quality_audit` are revoked from PUBLIC, anon and authenticated.
8. No Phase B object is readable by a client; every table has `client_visible` default false and a documented column whitelist for Phase D.
