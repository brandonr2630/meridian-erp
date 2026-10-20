// Shared authorisation helpers for create-erp-user and update-erp-user (IDENTICAL copy lives in both function folders; a test
// fails if the two drift apart, because the Supabase deploy takes one folder per function).
//
// Why: both functions used to authorise with user_has_perm('admin:users'), which is NOT company-scoped, so any holder of that
// atom (e.g. a company_admin of one company) could create or change users in ANY company, and assign ANY role, including
// super_admin. Here the caller is identified by a token verified with Supabase Auth, and their rights are read from the
// database for the specific company involved.

export type Env = { SUPABASE_URL: string; SERVICE_KEY: string; ANON_KEY: string };
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const MIN_PASSWORD = 12;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const isEmail = (v: unknown): v is string => typeof v === "string" && v.length <= 254 && EMAIL.test(v);

export const svcHeaders = (env: Env) => ({ Authorization: `Bearer ${env.SERVICE_KEY}`, apikey: env.SERVICE_KEY, "Content-Type": "application/json" });

/** Verifies the bearer token with Supabase Auth (signature and expiry), returning the auth user id or null. */
export async function verifyCaller(f: typeof fetch, env: Env, token: string): Promise<string | null> {
  const r = await f(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { Authorization: `Bearer ${token}`, apikey: env.ANON_KEY } });
  if (!r.ok) return null;
  const id = (await r.json().catch(() => ({})))?.id;
  return typeof id === "string" && UUID.test(id) ? id : null;
}

export async function svcSelect(f: typeof fetch, env: Env, path: string): Promise<any[]> {
  const r = await f(`${env.SUPABASE_URL}/rest/v1/${path}`, { headers: svcHeaders(env) });
  if (!r.ok) throw new Error(`lookup failed: ${path.split("?")[0]}`);
  const rows = await r.json();
  if (!Array.isArray(rows)) throw new Error(`lookup failed: ${path.split("?")[0]}`);
  return rows;
}

type Perms = Record<string, unknown> | null | undefined;
export const hasAtom = (p: Perms, atom: string) => p?.[atom] === true;
/** A role that carries admin:companies is a super-admin role (same test as the database function is_super_admin()). */
export const isSuperRole = (p: Perms) => hasAtom(p, "admin:companies");

export type Access = {
  callerId: string;
  /** erp_users.id of the caller, null when the caller has no active ERP profile */
  erpUserId: string | null;
  isSuper: boolean;
  /** companies in which the caller holds admin:users through a role assigned in THAT company */
  adminCompanies: Set<string>;
};

/** Reads the caller's rights from the database (service role), keyed on the verified auth user id. */
export async function loadAccess(f: typeof fetch, env: Env, callerId: string): Promise<Access> {
  const none: Access = { callerId, erpUserId: null, isSuper: false, adminCompanies: new Set() };
  const users = await svcSelect(f, env, `erp_users?auth_user_id=eq.${callerId}&is_active=eq.true&select=id`);
  if (users.length === 0) return none;
  const erpUserId: string = users[0].id;
  const ucr = await svcSelect(f, env, `erp_user_company_roles?user_id=eq.${erpUserId}&select=company_id,role_id`);
  if (ucr.length === 0) return { ...none, erpUserId };
  const ids = [...new Set(ucr.map((r) => r.role_id))].join(",");
  const roles = await svcSelect(f, env, `erp_roles?id=in.(${ids})&select=id,permissions`);
  const perms = new Map<string, Perms>(roles.map((r) => [r.id, r.permissions]));
  const adminCompanies = new Set<string>();
  let isSuper = false;
  for (const r of ucr) {
    const p = perms.get(r.role_id);
    if (isSuperRole(p)) isSuper = true;
    if (hasAtom(p, "admin:users")) adminCompanies.add(r.company_id);
  }
  return { callerId, erpUserId, isSuper, adminCompanies };
}

/** May the caller administer users of this company? Super admins may administer every company. */
export const canAdminister = (a: Access, companyId: string) => a.isSuper || a.adminCompanies.has(companyId);

/** Best-effort audit row; the account change must not fail because the audit insert did. Never put secrets in `metadata`. */
export async function audit(f: typeof fetch, env: Env, callerId: string, actionType: string, description: string, metadata: Record<string, unknown>) {
  try {
    await f(`${env.SUPABASE_URL}/rest/v1/job_audit_log`, {
      method: "POST",
      headers: { ...svcHeaders(env), Prefer: "return=minimal" },
      body: JSON.stringify({ job_id: null, user_id: callerId, action_type: actionType, description, metadata }),
    });
  } catch { /* best effort */ }
}
