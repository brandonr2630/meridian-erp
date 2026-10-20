// In-memory fake of Supabase Auth + PostgREST for the create-erp-user / update-erp-user handler tests.
// Every call is recorded in `log`; lookups require the service key, so a handler that forgets it fails loudly.
export const URL_ = "https://x.supabase.co";
export const ENV = { SUPABASE_URL: URL_, SERVICE_KEY: "svc", ANON_KEY: "anon" };
export const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
export const C1 = id(901), C2 = id(902), C3 = id(903), C_GHOST = id(999);
export const R_SUPER = id(801), R_ADMIN = id(802), R_OPS = id(803), R_C2ONLY = id(804), R_SETTINGS = id(805);

export function world(opts = {}) {
  const roles = [
    { id: R_SUPER, name: "super_admin", company_id: null, permissions: { "admin:companies": true, "admin:users": true, "admin:settings": true } },
    { id: R_ADMIN, name: "company_admin", company_id: null, permissions: { "admin:users": true, "admin:settings": true } },
    { id: R_OPS, name: "operations_tech", company_id: null, permissions: { "ops:work-orders:read": true } },
    { id: R_C2ONLY, name: "C2 custom", company_id: C2, permissions: { "ops:work-orders:read": true } },
    { id: R_SETTINGS, name: "settings only", company_id: null, permissions: { "admin:settings": true } },
  ];
  const person = (authN, euN, name, active, assignments) => ({
    auth: id(authN),
    row: { id: id(euN), auth_user_id: id(authN), full_name: name, is_active: active, company_id: assignments[0]?.[0] ?? null },
    assignments, // [[companyId, roleId], ...]
  });
  const people = {
    brandon: person(1, 101, "Brandon", true, [[C1, R_SUPER], [C2, R_SUPER], [C3, R_SUPER]]),
    adminC1: person(3, 103, "Admin C1", true, [[C1, R_ADMIN]]),
    adminC2: person(4, 104, "Admin C2", true, [[C2, R_ADMIN]]),
    adminC1C2: person(5, 105, "Admin C1+C2", true, [[C1, R_ADMIN], [C2, R_ADMIN]]),
    adminC1opsC2: person(6, 106, "Admin C1, Ops C2", true, [[C1, R_ADMIN], [C2, R_OPS]]),
    opsC1: person(7, 107, "Ops C1", true, [[C1, R_OPS]]),
    opsMulti: person(8, 108, "Ops C1+C2", true, [[C1, R_OPS], [C2, R_OPS]]),
    settingsC1: person(9, 109, "Settings-only C1", true, [[C1, R_SETTINGS]]),
    inactiveAdminC1: person(10, 110, "Inactive admin C1", false, [[C1, R_ADMIN]]),
    superC1: person(11, 111, "Second super (C1 only)", true, [[C1, R_SUPER]]),
    noRoles: person(12, 112, "No roles", true, []),
    noCompany: { auth: id(13), row: { id: id(113), auth_user_id: id(13), full_name: "Orphan", is_active: true, company_id: null }, assignments: [] },
  };
  const erpUsers = Object.values(people).map((p) => p.row);
  const ucr = Object.values(people).flatMap((p) => p.assignments.map(([c, r]) => ({ user_id: p.row.id, company_id: c, role_id: r })));
  const tokens = Object.fromEntries(Object.entries(people).map(([k, p]) => ["tok-" + k, p.auth]));
  const log = [];
  const st = { erpUsers, ucr, roles, tokens, log, authUsers: [], profiles: [], roleRows: [], audit: [], puts: [], deletes: [], failures: { ...(opts.failures ?? {}) } };
  const companies = [{ id: C1 }, { id: C2 }, { id: C3 }];

  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  const f = async (url, init = {}) => {
    const u = new globalThis.URL(url);
    const method = init.method ?? "GET";
    const hdr = init.headers ?? {};
    const bearer = String(hdr.Authorization ?? "").replace(/^Bearer /, "");
    const isSvc = bearer === "svc";
    const q = u.searchParams;
    log.push({ method, path: u.pathname + u.search, svc: isSvc });

    if (u.pathname === "/auth/v1/user") {
      const a = tokens[bearer];
      return a ? json(200, { id: a }) : json(401, { msg: "invalid token" });
    }
    if (u.pathname.startsWith("/auth/v1/admin/users")) {
      if (!isSvc) return json(401, {});
      if (method === "POST") {
        if (st.failures.createAuth) return json(st.failures.createAuth.status, st.failures.createAuth.body);
        const body = JSON.parse(init.body);
        const nu = { id: id(5000 + st.authUsers.length), email: body.email, password: body.password };
        st.authUsers.push(nu);
        return json(200, { id: nu.id });
      }
      if (method === "PUT") {
        if (st.failures.putAuth) return json(st.failures.putAuth.status, st.failures.putAuth.body);
        st.puts.push({ id: u.pathname.split("/").pop(), body: JSON.parse(init.body) });
        return json(200, {});
      }
      if (method === "DELETE") { st.deletes.push(u.pathname.split("/").pop()); return json(200, {}); }
    }
    if (u.pathname.startsWith("/rest/v1/")) {
      const t = u.pathname.replace("/rest/v1/", "");
      if (!isSvc) return json(401, { message: "service key required" });
      if (method === "GET") {
        const eq = (k) => { const v = q.get(k); return v?.startsWith("eq.") ? v.slice(3) : null; };
        if (t === "erp_users") {
          let rows = erpUsers.filter((r) => (eq("auth_user_id") ? r.auth_user_id === eq("auth_user_id") : true) && (eq("is_active") ? String(r.is_active) === eq("is_active") : true));
          return json(200, rows.map((r) => ({ id: r.id, full_name: r.full_name, company_id: r.company_id })));
        }
        if (t === "erp_user_company_roles") return json(200, ucr.filter((r) => r.user_id === eq("user_id")).map((r) => ({ company_id: r.company_id, role_id: r.role_id })));
        if (t === "erp_roles") {
          const idv = q.get("id");
          if (idv?.startsWith("in.(")) { const ids = idv.slice(4, -1).split(","); return json(200, roles.filter((r) => ids.includes(r.id))); }
          return json(200, roles.filter((r) => r.id === eq("id")));
        }
        if (t === "companies") return json(200, companies.filter((c) => c.id === eq("id")));
        return json(404, { message: "unknown table " + t });
      }
      if (method === "POST") {
        const body = JSON.parse(init.body);
        if (t === "erp_users") {
          if (st.failures.profile) return json(409, { message: "duplicate key" });
          const row = { id: id(6000 + st.profiles.length), ...body }; st.profiles.push(row); return json(201, [row]);
        }
        if (t === "erp_user_company_roles") {
          if (st.failures.roleRow) return json(400, { message: "fk violation" });
          st.roleRows.push(body); return json(201, null);
        }
        if (t === "job_audit_log") { st.audit.push(body); return json(201, null); }
      }
    }
    return json(404, { message: "unhandled " + method + " " + u.pathname });
  };
  const req = (token, body, method = "POST") => new Request("https://fn.example/x", {
    method, headers: { authorization: token ? "Bearer " + token : "", "content-type": "application/json" },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
  /** true when nothing was created, changed or deleted */
  const untouched = () => st.authUsers.length === 0 && st.profiles.length === 0 && st.roleRows.length === 0 && st.puts.length === 0 && st.deletes.length === 0 && st.audit.length === 0;
  return { st, f, req, people, untouched };
}
