// node --test supabase/tests/create_user/errors.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { describeAuthError } from "../../functions/create-erp-user/errors.ts";

test("weak password: the GoTrue `msg` and reasons reach the admin (the bug that hid an 11-character password)", () => {
  const r = describeAuthError({ code: 422, error_code: "weak_password", msg: "Password should be at least 12 characters.", weak_password: { reasons: ["length"] } }, 422);
  assert.equal(r.code, "weak_password"); assert.equal(r.status, 422);
  assert.match(r.message, /at least 12 characters/); assert.match(r.message, /length/);
});
test("weak password without a msg still explains itself", () => {
  const r = describeAuthError({ error_code: "weak_password" }, 422);
  assert.match(r.message, /password requirements/i);
});
test("email already registered gets a clear sentence for either code", () => {
  for (const code of ["email_exists", "user_already_exists"]) {
    const r = describeAuthError({ error_code: code, msg: "A user with this email address has already been registered" }, 422);
    assert.match(r.message, /already registered/); assert.equal(r.code, code);
  }
});
test("falls back through msg, message, error_description, error", () => {
  assert.equal(describeAuthError({ msg: "from msg" }, 400).message, "from msg");
  assert.equal(describeAuthError({ message: "from message" }, 400).message, "from message");
  assert.equal(describeAuthError({ error_description: "from desc" }, 400).message, "from desc");
  assert.equal(describeAuthError({ error: "from error" }, 400).message, "from error");
});
test("empty, null or non-object bodies give the generic fallback and never throw", () => {
  for (const b of [{}, null, undefined, "oops", 42, []]) assert.equal(describeAuthError(b, 500).message, "Failed to create auth user");
});
test("blank strings are ignored", () => { assert.equal(describeAuthError({ msg: "   ", message: "real" }, 400).message, "real"); });
test("status is passed through when it is a client/server error, otherwise normalised to 500", () => {
  assert.equal(describeAuthError({}, 422).status, 422);
  assert.equal(describeAuthError({}, 200).status, 500);
  assert.equal(describeAuthError({}, 0).status, 500);
  assert.equal(describeAuthError({}, NaN).status, 500);
  assert.equal(describeAuthError({}, 700).status, 500);
});
test("does not leak unrelated fields", () => {
  const r = describeAuthError({ msg: "x", service_key: "SECRET", stack: "trace" }, 400);
  assert.deepEqual(Object.keys(r).sort(), ["code", "message", "status"]); assert.ok(!JSON.stringify(r).includes("SECRET"));
});
