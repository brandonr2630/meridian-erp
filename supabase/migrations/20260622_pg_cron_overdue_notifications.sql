-- pg_cron overdue notification jobs
-- MANUAL APPLY: Run in Supabase SQL Editor (requires service_role context).
-- Before applying, replace {SERVICE_ROLE_KEY} with the actual service role key from
-- Project Settings → API → service_role secret.
--
-- Prerequisites:
--   1. pg_net extension enabled (Database → Extensions → pg_net)
--   2. pg_cron extension enabled (Database → Extensions → pg_cron)
--   3. send-notification Edge Function deployed
--   4. RESEND_API_KEY set in Edge Function secrets
--
-- To re-run safely: script uses SELECT cron.unschedule() before scheduling.

-- ── Enable extensions (idempotent) ──────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── Remove old schedules if re-running ──────────────────────────────────────
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN ('notify-overdue-tasks', 'notify-overdue-jobs', 'notify-overdue-invoices');

-- ── 1. Overdue tasks (07:00 UTC daily) ──────────────────────────────────────
-- Fires task.overdue → assignee (direct). One-shot: overdue_notified_at guards repeat.
SELECT cron.schedule(
  'notify-overdue-tasks',
  '0 7 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object(
      'source',      'cron',
      'event_key',   'task.overdue',
      'company_id',  company_id,
      'entity_type', 'task',
      'entity_id',   id::text,
      'context',     jsonb_build_object(
        'task_title',        title,
        'due_date',          due_date::text,
        'description',       COALESCE(description, ''),
        'recipient_user_id', assignee_id::text
      )
    )
  )
  FROM crm_tasks
  WHERE completed = false
    AND due_date < CURRENT_DATE
    AND assignee_id IS NOT NULL
    AND overdue_notified_at IS NULL;
  $$
);

-- After firing, stamp overdue_notified_at so the task is never re-notified.
-- A second cron job runs 1 min later to stamp (pg_net is async).
SELECT cron.schedule(
  'stamp-overdue-tasks',
  '1 7 * * *',
  $$
  UPDATE crm_tasks
  SET    overdue_notified_at = NOW()
  WHERE  completed = false
    AND  due_date < CURRENT_DATE
    AND  assignee_id IS NOT NULL
    AND  overdue_notified_at IS NULL;
  $$
);

-- ── 2. Overdue jobs (07:05 UTC daily) ───────────────────────────────────────
-- Fires job.overdue → role:admin. One-shot via overdue_notified_at.
SELECT cron.schedule(
  'notify-overdue-jobs',
  '5 7 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object(
      'source',      'cron',
      'event_key',   'job.overdue',
      'company_id',  company_id,
      'entity_type', 'job',
      'entity_id',   id::text,
      'context',     jsonb_build_object(
        'job_no',      job_no,
        'description', COALESCE(description, ''),
        'customer',    COALESCE(customer, ''),
        'due_date',    due_date::text
      )
    )
  )
  FROM jobs
  WHERE status NOT IN ('Completed','Invoiced','Closed')
    AND due_date < CURRENT_DATE
    AND overdue_notified_at IS NULL;
  $$
);

SELECT cron.schedule(
  'stamp-overdue-jobs',
  '6 7 * * *',
  $$
  UPDATE jobs
  SET    overdue_notified_at = NOW()
  WHERE  status NOT IN ('Completed','Invoiced','Closed')
    AND  due_date < CURRENT_DATE
    AND  overdue_notified_at IS NULL;
  $$
);

-- ── 3. Overdue invoices (07:10 UTC daily) ───────────────────────────────────
-- Fires invoice.overdue → role:admin. Uses contacts join for client name.
SELECT cron.schedule(
  'notify-overdue-invoices',
  '10 7 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://fcagxvjxfqqkmuposmcb.supabase.co/functions/v1/send-notification',
    headers := jsonb_build_object(
      'Authorization', 'Bearer {SERVICE_ROLE_KEY}',
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object(
      'source',      'cron',
      'event_key',   'invoice.overdue',
      'company_id',  i.company_id,
      'entity_type', 'invoice',
      'entity_id',   i.id::text,
      'context',     jsonb_build_object(
        'invoice_no',  i.invoice_no,
        'client_name', COALESCE(c.trading_name, c.name, ''),
        'due_date',    i.due_date::text,
        'balance',     CONCAT('TT$', ROUND(i.balance_due::numeric, 2)::text)
      )
    )
  )
  FROM invoices i
  LEFT JOIN contacts c ON c.id = i.contact_id
  WHERE i.status = 'overdue'
    AND i.balance_due > 0
    AND i.overdue_notified_at IS NULL;
  $$
);

SELECT cron.schedule(
  'stamp-overdue-invoices',
  '11 7 * * *',
  $$
  UPDATE invoices
  SET    overdue_notified_at = NOW()
  WHERE  status = 'overdue'
    AND  balance_due > 0
    AND  overdue_notified_at IS NULL;
  $$
);
