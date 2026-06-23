# Drawing PDF Upload — Design Spec
**Date:** 2026-06-23  
**Project:** Meridian ERP (`meridian-erp/index.html`)  
**Scope:** Drawing Control Register — PDF upload, view, archive, and hard-delete

---

## 1. Problem

The Drawing Control Register stores metadata (drawing number, title, revision, date, source) but has no way to attach or view the actual drawing PDF. Drawings are proprietary engineering documents; users need to open them during job execution without leaving the ERP.

---

## 2. Architecture

### 2.1 Supabase Storage

- **Bucket:** `job-drawings` (private — no public URL access)
- **File path:** `{company_id}/{job_id}/{timestamp}-{original_filename}`
- **Access:** authenticated company members can upload and generate signed URLs; only admins can delete storage objects
- **Signed URL TTL:** 3600 seconds (1 hour)

### 2.2 Database — new table `job_drawings`

Replaces the `jobs.drawings` JSONB column for all new operations.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK DEFAULT gen_random_uuid() | |
| `job_id` | UUID NOT NULL FK → jobs(id) ON DELETE CASCADE | |
| `company_id` | UUID NOT NULL FK → companies(id) | scopes RLS |
| `drawing_no` | TEXT | |
| `drawing_title` | TEXT | |
| `revision_no` | TEXT | |
| `date` | DATE | |
| `source` | TEXT DEFAULT 'Client' | 'Client' or 'Internal' |
| `storage_key` | TEXT | full path in bucket; NULL when no PDF attached |
| `archived` | BOOLEAN NOT NULL DEFAULT false | |
| `archived_at` | TIMESTAMPTZ | |
| `archived_by` | UUID FK → erp_users(id) | |
| `created_at` | TIMESTAMPTZ NOT NULL DEFAULT now() | |
| `created_by` | UUID FK → erp_users(id) | |

### 2.3 RLS Policies

| Operation | Who | Condition |
|---|---|---|
| SELECT | Company members | `company_id = any(my_company_ids()) AND archived = false` |
| SELECT (archived) | Admins | `company_id = any(my_company_ids()) AND is_company_admin(company_id)` |
| INSERT | Company members | `company_id = any(my_company_ids())` |
| UPDATE | Company members | `company_id = any(my_company_ids())` |
| DELETE | Admins only | `company_id = any(my_company_ids()) AND is_company_admin(company_id) AND archived = true` |

`my_company_ids()` already exists in the schema. `is_company_admin(cid UUID)` must be created — checks if the calling user has `admin:users` OR `admin:settings` permission in the given company (mirrors client-side `isAdmin()` at index.html line 5567). `is_admin()` does **not** exist; `is_super_admin()` checks a different permission (`admin:companies`) and must not be used here.

---

## 3. Data Flow

### 3.1 Load

`jcLoadJobData()` fetches `job_drawings` rows for the current `job_id` via `sbGet('job_drawings?job_id=eq.{id}&order=created_at.asc')`. RLS filters archived rows for non-admins automatically. Renders into the table; rows with `storage_key != null` show 📄 View; rows without show ⬆ Upload.

### 3.2 Add Row

`jcAddDrawingRow()` — if job is unsaved (no `id`), show toast "Save the job before adding drawings" and abort. Otherwise, INSERT a new `job_drawings` row immediately via `sbPost`. Render the returned row including its `id`.

### 3.3 Upload PDF

1. User clicks ⬆ Upload → hidden `<input type="file" accept=".pdf">` triggers
2. Client validates: PDF MIME type + file size ≤ 20 MB
3. Inline spinner: "Uploading…"
4. `PUT ${SUPABASE_URL}/storage/v1/object/job-drawings/{storage_key}` with Bearer token (same pattern as company-logos, line 9763)
5. On success: PATCH `job_drawings` row with `storage_key`
6. Button swaps to 📄 View + ↺ replace icon

### 3.4 View PDF

1. User clicks 📄 View
2. `POST ${SUPABASE_URL}/storage/v1/object/sign/job-drawings/{storage_key}` with body `{ "expiresIn": 3600 }`
3. Get `signedURL` from response
4. `window.open(SUPABASE_URL + signedURL, '_blank')` — browser renders PDF natively

### 3.5 Archive (soft delete)

Delete (✕) button → confirm dialog: *"Move [Drawing No.] to archive?"*  
On confirm: PATCH `{ archived: true, archived_at: now(), archived_by: currentUser.id }`.  
Row disappears from active register, appears in collapsed archived section (admin-only).

### 3.6 Hard Delete (admin only)

From archived section → "Delete Permanently" button → user must type `DELETE` to confirm.  
On confirm:
1. `DELETE ${SUPABASE_URL}/storage/v1/object/job-drawings` with body `{ "prefixes": [storage_key] }` (if `storage_key` exists)
2. DELETE `job_drawings` row
3. If storage delete fails (object already missing), proceed with DB delete and log warning to console

### 3.7 Restore

"Restore" button in archived section → PATCH `{ archived: false, archived_at: null, archived_by: null }` → row moves back to active register.

### 3.8 Save Job

`jcSaveJob()` no longer serializes drawings to JSONB. The `jobs.drawings` column is left in place but ignored by the JS going forward.

Persistence split by operation type:
- **Immediate** (own DB call, not deferred to Save): Add Row (INSERT), Upload (PATCH `storage_key`), Archive, Restore, Hard Delete
- **On Save Job click** (batched with the rest of the job): field edits to `drawing_no`, `drawing_title`, `revision_no`, `date`, `source` — collected from the DOM and PATCHed per changed row when the user hits Save

This keeps UX consistent with the existing dirty-flag pattern (`jcMarkDirty`) while ensuring uploads and archives are never lost if the user navigates away without saving.

---

## 4. UI Changes

### 4.1 Active Register

New **PDF** column inserted between Source and the delete (✕) button:

| Drawing No. | Drawing Title | Revision No. | Date | Source | PDF | ✕ |
|---|---|---|---|---|---|---|
| DWG-001 | Pump Layout | Rev A | 2026-06-01 | Client | 📄 View ↺ | ✕ |
| DWG-002 | Wiring Diagram | Rev B | 2026-06-10 | Internal | ⬆ Upload | ✕ |

- ⬆ Upload: small button, triggers hidden file input
- Uploading state: spinner + "Uploading…" text, input disabled
- 📄 View: opens signed URL in new tab
- ↺ (replace): triggers file input again, overwrites storage object and updates `storage_key`
- ✕ delete: soft-archive, not hard delete — confirm dialog uses archive language

### 4.2 Archived Section (admin-only)

Rendered below the active register and "+ Add Drawing" button:

```
▶ Archived Drawings (2)    ← collapsed by default, click to toggle
```

Expanded: same columns as active register + **Restore** button + **Delete Permanently** (red) button per row. "Delete Permanently" requires typing `DELETE` in a confirm input before proceeding.

---

## 5. Migration

One-time SQL migration (applied via `apply_migration`):

```sql
-- Create job_drawings table
CREATE TABLE public.job_drawings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id        UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  drawing_no    TEXT,
  drawing_title TEXT,
  revision_no   TEXT,
  date          DATE,
  source        TEXT DEFAULT 'Client',
  storage_key   TEXT,
  archived      BOOLEAN NOT NULL DEFAULT false,
  archived_at   TIMESTAMPTZ,
  archived_by   UUID REFERENCES public.erp_users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID REFERENCES public.erp_users(id)
);

-- Migrate existing JSONB drawing rows
INSERT INTO public.job_drawings (job_id, company_id, drawing_no, drawing_title, revision_no, date, source, created_at)
SELECT
  j.id AS job_id,
  j.company_id,
  d->>'Drawing No'    AS drawing_no,
  d->>'Drawing Title' AS drawing_title,
  d->>'Revision No'   AS revision_no,
  NULLIF(d->>'Date', '')::DATE AS date,
  COALESCE(d->>'Source', 'Client') AS source,
  now() AS created_at
FROM public.jobs j,
     jsonb_array_elements(j.drawings) AS d
WHERE j.drawings IS NOT NULL
  AND jsonb_array_length(j.drawings) > 0;

-- RLS
ALTER TABLE public.job_drawings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "company members read active drawings"
  ON public.job_drawings FOR SELECT
  USING (company_id = ANY(my_company_ids()) AND archived = false);

CREATE POLICY "admins read all drawings"
  ON public.job_drawings FOR SELECT
  USING (company_id = ANY(my_company_ids()) AND is_company_admin(company_id));

CREATE POLICY "company members insert drawings"
  ON public.job_drawings FOR INSERT
  WITH CHECK (company_id = ANY(my_company_ids()));

CREATE POLICY "company members update drawings"
  ON public.job_drawings FOR UPDATE
  USING (company_id = ANY(my_company_ids()));

CREATE POLICY "admins delete archived drawings"
  ON public.job_drawings FOR DELETE
  USING (company_id = ANY(my_company_ids()) AND is_company_admin(company_id) AND archived = true);
```

The migration must also create `is_company_admin(cid UUID)` before the policies above:

```sql
CREATE OR REPLACE FUNCTION public.is_company_admin(cid UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1
    FROM erp_users eu
    JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id AND ucr.company_id = cid
    JOIN erp_roles r ON r.id = ucr.role_id
    WHERE eu.auth_user_id = auth.uid()
      AND eu.is_active = true
      AND (
        (r.permissions->>'admin:users')::boolean = true
        OR (r.permissions->>'admin:settings')::boolean = true
      )
  )
$$;
```

> `my_company_ids()` already exists. `is_company_admin()` is new — mirrors `isAdmin()` in index.html line 5567.

---

## 6. Error Handling

| Scenario | Behaviour |
|---|---|
| Non-PDF file selected | Reject before upload: inline error "Only PDF files are accepted" |
| File > 20 MB | Reject before upload: inline error "File must be under 20 MB" |
| Upload fails | Inline error on row, button reverts to ⬆ Upload |
| Signed URL generation fails | Toast: "Could not open drawing — try again" |
| Hard delete — storage object missing | Proceed with DB row delete, `console.warn` |
| "+ Add Drawing" on unsaved job | Toast: "Save the job before adding drawings", button disabled |
| Job deleted (ON DELETE CASCADE) | All `job_drawings` rows auto-deleted by FK cascade; storage objects become orphaned (acceptable — no automatic cleanup) |

---

## 7. Out of Scope

- PDF preview inside the ERP (browser native rendering via new tab is sufficient)
- Drawing version history beyond what the register rows provide
- Automatic cleanup of orphaned storage objects when a job is deleted
- Specs register and Reports register (same pattern could be applied later)
