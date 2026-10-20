// create-erp-user v9 handler tests. Run: node --test supabase/tests/authz/
// AUTHZ_FN_DIR points the suite at a mutated copy of supabase/functions (see mutate.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { world, ENV, id, C1, C2, C3, C_GHOST, R_SUPER, R_ADMIN, R_OPS, R_C2ONLY } from "./world.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const FN = process.env.AUTHZ_FN_DIR ?? join(here, "..", "..", "functions");
const { handle } = await import(pathToFileURL(join(FN, "create-erp-user", "handler.ts")).href);

const PW = "correct-horse-battery";
const body = (o = {}) => ({ name: "New Person", email: "new@example.com", password: PW, role_id: R_OPS, company_id: C1, ...o });
const call = async (w, who, b) => { const r = await handle(w.req(who ? "tok-" + who : "", b), ENV, w.f); return { status: r.status, json: await r.json().catch(() => null) }; };

// ── authentication ──
test("no Authorization header: 401, nothing created", async () => {
  const w = world(); const r = await call(w, null, body());
  assert.equal(r.status, 401); assert.ok(w.untouched());
});
test("a token Supabase Auth rejects: 401, nothing created", async () => {
  const w = world(); const r = await handle(w.req("forged.token.value", body()), ENV, w.f);
  assert.equal(r.status, 401); assert.ok(w.untouched());
});
test("OPTIONS preflight is answered without a token; other methods are refused", async () => {
  const w = world();
  assert.equal((await handle(new Request("https://fn/x", { method: "OPTIONS" }), ENV, w.f)).status, 200);
  assert.equal((await handle(new Request("https://fn/x", { method: "GET" }), ENV, w.f)).status, 405);
  assert.ok(w.untouched());
});

// ── input validation (checked before any privileged work) ──
test("bad input is a 400 and creates nothing", async () => {
  for (const b of [
    body({ name: "" }), body({ email: "not-an-email" }), body({ password: "short-11-pw" }), body({ password: undefined }),
    body({ role_id: "not-a-uuid" }), body({ company_id: "not-a-uuid" }), body({ company_id: undefined }), body({ name: 42 }), "not json",
  ]) {
    const w = world(); const r = await call(w, "brandon", b);
    assert.equal(r.status, 400, JSON.stringify(b)); assert.ok(w.untouched(), JSON.stringify(b));
  }
});
test("the server enforces the 12 character minimum itself", async () => {
  const w = world();
  assert.equal((await call(w, "brandon", body({ password: "x".repeat(11) }))).status, 400);
  assert.equal((await call(w, "brandon", body({ password: "x".repeat(12) }))).status, 200);
});

// ── who may create ──
test("a super admin can create a user in any company with a normal role", async () => {
  for (const c of [C1, C2, C3]) {
    const w = world(); const r = await call(w, "brandon", body({ company_id: c }));
    assert.equal(r.status, 200, c); assert.deepEqual(r.json, { success: true });
    assert.equal(w.st.roleRows[0].company_id, c);
  }
});
test("a super admin whose only assignment is one company is still a super admin everywhere (same rule as is_super_admin())", async () => {
  const w = world(); assert.equal((await call(w, "superC1", body({ company_id: C3 }))).status, 200);
});
test("a company admin can create a user in THEIR company, with the right profile, role row and audit row", async () => {
  const w = world(); const r = await call(w, "adminC1", body());
  assert.equal(r.status, 200);
  assert.equal(w.st.authUsers.length, 1); assert.equal(w.st.authUsers[0].email, "new@example.com");
  assert.equal(w.st.profiles.length, 1);
  assert.equal(w.st.profiles[0].company_id, C1); assert.equal(w.st.profiles[0].full_name, "New Person"); assert.equal(w.st.profiles[0].is_active, true);
  assert.deepEqual({ c: w.st.roleRows[0].company_id, r: w.st.roleRows[0].role_id, u: w.st.roleRows[0].user_id }, { c: C1, r: R_OPS, u: w.st.profiles[0].id });
  assert.equal(w.st.audit.length, 1); assert.equal(w.st.audit[0].action_type, "staff.create"); assert.equal(w.st.audit[0].user_id, w.people.adminC1.auth);
  assert.ok(!JSON.stringify(w.st.audit).includes(PW), "audit must not contain the password");
});
test("a company admin can NOT create users in another company (the old hole)", async () => {
  for (const [who, c] of [["adminC1", C2], ["adminC1", C3], ["adminC2", C1], ["adminC1opsC2", C2]]) {
    const w = world(); const r = await call(w, who, body({ company_id: c }));
    assert.equal(r.status, 403, who + " -> " + c); assert.ok(w.untouched(), who + " -> " + c);
  }
});
test("an admin of two companies can create in either", async () => {
  for (const c of [C1, C2]) { const w = world(); assert.equal((await call(w, "adminC1C2", body({ company_id: c }))).status, 200); }
});
test("callers without admin:users in that company are refused: ops, settings-only, inactive admin, no roles, no profile", async () => {
  for (const who of ["opsC1", "opsMulti", "settingsC1", "inactiveAdminC1", "noRoles", "noCompany"]) {
    const w = world(); const r = await call(w, who, body());
    assert.equal(r.status, 403, who); assert.ok(w.untouched(), who);
  }
});
test("a company the caller is not admin of cannot be probed: unknown company is 403 for non-super callers", async () => {
  const w = world(); const r = await call(w, "adminC1", body({ company_id: C_GHOST }));
  assert.equal(r.status, 403); assert.ok(w.untouched());
});
test("an unknown company is a 400 for a super admin and creates nothing", async () => {
  const w = world(); const r = await call(w, "brandon", body({ company_id: C_GHOST }));
  assert.equal(r.status, 400); assert.ok(w.untouched());
});

// ── which role may be assigned ──
test("a company admin cannot hand out the super admin role (privilege escalation)", async () => {
  const w = world(); const r = await call(w, "adminC1", body({ role_id: R_SUPER }));
  assert.equal(r.status, 403); assert.ok(w.untouched());
});
test("a super admin can assign the super admin role", async () => {
  const w = world(); assert.equal((await call(w, "brandon", body({ role_id: R_SUPER }))).status, 200);
});
test("a company admin can assign the admin role inside their own company", async () => {
  const w = world(); assert.equal((await call(w, "adminC1", body({ role_id: R_ADMIN }))).status, 200);
});
test("a role owned by another company cannot be used (400); a role owned by the target company can", async () => {
  const w1 = world(); const r1 = await call(w1, "brandon", body({ company_id: C1, role_id: R_C2ONLY }));
  assert.equal(r1.status, 400); assert.ok(w1.untouched());
  const w2 = world(); assert.equal((await call(w2, "adminC2", body({ company_id: C2, role_id: R_C2ONLY }))).status, 200);
});
test("an unknown role is a 400 and creates nothing (no login without a role)", async () => {
  const w = world(); const r = await call(w, "brandon", body({ role_id: id(777) }));
  assert.equal(r.status, 400); assert.ok(w.untouched());
});
test("authorisation failures happen before any write, even when later steps would also fail", async () => {
  const w = world({ failures: { createAuth: { status: 422, body: {} } } });
  const r = await call(w, "adminC1", body({ company_id: C2 }));
  assert.equal(r.status, 403); assert.ok(w.untouched());
});

// ── effects and error reporting ──
test("Supabase Auth failures keep their real reason (weak password, duplicate email)", async () => {
  const w1 = world({ failures: { createAuth: { status: 422, body: { error_code: "weak_password", msg: "Password should be at least 12 characters." } } } });
  const r1 = await call(w1, "brandon", body());
  assert.equal(r1.status, 422); assert.match(r1.json.error, /at least 12 characters/); assert.equal(r1.json.code, "weak_password");
  const w2 = world({ failures: { createAuth: { status: 422, body: { error_code: "email_exists", msg: "x" } } } });
  const r2 = await call(w2, "brandon", body());
  assert.match(r2.json.error, /already registered/);
  assert.equal(w2.st.profiles.length, 0);
});
test("a failed profile insert removes the new login (no orphan)", async () => {
  const w = world({ failures: { profile: true } });
  const r = await call(w, "brandon", body());
  assert.equal(r.status, 500); assert.deepEqual(w.st.deletes, [w.st.authUsers[0].id]); assert.equal(w.st.roleRows.length, 0);
});
test("a failed role insert still reports success with a warning, and the audit row says so", async () => {
  const w = world({ failures: { roleRow: true } });
  const r = await call(w, "brandon", body());
  assert.equal(r.status, 200); assert.equal(r.json.success, true); assert.match(r.json.warning, /role assignment failed/);
  assert.equal(w.st.audit[0].metadata.role_assigned, false);
});
test("caller rights are read with the service key keyed on the VERIFIED user, never from the request body", async () => {
  const w = world(); await call(w, "adminC1", { ...body({ company_id: C2 }), caller_id: w.people.brandon.auth, auth_user_id: w.people.brandon.auth });
  assert.ok(w.untouched());
  assert.ok(w.st.log.filter((l) => l.path.startsWith("/rest/v1/")).every((l) => l.svc));
});
