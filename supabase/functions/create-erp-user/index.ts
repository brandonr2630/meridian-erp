// Supabase Edge Function: create-erp-user
// Securely creates a new Supabase auth user + erp_users profile.
// The service role key never touches the browser — it lives only here.
//
// Expected request body (JSON):
//   { name, email, password, role, company_id,
//     module_finance, module_sales, module_operations,
//     module_finance_ar, module_finance_ap, module_finance_bank,
//     module_finance_ledger, module_finance_reports,
//     module_sales_crm, module_sales_orders }
//
// Required env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY

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

  // ── 1. Parse request body ──────────────────────────────────────────────────
  let body: {
    name: string;
    email: string;
    password: string;
    role: string;
    company_id: string;
    module_finance: boolean;
    module_sales: boolean;
    module_operations: boolean;
    module_finance_ar: boolean;
    module_finance_ap: boolean;
    module_finance_bank: boolean;
    module_finance_ledger: boolean;
    module_finance_reports: boolean;
    module_sales_crm: boolean;
    module_sales_orders: boolean;
  };

  try {
    body = await req.json();
  } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON body" }), 400);
  }

  const {
    name, email, password, role, company_id,
    module_finance, module_sales, module_operations,
    module_finance_ar, module_finance_ap, module_finance_bank,
    module_finance_ledger, module_finance_reports,
    module_sales_crm, module_sales_orders,
  } = body;

  if (!name || !email || !password || !role || !company_id) {
    return corsResponse(JSON.stringify({ error: "Missing required fields: name, email, password, role, company_id" }), 400);
  }

  // ── 2. Validate caller is admin or super_admin ────────────────────────────
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

  const callerRole: string = profiles[0].role;

  if (callerRole !== "admin" && callerRole !== "super_admin") {
    return corsResponse(JSON.stringify({ error: "Forbidden: admin or super_admin role required" }), 403);
  }

  // ── 3. Create Supabase auth user (service role) ───────────────────────────
  const createAuthRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { force_password_change: true },
    }),
  });

  if (!createAuthRes.ok) {
    const errData = await createAuthRes.json().catch(() => ({}));
    const message = (errData as { message?: string }).message ?? "Failed to create auth user";
    return corsResponse(JSON.stringify({ error: message }), createAuthRes.status);
  }

  const authUser = await createAuthRes.json();
  const newUserId: string = authUser.id;

  // ── 4. Insert erp_users profile (service role) ────────────────────────────
  const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/erp_users`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      apikey: SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      auth_user_id: newUserId,
      full_name: name,
      role,
      company_id,
      module_finance:          module_finance          ?? true,
      module_sales:            module_sales            ?? true,
      module_operations:       module_operations       ?? true,
      module_finance_ar:       module_finance_ar       ?? true,
      module_finance_ap:       module_finance_ap       ?? true,
      module_finance_bank:     module_finance_bank     ?? true,
      module_finance_ledger:   module_finance_ledger   ?? true,
      module_finance_reports:  module_finance_reports  ?? true,
      module_sales_crm:        module_sales_crm        ?? true,
      module_sales_orders:     module_sales_orders     ?? true,
      is_active: true,
      force_password_change: true,
    }),
  });

  if (!insertRes.ok) {
    // Auth user was created but profile insert failed — attempt cleanup
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${newUserId}`, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        apikey: SERVICE_ROLE_KEY,
      },
    });

    const errText = await insertRes.text().catch(() => "");
    return corsResponse(
      JSON.stringify({ error: "Failed to create ERP user profile", detail: errText }),
      500,
    );
  }

  return corsResponse(JSON.stringify({ success: true }), 200);
});
