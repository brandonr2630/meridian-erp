-- Migration: email_delivery_20260622
-- Adds email delivery infrastructure:
--   companies.send_from_email, notification tables (types/prefs/log),
--   overdue_notified_at sentinels on crm_tasks/jobs/invoices, seed data

-- ── companies ────────────────────────────────────────────────────────────────
ALTER TABLE companies ADD COLUMN IF NOT EXISTS send_from_email text;

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
('task.assigned','Task assigned to me','Task assigned to you: {{task_title}}','<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;"><strong>{{assigned_by}}</strong> has assigned a task to you.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Task</td><td style="padding:6px 10px;border:1px solid #ddd;">{{task_title}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Due Date</td><td style="padding:6px 10px;border:1px solid #ddd;">{{due_date}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to view and action this task.</p>','direct'),
('task.overdue','Task overdue','Overdue task: {{task_title}}','<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">The following task is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Task</td><td style="padding:6px 10px;border:1px solid #ddd;">{{task_title}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to update this task.</p>','direct'),
('job.assigned','Work order assigned to me','Work order assigned to you: {{job_no}}','<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;"><strong>{{assigned_by}}</strong> has assigned a work order to you.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Job No</td><td style="padding:6px 10px;border:1px solid #ddd;">{{job_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Due Date</td><td style="padding:6px 10px;border:1px solid #ddd;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to view the work order.</p>','direct'),
('job.overdue','Work order overdue','Overdue work order: {{job_no}}','<p style="font-family:Arial,sans-serif;font-size:14px;">A work order is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Job No</td><td style="padding:6px 10px;border:1px solid #ddd;">{{job_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Description</td><td style="padding:6px 10px;border:1px solid #ddd;">{{description}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Customer</td><td style="padding:6px 10px;border:1px solid #ddd;">{{customer}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to update this work order.</p>','role:admin'),
('invoice.overdue','Invoice overdue','Overdue invoice: {{invoice_no}}','<p style="font-family:Arial,sans-serif;font-size:14px;">An invoice is <strong style="color:#c0392b;">overdue</strong>:</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Invoice</td><td style="padding:6px 10px;border:1px solid #ddd;">{{invoice_no}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Was Due</td><td style="padding:6px 10px;border:1px solid #ddd;color:#c0392b;">{{due_date}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Balance</td><td style="padding:6px 10px;border:1px solid #ddd;font-weight:bold;">{{balance}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to manage AR.</p>','role:admin'),
('deal.won','Deal won','Deal won: {{deal_name}}','<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">Your deal has been marked as <strong style="color:#27ae60;">WON</strong>.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Deal</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Value</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_value}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr></table><p style="font-family:Arial,sans-serif;font-size:13px;color:#888;">Log in to Meridian ERP to convert to a quotation.</p>','direct'),
('deal.lost','Deal lost','Deal lost: {{deal_name}}','<p style="font-family:Arial,sans-serif;font-size:14px;">Hi {{recipient_name}},</p><p style="font-family:Arial,sans-serif;font-size:14px;">Your deal has been marked as <strong style="color:#c0392b;">LOST</strong>.</p><table style="font-family:Arial,sans-serif;font-size:13px;border-collapse:collapse;width:100%;max-width:500px;"><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Deal</td><td style="padding:6px 10px;border:1px solid #ddd;">{{deal_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Client</td><td style="padding:6px 10px;border:1px solid #ddd;">{{client_name}}</td></tr><tr><td style="padding:6px 10px;background:#f5f5f5;font-weight:bold;border:1px solid #ddd;">Reason</td><td style="padding:6px 10px;border:1px solid #ddd;">{{lost_reason}}</td></tr></table>','direct')
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
    company_id IN (
      SELECT company_id FROM erp_users WHERE auth_user_id = auth.uid()
    )
  );
