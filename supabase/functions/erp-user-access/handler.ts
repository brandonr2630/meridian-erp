// erp-user-access: deactivate / activate / remove an ERP staff member AND ban or unban their Supabase login.
// Why: the ERP's toggleUserActive/removeUser only flip erp_users.is_active or delete the erp_users row, which leaves a
// working Supabase auth login behind (spec: Phase D, D0b). Pure handler so it can be unit tested without Deno.
//
// Request (POST, JSON):  { auth_user_id: uuid, action: "deactivate" | "activate" | "remove" }
// Authorisation: the caller's token is verified with Supabase Auth (/auth/v1/user, not just decoded); the caller must be
// super admin, or company admin (is_company_admin) of EVERY company the target belongs to. Only a super admin may act on
// another super admin, and a caller cannot target self, so at least one active super admin (the caller) always remains.
// Order of effects: deactivate = DB row then ban; activate = unban then DB row; remove = ban then delete (or retain inactive
// when records still reference the profile). All changes happen only after authorisation succeeds.

export type Env = {
  SUPABASE_URL: string;
  SERVICE_KEY: string;
  ANON_KEY: string;
  ALLOWED_ORIGINS: string[];
};

type Action = "deactivate" | "activate" | "remove";
const ACTIONS: Action[] = ["deactivate", "activate", "remove"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BAN_FOREVER = "876000h";

function corsHeaders(req: Request, env: Env): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && env.ALLOWED_ORIGINS.includes(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function reply(req: Request, env: Env, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req, env), "Content-Type": "application/json" },
  });
}

export async function handle(req: Request, env: Env, f: typeof fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req, env) });
  if (req.method !== "POST") return reply(req, env, 405, { error: "Method not allowed" });

  const svc = { Authorization: `Bearer ${env.SERVICE_KEY}`, apikey: env.SERVICE_KEY, "Content-Type": "application/json" };

  // ── 1. authenticate: verify the token with Supabase Auth (signature + expiry), do not just decode it ──
  const authz = req.headers.get("authorization") ?? "";
  if (!authz.toLowerCase().startsWith("bearer ")) return reply(req, env, 401, { error: "Missing Authorization header" });
  const token = authz.slice(7).trim();
  const userRes = await f(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { Authorization: `Bearer ${token}`, apikey: env.ANON_KEY } });
  if (!userRes.ok) return reply(req, env, 401, { error: "Invalid or expired session" });
  const callerId: string = (await userRes.json().catch(() => ({})))?.id ?? "";
  if (!UUID.test(callerId)) return reply(req, env, 401, { error: "Invalid or expired session" });

  // ── 2. validate input ──
  let body: { auth_user_id?: string; action?: string };
  try { body = await req.json(); } catch { return reply(req, env, 400, { error: "Invalid JSON" }); }
  const targetId = String(body.auth_user_id ?? "");
  const action = body.action as Action;
  if (!UUID.test(targetId)) return reply(req, env, 400, { error: "auth_user_id must be a uuid" });
  if (!ACTIONS.includes(action)) return reply(req, env, 400, { error: "action must be deactivate, activate or remove" });
  if (targetId.toLowerCase() === callerId.toLowerCase()) return reply(req, env, 400, { error: "You cannot change your own access" });

  // ── 3. authorise, using the CALLER's token against the permission functions ──
  const callerRpc = async (fn: string, args: Record<string, unknown>): Promise<boolean | null> => {
    const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, apikey: env.ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    if (!r.ok) return null;
    return (await r.json().catch(() => null)) === true;
  };
  const isSuper = await callerRpc("is_super_admin", {});
  if (isSuper === null) return reply(req, env, 500, { error: "Could not verify permissions" });
  if (!isSuper) {
    const hasAdmin = await callerRpc("user_has_perm", { perm: "admin:users" });
    if (hasAdmin === null) return reply(req, env, 500, { error: "Could not verify permissions" });
    if (!hasAdmin) return reply(req, env, 403, { error: "Forbidden" });
  }

  const sel = async (path: string) => {
    const r = await f(`${env.SUPABASE_URL}/rest/v1/${path}`, { headers: svc });
    if (!r.ok) throw new Error(`lookup failed: ${path.split("?")[0]}`);
    return await r.json();
  };

  let target: { id: string; full_name: string | null; is_active: boolean; company_id: string | null };
  let companies: string[];
  let targetIsSuper = false;
  try {
    const rows = await sel(`erp_users?auth_user_id=eq.${targetId}&select=id,full_name,is_active,company_id`);
    if (!Array.isArray(rows) || rows.length === 0) return reply(req, env, 404, { error: "User not found" });
    target = rows[0];
    const ucr: { company_id: string; role_id: string }[] = await sel(`erp_user_company_roles?user_id=eq.${target.id}&select=company_id,role_id`);
    companies = [...new Set([...(target.company_id ? [target.company_id] : []), ...ucr.map((r) => r.company_id)])];
    const roles: { id: string; permissions: Record<string, unknown> | null }[] = await sel("erp_roles?select=id,permissions");
    const superRoleIds = new Set(roles.filter((r) => r.permissions?.["admin:companies"] === true).map((r) => r.id));
    targetIsSuper = ucr.some((r) => superRoleIds.has(r.role_id));
  } catch {
    return reply(req, env, 500, { error: "Could not look up the user" });
  }

  if (!isSuper) {
    if (targetIsSuper) return reply(req, env, 403, { error: "Forbidden" });
    if (companies.length === 0) return reply(req, env, 403, { error: "Forbidden" });
    for (const c of companies) {
      const ok = await callerRpc("is_company_admin", { cid: c });
      if (ok === null) return reply(req, env, 500, { error: "Could not verify permissions" });
      if (!ok) return reply(req, env, 403, { error: "Forbidden" });
    }
  }
  // ── 4. effects (authorised) ──
  const patchActive = (value: boolean) =>
    f(`${env.SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${targetId}`, { method: "PATCH", headers: { ...svc, Prefer: "return=minimal" }, body: JSON.stringify({ is_active: value }) });
  const setBan = (duration: string) =>
    f(`${env.SUPABASE_URL}/auth/v1/admin/users/${targetId}`, { method: "PUT", headers: svc, body: JSON.stringify({ ban_duration: duration }) });

  let removed: boolean | undefined;
  let outcome = "ok";

  if (action === "deactivate") {
    const p = await patchActive(false);
    if (!p.ok) return reply(req, env, 500, { error: "Could not deactivate the user" });
    const b = await setBan(BAN_FOREVER);
    if (!b.ok) {
      await audit(f, env, svc, callerId, action, target, "partial: deactivated, ban failed");
      return reply(req, env, 502, { error: "User deactivated in the ERP, but the login could not be banned. Retry to finish.", partial: true });
    }
  } else if (action === "activate") {
    const b = await setBan("none");
    if (!b.ok) return reply(req, env, 502, { error: "Could not unban the login" });
    const p = await patchActive(true);
    if (!p.ok) {
      await audit(f, env, svc, callerId, action, target, "partial: unbanned, activation failed");
      return reply(req, env, 502, { error: "Login unbanned but the ERP profile could not be activated. Retry to finish.", partial: true });
    }
  } else {
    const b = await setBan(BAN_FOREVER);
    if (!b.ok) return reply(req, env, 502, { error: "Could not ban the login, nothing was removed" });
    const d = await f(`${env.SUPABASE_URL}/rest/v1/erp_users?auth_user_id=eq.${targetId}`, { method: "DELETE", headers: { ...svc, Prefer: "return=minimal" } });
    if (d.ok) {
      removed = true;
    } else {
      const err = await d.json().catch(() => ({}));
      if ((err as { code?: string }).code === "23503") {
        // records (CRM, drawings, roles) still reference this profile: keep it, inactive
        const p = await patchActive(false);
        if (!p.ok) return reply(req, env, 500, { error: "Login banned, but the profile could not be deactivated" });
        removed = false;
        outcome = "retained: profile referenced by records";
      } else {
        return reply(req, env, 500, { error: "Login banned, but the profile could not be removed. Retry." });
      }
    }
  }

  await audit(f, env, svc, callerId, action, target, outcome);
  return reply(req, env, 200, { success: true, action, ...(removed === undefined ? {} : { removed }) });
}

async function audit(
  f: typeof fetch, env: Env, svc: Record<string, string>, callerId: string, action: Action,
  target: { id: string; full_name: string | null }, outcome: string,
) {
  try {
    await f(`${env.SUPABASE_URL}/rest/v1/job_audit_log`, {
      method: "POST",
      headers: { ...svc, Prefer: "return=minimal" },
      body: JSON.stringify({
        job_id: null,
        user_id: callerId,
        action_type: `staff.access.${action}`,
        description: `${action} ${target.full_name ?? "user"}: ${outcome}`,
        metadata: { target_erp_user_id: target.id, outcome },
      }),
    });
  } catch { /* audit is best effort: the access change itself must not fail because of it */ }
}
