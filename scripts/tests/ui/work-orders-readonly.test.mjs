// Tests for the read-only work-order mode (D0c UI follow-up). Run: node --test scripts/tests/ui/work-orders-readonly.test.mjs
// index.html is one big inline script, so the code under test is sliced out of it (the D0c-UI block plus jcSetLocked) and
// evaluated against a tiny fake DOM; static assertions pin the call sites that cannot be run without a login.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const SRC = process.env.UI_SRC ?? join(root, "index.html");   // UI_SRC lets the mutation check point at a mutated copy
const html = readFileSync(SRC, "utf8").replaceAll("\r\n", "\n");
const between = html.slice(html.indexOf("// D0c-UI:begin"), html.indexOf("// D0c-UI:end"));
const lockFn = html.match(/function jcSetLocked\(lock\) \{[\s\S]*?\n\}\n/)[0];
assert.ok(between.length > 200 && lockFn, "could not slice the code under test");

function env({ canWrite }) {
  const classes = new Map(); const log = { toasts: [], patches: [] };
  const node = (id) => ({ id, style: { display: "" }, classList: {
    add: (c) => (classes.get(id) ?? classes.set(id, new Set()).get(id)).add(c),
    remove: (c) => classes.get(id)?.delete(c),
    toggle: (c, on) => { const s = classes.get(id) ?? classes.set(id, new Set()).get(id); (on ? s.add(c) : s.delete(c)); },
    contains: (c) => !!classes.get(id)?.has(c),
  } });
  const nodes = { "jc-form-wrap": node("jc-form-wrap"), "jc-ro-banner": node("jc-ro-banner"), "jc-lock-banner": node("jc-lock-banner") };
  const buttons = ["jcNewJob()", "jcSaveJob()", "jcSaveJob()", "jcDuplicateJob()", "jcDuplicateJob()"].map((x, i) => ({ id: "b" + i, onclick: x, style: { display: "" } }));
  const document = { getElementById: (id) => nodes[id] ?? null, querySelectorAll: () => buttons };
  const ctx = { can: (a) => (a === "ops:work-orders:write" ? canWrite : false), document, showToast: (m, t) => log.toasts.push([m, t]),
    jcIsLocked: false, jcAdminCostUnlocked: false, sbPatch: async (t, id, b) => { log.patches.push([t, id, b]); return ctx.__patchResult; }, __patchResult: [{ id: 1 }] };
  const names = ["jcIsReadOnlyRole", "jcDenyIfReadOnly", "jcApplyWriteAccess", "sbPatchChecked", "jcSetLocked"];
  // The code under test is sliced from this repo's own index.html (trusted); run it in a vm context holding only the fake globals.
  const code = `(function(){ let jcIsLocked=false, jcAdminCostUnlocked=false;\n${between}\n${lockFn}\nreturn { ${names.join(", ")}, setAdminUnlock:(v)=>{jcAdminCostUnlocked=v}, isLocked:()=>jcIsLocked }; })()`;
  vm.createContext(ctx);
  const api = vm.runInContext(code, ctx);
  return { api, nodes, buttons, log, ctx, has: (id, c) => nodes[id].classList.contains(c) };
}

test("a role WITH write sees every control and an editable form", () => {
  const e = env({ canWrite: true });
  assert.equal(e.api.jcApplyWriteAccess(), false);
  assert.ok(e.buttons.every((b) => b.style.display === ""));
  assert.ok(!e.has("jc-form-wrap", "jc-readonly") && !e.has("jc-form-wrap", "jc-ro-role") && !e.has("jc-ro-banner", "show"));
});
test("a read-only role: New / Save / Duplicate are hidden, form inert, banner shown, toolbar exception applied", () => {
  const e = env({ canWrite: false });
  assert.equal(e.api.jcApplyWriteAccess(), true);
  assert.ok(e.buttons.every((b) => b.style.display === "none"));
  assert.ok(e.has("jc-form-wrap", "jc-readonly") && e.has("jc-form-wrap", "jc-ro-role") && e.has("jc-ro-banner", "show"));
});
test("switching back to a writer restores the controls (no stale hidden state)", () => {
  const e = env({ canWrite: false }); e.api.jcApplyWriteAccess();
  e.ctx.can = () => true; // the closure reads ctx.can through the parameter, so rebuild instead
  const w = env({ canWrite: true }); w.buttons.forEach((b) => (b.style.display = "none")); w.api.jcApplyWriteAccess();
  assert.ok(w.buttons.every((b) => b.style.display === ""));
});
test("jcDenyIfReadOnly blocks and tells the user; allows writers silently", () => {
  const ro = env({ canWrite: false }); assert.equal(ro.api.jcDenyIfReadOnly(), true); assert.equal(ro.log.toasts.length, 1); assert.match(ro.log.toasts[0][0], /read-only/i);
  const rw = env({ canWrite: true }); assert.equal(rw.api.jcDenyIfReadOnly(), false); assert.equal(rw.log.toasts.length, 0);
});
test("jcSetLocked: a read-only role stays read-only even when the job is not locked", () => {
  const e = env({ canWrite: false }); e.api.jcSetLocked(false);
  assert.ok(e.has("jc-form-wrap", "jc-readonly")); assert.ok(!e.has("jc-lock-banner", "show"));
});
test("jcSetLocked: writers keep the existing lock behaviour (locked = inert, unlocked = editable, admin unlock = editable)", () => {
  const e = env({ canWrite: true });
  e.api.jcSetLocked(true); assert.ok(e.has("jc-form-wrap", "jc-readonly")); assert.ok(e.has("jc-lock-banner", "show"));
  e.api.setAdminUnlock(true); e.api.jcSetLocked(true); assert.ok(!e.has("jc-form-wrap", "jc-readonly"));
  e.api.setAdminUnlock(false); e.api.jcSetLocked(false); assert.ok(!e.has("jc-form-wrap", "jc-readonly")); assert.ok(!e.has("jc-lock-banner", "show"));
});
test("sbPatchChecked: an RLS-denied update (200 with an empty list) is an error, not a success", async () => {
  const e = env({ canWrite: true });
  for (const bad of [[], null, undefined, {}, "ok"]) { e.ctx.__patchResult = bad;
    await assert.rejects(() => e.api.sbPatchChecked("jobs", "1", { a: 1 }), /not saved/, String(JSON.stringify(bad))); }
});
test("sbPatchChecked: a real update passes the rows through and calls sbPatch once", async () => {
  const e = env({ canWrite: true }); e.ctx.__patchResult = [{ id: 7 }];
  assert.deepEqual(await e.api.sbPatchChecked("jobs", "7", { a: 1 }), [{ id: 7 }]); assert.deepEqual(e.log.patches, [["jobs", "7", { a: 1 }]]);
});

// ── call sites that need a login to run: pin them statically ──
const fnBody = (name) => html.match(new RegExp(`(?:async )?function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n\\}\\n`))[0];
test("New, Save and Duplicate start with the read-only guard", () => {
  for (const f of ["jcNewJob", "jcSaveJob", "jcDuplicateJob"]) assert.match(fnBody(f), /^(?:async )?function \w+\([^)]*\) \{\n  if \(jcDenyIfReadOnly\(\)\) return;/, f);
});
test("saving a work order and editing a task use the checked PATCH", () => {
  assert.match(fnBody("jcSaveJobData"), /await sbPatchChecked\('jobs', savedId, jobRecord\)/);
  assert.match(fnBody("jcTaskSet"), /await sbPatchChecked\('job_tasks', id, patch\)/);
  assert.ok(!/await sbPatch\('jobs', savedId/.test(fnBody("jcSaveJobData")));
});
test("write access is applied when Work Orders loads and when a job opens", () => {
  assert.match(fnBody("loadJobCards"), /jcApplyWriteAccess\(\);/);
  assert.match(fnBody("jcOpenForm"), /jcApplyWriteAccess\(\);/);
});
test("markup: the read-only banner exists and the toolbar exception CSS is present", () => {
  assert.ok(html.includes('id="jc-ro-banner"'));
  assert.match(html, /\.jc-form-wrap\.jc-ro-role \.jc-toolbar \{ pointer-events:auto; \}/);
});
test("every New / Save / Duplicate button in the markup is covered by the selector", () => {
  const sel = ['onclick="jcNewJob()"', 'onclick="jcSaveJob()"', 'onclick="jcDuplicateJob()"'];
  const markup = html.replace(/<script[\s\S]*?<\/script>/g, "");   // buttons only, not the selector strings inside the script
  const found = sel.map((s) => markup.split(s).length - 1);
  assert.deepEqual(found, [1, 3, 2], "if a button was added or removed, review jcApplyWriteAccess");
});
