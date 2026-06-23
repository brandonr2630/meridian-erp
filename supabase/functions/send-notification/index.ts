// Supabase Edge Function: send-notification
// Sends internal notification emails for ERP events (task assigned, job overdue, deal won, etc.)
//
// Expected request body (JSON):
//   { event_key, company_id, context,
//     source?,        // "cron" = trusted service-role call; omit for user-initiated
//     entity_type?,
//     entity_id? }
//
// Required env vars: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string | null, status: number, extra: Record<string, string> = {}) {
  return new Response(body, {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json", ...extra },
  });
}

function getJwtSub(jwt: string): string {
  const payload = JSON.parse(atob(jwt.split(".")[1]));
  return payload.sub;
}

/** Replace {{key}} placeholders with values from ctx. Missing keys become "". */
function interpolate(template: string, ctx: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_, k) => ctx[k] ?? "");
}

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return corsResponse(JSON.stringify({ error: "Method not allowed" }), 405);
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;

  // ── 1. Parse request body ──────────────────────────────────────────────────
  let body: {
    event_key: string;
    company_id: string;
    context: Record<string, string>;
    source?: string;
    entity_type?: string;
    entity_id?: string;
  };

  try {
    body = await req.json();
  } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON body" }), 400);
  }

  const { event_key, company_id, context, source, entity_type, entity_id } = body;

  if (!event_key || !company_id || !context) {
    return corsResponse(
      JSON.stringify({ error: "Missing required fields: event_key, company_id, context" }),
      400,
    );
  }

  // ── 2. Auth — skip JWT check for trusted cron calls ───────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return corsResponse(JSON.stringify({ error: "Missing or invalid Authorization header" }), 401);
  }

  const callerToken = authHeader.slice(7);

  if (source === "cron") {
    // Cron callers must present the service role key as their bearer token
    if (callerToken !== SERVICE_ROLE_KEY) {
      return corsResponse(JSON.stringify({ error: "Unauthorized" }), 401);
    }
  } else {
    // Non-cron callers must be active ERP users
    let callerSub: string;
    try {
      callerSub = getJwtSub(callerToken);
    } catch {
      return corsResponse(JSON.stringify({ error: "Malformed JWT" }), 401);
    }

    const profileRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${callerSub}&is_active=eq.true&limit=1`,
      {
        headers: {
          Authorization: `Bearer ${callerToken}`,
          apikey: ANON_KEY,
        },
      },
    );

    if (!profileRes.ok) {
      return corsResponse(JSON.stringify({ error: "Failed to verify caller identity" }), 500);
    }

    const profiles = await profileRes.json();
    if (!Array.isArray(profiles) || profiles.length === 0) {
      return corsResponse(JSON.stringify({ error: "Caller has no active ERP profile" }), 403);
    }
  }

  // ── 3. Look up notification type ──────────────────────────────────────────
  const ntRes = await fetch(
    `${SUPABASE_URL}/rest/v1/notification_types?event_key=eq.${encodeURIComponent(event_key)}&enabled=eq.true&limit=1`,
    {
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        apikey: SERVICE_ROLE_KEY,
      },
    },
  );

  if (!ntRes.ok) {
    return corsResponse(JSON.stringify({ error: "Failed to query notification_types" }), 500);
  }

  const ntRows = await ntRes.json();
  if (!Array.isArray(ntRows) || ntRows.length === 0) {
    return corsResponse(
      JSON.stringify({ success: true, skipped: "disabled_or_unknown" }),
      200,
    );
  }

  const notifType = ntRows[0] as {
    event_key: string;
    subject_tpl: string;
    body_html: string;
    recipient: string;
  };

  // ── 4. Resolve recipient user IDs ─────────────────────────────────────────
  let recipientIds: string[] = [];

  if (notifType.recipient === "direct") {
    if (!context.recipient_user_id) {
      return corsResponse(
        JSON.stringify({ success: true, skipped: "no_recipients" }),
        200,
      );
    }
    recipientIds = [context.recipient_user_id];
  } else if (notifType.recipient.startsWith("role:")) {
    const roleName = notifType.recipient.slice(5); // e.g. "admin"

    // Map role alias → actual system role names
    const roleNames = roleName === "admin"
      ? "super_admin,company_admin"
      : roleName;

    const roleRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_roles?name=in.(${encodeURIComponent(roleNames)})&select=id`,
      {
        headers: {
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          apikey: SERVICE_ROLE_KEY,
        },
      },
    );

    if (!roleRes.ok) {
      return corsResponse(JSON.stringify({ error: "Failed to query erp_roles" }), 500);
    }

    const roles = await roleRes.json() as { id: string }[];
    if (!roles.length) {
      return corsResponse(
        JSON.stringify({ success: true, skipped: "no_recipients" }),
        200,
      );
    }

    const roleIdList = roles.map((r) => r.id).join(",");

    const ucrRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_user_company_roles?company_id=eq.${company_id}&role_id=in.(${encodeURIComponent(roleIdList)})&select=user_id`,
      {
        headers: {
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          apikey: SERVICE_ROLE_KEY,
        },
      },
    );

    if (!ucrRes.ok) {
      return corsResponse(JSON.stringify({ error: "Failed to query erp_user_company_roles" }), 500);
    }

    const ucrs = await ucrRes.json() as { user_id: string }[];
    recipientIds = ucrs.map((u) => u.user_id);
  }

  if (recipientIds.length === 0) {
    return corsResponse(
      JSON.stringify({ success: true, skipped: "no_recipients" }),
      200,
    );
  }

  // ── 5. Get company sender details ─────────────────────────────────────────
  const companyRes = await fetch(
    `${SUPABASE_URL}/rest/v1/companies?id=eq.${company_id}&select=name,email,send_from_email&limit=1`,
    {
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        apikey: SERVICE_ROLE_KEY,
      },
    },
  );

  if (!companyRes.ok) {
    return corsResponse(JSON.stringify({ error: "Failed to query companies" }), 500);
  }

  const companyRows = await companyRes.json() as {
    name: string;
    email: string;
    send_from_email: string;
  }[];

  if (!companyRows.length) {
    return corsResponse(JSON.stringify({ error: "Company not found" }), 404);
  }

  const company = companyRows[0];
  const fromAddress = `${company.name} <${company.send_from_email || company.email}>`;

  // ── 6. Send to each recipient ─────────────────────────────────────────────
  const results: { user_id: string; sent: boolean; error?: string }[] = [];

  for (const userId of recipientIds) {
    // 6a. Check notification preference (absence = enabled by default)
    const prefRes = await fetch(
      `${SUPABASE_URL}/rest/v1/notification_preferences?user_id=eq.${userId}&event_key=eq.${encodeURIComponent(event_key)}&limit=1`,
      {
        headers: {
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          apikey: SERVICE_ROLE_KEY,
        },
      },
    );

    if (prefRes.ok) {
      const prefs = await prefRes.json() as { enabled: boolean }[];
      if (prefs.length > 0 && prefs[0].enabled === false) {
        // User has explicitly disabled this notification
        await insertNotificationLog({
          SUPABASE_URL, SERVICE_ROLE_KEY,
          event_key, company_id, entity_type, entity_id,
          recipient_id: userId, recipient_email: null,
          subject: null, error: "opted_out",
        });
        results.push({ user_id: userId, sent: false, error: "disabled_by_preference" });
        continue;
      }
    }

    // 6b. Get recipient profile
    const recipRes = await fetch(
      `${SUPABASE_URL}/rest/v1/erp_users?id=eq.${userId}&select=full_name,email&limit=1`,
      {
        headers: {
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          apikey: SERVICE_ROLE_KEY,
        },
      },
    );

    if (!recipRes.ok) {
      const logErr = "Failed to fetch recipient profile";
      await insertNotificationLog({
        SUPABASE_URL, SERVICE_ROLE_KEY,
        event_key, company_id, entity_type, entity_id,
        recipient_id: userId, recipient_email: null,
        subject: null, error: logErr,
      });
      results.push({ user_id: userId, sent: false, error: logErr });
      continue;
    }

    const recipRows = await recipRes.json() as { full_name: string; email: string }[];
    if (!recipRows.length || !recipRows[0].email) {
      const logErr = "Recipient has no email";
      await insertNotificationLog({
        SUPABASE_URL, SERVICE_ROLE_KEY,
        event_key, company_id, entity_type, entity_id,
        recipient_id: userId, recipient_email: null,
        subject: null, error: logErr,
      });
      results.push({ user_id: userId, sent: false, error: logErr });
      continue;
    }

    const recip = recipRows[0];

    // 6c. Interpolate templates
    const tplCtx: Record<string, string> = {
      ...context,
      recipient_name: recip.full_name ?? "",
    };

    const subject = interpolate(notifType.subject_tpl, tplCtx);
    const html = interpolate(notifType.body_html, tplCtx);

    // 6d. Send via Resend
    let sendError: string | null = null;

    try {
      const resendRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: fromAddress,
          to: [recip.email],
          subject,
          html,
        }),
      });

      if (!resendRes.ok) {
        const errBody = await resendRes.text().catch(() => "");
        sendError = `Resend error ${resendRes.status}: ${errBody}`;
      }
    } catch (e) {
      sendError = `Resend fetch failed: ${(e as Error).message}`;
    }

    // 6e. Log outcome (always, whether sent or failed)
    await insertNotificationLog({
      SUPABASE_URL, SERVICE_ROLE_KEY,
      event_key, company_id, entity_type, entity_id,
      recipient_id: userId, recipient_email: recip.email,
      subject, error: sendError,
    });

    results.push({
      user_id: userId,
      sent: sendError === null,
      ...(sendError ? { error: sendError } : {}),
    });
  }

  const sent = results.filter((r) => r.sent).length;
  const failed = results.filter((r) => !r.sent).length;

  return corsResponse(
    JSON.stringify({ success: true, sent, failed, results }),
    200,
  );
});

// ── Helpers ────────────────────────────────────────────────────────────────

async function insertNotificationLog(params: {
  SUPABASE_URL: string;
  SERVICE_ROLE_KEY: string;
  event_key: string;
  company_id: string;
  entity_type?: string;
  entity_id?: string;
  recipient_id: string;
  recipient_email: string | null;
  subject: string | null;
  error: string | null;
}): Promise<void> {
  const {
    SUPABASE_URL, SERVICE_ROLE_KEY,
    event_key, company_id, entity_type, entity_id,
    recipient_id, recipient_email, subject, error,
  } = params;

  const row: Record<string, string | null | undefined> = {
    event_key,
    company_id,
    recipient_id,
    recipient_email,
    subject,
    error,
  };

  if (entity_type) row.entity_type = entity_type;
  if (entity_id) row.entity_id = entity_id;
  if (!error) row.sent_at = new Date().toISOString();

  // Best-effort — swallow errors so a logging failure never breaks the send loop
  await fetch(`${SUPABASE_URL}/rest/v1/notification_log`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(row),
  }).catch(() => {});
}
