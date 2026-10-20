// update-erp-user v4 handler tests (see create.test.mjs for how to run).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { world, ENV, id } from "./world.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const FN = process.env.AUTHZ_FN_DIR ?? join(here, "..", "..", "functions");
const { handle } = await import(pathToFileURL(join(FN, "update-erp-user", "handler.ts")).href);

const PW = "correct-horse-battery";
const call = async (w, who, b) => { const r = await handle(w.req(who ? "tok-" + who : "", b), ENV, w.f); return { status: r.status, json: await r.json().catch(() => null) }; };
const T = (w, k) => w.people[k].auth;   // target auth id

// ── authentication and input ──
test("no header / forged token: 401, nothing changed", async () => {
  const w = world();
  assert.equal((await call(w, null, { auth_user_id: T(w, "opsC1"), password: PW })).status, 401);
  assert.equal((await handle(w.req("bad.token.x", { auth_user_id: T(w, "opsC1"), password: PW }), ENV, w.f)).status, 401);
  assert.ok(w.untouched());
});
test("bad input is a 400 and changes nothing", async () => {
  const w0 = world();
  for (const b of [{}, { auth_user_id: "nope", password: PW }, { auth_user_id: T(w0, "opsC1") }, { auth_user_id: T(w0, "opsC1"), password: "x".repeat(11) },
    { auth_user_id: T(w0, "opsC1"), email: "bad" }, "not json"]) {
    const w = world(); const r = await call(w, "brandon", b);
    assert.equal(r.status, 400, JSON.stringify(b)); assert.ok(w.untouched(), JSON.stringify(b));
  }
});
test("the server enforces the 12 character minimum (the old function allowed 8)", async () => {
  const w = world();
  assert.equal((await call(w, "brandon", { auth_user_id: T(w, "opsC1"), password: "12345678" })).status, 400);
  assert.equal((await call(w, "brandon", { auth_user_id: T(w, "opsC1"), password: "x".repeat(12) })).status, 200);
});

// ── who may change whom ──
test("a super admin can change anyone, including another super admin", async () => {
  for (const k of ["opsC1", "adminC2", "superC1", "noCompany"]) {
    const w = world(); const r = await call(w, "brandon", { auth_user_id: T(w, k), password: PW });
    assert.equal(r.status, 200, k); assert.deepEqual(w.st.puts, [{ id: T(w, k), body: { password: PW } }]);
  }
});
test("a company admin can change a member of their company (email and password)", async () => {
  const w = world(); const r = await call(w, "adminC1", { auth_user_id: T(w, "opsC1"), email: "new@example.com", password: PW });
  assert.equal(r.status, 200); assert.deepEqual(w.st.puts[0].body, { email: "new@example.com", password: PW });
});
test("a company admin can NOT change a user of another company (the old hole)", async () => {
  const w = world(); const r = await call(w, "adminC1", { auth_user_id: T(w, "adminC2"), password: PW });
  assert.equal(r.status, 403); assert.ok(w.untouched());
});
test("for a user in several companies the caller must administer ALL of them", async () => {
  const w1 = world(); assert.equal((await call(w1, "adminC1", { auth_user_id: T(w1, "opsMulti"), password: PW })).status, 403); assert.ok(w1.untouched());
  const w2 = world(); assert.equal((await call(w2, "adminC1C2", { auth_user_id: T(w2, "opsMulti"), password: PW })).status, 200);
  const w3 = world(); assert.equal((await call(w3, "adminC1opsC2", { auth_user_id: T(w3, "opsMulti"), password: PW })).status, 403);
});
test("a company admin can NOT change a super admin (takeover of the owner account)", async () => {
  const w = world(); const r = await call(w, "adminC1", { auth_user_id: T(w, "superC1"), password: PW });
  assert.equal(r.status, 403); assert.ok(w.untouched());
  const w2 = world(); assert.equal((await call(w2, "adminC1", { auth_user_id: T(w2, "brandon"), password: PW })).status, 403);
});
test("a user with no company cannot be changed by a non-super admin", async () => {
  const w = world(); assert.equal((await call(w, "adminC1", { auth_user_id: T(w, "noCompany"), password: PW })).status, 403); assert.ok(w.untouched());
});
test("non-admins are refused: ops, settings-only, inactive admin, no roles, no profile", async () => {
  for (const k of ["opsC1", "settingsC1", "inactiveAdminC1", "noRoles", "noCompany"]) {
    const w = world(); const r = await call(w, k, { auth_user_id: T(w, "opsC1"), password: PW });
    assert.equal(r.status, 403, k); assert.ok(w.untouched(), k);
  }
});
test("a caller with no admin rights gets 403 even for an account that does not exist (no existence oracle)", async () => {
  const w = world(); const r = await call(w, "opsC1", { auth_user_id: id(424242), password: PW });
  assert.equal(r.status, 403);
});
test("an unknown account is 404 for an admin", async () => {
  const w = world(); const r = await call(w, "brandon", { auth_user_id: id(424242), password: PW });
  assert.equal(r.status, 404); assert.ok(w.untouched());
});

// ── effects and error reporting ──
test("the error field is read from `msg`: the real Supabase reason reaches the admin (the wrong-field bug)", async () => {
  const w = world({ failures: { putAuth: { status: 422, body: { error_code: "weak_password", msg: "Password should be at least 12 characters.", weak_password: { reasons: ["length"] } } } } });
  const r = await call(w, "brandon", { auth_user_id: T(w, "opsC1"), password: PW });
  assert.equal(r.status, 422); assert.match(r.json.error, /at least 12 characters/); assert.equal(r.json.code, "weak_password");
});
test("an unexplained failure falls back to 'Failed to update auth user'", async () => {
  const w = world({ failures: { putAuth: { status: 500, body: {} } } });
  const r = await call(w, "brandon", { auth_user_id: T(w, "opsC1"), password: PW });
  assert.equal(r.status, 500); assert.equal(r.json.error, "Failed to update auth user");
  assert.equal(w.st.audit.length, 0);
});
test("the audit row names the fields changed but never contains the password or email values", async () => {
  const w = world(); await call(w, "adminC1", { auth_user_id: T(w, "opsC1"), email: "secret-new@example.com", password: PW });
  assert.equal(w.st.audit.length, 1); assert.equal(w.st.audit[0].action_type, "staff.credentials.update");
  assert.deepEqual(w.st.audit[0].metadata.fields, ["email", "password"]);
  const s = JSON.stringify(w.st.audit); assert.ok(!s.includes(PW) && !s.includes("secret-new@example.com"));
});

// ── the two functions share one authz.ts and one errors.ts ──
test("authz.ts and errors.ts are identical in both function folders (deploy takes one folder per function)", () => {
  for (const file of ["authz.ts", "errors.ts"]) {
    assert.equal(readFileSync(join(FN, "create-erp-user", file), "utf8").replaceAll("\r\n", "\n"), readFileSync(join(FN, "update-erp-user", file), "utf8").replaceAll("\r\n", "\n"), file);
  }
});
