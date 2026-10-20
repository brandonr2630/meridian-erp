// Closing a modal opened from inside the Work Orders job form (e.g. the Delete Phase confirm) must not reload the list view
// and drop the open job. Run: node --test scripts/tests/ui/modal-popstate.test.mjs  (UI_SRC points at a mutated copy)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const html = readFileSync(process.env.UI_SRC ?? join(root, "index.html"), "utf8").replaceAll("\r\n", "\n");
const start = html.indexOf("window.addEventListener('popstate'");
const end = html.indexOf("\n});\n", start) + 5;
assert.ok(start > 0 && end > start, "could not slice the popstate handler");
const code = html.slice(start, end);

function run({ state, overlays = [], currentView = "job-cards", formActive = false }) {
  const log = { navigated: [], closed: [] };
  let handler;
  const ctx = {
    window: { addEventListener: (ev, fn) => { if (ev === "popstate") handler = fn; } },
    document: {
      querySelectorAll: () => overlays.map((id) => ({ id })),
      getElementById: (id) => (id === "jc-form-wrap" ? { classList: { contains: (c) => c === "active" && formActive } } : null),
    },
    navigate: (v, o) => log.navigated.push([v, o]),
    _popstateCloseModal: (id) => log.closed.push(id),
    currentView,
  };
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  handler({ state });
  return log;
}

test("closing a modal from the open job form stays on the form (no reload of the list)", () => {
  const l = run({ state: { view: "job-cards" }, overlays: ["modal-confirm"], formActive: true });
  assert.deepEqual(l.closed, ["modal-confirm"]);
  assert.equal(l.navigated.length, 0);
});
test("closing a modal while the job LIST is showing still re-navigates to the view (unchanged behaviour)", () => {
  const l = run({ state: { view: "job-cards" }, overlays: ["modal-confirm"], formActive: false });
  assert.equal(JSON.stringify(l.navigated), JSON.stringify([["job-cards", { push: false }]]));
});
test("a real back navigation to another view with the form open still navigates", () => {
  const l = run({ state: { view: "dashboard" }, overlays: [], formActive: true, currentView: "job-cards" });
  assert.equal(JSON.stringify(l.navigated), JSON.stringify([["dashboard", { push: false }]]));
});
test("a back navigation within the same view but with NO modal closed still navigates", () => {
  const l = run({ state: { view: "job-cards" }, overlays: [], formActive: true });
  assert.equal(l.navigated.length, 1);
});
test("closing a modal in a different view's state navigates even with the form flag set", () => {
  const l = run({ state: { view: "ar" }, overlays: ["modal-confirm"], formActive: true, currentView: "job-cards" });
  assert.equal(l.navigated.length, 1);
});
test("no state falls back to the dashboard", () => {
  const l = run({ state: null, overlays: [], formActive: true });
  assert.equal(JSON.stringify(l.navigated), JSON.stringify([["dashboard", { push: false }]]));
});
test("a state that names a modal never navigates", () => {
  const l = run({ state: { view: "job-cards", modal: "modal-confirm" }, overlays: [], formActive: false });
  assert.equal(l.navigated.length, 0);
});
