// Supabase Edge Function: send-document-email
// Sends a PDF document (invoice, quote, delivery note, etc.) via Resend.
// Resolves the caller's company to determine the from-address and display name.
//
// Expected request body (JSON):
//   { to, subject, message?, pdf_base64, filename }
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
    to: string;
    subject: string;
    message?: string;
    pdf_base64: string;
    filename: string;
  };

  try {
    body = await req.json();
  } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON body" }), 400);
  }

  const { to, subject, message, pdf_base64, filename } = body;

  if (!to || !subject || !pdf_base64 || !filename) {
    return corsResponse(
      JSON.stringify({ error: "Missing required fields: to, subject, pdf_base64, filename" }),
      400,
    );
  }

  // ── 2. Validate caller JWT ─────────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return corsResponse(JSON.stringify({ error: "Missing or invalid Authorization header" }), 401);
  }

  const callerToken = authHeader.slice(7);
  let callerSub: string;

  try {
    callerSub = getJwtSub(callerToken);
  } catch {
    return corsResponse(JSON.stringify({ error: "Malformed JWT" }), 401);
  }

  // ── 3. Resolve caller's erp_users profile ─────────────────────────────────
  const profileUrl =
    `${SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${callerSub}&is_active=eq.true&limit=1`;

  const profileRes = await fetch(profileUrl, {
    headers: {
      Authorization: `Bearer ${callerToken}`,
      apikey: ANON_KEY,
    },
  });

  if (!profileRes.ok) {
    return corsResponse(JSON.stringify({ error: "Failed to verify caller identity" }), 500);
  }

  const profiles = await profileRes.json();

  if (!Array.isArray(profiles) || profiles.length === 0) {
    return corsResponse(JSON.stringify({ error: "Caller has no active ERP profile" }), 403);
  }

  const companyId: string = profiles[0].company_id;

  // ── 4. Resolve company for from-address and display name ───────────────────
  const companyUrl =
    `${SUPABASE_URL}/rest/v1/companies?id=eq.${companyId}&limit=1`;

  const companyRes = await fetch(companyUrl, {
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
    },
  });

  if (!companyRes.ok) {
    return corsResponse(JSON.stringify({ error: "Failed to resolve company" }), 500);
  }

  const companies = await companyRes.json();

  if (!Array.isArray(companies) || companies.length === 0) {
    return corsResponse(JSON.stringify({ error: "Company not found" }), 404);
  }

  const company = companies[0];
  const sendFromEmail: string =
    company.send_from_email || "accounts@terranresources.com";
  const companyName: string = company.name ?? "Terran Resources";
  const replyTo: string = company.email ?? sendFromEmail;

  // ── 5. Strip data URI prefix from base64 if present ───────────────────────
  const rawBase64 = pdf_base64.includes(",")
    ? pdf_base64.split(",")[1]
    : pdf_base64;

  // ── 6. Send email via Resend ───────────────────────────────────────────────
  const resendPayload = {
    from: `${companyName} <${sendFromEmail}>`,
    reply_to: replyTo,
    to: [to],
    subject,
    html: message ? `<p>${message.replace(/\n/g, "<br>")}</p>` : "<p>Please find the attached document.</p>",
    attachments: [
      {
        filename,
        content: rawBase64,
      },
    ],
  };

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(resendPayload),
  });

  if (!resendRes.ok) {
    const errData = await resendRes.json().catch(() => ({}));
    const message = (errData as { message?: string }).message ?? "Failed to send email";
    return corsResponse(JSON.stringify({ error: message }), resendRes.status);
  }

  return corsResponse(JSON.stringify({ success: true }), 200);
});
