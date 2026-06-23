# Drawing PDF Upload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PDF upload/view/archive to the Drawing Control Register, backed by a private Supabase Storage bucket and a dedicated `job_drawings` table migrated from JSONB.

**Architecture:** Drawings move from `jobs.drawings` JSONB to a `job_drawings` table with RLS. A private `job-drawings` Storage bucket holds PDFs; viewing requires a signed URL (1 hr TTL). Delete is always soft-archive; hard delete (admin only) removes both the DB row and the storage object.

**Tech Stack:** Vanilla JS (single-file `index.html`), Supabase REST API (storage + PostgREST), Supabase MCP tools.

**Key globals used throughout:**
- `jcCurrentJobId` — UUID of the open job, `null` if unsaved
- `currentCompany.id` — current company UUID
- `currentUser.id` — ERP user UUID (`erp_users.id`)
- `_accessToken` — JWT; `SUPABASE_KEY` — anon key; `SUPABASE_URL` — project URL
- `sbGet(table, params)`, `sbPost(table, body)`, `sbPatch(table, id, body)`, `sbDelete(table, id)` — thin fetch wrappers (lines 5714–5720)
- `showToast(msg, type)`, `showConfirm(msg, title, label)` — UI helpers
- `nowISO()` — ISO timestamp string (line 5653)
- `isAdmin()` — client-side admin check (line 5567)

---

## Task 1: Supabase Backend — Bucket + Migration

**Files:**
- No source files modified — Supabase MCP only

- [ ] **Step 1: Create the storage bucket**

Use the Supabase MCP `execute_sql` tool on project `fcagxvjxfqqkmuposmcb`:

```sql
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'job-drawings',
  'job-drawings',
  false,
  20971520,
  ARRAY['application/pdf']
)
ON CONFLICT (id) DO NOTHING;
```

- [ ] **Step 2: Add storage RLS policies**

```sql
CREATE POLICY "job-drawings auth upload"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-drawings');

CREATE POLICY "job-drawings auth read"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-drawings');

CREATE POLICY "job-drawings auth delete"
  ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'job-drawings');
```

- [ ] **Step 3: Apply DB migration**

Use the Supabase MCP `apply_migration` tool on project `fcagxvjxfqqkmuposmcb` with name `create_job_drawings`:

```sql
-- Helper function: mirrors client-side isAdmin() at index.html:5567
CREATE OR REPLACE FUNCTION public.is_company_admin(cid UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM erp_users eu
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

-- New table replacing jobs.drawings JSONB
CREATE TABLE public.job_drawings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id        UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  drawing_no    TEXT,
  drawing_title TEXT,
  revision_no   TEXT,
  date          DATE,
  source        TEXT DEFAULT 'Client',
  storage_key   TEXT,           -- path in bucket; NULL = no PDF yet
  archived      BOOLEAN NOT NULL DEFAULT false,
  archived_at   TIMESTAMPTZ,
  archived_by   UUID REFERENCES public.erp_users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ,    -- auto-set by sbPatch() wrapper
  created_by    UUID REFERENCES public.erp_users(id)
);

ALTER TABLE public.job_drawings ENABLE ROW LEVEL SECURITY;

-- Non-admins see only active rows; admins see everything (policies are OR'd)
CREATE POLICY "job_drawings members read active"
  ON public.job_drawings FOR SELECT
  USING (company_id = ANY(my_company_ids()) AND archived = false);

CREATE POLICY "job_drawings admins read all"
  ON public.job_drawings FOR SELECT
  USING (company_id = ANY(my_company_ids()) AND is_company_admin(company_id));

CREATE POLICY "job_drawings members insert"
  ON public.job_drawings FOR INSERT
  WITH CHECK (company_id = ANY(my_company_ids()));

CREATE POLICY "job_drawings members update"
  ON public.job_drawings FOR UPDATE
  USING (company_id = ANY(my_company_ids()));

CREATE POLICY "job_drawings admins delete archived"
  ON public.job_drawings FOR DELETE
  USING (
    company_id = ANY(my_company_ids())
    AND is_company_admin(company_id)
    AND archived = true
  );

-- Migrate existing JSONB rows (no storage_key — PDF upload is optional per row)
INSERT INTO public.job_drawings
  (job_id, company_id, drawing_no, drawing_title, revision_no, date, source, created_at)
SELECT
  j.id,
  j.company_id,
  d->>'Drawing No',
  d->>'Drawing Title',
  d->>'Revision No',
  NULLIF(d->>'Date', '')::DATE,
  COALESCE(NULLIF(d->>'Source', ''), 'Client'),
  now()
FROM public.jobs j,
     jsonb_array_elements(j.drawings) AS d
WHERE j.drawings IS NOT NULL
  AND jsonb_array_length(j.drawings) > 0;
```

- [ ] **Step 4: Verify migration**

```sql
SELECT COUNT(*) FROM public.job_drawings;
-- Should equal sum of drawing array lengths across all jobs
-- e.g. SELECT SUM(jsonb_array_length(drawings)) FROM jobs WHERE drawings IS NOT NULL AND jsonb_array_length(drawings) > 0;
```

---

## Task 2: HTML — Update Drawing Register Structure

**Files:**
- Modify: `index.html:3179–3184`

- [ ] **Step 1: Add PDF column header and archived section placeholder**

Find (line 3179–3184):
```html
                <div class="dyn-table-wrap"><table class="register-table"><thead><tr>
                  <th style="width:120px">Drawing No.</th><th>Drawing Title</th>
                  <th style="width:90px">Revision No.</th><th style="width:120px">Date</th>
                  <th style="width:120px">Source</th><th style="width:32px"></th>
                </tr></thead><tbody id="jc-drawings-body"></tbody></table></div>
                <button class="btn-add-row" onclick="jcAddDrawingRow()">+ Add Drawing</button>
```

Replace with:
```html
                <div class="dyn-table-wrap"><table class="register-table"><thead><tr>
                  <th style="width:120px">Drawing No.</th><th>Drawing Title</th>
                  <th style="width:90px">Revision No.</th><th style="width:120px">Date</th>
                  <th style="width:120px">Source</th><th style="width:100px">PDF</th><th style="width:32px"></th>
                </tr></thead><tbody id="jc-drawings-body"></tbody></table></div>
                <button class="btn-add-row" onclick="jcAddNewDrawingRow()">+ Add Drawing</button>
                <div id="jc-archived-drawings" style="display:none;margin-top:10px;">
                  <div class="jc-archive-toggle" onclick="jcToggleArchivedDrawings()" style="cursor:pointer;font-size:12px;color:var(--text-muted);padding:4px 0;">
                    <span id="jc-archived-drawings-chevron">▶</span> Archived Drawings (<span id="jc-archived-drawings-count">0</span>)
                  </div>
                  <div id="jc-archived-drawings-body" style="display:none;margin-top:6px;"></div>
                </div>
```

- [ ] **Step 2: Add minimal CSS for new PDF cell buttons**

Find the `/* Register tables (drawings, specs, reports) */` comment (line ~1383) and add after the existing register table CSS block:

```css
.btn-upload-pdf { font-size:11px; padding:2px 6px; border:1px solid var(--border); border-radius:4px; background:var(--bg-card); cursor:pointer; color:var(--text-muted); }
.btn-upload-pdf:hover { background:var(--primary); color:#fff; border-color:var(--primary); }
.btn-view-pdf { font-size:11px; color:var(--primary); text-decoration:none; margin-right:4px; }
.btn-view-pdf:hover { text-decoration:underline; }
.btn-replace-pdf { font-size:11px; background:none; border:none; cursor:pointer; color:var(--text-muted); padding:0 2px; }
.btn-replace-pdf:hover { color:var(--primary); }
.jc-dr-pdf-cell { white-space:nowrap; }
```

---

## Task 3: Load Drawings from `job_drawings` in `jcOpenJob()`

**Files:**
- Modify: `index.html:7582–7630`

- [ ] **Step 1: Add `job_drawings` to the parallel fetch**

Find (line 7588–7595):
```javascript
    const [jr, lr, er, mr, cr, sr] = await Promise.all([
      sbGet('jobs',                  `id=eq.${jobId}&limit=1`),
      sbGet('labour_entries',        `job_id=eq.${jobId}&order=sort_order`),
      sbGet('equipment_entries',     `job_id=eq.${jobId}&order=sort_order`),
      sbGet('material_entries',      `job_id=eq.${jobId}&order=sort_order`),
      sbGet('consumable_entries',    `job_id=eq.${jobId}&order=sort_order`),
      sbGet('subcontractor_entries', `job_id=eq.${jobId}&order=sort_order`),
    ]);
```

Replace with:
```javascript
    const [jr, lr, er, mr, cr, sr, dr] = await Promise.all([
      sbGet('jobs',                  `id=eq.${jobId}&limit=1`),
      sbGet('labour_entries',        `job_id=eq.${jobId}&order=sort_order`),
      sbGet('equipment_entries',     `job_id=eq.${jobId}&order=sort_order`),
      sbGet('material_entries',      `job_id=eq.${jobId}&order=sort_order`),
      sbGet('consumable_entries',    `job_id=eq.${jobId}&order=sort_order`),
      sbGet('subcontractor_entries', `job_id=eq.${jobId}&order=sort_order`),
      sbGet('job_drawings',          `job_id=eq.${jobId}&order=created_at.asc`),
    ]);
```

- [ ] **Step 2: Render drawings after `jcPopulateForm()`**

Find (line ~7625–7626):
```javascript
    jcPopulateForm(row);
    jcOpenForm();
```

Replace with:
```javascript
    jcPopulateForm(row);
    // Render drawings from dedicated table (RLS filters archived rows for non-admins)
    const activeDrawings   = (dr || []).filter(d => !d.archived);
    const archivedDrawings = (dr || []).filter(d =>  d.archived);
    activeDrawings.forEach(d => jcAddDrawingRow(d));
    jcRenderArchivedDrawings(archivedDrawings);
    jcOpenForm();
```

---

## Task 4: Rewrite `jcAddDrawingRow(dbRow)`

**Files:**
- Modify: `index.html:8265–8278`

`jcAddDrawingRow` now takes a DB row object (from `job_drawings` SELECT) instead of a JSONB element. The row's `id` is stored in `data-drawing-id` for later save-time field sync.

- [ ] **Step 1: Replace the function body**

Find (lines 8265–8278):
```javascript
function jcAddDrawingRow(d) {
  const tbody=document.getElementById('jc-drawings-body'); if (!tbody) return;
  const rid='jc-dr-'+Date.now()+Math.random().toString(36).substr(2,4);
  const tr=document.createElement('tr'); tr.id=rid;
  tr.innerHTML=`
    <td><input type="text" placeholder="DWG-001" value="${d&&d['Drawing No']||''}"></td>
    <td><input type="text" placeholder="Drawing title" value="${d&&d['Drawing Title']||''}"></td>
    <td><input type="text" placeholder="Rev A" value="${d&&d['Revision No']||''}"></td>
    <td><input type="date" value="${d&&d['Date']||''}"></td>
    <td><select><option value="Client">Client</option><option value="Internal">Internal</option></select></td>
    <td><button class="btn-del" onclick="document.getElementById('${rid}').remove();">✕</button></td>`;
  if (d&&d['Source']) tr.querySelector('select').value=d['Source'];
  tbody.appendChild(tr);
}
```

Replace with:
```javascript
function jcAddDrawingRow(d) {
  // d is a job_drawings DB row: { id, drawing_no, drawing_title, revision_no, date, source, storage_key, archived }
  const tbody = document.getElementById('jc-drawings-body');
  if (!tbody) return;
  const rid = 'jc-dr-' + d.id;
  const tr = document.createElement('tr');
  tr.id = rid;
  tr.dataset.drawingId = d.id;

  tr.innerHTML = `
    <td><input type="text" placeholder="DWG-001" value="" oninput="jcMarkDirty()"></td>
    <td><input type="text" placeholder="Drawing title" value="" oninput="jcMarkDirty()"></td>
    <td><input type="text" placeholder="Rev A" value="" oninput="jcMarkDirty()"></td>
    <td><input type="date" value="" oninput="jcMarkDirty()"></td>
    <td><select onchange="jcMarkDirty()"><option value="Client">Client</option><option value="Internal">Internal</option></select></td>
    <td class="jc-dr-pdf-cell">
      <input type="file" accept=".pdf" id="${rid}-file" style="display:none">
      <button class="btn-upload-pdf" id="${rid}-upload-btn">⬆ Upload</button>
    </td>
    <td><button class="btn-del" id="${rid}-del-btn">✕</button></td>`;

  // Set values after innerHTML (avoids XSS from user content in value attrs)
  const inputs = tr.querySelectorAll('input[type=text], input[type=date]');
  inputs[0].value = d.drawing_no    || '';
  inputs[1].value = d.drawing_title || '';
  inputs[2].value = d.revision_no   || '';
  inputs[3].value = d.date          || '';
  tr.querySelector('select').value  = d.source || 'Client';

  // Wire PDF cell
  const fileInput  = tr.querySelector(`#${rid}-file`);
  const uploadBtn  = tr.querySelector(`#${rid}-upload-btn`);
  fileInput.addEventListener('change', () => jcUploadDrawingPdf(d.id, rid, fileInput));
  uploadBtn.addEventListener('click',  () => fileInput.click());

  // If PDF already attached, replace upload button with view + replace
  if (d.storage_key) jcSetDrawingRowHasFile(rid, d.storage_key);

  // Delete = soft archive
  tr.querySelector(`#${rid}-del-btn`).addEventListener('click', () => jcArchiveDrawing(d.id, rid));

  tbody.appendChild(tr);
}

function jcSetDrawingRowHasFile(rid, storageKey) {
  const cell = document.querySelector(`#${rid} .jc-dr-pdf-cell`);
  if (!cell) return;
  cell.dataset.storageKey = storageKey;
  const uploadBtn = cell.querySelector('.btn-upload-pdf');
  if (uploadBtn) uploadBtn.remove();
  if (!cell.querySelector('.btn-view-pdf')) {
    const viewA = document.createElement('a');
    viewA.href = '#'; viewA.className = 'btn-view-pdf'; viewA.textContent = '📄 View';
    viewA.addEventListener('click', e => { e.preventDefault(); jcViewDrawingPdf(cell.dataset.storageKey); });
    const replaceBtn = document.createElement('button');
    replaceBtn.className = 'btn-replace-pdf'; replaceBtn.title = 'Replace PDF'; replaceBtn.textContent = '↺';
    replaceBtn.addEventListener('click', () => cell.closest('tr').querySelector('input[type=file]').click());
    cell.appendChild(viewA);
    cell.appendChild(replaceBtn);
  }
}
```

---

## Task 5: `jcAddNewDrawingRow()` — Guard + INSERT + Render

**Files:**
- Modify: `index.html` — add after `jcSetDrawingRowHasFile` (within the DRAWINGS section ~line 8310+)

- [ ] **Step 1: Add the function**

```javascript
async function jcAddNewDrawingRow() {
  if (!jcCurrentJobId) {
    showToast('Save the job before adding drawings.', 'warn');
    return;
  }
  try {
    const rows = await sbPost('job_drawings', {
      job_id:     jcCurrentJobId,
      company_id: currentCompany.id,
      source:     'Client',
      created_by: currentUser.id,
    });
    if (!rows || !rows[0]) throw new Error('No row returned');
    jcAddDrawingRow(rows[0]);
  } catch(err) {
    showToast('Failed to add drawing: ' + (err.message || err), 'error');
  }
}
```

---

## Task 6: `jcUploadDrawingPdf()` and `jcViewDrawingPdf()`

**Files:**
- Modify: `index.html` — add after `jcAddNewDrawingRow` in the DRAWINGS section

- [ ] **Step 1: Add upload function**

```javascript
async function jcUploadDrawingPdf(drawingId, rid, fileInput) {
  const file = fileInput.files[0];
  if (!file) return;
  if (file.type !== 'application/pdf') {
    showToast('Only PDF files are accepted.', 'error');
    fileInput.value = '';
    return;
  }
  if (file.size > 20 * 1024 * 1024) {
    showToast('File must be under 20 MB.', 'error');
    fileInput.value = '';
    return;
  }

  const cell = document.querySelector(`#${rid} .jc-dr-pdf-cell`);
  if (!cell) return;

  // Show uploading state
  const prevContent = cell.innerHTML;
  cell.innerHTML = '<span style="font-size:11px;color:var(--text-muted)">Uploading…</span>';

  try {
    const safeName   = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
    const storageKey = `${currentCompany.id}/${jcCurrentJobId}/${Date.now()}-${safeName}`;
    const authToken  = _accessToken || SUPABASE_KEY;

    const uploadRes = await fetch(`${SUPABASE_URL}/storage/v1/object/job-drawings/${storageKey}`, {
      method: 'POST',
      headers: {
        'apikey':        SUPABASE_KEY,
        'Authorization': `Bearer ${authToken}`,
        'Content-Type':  'application/pdf',
        'x-upsert':      'true',
      },
      body: file,
    });
    if (!uploadRes.ok) {
      const e = await uploadRes.json().catch(() => ({}));
      throw new Error(e.message || uploadRes.status);
    }

    await sbPatch('job_drawings', drawingId, { storage_key: storageKey });

    // Restore cell with file input + view/replace buttons
    cell.innerHTML = `<input type="file" accept=".pdf" id="${rid}-file" style="display:none">`;
    cell.querySelector('input[type=file]').addEventListener('change', () =>
      jcUploadDrawingPdf(drawingId, rid, cell.querySelector('input[type=file]')));
    jcSetDrawingRowHasFile(rid, storageKey);

    showToast('PDF uploaded.', 'success');
  } catch(err) {
    cell.innerHTML = prevContent;
    // Re-wire file input event after restoring
    const fi = cell.querySelector('input[type=file]');
    if (fi) fi.addEventListener('change', () => jcUploadDrawingPdf(drawingId, rid, fi));
    showToast('Upload failed: ' + (err.message || err), 'error');
  }
  fileInput.value = '';
}
```

- [ ] **Step 2: Add view function**

```javascript
async function jcViewDrawingPdf(storageKey) {
  try {
    const authToken = _accessToken || SUPABASE_KEY;
    const res = await fetch(
      `${SUPABASE_URL}/storage/v1/object/sign/job-drawings/${storageKey}`,
      {
        method: 'POST',
        headers: {
          'apikey':        SUPABASE_KEY,
          'Authorization': `Bearer ${authToken}`,
          'Content-Type':  'application/json',
        },
        body: JSON.stringify({ expiresIn: 3600 }),
      }
    );
    if (!res.ok) throw new Error('Could not generate download link.');
    const data = await res.json();
    const signedUrl = data.signedURL || data.signedUrl;
    if (!signedUrl) throw new Error('No signed URL returned.');
    window.open(SUPABASE_URL + signedUrl, '_blank');
  } catch(err) {
    showToast('Could not open drawing — try again.', 'error');
  }
}
```

---

## Task 7: `jcArchiveDrawing()` and Archived Section

**Files:**
- Modify: `index.html` — add after `jcViewDrawingPdf` in the DRAWINGS section

- [ ] **Step 1: Add archive function**

```javascript
async function jcArchiveDrawing(drawingId, rid) {
  const tr = document.getElementById(rid);
  const drawingNo = tr?.querySelector('input[type=text]')?.value || 'this drawing';
  const ok = await showConfirm(
    `Move "${drawingNo}" to the archive?`,
    'Archive Drawing',
    'Archive'
  );
  if (!ok) return;
  try {
    await sbPatch('job_drawings', drawingId, {
      archived:    true,
      archived_at: nowISO(),
      archived_by: currentUser.id,
    });
    // Collect current field values before removing row
    const inputs   = tr.querySelectorAll('input[type=text], input[type=date]');
    const sel      = tr.querySelector('select');
    const cell     = tr.querySelector('.jc-dr-pdf-cell');
    const archivedRow = {
      id:            drawingId,
      drawing_no:    inputs[0]?.value || '',
      drawing_title: inputs[1]?.value || '',
      revision_no:   inputs[2]?.value || '',
      date:          inputs[3]?.value || '',
      source:        sel?.value || 'Client',
      storage_key:   cell?.dataset.storageKey || null,
      archived:      true,
    };
    tr.remove();
    jcAppendArchivedRow(archivedRow);
    showToast('Drawing archived.', 'success');
  } catch(err) {
    showToast('Archive failed: ' + (err.message || err), 'error');
  }
}
```

- [ ] **Step 2: Add archived section render function**

```javascript
function jcRenderArchivedDrawings(drawings) {
  const container = document.getElementById('jc-archived-drawings');
  const countEl   = document.getElementById('jc-archived-drawings-count');
  const body      = document.getElementById('jc-archived-drawings-body');
  if (!container || !body) return;
  body.innerHTML = '';
  if (!isAdmin() || drawings.length === 0) {
    container.style.display = 'none';
    return;
  }
  container.style.display = '';
  if (countEl) countEl.textContent = drawings.length;
  drawings.forEach(d => jcAppendArchivedRow(d));
}

function jcAppendArchivedRow(d) {
  if (!isAdmin()) return;
  const container = document.getElementById('jc-archived-drawings');
  const body      = document.getElementById('jc-archived-drawings-body');
  const countEl   = document.getElementById('jc-archived-drawings-count');
  if (!body) return;

  container.style.display = '';
  const current = parseInt(countEl?.textContent || '0', 10);
  if (countEl) countEl.textContent = current + 1;

  const rid = 'jc-ar-' + d.id;
  const div = document.createElement('div');
  div.id = rid;
  div.style.cssText = 'display:flex;gap:8px;align-items:center;padding:4px 0;border-bottom:1px solid var(--border);font-size:12px;color:var(--text-muted);';
  div.innerHTML = `
    <span style="width:110px;flex-shrink:0">${d.drawing_no  || '—'}</span>
    <span style="flex:1">${d.drawing_title || '—'}</span>
    <span style="width:70px;flex-shrink:0">${d.revision_no  || '—'}</span>
    <span style="width:100px;flex-shrink:0">${d.date || '—'}</span>`;

  const restoreBtn = document.createElement('button');
  restoreBtn.className = 'btn btn-ghost btn-sm';
  restoreBtn.textContent = 'Restore';
  restoreBtn.style.fontSize = '11px';
  restoreBtn.addEventListener('click', () => jcRestoreDrawing(d.id, rid));

  const deleteBtn = document.createElement('button');
  deleteBtn.className = 'btn btn-sm';
  deleteBtn.textContent = 'Delete Permanently';
  deleteBtn.style.cssText = 'font-size:11px;color:#c00;border-color:#c00;';
  deleteBtn.addEventListener('click', () => jcHardDeleteDrawing(d.id, d.storage_key, rid));

  div.appendChild(restoreBtn);
  div.appendChild(deleteBtn);
  body.appendChild(div);
}

function jcToggleArchivedDrawings() {
  const body    = document.getElementById('jc-archived-drawings-body');
  const chevron = document.getElementById('jc-archived-drawings-chevron');
  if (!body) return;
  const open = body.style.display === 'none';
  body.style.display = open ? '' : 'none';
  if (chevron) chevron.textContent = open ? '▼' : '▶';
}
```

---

## Task 8: `jcRestoreDrawing()` and `jcHardDeleteDrawing()`

**Files:**
- Modify: `index.html` — add after `jcToggleArchivedDrawings` in the DRAWINGS section

- [ ] **Step 1: Add restore function**

```javascript
async function jcRestoreDrawing(drawingId, archivedRid) {
  try {
    const rows = await sbPatch('job_drawings', drawingId, {
      archived:    false,
      archived_at: null,
      archived_by: null,
    });
    // Re-fetch the restored row to get its current field values
    const fetched = await sbGet('job_drawings', `id=eq.${drawingId}&limit=1`);
    if (fetched && fetched[0]) jcAddDrawingRow(fetched[0]);
    // Remove from archived section, update count
    document.getElementById(archivedRid)?.remove();
    const countEl = document.getElementById('jc-archived-drawings-count');
    if (countEl) {
      const n = Math.max(0, parseInt(countEl.textContent || '1', 10) - 1);
      countEl.textContent = n;
      if (n === 0) document.getElementById('jc-archived-drawings').style.display = 'none';
    }
    showToast('Drawing restored.', 'success');
  } catch(err) {
    showToast('Restore failed: ' + (err.message || err), 'error');
  }
}
```

- [ ] **Step 2: Add hard delete function**

```javascript
async function jcHardDeleteDrawing(drawingId, storageKey, archivedRid) {
  const typed = prompt('Type DELETE to permanently remove this drawing and its PDF:');
  if (typed !== 'DELETE') return;
  try {
    // Delete storage object first (if PDF exists); proceed even if missing
    if (storageKey) {
      const authToken = _accessToken || SUPABASE_KEY;
      const delRes = await fetch(`${SUPABASE_URL}/storage/v1/object/job-drawings`, {
        method: 'DELETE',
        headers: {
          'apikey':        SUPABASE_KEY,
          'Authorization': `Bearer ${authToken}`,
          'Content-Type':  'application/json',
        },
        body: JSON.stringify({ prefixes: [storageKey] }),
      });
      if (!delRes.ok) console.warn('Storage delete may have failed — proceeding with DB delete.');
    }
    await sbDelete('job_drawings', drawingId);
    document.getElementById(archivedRid)?.remove();
    const countEl = document.getElementById('jc-archived-drawings-count');
    if (countEl) {
      const n = Math.max(0, parseInt(countEl.textContent || '1', 10) - 1);
      countEl.textContent = n;
      if (n === 0) document.getElementById('jc-archived-drawings').style.display = 'none';
    }
    showToast('Drawing permanently deleted.', 'success');
  } catch(err) {
    showToast('Delete failed: ' + (err.message || err), 'error');
  }
}
```

---

## Task 9: Update Save — Field-Edit Sync + Remove JSONB

**Files:**
- Modify: `index.html:7792–7796` (drawings in `jcCollectFormData`)
- Modify: `index.html:7498–7534` (`jcSaveJobData` — remove drawings from jobRecord)
- Modify: `index.html:7828` (return statement in `jcCollectFormData`)

- [ ] **Step 1: Replace drawings collection in `jcCollectFormData()`**

Find (lines 7792–7796):
```javascript
  const drawings = [];
  document.querySelectorAll('#jc-drawings-body tr').forEach(tr => {
    if (!tr.id) return; const inputs=tr.querySelectorAll('input');
    drawings.push({ 'Drawing No':inputs[0]?.value||'', 'Drawing Title':inputs[1]?.value||'', 'Revision No':inputs[2]?.value||'', 'Date':inputs[3]?.value||'', 'Source':tr.querySelector('select')?.value||'Client' });
  });
```

Replace with:
```javascript
  const drawings = []; // collected for field-sync PATCH in jcSaveJobData
  document.querySelectorAll('#jc-drawings-body tr[data-drawing-id]').forEach(tr => {
    const inputs = tr.querySelectorAll('input[type=text], input[type=date]');
    drawings.push({
      id:            tr.dataset.drawingId,
      drawing_no:    inputs[0]?.value || '',
      drawing_title: inputs[1]?.value || '',
      revision_no:   inputs[2]?.value || '',
      date:          inputs[3]?.value || null,
      source:        tr.querySelector('select')?.value || 'Client',
    });
  });
```

- [ ] **Step 2: Update return statement in `jcCollectFormData()`**

Find (line 7828):
```javascript
    qcState:       JSON.stringify(qcState),    drawings:      JSON.stringify(drawings),
```

Replace with:
```javascript
    qcState:       JSON.stringify(qcState),    drawingRows:   drawings,
```

- [ ] **Step 3: Remove `drawings` from `jobRecord` in `jcSaveJobData()` and add field-sync PATCH**

Find (line 7530):
```javascript
    drawings:        parse(data.drawings),
```

Delete that line entirely (remove it from `jobRecord`).

Then find the `return savedId;` line at the end of `jcSaveJobData` (line 7578) and add before it:

```javascript
  // Sync drawing field edits (text/date/source changes made while dirty)
  if (data.drawingRows && data.drawingRows.length) {
    await Promise.all(data.drawingRows.map(d =>
      sbPatch('job_drawings', d.id, {
        drawing_no:    d.drawing_no,
        drawing_title: d.drawing_title,
        revision_no:   d.revision_no,
        date:          d.date || null,
        source:        d.source,
      })
    ));
  }
```

---

## Task 10: Cleanup — `jcResetForm()` and `jcPopulateForm()`

**Files:**
- Modify: `index.html:7444–7468` (`jcResetForm`)
- Modify: `index.html:7667` (`jcPopulateForm` — remove old drawings populate)

- [ ] **Step 1: Add archived section reset in `jcResetForm()`**

Find (line 7455):
```javascript
  jcCurrentJobId = null; jcIsLocked = false; jcAdminCostUnlocked = false;
```

Add after that line:
```javascript
  const archSec = document.getElementById('jc-archived-drawings');
  if (archSec) archSec.style.display = 'none';
  const archBody = document.getElementById('jc-archived-drawings-body');
  if (archBody) archBody.innerHTML = '';
  const archCount = document.getElementById('jc-archived-drawings-count');
  if (archCount) archCount.textContent = '0';
```

- [ ] **Step 2: Remove old JSONB drawings populate from `jcPopulateForm()`**

Find (line 7667):
```javascript
  parse(row['Drawings Detail']).forEach(d => jcAddDrawingRow(d));
```

Delete that line entirely. (Drawings are now loaded directly in `jcOpenJob()` from the new table, not via `jcPopulateForm`.)

- [ ] **Step 3: Commit all changes**

```bash
cd "C:/Users/brand/OneDrive/Documents/Projects/meridian-erp"
git add index.html
git commit -m "feat(work-orders): add PDF upload to Drawing Control Register

- Migrate drawings from jobs.drawings JSONB to job_drawings table
- Private job-drawings Supabase Storage bucket with signed URL viewing
- Per-row upload/view/replace; soft-archive on delete; admin hard-delete
- Archived section (admin-only) with restore and permanent delete
- Field edits synced to DB on job save; uploads/archives immediate"
```

---

## Self-Review Checklist

- [x] **Bucket created** — Task 1 Step 1
- [x] **Storage RLS** — Task 1 Step 2
- [x] **`is_company_admin()` function** — Task 1 Step 3
- [x] **`job_drawings` table + RLS** — Task 1 Step 3
- [x] **JSONB migration** — Task 1 Step 3
- [x] **PDF column header** — Task 2 Step 1
- [x] **Archived section HTML** — Task 2 Step 1
- [x] **CSS for PDF buttons** — Task 2 Step 2
- [x] **Load from `job_drawings` in `jcOpenJob()`** — Task 3
- [x] **`jcAddDrawingRow(dbRow)` rewrite** — Task 4
- [x] **`jcSetDrawingRowHasFile()` helper** — Task 4
- [x] **`jcAddNewDrawingRow()` guard + INSERT** — Task 5
- [x] **`jcUploadDrawingPdf()` — validation, upload, PATCH, UI swap** — Task 6
- [x] **`jcViewDrawingPdf()` — signed URL, open** — Task 6
- [x] **`jcArchiveDrawing()` — confirm, PATCH, move to archived** — Task 7
- [x] **`jcRenderArchivedDrawings()` + `jcAppendArchivedRow()` + `jcToggleArchivedDrawings()`** — Task 7
- [x] **`jcRestoreDrawing()`** — Task 8
- [x] **`jcHardDeleteDrawing()` — typed confirm, storage delete, DB delete** — Task 8
- [x] **`jcCollectFormData()` drawings → `drawingRows`** — Task 9
- [x] **`jcSaveJobData()` — remove JSONB drawings, add field-sync PATCH** — Task 9
- [x] **`jcResetForm()` — archived section reset** — Task 10
- [x] **`jcPopulateForm()` — remove old JSONB line** — Task 10
- [x] **Commit** — Task 10 Step 3
