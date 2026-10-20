// create-erp-user v9 — company-scoped authorisation (pure handler so it can be unit tested without Deno).
// Request (POST, JSON): { name, email, password, role_id, company_id }
// Authorisation (all checked BEFORE anything is created):
//   * the bearer token is verified with Supabase Auth (not just decoded);
//   * the caller must hold admin:users through a role assigned in the TARGET company, or be a super admin;
//   * the role must exist and be usable in that company (global role, or a role owned by that company);
//   * only a super admin may assign a role that carries admin:companies (super_admin).
import { describeAuthError } from "./errors.ts";
import { audit, canAdminister, isEmail, isSuperRole, loadAccess, MIN_PASSWORD, svcHeaders, svcSelect, UUID, verifyCaller } from "./authz.ts";
import type { Env } from "./authz.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });

export async function handle(req: Request, env: Env, f: typeof fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" });

  // 1. authenticate
  const authz = req.headers.get("authorization") ?? "";
  if (!authz.toLowerCase().startsWith("bearer ")) return reply(401, { error: "Missing Authorization header" });
  const callerId = await verifyCaller(f, env, authz.slice(7).trim());
  if (!callerId) return reply(401, { error: "Invalid or expired session" });

  // 2. validate input
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "Invalid JSON" }); }
  if (!body || typeof body !== "object") return reply(400, { error: "Invalid JSON" });
  const { name, email, password, role_id, company_id } = body as Record<string, unknown>;
  if (!name || !email || !password || !role_id || !company_id) {
    return reply(400, { error: "Missing required fields: name, email, password, role_id, company_id" });
  }
  if (typeof name !== "string" || name.trim() === "" || name.length > 200) return reply(400, { error: "Invalid name" });
  if (!isEmail(email)) return reply(400, { error: "Invalid email address" });
  if (typeof password !== "string" || password.length < MIN_PASSWORD) return reply(400, { error: `Password must be at least ${MIN_PASSWORD} characters` });
  if (typeof role_id !== "string" || !UUID.test(role_id)) return reply(400, { error: "role_id must be a uuid" });
  if (typeof company_id !== "string" || !UUID.test(company_id)) return reply(400, { error: "company_id must be a uuid" });

  // 3. authorise (company-scoped)
  let access, role: { id: string; name: string; company_id: string | null; permissions: Record<string, unknown> | null } | undefined;
  try {
    access = await loadAccess(f, env, callerId);
    if (!canAdminister(access, company_id)) return reply(403, { error: "Forbidden: admin:users permission required for this company" });
    const companies = await svcSelect(f, env, `companies?id=eq.${company_id}&select=id`);
    if (companies.length === 0) return reply(400, { error: "Unknown company" });
    role = (await svcSelect(f, env, `erp_roles?id=eq.${role_id}&select=id,name,company_id,permissions`))[0];
  } catch {
    return reply(500, { error: "Could not verify permissions" });
  }
  if (!role) return reply(400, { error: "Unknown role" });
  if (role.company_id && role.company_id !== company_id) return reply(400, { error: "That role belongs to a different company" });
  if (isSuperRole(role.permissions) && !access.isSuper) return reply(403, { error: "Forbidden: only a super admin can assign this role" });

  // 4. effects (authorised)
  const svc = svcHeaders(env);
  const createAuthRes = await f(`${env.SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: svc,
    body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { force_password_change: true } }),
  });
  if (!createAuthRes.ok) {
    const err = await createAuthRes.json().catch(() => ({}));
    const info = describeAuthError(err, createAuthRes.status);
    return reply(info.status, { error: info.message, code: info.code });
  }
  const authUserId: string = (await createAuthRes.json()).id;

  const insertRes = await f(`${env.SUPABASE_URL}/rest/v1/erp_users`, {
    method: "POST",
    headers: { ...svc, Prefer: "return=representation" },
    body: JSON.stringify({ auth_user_id: authUserId, full_name: name, email, company_id, is_active: true, force_password_change: true }),
  });
  if (!insertRes.ok) {
    await f(`${env.SUPABASE_URL}/auth/v1/admin/users/${authUserId}`, { method: "DELETE", headers: svc }); // no orphan login
    const errBody = await insertRes.json().catch(() => ({ message: "Unknown error" }));
    const detail = (errBody as { message?: string; details?: string }).message ?? (errBody as { details?: string }).details ?? JSON.stringify(errBody);
    return reply(500, { error: `Failed to create ERP user profile: ${detail}` });
  }
  const newUserId: string = (await insertRes.json())[0].id;

  const roleRes = await f(`${env.SUPABASE_URL}/rest/v1/erp_user_company_roles`, {
    method: "POST",
    headers: { ...svc, Prefer: "return=minimal" },
    body: JSON.stringify({ user_id: newUserId, company_id, role_id, permission_overrides: {} }),
  });
  const roleOk = roleRes.ok;
  await audit(f, env, callerId, "staff.create", `create ${name}: ${roleOk ? "ok" : "role assignment failed"}`,
    { target_erp_user_id: newUserId, company_id, role_id, role_name: role.name, role_assigned: roleOk });
  if (!roleOk) {
    const errBody = await roleRes.json().catch(() => ({ message: "Unknown error" }));
    const detail = (errBody as { message?: string }).message ?? JSON.stringify(errBody);
    return reply(200, { success: true, warning: `User created but role assignment failed: ${detail}. Use Edit Role to assign manually.` });
  }
  return reply(200, { success: true });
}
