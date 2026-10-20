// create-erp-user Edge Function v8 — Phase 4 RBAC (repo copy refreshed from the deployed v7; v8 changes ONLY the error reporting)
// Accepts: { name, email, password, role_id, company_id }
// v8: Supabase Auth failures are reported with their real reason (weak password, email already registered, ...) instead of the
// generic "Failed to create auth user" (see errors.ts). Deploy with verify_jwt = false (the browser preflight has no Authorization).
import { describeAuthError } from "./errors.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string, status: number) {
  return new Response(body, {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return corsResponse(JSON.stringify({ error: "Method not allowed" }), 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANON_KEY     = Deno.env.get("SUPABASE_ANON_KEY")!;

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return corsResponse(JSON.stringify({ error: "Missing Authorization header" }), 401);
  }
  const callerToken = authHeader.slice(7);

  let body: { name: string; email: string; password: string; role_id: string; company_id: string };
  try { body = await req.json(); }
  catch { return corsResponse(JSON.stringify({ error: "Invalid JSON" }), 400); }

  const { name, email, password, role_id, company_id } = body;
  if (!name || !email || !password || !role_id || !company_id) {
    return corsResponse(JSON.stringify({ error: "Missing required fields: name, email, password, role_id, company_id" }), 400);
  }

  // Validate caller has admin:users permission
  const permRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/user_has_perm`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${callerToken}`,
      "apikey": ANON_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ perm: "admin:users" }),
  });
  if (!permRes.ok) return corsResponse(JSON.stringify({ error: "Failed to verify caller permissions" }), 500);
  const hasPerm = await permRes.json();
  if (!hasPerm) return corsResponse(JSON.stringify({ error: "Forbidden: admin:users permission required" }), 403);

  // Create Supabase auth user
  const createAuthRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "apikey": SERVICE_KEY,
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
    const err = await createAuthRes.json().catch(() => ({}));
    const info = describeAuthError(err, createAuthRes.status);
    return corsResponse(JSON.stringify({ error: info.message, code: info.code }), info.status);
  }
  const authUser = await createAuthRes.json();
  const authUserId: string = authUser.id;

  // Insert erp_users profile (email is NOT NULL — must include it)
  const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/erp_users`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "apikey": SERVICE_KEY,
      "Content-Type": "application/json",
      "Prefer": "return=representation",
    },
    body: JSON.stringify({
      auth_user_id:          authUserId,
      full_name:             name,
      email:                 email,
      company_id,
      is_active:             true,
      force_password_change: true,
    }),
  });
  if (!insertRes.ok) {
    // Clean up auth user to avoid orphan
    await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${authUserId}`, {
      method: "DELETE",
      headers: { "Authorization": `Bearer ${SERVICE_KEY}`, "apikey": SERVICE_KEY },
    });
    const errBody = await insertRes.json().catch(() => ({ message: "Unknown error" }));
    const detail = (errBody as { message?: string; details?: string }).message
      ?? (errBody as { details?: string }).details
      ?? JSON.stringify(errBody);
    return corsResponse(JSON.stringify({ error: `Failed to create ERP user profile: ${detail}` }), 500);
  }
  const [newUser] = await insertRes.json();
  const newUserId: string = newUser.id;

  // Assign role via erp_user_company_roles
  const roleRes = await fetch(`${SUPABASE_URL}/rest/v1/erp_user_company_roles`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "apikey": SERVICE_KEY,
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({
      user_id:              newUserId,
      company_id,
      role_id,
      permission_overrides: {},
    }),
  });
  if (!roleRes.ok) {
    const errBody = await roleRes.json().catch(() => ({ message: "Unknown error" }));
    const detail = (errBody as { message?: string }).message ?? JSON.stringify(errBody);
    return corsResponse(JSON.stringify({
      success: true,
      warning: `User created but role assignment failed: ${detail}. Use Edit Role to assign manually.`,
    }), 200);
  }

  return corsResponse(JSON.stringify({ success: true }), 200);
});
