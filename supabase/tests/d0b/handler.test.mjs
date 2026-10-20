// Unit tests for erp-user-access using an in-memory fake of Supabase Auth + PostgREST that records every call.
// Run: node --test supabase/tests/d0b/   (Node 22.18+ strips the TypeScript types natively)
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../../functions/erp-user-access/handler.ts";

const URL_ = "https://x.supabase.co";
const ENV = { SUPABASE_URL: URL_, SERVICE_KEY: "svc", ANON_KEY: "anon", ALLOWED_ORIGINS: ["https://erp.example"] };
const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const C1 = id(901), C2 = id(902), C3 = id(903);

// role ids
const R_SUPER = id(801), R_ADMIN = id(802), R_OPS = id(803), R_OFFICE = id(804);

function world(opts = {}) {
  const roles = [
    { id: R_SUPER, permissions: { "admin:companies": true, "admin:users": true, "admin:settings": true } },
    { id: R_ADMIN, permissions: { "admin:users": true, "admin:settings": true } },
    { id: R_OPS, permissions: { "ops:work-orders:read": true } },
    { id: R_OFFICE, permissions: { "finance:ap:read": true } },
  ];
  // auth user id -> erp user
  const eu = (authN, euN, name, active, cos, roleId) => ({ auth: id(authN), row: { id: id(euN), auth_user_id: id(authN), full_name: name, is_active: active, company_id: cos[0] }, cos, roleId });
  const people = {
    brandon: eu(1, 101, "Brandon", true, [C1, C2, C3], R_SUPER),   // super in 3 companies
    vanessa: eu(2, 102, "Vanessa", true, [C1], R_SUPER),          // second super
    adminC1: eu(3, 103, "Admin C1", true, [C1], R_ADMIN),
    adminC2: eu(4, 104, "Admin C2", true, [C2], R_ADMIN),
    opsC1: eu(5, 105, "Ops C1", true, [C1], R_OPS),
    opsMulti: eu(6, 106, "Ops C1+C2", true, [C1, C2], R_OPS),
    office: eu(7, 107, "Office", true, [C1], R_OFFICE),
    inactiveOps: eu(8, 108, "Inactive Ops", false, [C1], R_OPS),
  };
  if (opts.singleSuper) delete people.vanessa;
  const erpUsers = Object.values(people).map((p) => p.row);
  const ucr = Object.values(people).flatMap((p) => p.cos.map((c) => ({ user_id: p.row.id, company_id: c, role_id: p.roleId })));
  const tokens = Object.fromEntries(Object.entries(people).map(([k, p]) => ["tok-" + k, p.auth]));
  const log = [];
  const state = { erpUsers, ucr, roles, tokens, log, banned: new Set(), audit: [] };
  const callerPerms = (authId) => {
    const row = erpUsers.find((u) => u.auth_user_id === authId && u.is_active);
    if (!row) return { atoms: new Set(), cos: new Map() };
    const mine = ucr.filter((r) => r.user_id === row.id);
    const atoms = new Set(); const cos = new Map();
    for (const r of mine) {
      const perms = roles.find((x) => x.id === r.role_id).permissions;
      Object.keys(perms).forEach((a) => atoms.add(a));
      cos.set(r.company_id, perms);
    }
    return { atoms, cos };
  };
  const json = (status, body) => (status === 204 ? new Response(null, { status }) : new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));
  const f = async (url, init = {}) => {
    const u = new globalThis.URL(url);
    const method = init.method ?? "GET";
    const hdr = init.headers ?? {};
    const bearer = String(hdr.Authorization ?? "").replace(/^Bearer /, "");
    const isSvc = bearer === "svc";
    const path = u.pathname.replace("/rest/v1/", "").replace("/auth/v1/", "auth:");
    const q = u.searchParams;

    if (u.pathname === "/auth/v1/user") {
      log.push("auth.user");
      const a = state.tokens[bearer];
      return a ? json(200, { id: a }) : json(401, { message: "bad jwt" });
    }
    if (u.pathname.startsWith("/rest/v1/rpc/")) {
      const fn = u.pathname.split("/").pop();
      log.push("rpc." + fn);
      const caller = state.tokens[bearer];
      if (!caller) return json(401, {});
      const { atoms, cos } = callerPerms(caller);
      const args = init.body ? JSON.parse(init.body) : {};
      if (fn === "is_super_admin") return json(200, atoms.has("admin:companies"));
      if (fn === "user_has_perm") return json(200, atoms.has(args.perm));
      if (fn === "is_company_admin") { const p = cos.get(args.cid); return json(200, !!p && (p["admin:users"] === true || p["admin:settings"] === true)); }
      return json(404, {});
    }
    if (!isSvc) return json(401, { message: "service role required" });

    if (u.pathname.startsWith("/auth/v1/admin/users/") && method === "PUT") {
      const body = JSON.parse(init.body); const uid = u.pathname.split("/").pop();
      log.push("ban:" + body.ban_duration);
      if (opts.failBan) return json(500, {});
      if (body.ban_duration === "none") state.banned.delete(uid); else state.banned.add(uid);
      return json(200, {});
    }
    if (path.startsWith("erp_users") && method === "GET") {
      log.push("get.erp_users");
      const a = q.get("auth_user_id"); const idIn = q.get("id");
      let rows = erpUsers;
      if (a) rows = rows.filter((r) => r.auth_user_id === a.replace("eq.", ""));
      if (idIn) { const ids = idIn.replace(/^in\.\(/, "").replace(/\)$/, "").split(","); rows = rows.filter((r) => ids.includes(r.id)); }
      if (q.get("is_active") === "eq.true") rows = rows.filter((r) => r.is_active);
      return json(200, rows);
    }
    if (path.startsWith("erp_users") && method === "PATCH") {
      log.push("patch.erp_users");
      if (opts.failPatch) return json(500, {});
      const a = q.get("auth_user_id").replace("eq.", ""); const b = JSON.parse(init.body);
      erpUsers.filter((r) => r.auth_user_id === a).forEach((r) => Object.assign(r, b));
      return json(204, null);
    }
    if (path.startsWith("erp_users") && method === "DELETE") {
      log.push("delete.erp_users");
      if (opts.deleteFk) return json(409, { code: "23503", message: "fk" });
      const a = q.get("auth_user_id").replace("eq.", "");
      const i = erpUsers.findIndex((r) => r.auth_user_id === a); if (i >= 0) erpUsers.splice(i, 1);
      return new Response(null, { status: 204 });
    }
    if (path.startsWith("erp_user_company_roles")) {
      log.push("get.ucr");
      const uid = q.get("user_id"); const roleIn = q.get("role_id");
      let rows = ucr;
      if (uid) rows = rows.filter((r) => r.user_id === uid.replace("eq.", ""));
      if (roleIn) { const ids = roleIn.replace(/^in\.\(/, "").replace(/\)$/, "").split(","); rows = rows.filter((r) => ids.includes(r.role_id)); }
      return json(200, rows);
    }
    if (path.startsWith("erp_roles")) { log.push("get.roles"); return json(200, roles); }
    if (path.startsWith("job_audit_log") && method === "POST") { log.push("audit"); state.audit.push(JSON.parse(init.body)); return json(201, null); }
    return json(404, { message: "unrouted " + method + " " + path });
  };
  return { state, f, people };
}

const call = (w, token, body, extra = {}) =>
  handle(new Request(URL_ + "/functions/v1/erp-user-access", {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}), ...(extra.headers ?? {}) },
    body: typeof body === "string" ? body : JSON.stringify(body),
  }), ENV, w.f);

const mutations = (log) => log.filter((l) => /^(patch|delete|ban:|audit)/.test(l));

test("rejects a request with no Authorization header", async () => {
  const w = world(); const r = await call(w, null, { auth_user_id: w.people.opsC1.auth, action: "deactivate" });
  assert.equal(r.status, 401); assert.deepEqual(mutations(w.state.log), []);
});
test("rejects a token Supabase Auth does not accept (forged or expired)", async () => {
  const w = world(); const r = await call(w, "forged", { auth_user_id: w.people.opsC1.auth, action: "deactivate" });
  assert.equal(r.status, 401); assert.deepEqual(mutations(w.state.log), []);
});
test("rejects bad input: invalid JSON, non-uuid id, unknown action", async () => {
  const w = world();
  assert.equal((await call(w, "tok-brandon", "{not json")).status, 400);
  assert.equal((await call(w, "tok-brandon", { auth_user_id: "nope", action: "deactivate" })).status, 400);
  assert.equal((await call(w, "tok-brandon", { auth_user_id: w.people.opsC1.auth, action: "explode" })).status, 400);
  assert.deepEqual(mutations(w.state.log), []);
});
test("a caller cannot change their own access", async () => {
  const w = world(); const r = await call(w, "tok-brandon", { auth_user_id: w.people.brandon.auth, action: "deactivate" });
  assert.equal(r.status, 400); assert.deepEqual(mutations(w.state.log), []);
});
test("a caller without admin rights is refused and nothing changes", async () => {
  const w = world();
  for (const who of ["opsC1", "office"]) {
    const r = await call(w, "tok-" + who, { auth_user_id: w.people.opsMulti.auth, action: "deactivate" });
    assert.equal(r.status, 403, who);
  }
  assert.deepEqual(mutations(w.state.log), []);
});
test("an inactive admin-less/inactive caller is refused", async () => {
  const w = world(); const r = await call(w, "tok-inactiveOps", { auth_user_id: w.people.opsC1.auth, action: "deactivate" });
  assert.equal(r.status, 403); assert.deepEqual(mutations(w.state.log), []);
});
test("company admin deactivates a user in their company: DB row first, then ban, then audit", async () => {
  const w = world(); const t = w.people.opsC1;
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "deactivate" });
  assert.equal(r.status, 200); assert.equal((await r.json()).success, true);
  assert.equal(t.row.is_active, false); assert.ok(w.state.banned.has(t.auth));
  assert.deepEqual(mutations(w.state.log), ["patch.erp_users", "ban:876000h", "audit"]);
  assert.equal(w.state.audit[0].action_type, "staff.access.deactivate");
  assert.equal(w.state.audit[0].user_id, w.people.adminC1.auth);
});
test("authorisation completes before any change (no mutation precedes the last permission check)", async () => {
  const w = world(); await call(w, "tok-adminC1", { auth_user_id: w.people.opsC1.auth, action: "deactivate" });
  const lastCheck = Math.max(...w.state.log.map((l, i) => (l.startsWith("rpc.") ? i : -1)));
  const firstMutation = w.state.log.findIndex((l) => /^(patch|delete|ban:)/.test(l));
  assert.ok(lastCheck < firstMutation);
});
test("company admin cannot touch a user who also belongs to a company they do not administer", async () => {
  const w = world(); const r = await call(w, "tok-adminC1", { auth_user_id: w.people.opsMulti.auth, action: "deactivate" });
  assert.equal(r.status, 403); assert.deepEqual(mutations(w.state.log), []); assert.equal(w.people.opsMulti.row.is_active, true);
});
test("an admin of a different company cannot act on the user", async () => {
  const w = world(); const r = await call(w, "tok-adminC2", { auth_user_id: w.people.opsC1.auth, action: "remove" });
  assert.equal(r.status, 403); assert.deepEqual(mutations(w.state.log), []);
});
test("a company admin cannot act on a super admin, even one in a single shared company", async () => {
  const w = world(); const r = await call(w, "tok-adminC1", { auth_user_id: w.people.vanessa.auth, action: "deactivate" });
  assert.equal(r.status, 403); assert.deepEqual(mutations(w.state.log), []);
});
test("a super admin may manage a user in several companies", async () => {
  const w = world(); const r = await call(w, "tok-brandon", { auth_user_id: w.people.opsMulti.auth, action: "deactivate" });
  assert.equal(r.status, 200); assert.equal(w.people.opsMulti.row.is_active, false);
});
test("a super admin may deactivate another super admin while a third remains", async () => {
  const w = world(); const r = await call(w, "tok-brandon", { auth_user_id: w.people.vanessa.auth, action: "deactivate" });
  assert.equal(r.status, 200);
});
test("activate: unban first, then reactivate the row", async () => {
  const w = world(); const t = w.people.inactiveOps; w.state.banned.add(t.auth);
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "activate" });
  assert.equal(r.status, 200); assert.equal(t.row.is_active, true); assert.ok(!w.state.banned.has(t.auth));
  assert.deepEqual(mutations(w.state.log), ["ban:none", "patch.erp_users", "audit"]);
});
test("remove: ban first, then delete the profile", async () => {
  const w = world(); const t = w.people.opsC1;
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "remove" });
  const j = await r.json(); assert.equal(r.status, 200); assert.equal(j.removed, true);
  assert.ok(w.state.banned.has(t.auth)); assert.ok(!w.state.erpUsers.some((u) => u.auth_user_id === t.auth));
  assert.deepEqual(mutations(w.state.log), ["ban:876000h", "delete.erp_users", "audit"]);
});
test("remove when records still reference the profile: login banned, profile kept inactive", async () => {
  const w = world({ deleteFk: true }); const t = w.people.opsC1;
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "remove" });
  const j = await r.json(); assert.equal(r.status, 200); assert.equal(j.removed, false);
  assert.ok(w.state.banned.has(t.auth)); assert.equal(t.row.is_active, false);
});
test("deactivate where the ban fails reports a partial result so the admin can retry", async () => {
  const w = world({ failBan: true }); const t = w.people.opsC1;
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "deactivate" });
  const j = await r.json(); assert.equal(r.status, 502); assert.equal(j.partial, true); assert.equal(t.row.is_active, false);
});
test("remove where the ban fails removes nothing", async () => {
  const w = world({ failBan: true }); const t = w.people.opsC1;
  const r = await call(w, "tok-adminC1", { auth_user_id: t.auth, action: "remove" });
  assert.equal(r.status, 502); assert.ok(w.state.erpUsers.some((u) => u.auth_user_id === t.auth)); assert.ok(!w.state.log.includes("delete.erp_users"));
});
test("no existence oracle: a non-admin gets 403 for an unknown target, never 404", async () => {
  const w = world(); const r = await call(w, "tok-opsC1", { auth_user_id: id(777), action: "deactivate" });
  assert.equal(r.status, 403); assert.ok(!w.state.log.includes("get.erp_users"));
});
test("unknown target gives 404 to an authorised caller", async () => {
  const w = world(); const r = await call(w, "tok-brandon", { auth_user_id: id(777), action: "deactivate" });
  assert.equal(r.status, 404);
});
test("CORS: allowed origin is echoed, others get no Access-Control-Allow-Origin", async () => {
  const w = world();
  const ok = await handle(new Request(URL_ + "/x", { method: "OPTIONS", headers: { origin: "https://erp.example" } }), ENV, w.f);
  assert.equal(ok.status, 204); assert.equal(ok.headers.get("access-control-allow-origin"), "https://erp.example");
  const bad = await handle(new Request(URL_ + "/x", { method: "OPTIONS", headers: { origin: "https://evil.example" } }), ENV, w.f);
  assert.equal(bad.headers.get("access-control-allow-origin"), null);
});
test("non-POST methods are refused", async () => {
  const w = world(); const r = await handle(new Request(URL_ + "/x", { method: "GET" }), ENV, w.f);
  assert.equal(r.status, 405);
});
