# Email Delivery — Design Spec

**Date:** 2026-06-22
**Session:** 35
**Status:** Approved

---

## Overview

Two distinct email subsystems built on a shared Resend integration:

1. **Document Email** — manual, user-triggered, sends PDF attachments to clients
2. **Notification Email** — automatic, event-triggered, sends HTML-only emails to internal team members

---

## Sending Domain

Two verified domains in Resend:

| Domain | Companies |
|--------|-----------|
| `terranresources.com` | Terran Resources Ltd, Terran Resources LLC, others |
| `q2m.io` | Q2 Machines |

`companies` table gains a `send_from_email` column (nullable, admin-configured in Settings). Falls back to `accounts@terranresources.com` if unset.

Email pattern for all outbound:
```
From:     {company.name} <{company.send_from_email}>
Reply-To: {company.email}
```

---

## Part 1 — Document Email

### Supported Documents (7)

| # | Document | PDF Builder | Status | Recipient |
|---|----------|-------------|--------|-----------|
| 1 | Invoice | `buildInvoicePDFHTML()` | ✅ exists | `contact.email` |
| 2 | Quotation | quotation renderer | ✅ exists | `contact.email` |
| 3 | Delivery Note | DN renderer | ✅ exists | `contact.email` |
| 4 | Credit Note | CN renderer | ✅ exists | `contact.email` |
| 5 | Payment Receipt | `buildReceiptPDFHTML()` | ✅ exists | `contact.email` |
| 6 | Work Order Receipt | `buildWorkOrderReceiptHTML()` | 🔨 new | job customer email |
| 7 | AR Statement | `buildARStatementHTML()` | 🔨 new | `contact.email` |

### PDF Generation

`html2pdf.js` loaded lazily from CDN on first email send. Client-side only — no server-side rendering dependency.

```js
async function generatePDFBase64(htmlString) {
  // Inject html into temp off-screen element
  // Run html2pdf({ ... }).outputPdf('datauristring')
  // Return base64 string
}
```

Output is image-based (canvas snapshot). Files are ~1–2 MB. Text is not selectable in the resulting PDF — acceptable for emailed documents.

### New PDF Builders

**`buildWorkOrderReceiptHTML(job, labourEntries, materialEntries, consumableEntries, contact)`**
- Company header (logo, name, address)
- Job header: number, date, client, site, description
- Labour table: technician, classification, date, hours, rate, total
- Materials table: item, qty, unit, unit cost, total
- Consumables table: item, qty, unit cost, total
- Costing summary: subtotals per category + grand total
- Sign-off section: completed by, completion date, client signature line

**`buildARStatementHTML(contact, invoices, asOfDate)`**
- Company header
- Client name + address block
- "Account Statement as of {date}"
- Invoice table: Invoice #, Date, Due Date, Total, Paid, Balance
- Footer: Total Balance Due (highlighted)
- Currency respected per invoice (TTD/USD/GYD)

### Edge Function: `send-document-email`

**File:** `supabase/functions/send-document-email/index.ts`

**Request body:**
```json
{
  "to": "client@example.com",
  "subject": "Invoice #INV-0042 from Q2 Machines",
  "message": "Please find attached...",
  "pdf_base64": "JVBERi0x...",
  "filename": "INV-0042.pdf",
  "reply_to": "accounts@q2m.io"
}
```

**Flow:**
1. Validate caller JWT (same pattern as `create-erp-user`)
2. Look up caller's company → resolve `send_from_email`
3. Call `https://api.resend.com/emails` with attachment
4. Return `{ success: true }` or error

**Env vars:** `RESEND_API_KEY`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`

**Resend payload:**
```json
{
  "from": "Q2 Machines <accounts@q2m.io>",
  "reply_to": "accounts@q2m.io",
  "to": ["client@example.com"],
  "subject": "Invoice #INV-0042 from Q2 Machines",
  "html": "<p>User message...</p>",
  "attachments": [{
    "filename": "INV-0042.pdf",
    "content": "JVBERi0x..."
  }]
}
```

### UI

**Send Email modal (`modal-send-email`)**
- Fields: To (pre-filled from contact.email), Subject (pre-filled per doc type), Message (textarea, editable)
- "Send" button → shows spinner while generating PDF + sending
- Toast on success/error

**✉️ button placement (next to existing 🖨 buttons):**
- AR invoices table row
- Quotations table row
- Delivery Notes table row
- Credit Notes table row
- AR receipt history modal (per receipt row)
- Work Orders table row (once WO receipt builder exists)
- AR table toolbar: "Email Statement" button when filtered to a single client

**Client functions:**
```js
openEmailDocument(type, id)   // opens modal, pre-fills fields, fetches data
sendEmailDocument()           // generates PDF, calls Edge Function
generatePDFBase64(htmlString) // html2pdf.js wrapper, returns base64
```

---

## Part 2 — Notification System

### Schema (3 new tables + 1 column)

```sql
-- Add to erp_users (backfill from auth.users via service role at migration time)
ALTER TABLE erp_users ADD COLUMN email text;
-- Backfill: UPDATE erp_users SET email = au.email FROM auth.users au WHERE au.id = erp_users.auth_user_id;

-- Notification type registry (seeded, not user-edited)
CREATE TABLE notification_types (
  event_key    text PRIMARY KEY,
  label        text NOT NULL,
  subject_tpl  text NOT NULL,
  body_html    text NOT NULL,
  recipient    text NOT NULL,  -- 'direct' | 'role:admin' | 'owner'
  enabled      boolean DEFAULT true
);

-- Per-user opt-out preferences
CREATE TABLE notification_preferences (
  user_id   uuid REFERENCES erp_users(id) ON DELETE CASCADE,
  event_key text REFERENCES notification_types(event_key),
  enabled   boolean DEFAULT true,
  PRIMARY KEY (user_id, event_key)
);

-- Audit log + dedup guard
CREATE TABLE notification_log (
  id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  event_key       text NOT NULL,
  company_id      uuid,
  entity_type     text,
  entity_id       text,
  recipient_id    uuid REFERENCES erp_users(id),
  recipient_email text,
  subject         text,
  sent_at         timestamptz DEFAULT now(),
  error           text
);
```

RLS: `notification_log` and `notification_preferences` scoped to `company_id` / `user_id`. `notification_types` readable by all authenticated.

### Phase 1 Notification Types (seeded)

| event_key | Label | Recipient | Trigger |
|-----------|-------|-----------|---------|
| `task.assigned` | Task assigned to me | Assignee (direct) | On saveTask() |
| `task.overdue` | Task overdue | Assignee (direct) | pg_cron daily |
| `job.assigned` | Work order assigned to me | Employee (direct) | On saveJob() |
| `job.overdue` | Work order overdue | Admin (role) | pg_cron daily |
| `invoice.overdue` | Invoice overdue | Admin (role) | pg_cron daily |
| `deal.won` | Deal won | Owner (direct) | On saveOpportunity() / quickMarkOpp() |
| `deal.lost` | Deal lost | Owner (direct) | On saveOpportunity() / quickMarkOpp() |

Template variables use `{{double_braces}}` syntax, interpolated in the Edge Function.

### Edge Function: `send-notification`

**File:** `supabase/functions/send-notification/index.ts`

**Request body:**
```json
{
  "event_key": "task.assigned",
  "entity_type": "task",
  "entity_id": "uuid",
  "company_id": "uuid",
  "context": {
    "task_title": "Follow up with client",
    "due_date": "2026-06-30",
    "assigned_by": "Brandon R",
    "recipient_user_id": "uuid"
  }
}
```

**Flow:**
1. Validate caller JWT
2. Look up `notification_types` by `event_key` — return 204 if disabled
3. Resolve recipient: from `context.recipient_user_id` (direct) or sweep `erp_users` by role
4. Fetch recipient `email` from `erp_users`
5. Check `notification_preferences` — skip if opted out
6. Check `notification_log` — skip if same `event_key + entity_id` sent within 24h (dedup)
7. Interpolate `subject_tpl` + `body_html` with context
8. Call Resend API (HTML only, no attachment)
9. Insert into `notification_log`

**For pg_cron triggers:** `pg_net.http_post()` calls the Edge Function with service role key in the Authorization header (bypasses JWT user validation, uses a `source: 'cron'` flag).

### pg_cron Jobs

```sql
-- Daily 07:00 UTC — overdue tasks (one notification per task, not repeated daily)
SELECT cron.schedule('notify-overdue-tasks', '0 7 * * *', $$
  SELECT net.http_post(
    url := '{SUPABASE_URL}/functions/v1/send-notification',
    headers := '{"Authorization":"Bearer {SERVICE_ROLE_KEY}","Content-Type":"application/json"}'::jsonb,
    body := json_build_object(
      'event_key', 'task.overdue',
      'source', 'cron',
      'company_id', company_id,
      'entity_type', 'task',
      'entity_id', id::text,
      'context', json_build_object(
        'task_title', title,
        'due_date', due_date,
        'recipient_user_id', assignee_id
      )
    )::jsonb
  )
  FROM crm_tasks
  WHERE completed = false
    AND due_date < CURRENT_DATE
    AND overdue_notified_at IS NULL;  -- send once only
$$);
```

`URL` and `SERVICE_ROLE_KEY` are substituted at migration time via psql vars or hardcoded during deployment.

**One-shot dedup for scheduled notifications:** rather than the 24h log check, entity tables gain a `overdue_notified_at` column. Set to `now()` when the notification fires. Never re-sends unless the column is cleared (e.g., task due date extended). Same pattern for `jobs.overdue_notified_at` and `invoices.overdue_notified_at`.

Migrations add:
```sql
ALTER TABLE crm_tasks  ADD COLUMN overdue_notified_at timestamptz;
ALTER TABLE jobs       ADD COLUMN overdue_notified_at timestamptz;
ALTER TABLE invoices   ADD COLUMN overdue_notified_at timestamptz;
```

### Notification Preferences UI

Settings view → new **"Notifications" tab** (admin sees all types; non-admins see only their own applicable types).

Toggle grid per user:
```
Notification              Enabled
─────────────────────────────────
Task assigned to me         ✅
Task overdue                ✅
Work order assigned to me   ✅
Invoice overdue             ✅  ← admin only
Deal won                    ✅
Deal lost                   ✅
```

Saves via `UPSERT` to `notification_preferences`.

---

## Deployment

1. Verify `terranresources.com` + `q2m.io` in Resend dashboard (DNS TXT records)
2. Add `RESEND_API_KEY` to Supabase Edge Function secrets
3. Deploy `send-document-email` Edge Function
4. Deploy `send-notification` Edge Function
5. Apply DB migration (notification tables + `erp_users.email` + `companies.send_from_email`)
6. Seed `notification_types`
7. Enable `pg_net` extension + schedule cron jobs
8. Update `index.html`: html2pdf.js CDN, email buttons, modal, client functions, notification triggers, Settings Notifications tab

---

## Out of Scope

- In-app notification bell / unread count (future)
- Email open/click tracking (future)
- Unsubscribe link management (future)
- External notification emails to clients (e.g. payment reminders) — separate feature
- Bulk email / mail merge
