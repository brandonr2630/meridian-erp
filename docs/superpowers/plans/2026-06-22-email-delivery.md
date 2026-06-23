# Email Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two email subsystems to Meridian ERP — manual PDF document email (7 document types via Resend) and an automatic internal notification system (7 event types, pg_cron for overdue alerts).

**Architecture:** Client-side pdf generation via html2pdf.js; two Supabase Edge Functions (`send-document-email`, `send-notification`) call Resend API. Notifications triggered from existing save functions + pg_cron via pg_net for scheduled overdue alerts.

**Tech Stack:** Supabase Edge Functions (Deno/TypeScript), Resend API, html2pdf.js 0.10.1 CDN, pg_net extension, vanilla JS in `index.html`

---

## Parallel Execution Map

```
Task 1 (manual) → Task 2 (DB) ─┬─ Tasks 3–9  (Phase A: Document Email)
                                └─ Tasks 10–13 (Phase B: Notifications)
```

Tasks 3 and 10 can run in parallel (separate files). Within each phase, tasks are sequential.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `supabase/functions/send-document-email/index.ts` | Create | Validate JWT, resolve sender, call Resend with PDF attachment |
| `supabase/functions/send-notification/index.ts` | Create | Validate caller, resolve recipients, check prefs, interpolate template, call Resend, log |
| `supabase/migrations/20260622_email_delivery.sql` | Create | All schema changes: companies.send_from_email, erp_users.email, 3 notification tables, 3 overdue_notified_at columns, seed data, RLS |
| `index.html` | Modify | html2pdf.js lazy load, staging div, email modal, 7 doc types, WO receipt builder, AR statement builder, notification triggers, Settings Notifications tab, send_from_email field |

---

## Task 1: Resend Prerequisites (Manual)

**No code changes. Must complete before Task 3/10 deploy.**

- [ ] **Step 1: Verify domains in Resend**

  Log in to resend.com → Domains → Add Domain.
  Add `terranresources.com` and `q2m.io`. Follow DNS verification (TXT + MX records). Wait for verification (usually <5 min).

- [ ] **Step 2: Get API key**

  Resend → API Keys → Create API Key (Full Access). Copy value.

- [ ] **Step 3: Add to Supabase Edge Function secrets**

  In Supabase Dashboard → Project `fcagxvjxfqqkmuposmcb` → Settings → Edge Functions → Secrets:
  Add `RESEND_API_KEY` = the key from Step 2.

- [ ] **Step 4: Commit nothing** — manual step, no files change.

---

## Task 2: DB Migration

**Files:**
- Create: `supabase/migrations/20260622_email_delivery.sql`

- [ ] **Step 1: Write migration**

```sql
-- supabase/migrations/20260622_email_delivery.sql

-- ── companies ────────────────────────────────────────────────────────────────
ALTER TABLE companies ADD COLUMN IF NOT EXISTS send_from_email text;

-- ── erp_users ────────────────────────────────────────────────────────────────
ALTER TABLE erp_users ADD COLUMN IF NOT EXISTS email text;
-- Backfill: run this separately in Supabase SQL editor (requires service role):
-- UPDATE erp_users SET email = au.email
--   FROM auth.users au WHERE au.id = erp_users.auth_user_id;

-- ── notification_types ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_types (
  event_key   text PRIMARY KEY,
  label       text NOT NULL,
  subject_tpl text NOT NULL,
  body_html   text NOT NULL,
  recipient   text NOT NULL CHECK (recipient IN ('direct','role:admin','owner')),
  enabled     boolean DEFAULT true
);

-- ── notification_preferences ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_preferences (
  user_id   uuid REFERENCES erp_users(id) ON DELETE CASCADE,
  event_key text REFERENCES notification_types(event_key) ON DELETE CASCADE,
  enabled   boolean DEFAULT true,
  PRIMARY KEY (user_id, event_key)
);

-- ── notification_log ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_log (
  id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  event_key       text NOT NULL,
  company_id      uuid,
  entity_type     text,
  entity_id       text,
  recipient_id    uuid REFERENCES erp_users(id) ON DELETE SET NULL,
  recipient_email text,
  subject         text,
  sent_at         timestamptz DEFAULT now(),
  error           text
);

CREATE INDEX IF NOT EXISTS notification_log_company_idx ON notification_log(company_id);
CREATE INDEX IF NOT EXISTS notification_log_event_entity ON notification_log(event_key, entity_id);

-- ── overdue notification sentinels ───────────────────────────────────────────
ALTER TABLE crm_tasks ADD COLUMN IF NOT EXISTS overdue_notified_at timestamptz;
ALTER TABLE jobs      ADD COLUMN IF NOT EXISTS overdue_notified_at timestamptz;
ALTER TABLE invoices  ADD COLUMN IF NOT EXISTS overdue_notified_at timestamptz;

-- ── Seed notification_types ──────────────────────────────────────────────────
INSERT INTO notification_types (event_key, label, subject_tpl, body_html, recipient) VALUES
('task.assigned','Task assigned to me',
  'Task assigned to you: {{task_title}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;"><strong>{{assigned_by}}</strong> has assigned a task to you.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Task</td><td style="padding:6px 10px;border:1px solid #ddd;">{{task_title}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Due Date</td><td style="padding:6px 10px;border:1px solid #ddd;">{{due_date}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to view and action this task.</p>',
  'direct'),
('task.overdue','Task overdue',
  'Overdue task: {{task_title}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">The following task is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Task</td><td style="padding:6px 10px;border:1px solid #ddd;">{{task_title}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to update this task.</p>',
  'direct'),
('job.assigned','Work order assigned to me',
  'Work order assigned to you: {{job_no}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;"><strong>{{assigned_by}}</strong> has assigned a work order to you.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Job No</td><td style="padding:6px 10px;border:1px solid #ddd;">{{job_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Due Date</td><td style="padding:6px 10px;border:1px solid #ddd;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to view the work order.</p>',
  'direct'),
('job.overdue','Work order overdue',
  'Overdue work order: {{job_no}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">A work order is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Job No</td><td style="padding:6px 10px;border:1px solid #ddd;">{{job_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Customer</td><td style="padding:6px 10px;border:1px solid #ddd;">{{customer}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to update this work order.</p>',
  'role:admin'),
('invoice.overdue','Invoice overdue',
  'Overdue invoice: {{invoice_no}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">An invoice is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Invoice</td><td style="padding:6px 10px;border:1px solid #ddd;">{{invoice_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Balance</td><td style="padding:6px 10px;border:1px solid #ddd;font-weight:bold;">{{balance}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to manage AR.</p>',
  'role:admin'),
('deal.won','Deal won',
  'Deal won: {{deal_name}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">Your deal has been marked as <strong style="color:#27ae60;">WON</strong> 🏆</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Deal</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Value</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_value}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to convert to a quotation.</p>',
  'direct'),
('deal.lost','Deal lost',
  'Deal lost: {{deal_name}}',
  '<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">Your deal has been marked as <strong style="color:#c0392b;">LOST</strong>.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Deal</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Reason</td><td style="padding:6px 10px;border:1px solid #ddd;">{{lost_reason}}</td></tr></table>',
  'direct')
ON CONFLICT DO NOTHING;

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE notification_types        ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences  ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_log          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notif_types_read        ON notification_types;
DROP POLICY IF EXISTS notif_prefs_own         ON notification_preferences;
DROP POLICY IF EXISTS notif_log_company_read  ON notification_log;

CREATE POLICY notif_types_read ON notification_types
  FOR SELECT TO authenticated USING (true);

CREATE POLICY notif_prefs_own ON notification_preferences
  FOR ALL TO authenticated USING (
    user_id IN (SELECT id FROM erp_users WHERE auth_user_id = auth.uid())
  ) WITH CHECK (
    user_id IN (SELECT id FROM erp_users WHERE auth_user_id = auth.uid())
  );

CREATE POLICY notif_log_company_read ON notification_log
  FOR SELECT TO authenticated USING (
    company_id = ANY(my_company_ids())
  );
```

- [ ] **Step 2: Apply migration via Supabase MCP**

  Apply `20260622_email_delivery.sql` to project `fcagxvjxfqqkmuposmcb`.

- [ ] **Step 3: Backfill erp_users.email**

  In Supabase SQL Editor (service role required):
  ```sql
  UPDATE erp_users
  SET email = au.email
  FROM auth.users au
  WHERE au.id = erp_users.auth_user_id
    AND erp_users.email IS NULL;
  ```

- [ ] **Step 4: Verify**

  In Supabase SQL Editor:
  ```sql
  SELECT id, full_name, email FROM erp_users LIMIT 5;
  SELECT * FROM notification_types ORDER BY event_key;
  SELECT column_name FROM information_schema.columns
    WHERE table_name = 'companies' AND column_name = 'send_from_email';
  ```
  Expected: 7 notification_types rows, erp_users have email values, companies has send_from_email column.

- [ ] **Step 5: Commit**

  ```bash
  git add supabase/migrations/20260622_email_delivery.sql
  git commit -m "feat: add email delivery DB migration"
  ```

---

## Task 3: Edge Function — send-document-email

**Files:**
- Create: `supabase/functions/send-document-email/index.ts`

- [ ] **Step 1: Create the function**

```typescript
// supabase/functions/send-document-email/index.ts

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string | null, status: number) {
  return new Response(body, {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function getJwtSub(jwt: string): string {
  const payload = JSON.parse(atob(jwt.split(".")[1]));
  return payload.sub;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return corsResponse(JSON.stringify({ error: "Method not allowed" }), 405);

  const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY          = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const RESEND_API_KEY    = Deno.env.get("RESEND_API_KEY")!;

  let body: { to: string; subject: string; message: string; pdf_base64: string; filename: string };
  try { body = await req.json(); } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON" }), 400);
  }
  const { to, subject, message, pdf_base64, filename } = body;
  if (!to || !subject || !pdf_base64 || !filename) {
    return corsResponse(JSON.stringify({ error: "Missing: to, subject, pdf_base64, filename" }), 400);
  }

  // Validate caller JWT
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return corsResponse(JSON.stringify({ error: "Missing Authorization header" }), 401);
  }
  const callerToken = authHeader.slice(7);
  let callerSub: string;
  try { callerSub = getJwtSub(callerToken); } catch {
    return corsResponse(JSON.stringify({ error: "Malformed JWT" }), 401);
  }

  // Look up caller's company
  const userRes = await fetch(
    `${SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${callerSub}&select=company_id&limit=1`,
    { headers: { Authorization: `Bearer ${callerToken}`, apikey: ANON_KEY } }
  );
  const users = await userRes.json();
  if (!Array.isArray(users) || !users.length) {
    return corsResponse(JSON.stringify({ error: "User not found" }), 403);
  }

  const coRes = await fetch(
    `${SUPABASE_URL}/rest/v1/companies?id=eq.${users[0].company_id}&select=name,email,send_from_email&limit=1`,
    { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
  );
  const companies = await coRes.json();
  const co = companies[0] ?? {};
  const fromEmail = co.send_from_email ?? "accounts@terranresources.com";
  const fromName  = co.name ?? "Meridian ERP";
  const replyTo   = co.email ?? fromEmail;

  // Strip data URI prefix if present
  const base64Content = pdf_base64.replace(/^data:[^;]+;base64,/, "");

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: `${fromName} <${fromEmail}>`,
      reply_to: replyTo,
      to: [to],
      subject,
      html: message
        ? `<p style="font-family:Arial,sans-serif;font-size:14px;">${message.replace(/\n/g, "<br>")}</p>`
        : `<p style="font-family:Arial,sans-serif;font-size:14px;">Please find your document attached.</p>`,
      attachments: [{ filename, content: base64Content }],
    }),
  });

  if (!resendRes.ok) {
    const err = await resendRes.json().catch(() => ({}));
    return corsResponse(JSON.stringify({ error: "Resend error", detail: err }), 500);
  }

  return corsResponse(JSON.stringify({ success: true }), 200);
});
```

- [ ] **Step 2: Deploy**

  ```bash
  npx supabase functions deploy send-document-email --project-ref fcagxvjxfqqkmuposmcb
  ```

- [ ] **Step 3: Smoke test**

  ```bash
  curl -X POST https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-document-email \
    -H "Authorization: Bearer <your_access_token>" \
    -H "Content-Type: application/json" \
    -d '{"to":"test@example.com","subject":"Test","message":"Hello","pdf_base64":"JVBERi0xLjMK","filename":"test.pdf"}'
  ```
  Expected: `{"success":true}` and email arrives (note: `JVBERi0xLjMK` is a minimal valid PDF header in base64).

- [ ] **Step 4: Commit**

  ```bash
  git add supabase/functions/send-document-email/
  git commit -m "feat: add send-document-email Edge Function"
  ```

---

## Task 4: html2pdf.js Integration + PDF Staging

**Files:**
- Modify: `index.html`

All index.html edits reference the function/section by name — search for the named anchor.

- [ ] **Step 1: Add PDF staging div**

  Search for `<div id="modal-pdf-preview"`. Immediately BEFORE that element, add:

  ```html
  <!-- Email PDF staging — off-screen render target for html2pdf.js -->
  <div id="email-pdf-staging" style="position:absolute;left:-9999px;top:0;width:794px;background:#fff;font-family:Arial,sans-serif;"></div>
  ```

- [ ] **Step 2: Add html2pdf lazy loader + generatePDFBase64**

  Search for `async function openInvoicePDF(id)` (~line 14243). Immediately BEFORE that function, add:

  ```js
  // ── Email PDF helpers ──────────────────────────────────────────────────────
  async function _loadHtml2Pdf() {
    if (window.html2pdf) return;
    await new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js';
      s.onload = resolve; s.onerror = reject;
      document.head.appendChild(s);
    });
  }

  async function generatePDFBase64(source) {
    // source: DOM element or HTML string
    await _loadHtml2Pdf();
    return html2pdf()
      .set({
        margin: 0,
        html2canvas: { scale: 2, useCORS: true, logging: false },
        jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' }
      })
      .from(source)
      .toPdf()
      .output('datauristring');
  }
  ```

- [ ] **Step 3: Verify lazy load works**

  Open browser console on the ERP and run:
  ```js
  await _loadHtml2Pdf();
  console.log(typeof window.html2pdf); // expected: "function"
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add html2pdf.js lazy loader and generatePDFBase64"
  ```

---

## Task 5: Email Modal + Core Email Functions

**Files:**
- Modify: `index.html`

- [ ] **Step 1: Add state var**

  Search for `// ── STATE ──`. Add alongside other state declarations:
  ```js
  let _emailDocMeta = null; // { type, id, to, subject, filename }
  ```

- [ ] **Step 2: Add email modal HTML**

  Search for the closing `</body>` tag. Immediately before it, add:

  ```html
  <!-- ── Send Email Modal ───────────────────────────────────────────────────── -->
  <div id="modal-send-email" class="modal-overlay" onclick="if(event.target===this)closeModal('modal-send-email')">
    <div class="modal" style="max-width:min(560px,95vw);">
      <div class="modal-header">
        <h3 class="modal-title">✉️ Send Document</h3>
        <button class="btn btn-ghost btn-sm btn-icon" onclick="closeModal('modal-send-email')" aria-label="Close">✕</button>
      </div>
      <div class="modal-body">
        <div class="field">
          <label>To</label>
          <input type="email" id="email-doc-to" placeholder="recipient@example.com">
        </div>
        <div class="field">
          <label>Subject</label>
          <input type="text" id="email-doc-subject">
        </div>
        <div class="field">
          <label>Message <span style="color:var(--text-3);font-size:11px;">(optional)</span></label>
          <textarea id="email-doc-message" rows="4" placeholder="Add a message to accompany the document…" style="resize:vertical;"></textarea>
        </div>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="closeModal('modal-send-email')">Cancel</button>
        <button id="btn-send-email" class="btn btn-primary" onclick="sendEmailDocument()">Send</button>
      </div>
    </div>
  </div>
  ```

- [ ] **Step 3: Add openEmailDocument, _buildEmailPDF, sendEmailDocument**

  Search for `// ── Email PDF helpers ──` (added in Task 4). After `generatePDFBase64`, add:

  ```js
  function openEmailDocument(type, id) {
    const meta = _resolveEmailMeta(type, id);
    _emailDocMeta = { type, id, ...meta };
    document.getElementById('email-doc-to').value      = meta.to;
    document.getElementById('email-doc-subject').value = meta.subject;
    document.getElementById('email-doc-message').value = '';
    const btn = document.getElementById('btn-send-email');
    btn.disabled = false; btn.textContent = 'Send';
    openModal('modal-send-email');
  }

  function _resolveEmailMeta(type, id) {
    const co = currentCompany;
    if (type === 'invoice') {
      const inv = invoices.find(i => i.id === id) || {};
      const c   = contacts.find(x => x.id === inv.contact_id) || {};
      return { to: c.email || '', subject: `Invoice ${inv.invoice_no || ''} from ${escHTML(co.name)}`, filename: `${inv.invoice_no || 'invoice'}.pdf` };
    }
    if (type === 'quotation') {
      const q = quotations.find(x => x.id === id) || {};
      const c = contacts.find(x => x.id === q.contact_id) || {};
      return { to: c.email || '', subject: `Quotation ${q.quote_no || ''} from ${escHTML(co.name)}`, filename: `${q.quote_no || 'quotation'}.pdf` };
    }
    if (type === 'delivery-note') {
      const dn = deliveryNotes.find(x => x.id === id) || {};
      const c  = contacts.find(x => x.id === dn.contact_id) || {};
      return { to: c.email || '', subject: `Delivery Note ${dn.dn_no || ''} from ${escHTML(co.name)}`, filename: `${dn.dn_no || 'delivery-note'}.pdf` };
    }
    if (type === 'credit-note') {
      const cn = creditNotes.find(x => x.id === id) || {};
      const c  = contacts.find(x => x.id === cn.contact_id) || {};
      return { to: c.email || '', subject: `Credit Note ${cn.cn_no || ''} from ${escHTML(co.name)}`, filename: `${cn.cn_no || 'credit-note'}.pdf` };
    }
    if (type === 'receipt') {
      const rec = (window._arReceipts || []).find(x => x.id === id) || {};
      const inv = invoices.find(x => x.id === rec.invoice_id) || {};
      const c   = contacts.find(x => x.id === rec.contact_id) || {};
      return { to: c.email || '', subject: `Payment Receipt ${rec.receipt_no || ''} from ${escHTML(co.name)}`, filename: `${rec.receipt_no || 'receipt'}.pdf` };
    }
    if (type === 'work-order') {
      const job = (window._jcJobs || []).find(x => x.id === id) || {};
      return { to: job.email || '', subject: `Work Order Receipt ${job.job_no || ''} from ${escHTML(co.name)}`, filename: `${job.job_no || 'work-order'}.pdf` };
    }
    if (type === 'ar-statement') {
      const c = contacts.find(x => x.id === id) || {};
      return { to: c.email || '', subject: `Account Statement from ${escHTML(co.name)}`, filename: `statement-${(c.trading_name || c.name || 'client').replace(/\s+/g,'-').toLowerCase()}.pdf` };
    }
    return { to: '', subject: '', filename: 'document.pdf' };
  }

  async function _buildEmailPDF(type, id) {
    const staging = document.getElementById('email-pdf-staging');

    if (type === 'invoice') {
      const inv     = invoices.find(i => i.id === id);
      if (!inv) throw new Error('Invoice not found');
      const lines   = await sbGet('invoice_lines', `invoice_id=eq.${id}&order=line_order`).catch(() => []);
      const contact = contacts.find(c => c.id === inv.contact_id) || {};
      const co      = currentCompany;
      const taxRate = parseFloat(inv.tax_rate || 0);
      const totalsH = calcTotalsH(inv.incoterms, inv.notes, co.bank_details);
      const pages   = splitLinesIntoPages(lines, calcFirstRows(totalsH), calcContRows(totalsH));
      const metaRows = [
        ['Invoice Date :', formatDateDisplay(inv.invoice_date)],
        ['Terms :', inv.payment_terms || '—'],
        ['Due Date :', inv.due_date ? formatDateDisplay(inv.due_date) : '—'],
        ...(inv.client_ref ? [['Client Ref :', escHTML(inv.client_ref)]] : [])
      ];
      const headerHTML = buildPDFHeader(co, 'Invoice', inv.invoice_no || 'DRAFT', 'Balance Due',
        fmt(inv.balance_due, inv.currency), contact, metaRows);
      staging.innerHTML = '';
      renderMultiPagePDF('email-pdf-staging', pages, headerHTML, true, inv.currency,
        parseFloat(inv.subtotal||0), taxRate, parseFloat(inv.tax_amount||0),
        parseFloat(inv.total||0), inv.incoterms, inv.incoterms_place,
        inv.notes, co.bank_details, co.name, inv.invoice_no);
      return generatePDFBase64(staging);
    }

    if (type === 'quotation') {
      const quo     = quotations.find(q => q.id === id);
      if (!quo) throw new Error('Quotation not found');
      const lines   = await sbGet('quotation_lines', `quotation_id=eq.${id}&order=line_order`).catch(() => []);
      const contact = contacts.find(c => c.id === quo.contact_id) || {};
      const co      = currentCompany;
      const lead    = salesLeads.find(l => l.id === quo.sales_lead_id);
      const taxRate = parseFloat(quo.tax_rate || 0);
      const totalsH = calcTotalsH(quo.incoterms, quo.notes, null);
      const pages   = splitLinesIntoPages(lines, calcFirstRows(totalsH), calcContRows(totalsH));
      const metaRows = [
        ['Quote Date :', formatDateDisplay(quo.quote_date)],
        ['Valid Until :', quo.valid_until ? formatDateDisplay(quo.valid_until) : '—'],
        ['Terms :', quo.payment_terms || '—'],
        ...(quo.client_ref ? [['Client Ref :', escHTML(quo.client_ref)]] : []),
        ...(lead ? [['Prepared By :', escHTML(lead.name)]] : [])
      ];
      const headerHTML = buildPDFHeader(co, 'Quotation', quo.quote_no || 'DRAFT', 'Total Value',
        fmt(quo.total, quo.currency), contact, metaRows);
      staging.innerHTML = '';
      renderMultiPagePDF('email-pdf-staging', pages, headerHTML, true, quo.currency,
        parseFloat(quo.subtotal||0), taxRate, parseFloat(quo.tax_amount||0),
        parseFloat(quo.total||0), quo.incoterms, quo.incoterms_place,
        quo.notes, null, co.name, quo.quote_no);
      return generatePDFBase64(staging);
    }

    if (type === 'delivery-note') {
      const dn      = deliveryNotes.find(d => d.id === id);
      if (!dn) throw new Error('Delivery note not found');
      const lines   = await sbGet('delivery_note_lines', `dn_id=eq.${id}&order=line_order`).catch(() => []);
      const contact = contacts.find(c => c.id === dn.contact_id) || {};
      const co      = currentCompany;
      const totalsH = calcTotalsH(null, dn.notes, null);
      const pages   = splitLinesIntoPages(lines, calcFirstRows(totalsH) + 4, calcContRows(totalsH) + 4);
      const delAddr = [dn.delivery_address_line1, dn.delivery_address_line2, dn.delivery_address_line3, dn.delivery_country].filter(Boolean).join(', ') || null;
      const metaRows = [
        ['DN Date :', formatDateDisplay(dn.dn_date)],
        ['Delivery Date :', dn.delivery_date ? formatDateDisplay(dn.delivery_date) : '—'],
        ...(dn.client_ref    ? [['Client Ref :', escHTML(dn.client_ref)]]       : []),
        ...(dn.carrier       ? [['Carrier :', escHTML(dn.carrier)]]             : []),
        ...(dn.driver        ? [['Driver :', escHTML(dn.driver)]]               : []),
        ...(dn.vehicle_ref   ? [['Vehicle :', escHTML(dn.vehicle_ref)]]         : []),
        ...(dn.recipient_name? [['Recipient :', escHTML(dn.recipient_name)]]    : []),
        ...(delAddr          ? [['Deliver To :', escHTML(delAddr)]]             : [])
      ];
      const headerHTML = buildPDFHeader(co, 'Delivery Note', dn.dn_no,
        'Status', dn.status.charAt(0).toUpperCase() + dn.status.slice(1), contact, metaRows);
      staging.innerHTML = '';
      renderMultiPagePDF('email-pdf-staging', pages, headerHTML, false, co.currency,
        0, 0, 0, 0, null, null, dn.notes, null, co.name, dn.dn_no);
      return generatePDFBase64(staging);
    }

    if (type === 'credit-note') {
      const cn      = creditNotes.find(c => c.id === id);
      if (!cn) throw new Error('Credit note not found');
      const lines   = await sbGet('credit_note_lines', `cn_id=eq.${id}&order=line_order`).catch(() => []);
      const contact = contacts.find(c => c.id === cn.contact_id) || {};
      const co      = currentCompany;
      const inv     = invoices.find(i => i.id === cn.invoice_id);
      const taxRate = parseFloat(cn.tax_rate || 0);
      const totalsH = calcTotalsH(null, cn.notes, null);
      const pages   = splitLinesIntoPages(lines, calcFirstRows(totalsH), calcContRows(totalsH));
      const metaRows = [
        ['CN Date :', formatDateDisplay(cn.cn_date)],
        ['Ref Invoice :', inv?.invoice_no || '—'],
        ['Reason :', escHTML(cn.reason) || '—']
      ];
      const headerHTML = buildPDFHeader(co, 'Credit Note', cn.cn_no, 'Credit Amount',
        fmt(cn.total, cn.currency), contact, metaRows);
      staging.innerHTML = '';
      renderMultiPagePDF('email-pdf-staging', pages, headerHTML, true, cn.currency,
        parseFloat(cn.subtotal||0), taxRate, parseFloat(cn.tax_amount||0),
        parseFloat(cn.total||0), null, null, cn.notes, null, co.name, cn.cn_no);
      return generatePDFBase64(staging);
    }

    if (type === 'receipt') {
      const rows    = await sbGet('payment_receipts', `id=eq.${id}&limit=1`);
      const receipt = rows[0]; if (!receipt) throw new Error('Receipt not found');
      const inv     = invoices.find(i => i.id === receipt.invoice_id) || {};
      const contact = contacts.find(c => c.id === receipt.contact_id) || {};
      const bankAcc = bankAccounts.find(b => b.id === receipt.bank_account_id) || {};
      return generatePDFBase64(buildReceiptPDFHTML(receipt, inv, contact, bankAcc));
    }

    if (type === 'work-order') {
      const jobRows  = await sbGet('jobs', `id=eq.${id}&limit=1`);
      const job      = jobRows[0]; if (!job) throw new Error('Job not found');
      const [labour, materials, consumables] = await Promise.all([
        sbGet('labour_entries',    `job_id=eq.${id}&order=date`).catch(() => []),
        sbGet('material_entries',  `job_id=eq.${id}`).catch(() => []),
        sbGet('consumable_entries',`job_id=eq.${id}`).catch(() => [])
      ]);
      return generatePDFBase64(buildWorkOrderReceiptHTML(job, labour, materials, consumables, currentCompany));
    }

    if (type === 'ar-statement') {
      // id is contact_id
      const contact = contacts.find(c => c.id === id) || {};
      const clientInvoices = invoices.filter(i => i.contact_id === id && i.invoice_no);
      return generatePDFBase64(buildARStatementHTML(contact, clientInvoices, currentCompany));
    }

    throw new Error(`Unknown email document type: ${type}`);
  }

  async function sendEmailDocument() {
    const btn = document.getElementById('btn-send-email');
    const to      = document.getElementById('email-doc-to').value.trim();
    const subject = document.getElementById('email-doc-subject').value.trim();
    const message = document.getElementById('email-doc-message').value.trim();
    if (!to || !subject) { showToast('To and Subject are required.', 'error'); return; }
    btn.disabled = true; btn.textContent = 'Generating PDF…';
    try {
      const pdfBase64 = await _buildEmailPDF(_emailDocMeta.type, _emailDocMeta.id);
      btn.textContent = 'Sending…';
      const res = await fetch(`${SUPABASE_URL}/functions/v1/send-document-email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${_accessToken}`, apikey: SUPABASE_ANON_KEY },
        body: JSON.stringify({ to, subject, message, pdf_base64: pdfBase64, filename: _emailDocMeta.filename })
      });
      if (!res.ok) throw new Error((await res.json()).error || 'Send failed');
      closeModal('modal-send-email');
      showToast(`Document emailed to ${to}`, 'success');
    } catch(e) {
      showToast('Email failed: ' + e.message, 'error');
    } finally {
      btn.disabled = false; btn.textContent = 'Send';
    }
  }
  ```

- [ ] **Step 4: Verify state var exists**

  Search `index.html` for `_emailDocMeta`. Confirm it appears in both the state declaration and the three new functions.

- [ ] **Step 5: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add email modal and document email core functions"
  ```

---

## Task 6: Email Buttons on Existing Document Types

**Files:**
- Modify: `index.html`

Add `✉️` button next to each existing `🖨` button. Do NOT remove existing buttons.

- [ ] **Step 1: AR Invoices — renderARTable (~line 12101)**

  Find this exact line in `renderARTable`:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openInvoicePDF('${inv.id}')" title="Preview / Print" aria-label="Preview / Print" style="font-size:16px;padding:4px 8px;">🖨</button>
  ```
  Add immediately after it:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('invoice','${inv.id}')" title="Email Invoice" aria-label="Email Invoice" style="font-size:15px;padding:4px 8px;">✉️</button>
  ```

- [ ] **Step 2: Quotations — renderQuotationsTable (~line 12277)**

  Find:
  ```js
  onclick="openQuoPDF('${q.id}')"
  ```
  In the action buttons cell, add after the 🖨 button:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('quotation','${q.id}')" title="Email Quotation" aria-label="Email Quotation" style="font-size:15px;padding:4px 7px;">✉️</button>
  ```

- [ ] **Step 3: Delivery Notes — renderDNTable**

  Find `openDNPDF` button in `renderDNTable`. Add after it:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('delivery-note','${dn.id}')" title="Email Delivery Note" aria-label="Email Delivery Note" style="font-size:15px;padding:4px 7px;">✉️</button>
  ```

- [ ] **Step 4: Credit Notes — renderCNTable**

  Find `openCNPDF` button in `renderCNTable`. Add after it:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('credit-note','${cn.id}')" title="Email Credit Note" aria-label="Email Credit Note" style="font-size:15px;padding:4px 7px;">✉️</button>
  ```

- [ ] **Step 5: Receipt history modal — openInvoiceReceiptHistory (~line 10399)**

  Find the 🖨 Print Receipt button in the receipt history table row render. Add after it:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('receipt','${r.id}')" title="Email Receipt" aria-label="Email Receipt" style="font-size:15px;padding:4px 7px;">✉️</button>
  ```

- [ ] **Step 6: Manual verification**

  Open the ERP in browser:
  - Navigate to AR → confirm ✉️ button appears on each invoice row
  - Click ✉️ on a posted invoice → modal opens, To pre-filled with client email, Subject pre-filled
  - Click Cancel

- [ ] **Step 7: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add email buttons to AR, Quotations, DN, CN, Receipt tables"
  ```

---

## Task 7: Work Order Receipt Builder + Email Button

**Files:**
- Modify: `index.html`

- [ ] **Step 1: Add buildWorkOrderReceiptHTML**

  After `sendEmailDocument` (end of the email helpers block), add:

  ```js
  function buildWorkOrderReceiptHTML(job, labour, materials, consumables, co) {
    const css = `<style>
      *{box-sizing:border-box;margin:0;padding:0;}
      body{font-family:Arial,sans-serif;font-size:12px;color:#333;background:#fff;}
      .wrap{padding:24px 28px;}
      .header{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid #c9a84c;padding-bottom:14px;margin-bottom:18px;}
      .co-block .co-name{font-size:17px;font-weight:700;color:#1a1a2e;}
      .co-block .co-sub{font-size:11px;color:#777;margin-top:3px;}
      .doc-block{text-align:right;}
      .doc-block .doc-title{font-size:20px;font-weight:700;color:#c9a84c;letter-spacing:.5px;}
      .doc-block .doc-no{font-size:13px;color:#555;margin-top:4px;}
      .meta-grid{display:grid;grid-template-columns:1fr 1fr;gap:4px 24px;margin-bottom:16px;}
      .meta-row{display:flex;gap:8px;font-size:11px;}
      .meta-key{color:#888;min-width:90px;flex-shrink:0;}
      .meta-val{font-weight:600;}
      .section-title{font-size:10px;font-weight:700;text-transform:uppercase;color:#c9a84c;border-bottom:1px solid #e8e8e8;padding-bottom:3px;margin:14px 0 8px;}
      table{width:100%;border-collapse:collapse;font-size:11px;}
      th{background:#f5f5f5;padding:6px 8px;text-align:left;border:1px solid #ddd;font-size:10px;text-transform:uppercase;color:#555;}
      td{padding:5px 8px;border:1px solid #ddd;}
      .right{text-align:right;}
      .total-row td{font-weight:700;background:#fafafa;}
      .grand{display:flex;justify-content:flex-end;margin-top:10px;}
      .grand-box{background:#1a1a2e;color:#c9a84c;padding:10px 18px;font-size:14px;font-weight:700;border-radius:4px;}
      .sign-row{display:flex;gap:32px;margin-top:28px;}
      .sign-box{flex:1;border-top:1px solid #aaa;padding-top:6px;font-size:10px;color:#777;}
      .empty{color:#aaa;font-style:italic;font-size:11px;padding:8px;}
    </style>`;

    const fmtMoney = (n) => parseFloat(n||0).toLocaleString('en-TT',{minimumFractionDigits:2,maximumFractionDigits:2});

    const labourTotal = labour.reduce((s,r) => s + parseFloat(r.total||r.amount||0), 0);
    const materialsTotal = materials.reduce((s,r) => s + parseFloat(r.total||r.amount||0), 0);
    const consumablesTotal = consumables.reduce((s,r) => s + parseFloat(r.total||r.amount||0), 0);
    const grandTotal = labourTotal + materialsTotal + consumablesTotal;

    const labourRows = labour.length
      ? labour.map(r => `<tr>
          <td>${escHTML(r.date||'')}</td>
          <td>${escHTML(r.employee||r.technician||'')}</td>
          <td>${escHTML(r.classification||'')}</td>
          <td class="right">${r.hours||''}</td>
          <td class="right">${fmtMoney(r.rate)}</td>
          <td class="right">${fmtMoney(r.total||r.amount)}</td>
        </tr>`).join('')
      : `<tr><td colspan="6" class="empty">No labour entries</td></tr>`;

    const materialsRows = materials.length
      ? materials.map(r => `<tr>
          <td>${escHTML(r.description||r.item||'')}</td>
          <td class="right">${r.quantity||r.qty||''}</td>
          <td>${escHTML(r.unit||'')}</td>
          <td class="right">${fmtMoney(r.unit_cost||r.rate)}</td>
          <td class="right">${fmtMoney(r.total||r.amount)}</td>
        </tr>`).join('')
      : `<tr><td colspan="5" class="empty">No materials</td></tr>`;

    const consumablesRows = consumables.length
      ? consumables.map(r => `<tr>
          <td>${escHTML(r.description||r.item||'')}</td>
          <td class="right">${r.quantity||r.qty||''}</td>
          <td>${escHTML(r.unit||'')}</td>
          <td class="right">${fmtMoney(r.unit_cost||r.rate)}</td>
          <td class="right">${fmtMoney(r.total||r.amount)}</td>
        </tr>`).join('')
      : `<tr><td colspan="5" class="empty">No consumables</td></tr>`;

    const coAddr = [co.address_line1, co.address_line2, co.city, co.country].filter(Boolean).join(', ');

    return `<!DOCTYPE html><html><head><meta charset="utf-8">${css}</head><body><div class="wrap">
      <div class="header">
        <div class="co-block">
          ${co.logo_url ? `<img src="${escHTML(co.logo_url)}" style="height:44px;margin-bottom:6px;display:block;">` : ''}
          <div class="co-name">${escHTML(co.name||'')}</div>
          <div class="co-sub">${escHTML(coAddr)}</div>
          ${co.phone ? `<div class="co-sub">${escHTML(co.phone)}</div>` : ''}
        </div>
        <div class="doc-block">
          <div class="doc-title">WORK ORDER RECEIPT</div>
          <div class="doc-no">${escHTML(job.job_no||'DRAFT')}</div>
        </div>
      </div>

      <div class="meta-grid">
        <div class="meta-row"><span class="meta-key">Date:</span><span class="meta-val">${job.start_date ? formatDateDisplay(job.start_date) : '—'}</span></div>
        <div class="meta-row"><span class="meta-key">Customer:</span><span class="meta-val">${escHTML(job.customer||'—')}</span></div>
        <div class="meta-row"><span class="meta-key">Completed:</span><span class="meta-val">${job.completion_date ? formatDateDisplay(job.completion_date) : '—'}</span></div>
        <div class="meta-row"><span class="meta-key">Contact:</span><span class="meta-val">${escHTML(job.contact||'—')}</span></div>
        <div class="meta-row" style="grid-column:1/-1;"><span class="meta-key">Description:</span><span class="meta-val">${escHTML(job.description||'—')}</span></div>
        ${job.site_location ? `<div class="meta-row" style="grid-column:1/-1;"><span class="meta-key">Site:</span><span class="meta-val">${escHTML(job.site_location)}</span></div>` : ''}
      </div>

      <div class="section-title">Labour</div>
      <table>
        <thead><tr><th>Date</th><th>Employee</th><th>Classification</th><th class="right">Hrs</th><th class="right">Rate</th><th class="right">Total</th></tr></thead>
        <tbody>${labourRows}</tbody>
        <tfoot><tr class="total-row"><td colspan="5" class="right">Labour Total</td><td class="right">${fmtMoney(labourTotal)}</td></tr></tfoot>
      </table>

      <div class="section-title">Materials</div>
      <table>
        <thead><tr><th>Description</th><th class="right">Qty</th><th>Unit</th><th class="right">Unit Cost</th><th class="right">Total</th></tr></thead>
        <tbody>${materialsRows}</tbody>
        <tfoot><tr class="total-row"><td colspan="4" class="right">Materials Total</td><td class="right">${fmtMoney(materialsTotal)}</td></tr></tfoot>
      </table>

      <div class="section-title">Consumables</div>
      <table>
        <thead><tr><th>Description</th><th class="right">Qty</th><th>Unit</th><th class="right">Unit Cost</th><th class="right">Total</th></tr></thead>
        <tbody>${consumablesRows}</tbody>
        <tfoot><tr class="total-row"><td colspan="4" class="right">Consumables Total</td><td class="right">${fmtMoney(consumablesTotal)}</td></tr></tfoot>
      </table>

      <div class="grand"><div class="grand-box">TOTAL: ${fmtMoney(grandTotal)}</div></div>

      <div class="sign-row">
        <div class="sign-box">Prepared by<br><br><br>_______________________<br>${escHTML(currentUser?.full_name||'')}</div>
        <div class="sign-box">Received / Approved by<br><br><br>_______________________<br>Date: ___________________</div>
      </div>
    </div></body></html>`;
  }
  ```

- [ ] **Step 2: Add ✉️ button to Work Orders table**

  In `index.html`, search for the Work Orders job row render (look for `jcRenderJobsTable` or the table that calls `openInvoicePDF` / has `jcOpenJob`). Find the action cell for each job row and add:
  ```js
  <button class="btn btn-ghost btn-sm btn-icon" onclick="openEmailDocument('work-order','${j.id}')" title="Email Work Order Receipt" aria-label="Email Work Order Receipt" style="font-size:15px;padding:4px 7px;">✉️</button>
  ```
  Only show this button when `j.status === 'completed'`.

- [ ] **Step 3: Manual verification**

  Navigate to Work Orders in the ERP. Open a completed job. Click ✉️. Confirm modal opens with job_no in subject line.

- [ ] **Step 4: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add Work Order Receipt PDF builder and email button"
  ```

---

## Task 8: AR Statement Builder + Email Button

**Files:**
- Modify: `index.html`

- [ ] **Step 1: Add buildARStatementHTML**

  After `buildWorkOrderReceiptHTML`, add:

  ```js
  function buildARStatementHTML(contact, invs, co) {
    const css = `<style>
      *{box-sizing:border-box;margin:0;padding:0;}
      body{font-family:Arial,sans-serif;font-size:12px;color:#333;background:#fff;}
      .wrap{padding:24px 28px;}
      .header{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid #c9a84c;padding-bottom:14px;margin-bottom:18px;}
      .co-name{font-size:17px;font-weight:700;color:#1a1a2e;}
      .co-sub{font-size:11px;color:#777;margin-top:3px;}
      .doc-title{font-size:20px;font-weight:700;color:#c9a84c;text-align:right;}
      .as-of{font-size:11px;color:#777;text-align:right;margin-top:4px;}
      .client-block{background:#f8f8f8;padding:10px 14px;border-radius:4px;margin-bottom:16px;font-size:12px;}
      .client-name{font-size:14px;font-weight:700;margin-bottom:4px;}
      table{width:100%;border-collapse:collapse;font-size:11px;}
      th{background:#1a1a2e;color:#c9a84c;padding:7px 9px;text-align:left;font-size:10px;text-transform:uppercase;}
      th.right,td.right{text-align:right;}
      td{padding:6px 9px;border-bottom:1px solid #eee;}
      tr:hover td{background:#fafafa;}
      .status-paid{color:#27ae60;font-weight:600;}
      .status-overdue{color:#c0392b;font-weight:600;}
      .status-partial{color:#e67e22;font-weight:600;}
      .total-row td{font-weight:700;border-top:2px solid #1a1a2e;background:#f8f8f8;}
      .balance-box{display:flex;justify-content:flex-end;margin-top:14px;}
      .balance-inner{background:#1a1a2e;color:#c9a84c;padding:12px 20px;border-radius:4px;font-size:15px;font-weight:700;}
      .footer{margin-top:24px;font-size:10px;color:#aaa;text-align:center;border-top:1px solid #eee;padding-top:8px;}
    </style>`;

    const fmtMoney = (n, cur) => {
      const sym = cur === 'USD' ? 'US$' : cur === 'GYD' ? 'G$' : 'TT$';
      return sym + ' ' + parseFloat(n||0).toLocaleString('en-TT',{minimumFractionDigits:2,maximumFractionDigits:2});
    };

    const asOf = new Date().toLocaleDateString('en-TT', { year:'numeric', month:'long', day:'numeric' });
    const clientName = escHTML(contact.trading_name || contact.name || '—');
    const clientAddr = [contact.bill_address_line1, contact.city, contact.country].filter(Boolean).map(escHTML).join(', ');

    const totalBalance = invs.reduce((s,i) => s + parseFloat(i.balance_due||0), 0);
    const primaryCur   = invs[0]?.currency || co.currency || 'TTD';

    const rows = invs.length ? invs.map(inv => {
      const statusClass = inv.status === 'paid' ? 'status-paid' : inv.status === 'overdue' ? 'status-overdue' : inv.status === 'partial' ? 'status-partial' : '';
      return `<tr>
        <td>${escHTML(inv.invoice_no||'—')}</td>
        <td>${formatDateDisplay(inv.invoice_date)}</td>
        <td>${inv.due_date ? formatDateDisplay(inv.due_date) : '—'}</td>
        <td class="right">${fmtMoney(inv.total, inv.currency)}</td>
        <td class="right">${fmtMoney(parseFloat(inv.total||0) - parseFloat(inv.balance_due||0), inv.currency)}</td>
        <td class="right">${fmtMoney(inv.balance_due, inv.currency)}</td>
        <td><span class="${statusClass}">${inv.status.charAt(0).toUpperCase()+inv.status.slice(1)}</span></td>
      </tr>`;
    }).join('') : `<tr><td colspan="7" style="text-align:center;color:#aaa;padding:16px;">No invoices found</td></tr>`;

    const coAddr = [co.address_line1, co.address_line2, co.city, co.country].filter(Boolean).join(', ');

    return `<!DOCTYPE html><html><head><meta charset="utf-8">${css}</head><body><div class="wrap">
      <div class="header">
        <div>
          ${co.logo_url ? `<img src="${escHTML(co.logo_url)}" style="height:44px;margin-bottom:6px;display:block;">` : ''}
          <div class="co-name">${escHTML(co.name||'')}</div>
          <div class="co-sub">${escHTML(coAddr)}</div>
        </div>
        <div>
          <div class="doc-title">ACCOUNT STATEMENT</div>
          <div class="as-of">As of ${asOf}</div>
        </div>
      </div>

      <div class="client-block">
        <div class="client-name">${clientName}</div>
        ${clientAddr ? `<div style="color:#666;font-size:11px;">${clientAddr}</div>` : ''}
        ${contact.email ? `<div style="color:#666;font-size:11px;">${escHTML(contact.email)}</div>` : ''}
      </div>

      <table>
        <thead><tr>
          <th>Invoice #</th><th>Date</th><th>Due Date</th>
          <th class="right">Amount</th><th class="right">Paid</th>
          <th class="right">Balance</th><th>Status</th>
        </tr></thead>
        <tbody>${rows}</tbody>
        <tfoot><tr class="total-row">
          <td colspan="5" class="right">Total Balance Due</td>
          <td class="right">${fmtMoney(totalBalance, primaryCur)}</td>
          <td></td>
        </tr></tfoot>
      </table>

      <div class="balance-box">
        <div class="balance-inner">BALANCE DUE: ${fmtMoney(totalBalance, primaryCur)}</div>
      </div>

      <div class="footer">Generated by Meridian ERP · ${escHTML(co.name||'')} · ${asOf}</div>
    </div></body></html>`;
  }
  ```

- [ ] **Step 2: Add "Email Statement" button to AR toolbar**

  In `renderARTable`, find the filter toolbar (the area with the search input and status filter). Add this button at the end of the toolbar row. It only shows/is relevant when the client filter is active:

  ```js
  // At the end of renderARTable, or within the toolbar HTML string, add:
  <button class="btn btn-ghost btn-sm" onclick="_emailARStatement()" title="Email statement to filtered client">✉️ Email Statement</button>
  ```

  Then add the helper function after `buildARStatementHTML`:
  ```js
  function _emailARStatement() {
    // Get the currently filtered contact (requires AR client filter to be a single contact)
    const contactId = document.getElementById('ar-filter-client')?.value || '';
    if (!contactId) { showToast('Filter AR by a single client first.', 'error'); return; }
    openEmailDocument('ar-statement', contactId);
  }
  ```

  Note: `ar-filter-client` is the ID of the client filter select in the AR toolbar. Search `index.html` for the AR client filter element — if the ID differs, use the correct one.

- [ ] **Step 3: Manual verification**

  Navigate to AR. Filter by a specific client. Click "✉️ Email Statement". Confirm modal opens with client email pre-filled and subject "Account Statement from [company]".

- [ ] **Step 4: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add AR Statement PDF builder and email button"
  ```

---

## Task 9: Company send_from_email in Settings

**Files:**
- Modify: `index.html`

- [ ] **Step 1: Add field to company modal**

  Search for `modal-erp-company` (the company edit modal). Find the form fields — look for `erp-co-email`. After the company email field, add:

  ```html
  <div class="field">
    <label>Send From Email <span style="color:var(--text-3);font-size:11px;">(verified Resend sender)</span></label>
    <input type="email" id="erp-co-send-from" placeholder="accounts@q2m.io">
  </div>
  ```

- [ ] **Step 2: Populate on edit**

  Search for `document.getElementById('erp-co-email').value`. After that line, add:
  ```js
  document.getElementById('erp-co-send-from').value = c.send_from_email || '';
  ```

- [ ] **Step 3: Save on submit**

  Search for the `saveERPCompany` function (or equivalent). Find where the company PATCH payload is built. Add:
  ```js
  send_from_email: document.getElementById('erp-co-send-from').value.trim() || null,
  ```

- [ ] **Step 4: Manual verification**

  Settings → ERP Companies → Edit a company. Confirm "Send From Email" field appears. Set `accounts@q2m.io` for Q2 Machines. Save. Reopen — field persists.

- [ ] **Step 5: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add send_from_email field to company settings"
  ```

---

## Task 10: Edge Function — send-notification

**Files:**
- Create: `supabase/functions/send-notification/index.ts`

- [ ] **Step 1: Create the function**

```typescript
// supabase/functions/send-notification/index.ts

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string | null, status: number) {
  return new Response(body, {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function getJwtSub(jwt: string): string {
  const payload = JSON.parse(atob(jwt.split(".")[1]));
  return payload.sub;
}

function interpolate(template: string, ctx: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_, k) => ctx[k] ?? "");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return corsResponse(JSON.stringify({ error: "Method not allowed" }), 405);

  const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY         = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const RESEND_API_KEY   = Deno.env.get("RESEND_API_KEY")!;

  let body: {
    event_key: string;
    entity_type?: string;
    entity_id?: string;
    company_id: string;
    context: Record<string, string>;
    source?: string;
  };
  try { body = await req.json(); } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON" }), 400);
  }
  const { event_key, entity_type, entity_id, company_id, context, source } = body;
  if (!event_key || !company_id || !context) {
    return corsResponse(JSON.stringify({ error: "Missing: event_key, company_id, context" }), 400);
  }

  // Auth validation
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return corsResponse(JSON.stringify({ error: "Missing Authorization header" }), 401);
  }

  if (source !== "cron") {
    const callerToken = authHeader.slice(7);
    let callerSub: string;
    try { callerSub = getJwtSub(callerToken); } catch {
      return corsResponse(JSON.stringify({ error: "Malformed JWT" }), 401);
    }
    const pRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${callerSub}&is_active=eq.true&limit=1`,
      { headers: { Authorization: `Bearer ${authHeader.slice(7)}`, apikey: ANON_KEY } }
    );
    const profiles = await pRes.json();
    if (!Array.isArray(profiles) || !profiles.length) {
      return corsResponse(JSON.stringify({ error: "Unauthorized" }), 403);
    }
  }

  // Look up notification type
  const ntRes = await fetch(
    `${SUPABASE_URL}/rest/v1/notification_types?event_key=eq.${event_key}&enabled=eq.true&limit=1`,
    { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
  );
  const ntRows = await ntRes.json();
  if (!ntRows.length) return corsResponse(JSON.stringify({ success: true, skipped: "disabled_or_unknown" }), 200);
  const nt = ntRows[0];

  // Resolve recipients
  let recipientIds: string[] = [];
  if (nt.recipient === "direct" && context.recipient_user_id) {
    recipientIds = [context.recipient_user_id];
  } else if (nt.recipient === "role:admin") {
    const usersRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_users?company_id=eq.${company_id}&is_active=eq.true&select=id,email`,
      { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
    );
    const allUsers = await usersRes.json();
    // In Phase 1: notify all active users in the company (admins identified by role column or RBAC)
    // Simplification: send to all active users; refine with RBAC in a future pass
    recipientIds = (allUsers as Array<{ id: string; email: string }>)
      .filter(u => u.email).map(u => u.id);
  }
  if (!recipientIds.length) return corsResponse(JSON.stringify({ success: true, skipped: "no_recipients" }), 200);

  // Get company sender
  const coRes = await fetch(
    `${SUPABASE_URL}/rest/v1/companies?id=eq.${company_id}&select=name,email,send_from_email&limit=1`,
    { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
  );
  const cos = await coRes.json();
  const co = cos[0] ?? {};
  const fromEmail = co.send_from_email ?? "accounts@terranresources.com";
  const fromName  = co.name ?? "Meridian ERP";

  for (const recipientId of recipientIds) {
    // Check preferences (absence = enabled by default)
    const prefRes = await fetch(
      `${SUPABASE_URL}/rest/v1/notification_preferences?user_id=eq.${recipientId}&event_key=eq.${event_key}&limit=1`,
      { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
    );
    const prefs = await prefRes.json();
    if (prefs.length && prefs[0].enabled === false) continue;

    // Get recipient details
    const recipRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_users?id=eq.${recipientId}&select=full_name,email&limit=1`,
      { headers: { Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY } }
    );
    const recips = await recipRes.json();
    if (!recips.length || !recips[0].email) continue;
    const recip = recips[0];

    const ctx = { ...context, recipient_name: recip.full_name ?? "Team Member" };
    const subject = interpolate(nt.subject_tpl, ctx);
    const html    = interpolate(nt.body_html, ctx);

    const rRes = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: `${fromName} <${fromEmail}>`, to: [recip.email], subject, html }),
    });

    const sentOk = rRes.ok;
    const errText = sentOk ? null : await rRes.text().catch(() => "unknown");

    await fetch(`${SUPABASE_URL}/rest/v1/notification_log`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`, apikey: SERVICE_ROLE_KEY,
        "Content-Type": "application/json", Prefer: "return=minimal",
      },
      body: JSON.stringify({
        event_key, company_id,
        entity_type: entity_type ?? null,
        entity_id: entity_id ?? null,
        recipient_id: recipientId,
        recipient_email: recip.email,
        subject,
        error: errText,
      }),
    });
  }

  return corsResponse(JSON.stringify({ success: true }), 200);
});
```

- [ ] **Step 2: Deploy**

  ```bash
  npx supabase functions deploy send-notification --project-ref fcagxvjxfqqkmuposmcb
  ```

- [ ] **Step 3: Smoke test**

  ```bash
  curl -X POST https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification \
    -H "Authorization: Bearer <your_access_token>" \
    -H "Content-Type: application/json" \
    -d '{"event_key":"task.assigned","company_id":"<your_company_uuid>","context":{"task_title":"Test task","due_date":"2026-07-01","description":"Test","assigned_by":"Admin","recipient_user_id":"<your_user_uuid>"}}'
  ```
  Expected: `{"success":true}` and email arrives at `erp_users.email` for the recipient.

- [ ] **Step 4: Commit**

  ```bash
  git add supabase/functions/send-notification/
  git commit -m "feat: add send-notification Edge Function"
  ```

---

## Task 11: Notification Triggers in index.html

**Files:**
- Modify: `index.html`

Add a `_sendNotification` helper then call it from 4 save functions.

- [ ] **Step 1: Add _sendNotification helper**

  Search for `// ── Email PDF helpers ──`. Before that block, add:

  ```js
  // ── Notification helper ───────────────────────────────────────────────────
  function _sendNotification(eventKey, entityType, entityId, context) {
    // Fire-and-forget — failures are logged server-side, never block the UI
    fetch(`${SUPABASE_URL}/functions/v1/send-notification`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${_accessToken}`,
        apikey: SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        event_key:   eventKey,
        entity_type: entityType,
        entity_id:   entityId,
        company_id:  currentCompany.id,
        context
      })
    }).catch(() => {}); // silent failure
  }
  ```

- [ ] **Step 2: Wire task.assigned in saveTask (~line 15230)**

  Find the existing notification block in `saveTask`:
  ```js
  if (payload.assignee_id && payload.assignee_id !== prevAssigneeId) {
    sbPost('erp_notifications', { ... }).then(...).catch(() => {});
  }
  ```
  Immediately after the existing `sbPost('erp_notifications', ...)` call (keep it, add below):
  ```js
    _sendNotification('task.assigned', 'task', taskId, {
      task_title:         payload.title,
      due_date:           payload.due_date || '—',
      description:        payload.description || '—',
      assigned_by:        currentUser?.full_name || 'A team member',
      recipient_user_id:  payload.assignee_id
    });
  ```

- [ ] **Step 3: Wire job.assigned in jcSaveJob (~line 7457)**

  Find `jcSaveJob`. After a successful save (look for `showToast` on success), add:
  ```js
  // Notify assigned employee if set
  const assignedEmpId = data.assigned_employee_id || null; // check the actual field name in jcCollectFormData
  if (assignedEmpId) {
    _sendNotification('job.assigned', 'job', jobId, {
      job_no:      data.job_no || '',
      description: data.description || '—',
      due_date:    data.due_date || '—',
      assigned_by: currentUser?.full_name || 'A team member',
      recipient_user_id: assignedEmpId
    });
  }
  ```
  Note: check the actual field name for employee assignment in `jcCollectFormData` — search for `assigned_employee_id` or `employee_id` in the job save payload. Use whatever key maps to a user ID.

- [ ] **Step 4: Wire deal.won and deal.lost in quickMarkOpp (~line 14882)**

  Find `quickMarkOpp`. After the PATCH succeeds and the in-memory update runs, add:
  ```js
  if (status === 'won' || status === 'lost') {
    const opp = crmOpps.find(o => o.id === id) || {};
    const c   = contacts.find(x => x.id === opp.contact_id) || {};
    _sendNotification(status === 'won' ? 'deal.won' : 'deal.lost', 'opportunity', id, {
      deal_name:  opp.name || '—',
      deal_value: opp.value ? fmt(opp.value, opp.currency) : '—',
      client_name: c.trading_name || c.name || '—',
      lost_reason: opp.lost_reason || '—',
      recipient_user_id: opp.owner_id || currentUser?.id || ''
    });
  }
  ```

- [ ] **Step 5: Wire deal.won and deal.lost in saveOpportunity (~line 14843)**

  Find `saveOpportunity`. After successful save, when `status` transitions to `'won'` or `'lost'`, add the same notification call as Step 4 (check the saved payload's status vs the previous status using `_editOppId` lookup).

- [ ] **Step 6: Verify**

  In the ERP:
  - Create a CRM task with an assignee → check that the assignee receives an email
  - Mark an opportunity as Won → check that the owner receives an email

- [ ] **Step 7: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add notification triggers for task.assigned, job.assigned, deal.won/lost"
  ```

---

## Task 12: Settings Notifications Tab

**Files:**
- Modify: `index.html`

- [ ] **Step 1: Add Notifications tab to Settings view**

  Search for the Settings view (`view-settings` or `id="view-settings"`). Find the tab bar within Settings. Add a new tab:
  ```html
  <button class="tab-btn" onclick="switchSettingsTab('notifications',this)">Notifications</button>
  ```

- [ ] **Step 2: Add Notifications tab content panel**

  In the Settings view, alongside other tab panels (e.g., Profile, Security), add:
  ```html
  <div id="settings-tab-notifications" class="settings-tab-panel" style="display:none;">
    <div class="page-section-header">Email Notifications</div>
    <p style="font-size:12px;color:var(--text-2);margin-bottom:12px;">Toggle which email notifications you receive. Changes save immediately.</p>
    <div id="notif-prefs-grid" style="display:grid;gap:8px;max-width:480px;"></div>
  </div>
  ```

- [ ] **Step 3: Add loadNotifPrefs and renderNotifPrefs**

  ```js
  // ── Notification Preferences (Settings) ──────────────────────────────────
  let _notifTypes = [];
  let _notifPrefs = {};

  async function loadNotifPrefs() {
    document.getElementById('notif-prefs-grid').innerHTML = '<div style="color:var(--text-2);font-size:12px;">Loading…</div>';
    const [types, prefs] = await Promise.all([
      sbGet('notification_types', 'enabled=eq.true&order=event_key'),
      sbGet('notification_preferences', `user_id=eq.${currentUser?.erp_user_id || ''}`)
    ]);
    _notifTypes = types;
    _notifPrefs = {};
    prefs.forEach(p => { _notifPrefs[p.event_key] = p.enabled; });
    renderNotifPrefs();
  }

  function renderNotifPrefs() {
    const grid = document.getElementById('notif-prefs-grid');
    if (!grid) return;
    grid.innerHTML = _notifTypes.map(t => {
      const enabled = _notifPrefs[t.event_key] !== false; // default true
      return `<div style="display:flex;justify-content:space-between;align-items:center;padding:10px 12px;background:var(--surface);border:1px solid var(--border);border-radius:6px;">
        <span style="font-size:13px;">${escHTML(t.label)}</span>
        <label class="toggle" style="cursor:pointer;">
          <input type="checkbox" ${enabled ? 'checked' : ''} onchange="_toggleNotifPref('${t.event_key}',this.checked)" style="display:none;">
          <span class="toggle-slider" style="display:inline-block;width:36px;height:20px;border-radius:10px;background:${enabled ? 'var(--accent)' : 'var(--border)'};position:relative;transition:background .2s;">
            <span style="position:absolute;top:3px;left:${enabled ? '18px' : '3px'};width:14px;height:14px;border-radius:50%;background:#fff;transition:left .2s;"></span>
          </span>
        </label>
      </div>`;
    }).join('');
  }

  async function _toggleNotifPref(eventKey, enabled) {
    if (!currentUser?.erp_user_id) return;
    _notifPrefs[eventKey] = enabled;
    try {
      await sbPost('notification_preferences',
        { user_id: currentUser.erp_user_id, event_key: eventKey, enabled },
        { headers: { Prefer: 'resolution=merge-duplicates,return=minimal' } }
      );
    } catch(e) {
      showToast('Failed to save preference: ' + e.message, 'error');
    }
  }
  ```

  Note: `currentUser.erp_user_id` — check the actual property name in the `currentUser` object. Search for where `currentUser` is populated in `tryRestoreSession` / `doLogin`. Use whatever property holds the `erp_users.id` UUID.

- [ ] **Step 4: Call loadNotifPrefs when tab activated**

  Find `switchSettingsTab` (or equivalent). Add:
  ```js
  if (tab === 'notifications') loadNotifPrefs();
  ```

- [ ] **Step 5: Manual verification**

  Settings → Notifications tab. Confirm toggle grid renders for all 7 notification types. Toggle one off. Confirm `notification_preferences` row exists in Supabase with `enabled=false`. Trigger the disabled notification → confirm email is NOT sent.

- [ ] **Step 6: Commit**

  ```bash
  git add index.html
  git commit -m "feat: add Notifications settings tab with per-user preference toggles"
  ```

---

## Task 13: pg_cron Scheduled Notification Jobs

**Files:**
- Create: `supabase/migrations/20260622_email_cron_jobs.sql`

Prerequisite: Task 10 deployed (`send-notification` Edge Function live).

- [ ] **Step 1: Get the Edge Function URL and service role key**

  - URL: `https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification`
  - Service Role Key: Supabase Dashboard → Settings → API → `service_role` key

- [ ] **Step 2: Enable pg_net extension**

  In Supabase SQL Editor:
  ```sql
  CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;
  ```

- [ ] **Step 3: Write cron migration**

```sql
-- supabase/migrations/20260622_email_cron_jobs.sql
-- Replace {SUPABASE_URL} and {SERVICE_ROLE_KEY} with actual values before applying.
-- These are substituted at apply time — do NOT commit the key to git.
-- Apply via Supabase SQL Editor (not via migration file to avoid committing secrets).

-- Overdue tasks: notify assignee once (overdue_notified_at sentinel)
SELECT cron.schedule('notify-overdue-tasks', '0 7 * * *', $$
  SELECT extensions.http_post(
    url    := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body := jsonb_build_object(
      'event_key',   'task.overdue',
      'source',      'cron',
      'entity_type', 'task',
      'entity_id',   id::text,
      'company_id',  company_id::text,
      'context',     jsonb_build_object(
        'task_title',         title,
        'due_date',           due_date::text,
        'description',        COALESCE(description, '—'),
        'recipient_user_id',  COALESCE(assignee_id::text, '')
      )
    )::text
  )
  FROM crm_tasks
  WHERE completed = false
    AND due_date < CURRENT_DATE
    AND assignee_id IS NOT NULL
    AND overdue_notified_at IS NULL;
$$);

-- Overdue jobs: notify admins once
SELECT cron.schedule('notify-overdue-jobs', '0 7 * * *', $$
  SELECT extensions.http_post(
    url    := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body := jsonb_build_object(
      'event_key',   'job.overdue',
      'source',      'cron',
      'entity_type', 'job',
      'entity_id',   id::text,
      'company_id',  company_id::text,
      'context',     jsonb_build_object(
        'job_no',      job_no,
        'description', COALESCE(description, '—'),
        'customer',    COALESCE(customer, '—'),
        'due_date',    COALESCE(due_date::text, '—')
      )
    )::text
  )
  FROM jobs
  WHERE status NOT IN ('completed','cancelled')
    AND due_date < CURRENT_DATE
    AND overdue_notified_at IS NULL;
$$);

-- Overdue invoices: notify admins once
SELECT cron.schedule('notify-overdue-invoices', '0 8 * * *', $$
  SELECT extensions.http_post(
    url    := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body := jsonb_build_object(
      'event_key',   'invoice.overdue',
      'source',      'cron',
      'entity_type', 'invoice',
      'entity_id',   i.id::text,
      'company_id',  i.company_id::text,
      'context',     jsonb_build_object(
        'invoice_no',  i.invoice_no,
        'client_name', COALESCE(c.trading_name, c.name, '—'),
        'due_date',    i.due_date::text,
        'balance',     i.balance_due::text
      )
    )::text
  )
  FROM invoices i
  LEFT JOIN contacts c ON c.id = i.contact_id
  WHERE i.status = 'overdue'
    AND i.overdue_notified_at IS NULL;
$$);

-- After each cron fires and http_post is dispatched, mark the sentinel.
-- Note: pg_net is async — these UPDATE statements run in the same transaction as the SELECT.
-- The sentinel is set before confirmation of delivery (acceptable for "notify once" semantics).
UPDATE crm_tasks SET overdue_notified_at = now()
  WHERE completed = false AND due_date < CURRENT_DATE AND assignee_id IS NOT NULL AND overdue_notified_at IS NULL;

UPDATE jobs SET overdue_notified_at = now()
  WHERE status NOT IN ('completed','cancelled') AND due_date < CURRENT_DATE AND overdue_notified_at IS NULL;

UPDATE invoices SET overdue_notified_at = now()
  WHERE status = 'overdue' AND overdue_notified_at IS NULL;
```

  **IMPORTANT:** Replace `{SERVICE_ROLE_KEY}` with the actual value before running. Do NOT commit this file to git with the real key — apply it manually via Supabase SQL Editor.

- [ ] **Step 4: Apply manually in Supabase SQL Editor**

  Paste the SQL (with real key substituted) into Supabase SQL Editor and run. Do not save to file with the key in it.

- [ ] **Step 5: Verify cron jobs scheduled**

  ```sql
  SELECT jobname, schedule, command FROM cron.job ORDER BY jobname;
  ```
  Expected: 3 rows — `notify-overdue-invoices`, `notify-overdue-jobs`, `notify-overdue-tasks`.

- [ ] **Step 6: Commit** (migration file without the key — add a placeholder)

  ```bash
  git add supabase/migrations/20260622_email_cron_jobs.sql
  git commit -m "feat: add pg_cron scheduled overdue notification jobs"
  ```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|-----------------|------|
| Resend domain verification | Task 1 |
| companies.send_from_email | Tasks 2, 9 |
| erp_users.email + backfill | Task 2 |
| send-document-email Edge Fn | Task 3 |
| html2pdf.js + generatePDFBase64 | Task 4 |
| Email modal + openEmailDocument + sendEmailDocument | Task 5 |
| Invoice email button | Task 6 |
| Quotation email button | Task 6 |
| Delivery Note email button | Task 6 |
| Credit Note email button | Task 6 |
| Receipt email button | Task 6 |
| Work Order Receipt builder + button | Task 7 |
| AR Statement builder + button | Task 8 |
| notification_types + preferences + log tables | Task 2 |
| send-notification Edge Fn | Task 10 |
| task.assigned trigger | Task 11 |
| job.assigned trigger | Task 11 |
| deal.won / deal.lost triggers | Task 11 |
| Settings Notifications tab | Task 12 |
| task.overdue pg_cron | Task 13 |
| job.overdue pg_cron | Task 13 |
| invoice.overdue pg_cron | Task 13 |
| overdue_notified_at sentinels | Tasks 2, 13 |

All spec requirements covered. ✅

**Parallel execution:** Tasks 3 and 10 are fully independent (different files) and can be executed by separate agents simultaneously after Task 2 completes.
