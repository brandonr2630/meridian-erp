// update-erp-user v4 — company-scoped authorisation, real error messages (pure handler, unit tested without Deno).
// Request (POST, JSON): { auth_user_id, email?, password? }
// Authorisation (checked BEFORE anything changes):
//   * the bearer token is verified with Supabase Auth (not just decoded);
//   * a super admin may change anyone; otherwise the caller must hold admin:users in EVERY company the target belongs to,
//     the target must not be a super admin, and the target must belong to at least one company;
//   * a caller with no admin rights at all gets 403 before any lookup, so the function is not an oracle for which accounts exist.
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
  const { auth_user_id, email, password } = body as Record<string, unknown>;
  if (typeof auth_user_id !== "string" || !UUID.test(auth_user_id)) return reply(400, { error: "auth_user_id must be a uuid" });
  if (!email && !password) return reply(400, { error: "Provide at least one of: email, password" });
  if (email !== undefined && email !== null && email !== "" && !isEmail(email)) return reply(400, { error: "Invalid email address" });
  if (password && (typeof password !== "string" || password.length < MIN_PASSWORD)) return reply(400, { error: `Password must be at least ${MIN_PASSWORD} characters` });

  // 3. authorise (company-scoped)
  let target: { id: string; full_name: string | null; company_id: string | null };
  let companies: string[];
  let targetIsSuper = false;
  let access;
  try {
    access = await loadAccess(f, env, callerId);
    if (!access.isSuper && access.adminCompanies.size === 0) return reply(403, { error: "Forbidden" });
    const rows = await svcSelect(f, env, `erp_users?auth_user_id=eq.${auth_user_id}&select=id,full_name,company_id`);
    if (rows.length === 0) return reply(404, { error: "User not found" });
    target = rows[0];
    const ucr = await svcSelect(f, env, `erp_user_company_roles?user_id=eq.${target.id}&select=company_id,role_id`);
    companies = [...new Set([...(target.company_id ? [target.company_id] : []), ...ucr.map((r) => r.company_id)])];
    if (ucr.length > 0) {
      const roles = await svcSelect(f, env, `erp_roles?id=in.(${[...new Set(ucr.map((r) => r.role_id))].join(",")})&select=id,permissions`);
      const superIds = new Set(roles.filter((r) => isSuperRole(r.permissions)).map((r) => r.id));
      targetIsSuper = ucr.some((r) => superIds.has(r.role_id));
    }
  } catch {
    return reply(500, { error: "Could not verify permissions" });
  }
  if (!access.isSuper) {
    if (targetIsSuper || companies.length === 0) return reply(403, { error: "Forbidden" });
    if (!companies.every((c) => canAdminister(access, c))) return reply(403, { error: "Forbidden" });
  }

  // 4. effects (authorised)
  const updates: Record<string, string> = {};
  if (email) updates.email = email as string;
  if (password) updates.password = password as string;
  const res = await f(`${env.SUPABASE_URL}/auth/v1/admin/users/${auth_user_id}`, { method: "PUT", headers: svcHeaders(env), body: JSON.stringify(updates) });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    const info = describeAuthError(err, res.status, "Failed to update auth user");
    return reply(info.status, { error: info.message, code: info.code });
  }
  await audit(f, env, callerId, "staff.credentials.update", `update ${target.full_name ?? "user"}: ${Object.keys(updates).join(", ")}`,
    { target_erp_user_id: target.id, fields: Object.keys(updates) }); // field names only, never values
  return reply(200, { success: true });
}
