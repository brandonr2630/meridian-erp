# Browser History Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Meridian ERP's in-app navigation with the browser's native Back, Forward, and Refresh — views get real bookmarkable URLs, opening a modal is a Back step, and a defined set of primary-record modals are deep-linkable (refresh re-fetches the record and reopens the modal).

**Architecture:** Hash-based routing for views (`#/<view>`), full deep-links for the ~17 modals that edit an existing record with a stable ID (`#/<view>/<type>/<id>`), and invisible `history.pushState` markers for every other modal (create-new forms, confirmations, action dialogs, PDF previews) so Back closes them without giving them a visible URL. `openModal(id, opts)` is implemented for real for the first time — it was referenced once in the codebase (`openEmailDocument()`) but never defined; that `ReferenceError` was already fixed this session by removing the call rather than adding the function. This plan supersedes that patch with a real implementation. The existing `closeModal(id)` function (already the single close point used everywhere) gets the history-popping logic added to it, so all ~60 existing call sites that already call `closeModal` need no changes at all.

**Tech Stack:** Vanilla HTML/CSS/JS (single file `index.html`), no build step, no test framework — verification is manual click-through, per this repo's existing convention.

**Reference:** Design spec at `docs/superpowers/specs/2026-08-14-browser-history-sync-design.md`. That spec's modal classification table has been superseded by the corrected one in Task 3/Task 4 below — six modals originally flagged "confirm in plan phase" or tentatively deep-linked turned out, on inspection of their open functions, to be create-only or list-management panels with no per-record edit mode, so they're reclassified marker-only here: `modal-journal`, `modal-credit-note`, `modal-delivery-note`, `modal-bank-txn`, `modal-sales-leads`, `modal-contact`.

---

## Task 1: Hash-based view routing

**Files:**
- Modify: `meridian-erp/index.html` — `navigate()` at line 6449, plus a new boot-time restore call

- [ ] **Step 1: Add `push` option to `navigate()`**

Find (line 6449):
```js
function navigate(view) {
```

Replace with:
```js
function navigate(view, opts = {}) {
  const push = opts.push !== false;
```

- [ ] **Step 2: Push history state at the end of `navigate()`, after the (possibly guard-reassigned) `view` is final**

Find (lines 6478-6486):
```js
  document.querySelectorAll('.page-view').forEach(v => v.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  document.getElementById('view-' + view)?.classList.add('active');
  document.getElementById('nav-' + view)?.classList.add('active');
  currentView = view;
  (VIEW_SECTIONS[view] || []).forEach(expandSection);
  if (window.innerWidth <= 900) closeSidebar();
  loadViewData(view);
}
```

Replace with:
```js
  document.querySelectorAll('.page-view').forEach(v => v.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  document.getElementById('view-' + view)?.classList.add('active');
  document.getElementById('nav-' + view)?.classList.add('active');
  currentView = view;
  (VIEW_SECTIONS[view] || []).forEach(expandSection);
  if (window.innerWidth <= 900) closeSidebar();
  if (push) history.pushState({ view }, '', '#/' + view);
  loadViewData(view);
}
```

- [ ] **Step 3: Add the `popstate` handler and boot-time hash restore**

Add this new code immediately after the `navigate()` function (after its closing `}` at what is now line ~6488, before `function toggleSidebar()`):

```js
window.addEventListener('popstate', (e) => {
  const state = e.state;
  if (!state) { navigate('dashboard', { push: false }); return; }
  if (state.modal) {
    _popstateCloseModal(state.modal);
    return;
  }
  if (state.view) { navigate(state.view, { push: false }); }
});

function _restoreViewFromHash() {
  const hash = location.hash.replace(/^#\/?/, '');
  if (!hash) { navigate('dashboard', { push: false }); return; }
  const parts = hash.split('/');
  const view = parts[0];
  if (!document.getElementById('view-' + view)) { navigate('dashboard', { push: false }); return; }
  navigate(view, { push: false });
  history.replaceState({ view }, '', '#/' + view);
  if (parts.length >= 3) {
    _restoreDeepLinkedModal(parts[0], parts[1], parts[2]);
  }
}
```

`_popstateCloseModal` and `_restoreDeepLinkedModal` are defined in Task 2 and Task 5 respectively — this step only wires the call sites; the app will not yet call `_restoreViewFromHash()` until Task 5 hooks it into boot.

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat: hash-based view routing, push view state on navigate()"
```

---

## Task 2: `openModal()`/`closeModal()` history-aware lifecycle

**Files:**
- Modify: `meridian-erp/index.html` — `closeModal()` at line 17331, new `openModal()` added near it

- [ ] **Step 1: Add `openModal()` right before the existing `closeModal()`**

Find (line 17331):
```js
function closeModal(id) {
  document.getElementById(id).classList.remove('show');
}
```

Replace with:
```js
function openModal(id, opts = {}) {
  document.getElementById(id).classList.add('show');
  if (opts.recordType && opts.recordId) {
    history.pushState(
      { view: currentView, modal: id, recordType: opts.recordType, recordId: opts.recordId },
      '',
      '#/' + currentView + '/' + opts.recordType + '/' + opts.recordId
    );
  } else {
    history.pushState({ view: currentView, modal: id }, '', location.href);
  }
}

function closeModal(id) {
  if (history.state && history.state.modal === id) {
    history.back();
    return;
  }
  document.getElementById(id).classList.remove('show');
}

function _popstateCloseModal(id) {
  document.getElementById(id).classList.remove('show');
}
```

`_popstateCloseModal` is the DOM-only hide path used by the `popstate` handler from Task 1 — it must NOT call `closeModal()` (which would call `history.back()` again and desync the stack, since `popstate` fires as a *result* of a back navigation, not a cause of one).

- [ ] **Step 2: Pilot-wire one marker-only modal to prove the round trip — `modal-confirm`**

Find (line 11613, inside the function that shows the generic confirm dialog):
```js
    document.getElementById('modal-confirm').classList.add('show');
```

Replace with:
```js
    openModal('modal-confirm');
```

(The rest of Task 3 does the same mechanical replacement for every other marker-only modal — this step exists only so Step 3 below has one real modal to test against before rolling out to the other ~43.)

- [ ] **Step 3: Manually verify the round trip**

Open the app, trigger any action that shows a confirm dialog (e.g. delete a draft — cancel out of the actual delete, just get the dialog open). Confirm:
1. The dialog opens normally.
2. Press the browser Back button — the dialog closes, the underlying view is unchanged, and the URL/history pointer moved back by exactly one step (check via a second Back press: it should now navigate to the previously viewed page, not do nothing / not skip two steps).
3. Reopen the dialog, this time close it via its own Cancel/X button (which calls `closeModal('modal-confirm')`) — confirm it closes normally, AND that a subsequent Back press does NOT re-show the dialog (i.e. `closeModal`'s `history.back()` correctly popped the entry, it didn't leave a stale one behind).

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat: implement openModal()/closeModal() history-aware modal lifecycle"
```

---

## Task 3: Migrate marker-only modals to `openModal()`

**Files:**
- Modify: `meridian-erp/index.html` — every line below

Mechanical rule for this whole task: every line of the form `document.getElementById('modal-X').classList.add('show');` becomes `openModal('modal-X');` (same indentation, same trailing semicolon/comment if present). `modal-confirm` (line 11613) was already migrated in Task 2 Step 2 — skip it here.

- [ ] **Step 1: Apply the replacement to every line below**

| Line | Modal | Before | After |
|---|---|---|---|
| 6629 | `modal-role-edit` (new) | `document.getElementById('modal-role-edit').classList.add('show');` | `openModal('modal-role-edit');` |
| 6925 | `modal-create-user` | `document.getElementById('modal-create-user').classList.add('show');` | `openModal('modal-create-user');` |
| 9647 | `modal-account` (new) | `document.getElementById('modal-account').classList.add('show');` | `openModal('modal-account');` |
| 9819 | `modal-journal` | `document.getElementById('modal-journal').classList.add('show');` | `openModal('modal-journal');` |
| 10237 | `modal-po` (new) | `document.getElementById('modal-po').classList.add('show');` | `openModal('modal-po');` |
| 10358 | `modal-po` (duplicate-as-new) | `document.getElementById('modal-po').classList.add('show');` | `openModal('modal-po');` |
| 10459 | `modal-po-pdf` | `document.getElementById('modal-po-pdf').classList.add('show');` | `openModal('modal-po-pdf');` |
| 10537 | `modal-bill-payment` | `document.getElementById('modal-bill-payment').classList.add('show');` | `openModal('modal-bill-payment');` |
| 10653 | `modal-bill-pay-history` | `document.getElementById('modal-bill-pay-history').classList.add('show');` | `openModal('modal-bill-pay-history');` |
| 10771 | `modal-void-reason` | `document.getElementById('modal-void-reason').classList.add('show');` | `openModal('modal-void-reason');` |
| 10916 | `modal-client` (new) | `document.getElementById('modal-client').classList.add('show');` | `openModal('modal-client');` |
| 11105 | `modal-vendor` (new) | `document.getElementById('modal-vendor').classList.add('show');` | `openModal('modal-vendor');` |
| 11255 | `modal-erp-company` (new) | `document.getElementById('modal-erp-company').classList.add('show');` | `openModal('modal-erp-company');` |
| 11531 | `modal-contact` | `function openAddContact() { document.getElementById('modal-contact').classList.add('show'); }` | `function openAddContact() { openModal('modal-contact'); }` |
| 11569 | `modal-fy` | `document.getElementById('modal-fy').classList.add('show');` | `openModal('modal-fy');` |
| 11663 | `modal-post-review` | `document.getElementById('modal-post-review').classList.add('show');` | `openModal('modal-post-review');` |
| 11702 | `modal-payment` | `document.getElementById('modal-payment').classList.add('show');` | `openModal('modal-payment');` |
| 11820 | `modal-payment-confirmed` | `document.getElementById('modal-payment-confirmed').classList.add('show');` | `openModal('modal-payment-confirmed');` |
| 11976 | `modal-receipt-pdf` | `document.getElementById('modal-receipt-pdf').classList.add('show');` | `openModal('modal-receipt-pdf');` |
| 11989 | `modal-invoice-receipts` | `document.getElementById('modal-invoice-receipts').classList.add('show');` | `openModal('modal-invoice-receipts');` |
| 12142 | `modal-bank-account` (new) | `document.getElementById('modal-bank-account').classList.add('show');` | `openModal('modal-bank-account');` |
| 12324 | `modal-bank-txn` | `document.getElementById('modal-bank-txn').classList.add('show');` | `openModal('modal-bank-txn');` |
| 12398 | `modal-bill` (new) | `document.getElementById('modal-bill').classList.add('show');` | `openModal('modal-bill');` |
| 13087 | `modal-report-preview` | `document.getElementById('modal-report-preview').classList.add('show');` | `openModal('modal-report-preview');` |
| 13704 | `modal-invoice` (new) | `document.getElementById('modal-invoice').classList.add('show');` | `openModal('modal-invoice');` |
| 14442 | `modal-quotation` (new) | `document.getElementById('modal-quotation').classList.add('show');` | `openModal('modal-quotation');` |
| 14493 | `modal-quo-template-picker` | `document.getElementById('modal-quo-template-picker').classList.add('show');` | `openModal('modal-quo-template-picker');` |
| 14647 | `modal-quotation` (from template) | `document.getElementById('modal-quotation').classList.add('show');` | `openModal('modal-quotation');` |
| 14833 | `modal-quo-status` | `document.getElementById('modal-quo-status').classList.add('show');` | `openModal('modal-quo-status');` |
| 14940 | `modal-sales-leads` | `document.getElementById('modal-sales-leads').classList.add('show');` | `openModal('modal-sales-leads');` |
| 15395 | `modal-delivery-note` | `document.getElementById('modal-delivery-note').classList.add('show');` | `openModal('modal-delivery-note');` |
| 15505 | `modal-dn-status` | `document.getElementById('modal-dn-status').classList.add('show');` | `openModal('modal-dn-status');` |
| 15669 | `modal-credit-note` | `document.getElementById('modal-credit-note').classList.add('show');` | `openModal('modal-credit-note');` |
| 16408 | `modal-send-email` | `document.getElementById('modal-send-email').classList.add('show');` | `openModal('modal-send-email');` |
| 16930 | `modal-pdf-preview` | `document.getElementById('modal-pdf-preview').classList.add('show');` | `openModal('modal-pdf-preview');` |
| 16962 | `modal-quo-pdf` | `document.getElementById('modal-quo-pdf').classList.add('show');` | `openModal('modal-quo-pdf');` |
| 16997 | `modal-dn-pdf` | `document.getElementById('modal-dn-pdf').classList.add('show');` | `openModal('modal-dn-pdf');` |
| 17026 | `modal-cn-pdf` | `document.getElementById('modal-cn-pdf').classList.add('show');` | `openModal('modal-cn-pdf');` |
| 17467 | `modal-opportunity` (new) | `document.getElementById('modal-opportunity').classList.add('show');` | `openModal('modal-opportunity');` |
| 17697 | `modal-crm-activity` (new) | `document.getElementById('modal-crm-activity').classList.add('show');` | `openModal('modal-crm-activity');` |
| 17879 | `modal-crm-task` (new) | `document.getElementById('modal-crm-task').classList.add('show');` | `openModal('modal-crm-task');` |
| 18030 | `modal-crm-team-member` (new) | `document.getElementById('modal-crm-team-member').classList.add('show');` | `openModal('modal-crm-team-member');` |
| 18436 | `modal-contact-persons` | `document.getElementById('modal-contact-persons').classList.add('show');` | `openModal('modal-contact-persons');` |
| 18486 | `modal-cp-form` (new) | `document.getElementById('modal-cp-form').classList.add('show');` | `openModal('modal-cp-form');` |

**Note:** several line numbers above will shift by a small amount after Task 1/2's edits land earlier in the file (Task 1 adds ~15 lines around line 6449-6488, Task 2 adds ~15 lines around line 17331). Re-`Grep` for `classList.add('show')` before starting this task to get current line numbers — the modal IDs and surrounding code are unambiguous regardless of the exact line number, so use the modal ID + surrounding 1-2 lines of context to locate each one precisely.

- [ ] **Step 2: `modal-user-overrides` — special case (non-standard open pattern)**

This modal doesn't use the `classList.add('show')` convention at all — it uses inline `style.display`. Find (around line 6716, inside its open function):
```js
  document.getElementById('modal-user-overrides').style.display = 'flex';
```

Replace with:
```js
  openModal('modal-user-overrides');
```

This normalizes it onto the standard convention (and, as a side effect, fixes a latent bug: `closeModal()` only ever did `classList.remove('show')`, which never undid `style.display = 'flex'` — meaning this modal's existing "Cancel"/X close buttons may not have been fully hiding it before this change). Also confirm the modal's CSS class `modal-overlay` already defines its default hidden state and `.show` visible state consistently with every other modal (check `.modal-overlay` and `.modal-overlay.show` rules in the `<style>` block) — if `modal-user-overrides` has a `style="display:none;"` inline attribute in its HTML (it does, per its `<div id="modal-user-overrides" class="modal-overlay" style="display:none;" ...>` tag), remove that inline `style="display:none;"` from the HTML too, since `.modal-overlay` (without `.show`) should already hide it via CSS the same way every other modal is hidden by default — leaving both would be redundant but not necessarily broken; removing it makes this modal consistent with all the others structurally.

- [ ] **Step 3: Manual spot-check**

Pick 5 modals from the table above spanning different areas of the app (e.g. `modal-account`, `modal-payment`, `modal-send-email`, `modal-pdf-preview`, `modal-crm-task`). For each: open it, confirm it still displays correctly, press Back, confirm it closes and the URL is unchanged (no visible hash segment appeared/disappeared), confirm the app is otherwise fully functional (no console errors).

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat: route all marker-only modals through openModal() for Back-to-close"
```

---

## Task 4: Wire the 17 deep-linked record modals

**Files:**
- Modify: `meridian-erp/index.html` — the 17 lines below, all inside their respective `openEditX(id)` functions

Each row: replace the modal's `classList.add('show')` call (inside the confirmed `openEditX(id)` function, NOT the sibling "new" function for the same modal) with `openModal('modal-X', { recordType: '<type>', recordId: <idVar> })`.

| Line | Function | Modal | recordType | idVar | After |
|---|---|---|---|---|---|
| 6640 | `openEditRoleModal(roleId)` | `modal-role-edit` | `role` | `roleId` | `openModal('modal-role-edit', { recordType: 'role', recordId: roleId });` |
| 6943 | `openEditUserModal(authUserId)` | `modal-edit-user` | `user` | `authUserId` | `openModal('modal-edit-user', { recordType: 'user', recordId: authUserId });` |
| 7029 | `openEditPermissionsModal(authUserId)` | `modal-edit-permissions` | `permissions` | `authUserId` | `openModal('modal-edit-permissions', { recordType: 'permissions', recordId: authUserId });` |
| 9668 | `openEditAccount(id)` | `modal-account` | `account` | `id` | `openModal('modal-account', { recordType: 'account', recordId: id });` |
| 10327 | `openEditPO(id)` | `modal-po` | `po` | `id` | `openModal('modal-po', { recordType: 'po', recordId: id });` |
| 10951 | `openEditClient(id)` | `modal-client` | `client` | `id` | `openModal('modal-client', { recordType: 'client', recordId: id });` |
| 11141 | `openEditVendor(id)` | `modal-vendor` | `vendor` | `id` | `openModal('modal-vendor', { recordType: 'vendor', recordId: id });` |
| 11292 | `openEditErpCompany(id)` | `modal-erp-company` | `company` | `id` | `openModal('modal-erp-company', { recordType: 'company', recordId: id });` |
| 12168 | `openEditBankAccount(id)` | `modal-bank-account` | `bank-account` | `id` | `openModal('modal-bank-account', { recordType: 'bank-account', recordId: id });` |
| 12443 | `openEditBill(billId)` | `modal-bill` | `bill` | `billId` | `openModal('modal-bill', { recordType: 'bill', recordId: billId });` |
| 13773 | `openEditInvoice(id)` | `modal-invoice` | `invoice` | `id` | `openModal('modal-invoice', { recordType: 'invoice', recordId: id });` |
| 14587 | `openEditQuotation(id)` | `modal-quotation` | `quote` | `id` | `openModal('modal-quotation', { recordType: 'quote', recordId: id });` |
| 17490 | `openEditOpportunity(id)` | `modal-opportunity` | `opp` | `id` | `openModal('modal-opportunity', { recordType: 'opp', recordId: id });` |
| 17710 | `openEditActivity(id)` | `modal-crm-activity` | `activity` | `id` | `openModal('modal-crm-activity', { recordType: 'activity', recordId: id });` |
| 17892 | `openEditTask(id)` | `modal-crm-task` | `task` | `id` | `openModal('modal-crm-task', { recordType: 'task', recordId: id });` |
| 18041 | `openEditTeamMember(id)` | `modal-crm-team-member` | `team-member` | `id` | `openModal('modal-crm-team-member', { recordType: 'team-member', recordId: id });` |
| 18500 | `openEditCPForm(id)` | `modal-cp-form` | `cp` | `id` | `openModal('modal-cp-form', { recordType: 'cp', recordId: currentClient360Id + ':' + id });` |

`modal-cp-form` is the one nested case — it lives under Client 360, so its `recordId` is composited as `<clientId>:<contactPersonId>` (both needed to restore it; `currentClient360Id` is the existing global used by the Client 360 view). Task 5's restore logic splits on `:` for this one entry.

- [ ] **Step 1: Apply all 17 replacements above**

Same line-number caveat as Task 3 — re-locate by function name + modal ID if line numbers have shifted from earlier tasks in this plan.

- [ ] **Step 2: Add the `MODAL_RECORD_ROUTES` dispatch table**

Add this near the top of the navigation code, right after the `_restoreViewFromHash()` function added in Task 1 Step 3:

```js
const MODAL_RECORD_ROUTES = {
  role:           { view: 'role-management', openFn: id => openEditRoleModal(id) },
  user:           { view: 'user-management', openFn: id => openEditUserModal(id) },
  permissions:    { view: 'user-management', openFn: id => openEditPermissionsModal(id) },
  account:        { view: 'coa',              openFn: id => openEditAccount(id) },
  po:             { view: 'purchase-orders',  openFn: id => openEditPO(id) },
  client:         { view: 'clients',          openFn: id => openEditClient(id) },
  vendor:         { view: 'vendors',          openFn: id => openEditVendor(id) },
  company:        { view: 'companies',        openFn: id => openEditErpCompany(id) },
  'bank-account': { view: 'bank',             openFn: id => openEditBankAccount(id) },
  bill:           { view: 'ap',               openFn: id => openEditBill(id) },
  invoice:        { view: 'ar',               openFn: id => openEditInvoice(id) },
  quote:          { view: 'quotations',       openFn: id => openEditQuotation(id) },
  opp:            { view: 'pipeline',         openFn: id => openEditOpportunity(id) },
  activity:       { view: 'pipeline',         openFn: id => openEditActivity(id) },
  task:           { view: 'pipeline',         openFn: id => openEditTask(id) },
  'team-member':  { view: 'pipeline',         openFn: id => openEditTeamMember(id) },
  cp:             { view: 'client-360',       openFn: id => openEditCPForm(id) },
};
```

This table is consumed by Task 5's `_restoreDeepLinkedModal()`.

- [ ] **Step 3: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat: wire 17 deep-linked record modals with recordType/recordId + dispatch table"
```

---

## Task 5: Refresh restoration + error handling

**Files:**
- Modify: `meridian-erp/index.html` — `_restoreDeepLinkedModal()` (new), boot sequence hook

- [ ] **Step 1: Implement `_restoreDeepLinkedModal()`**

Add this function right after `MODAL_RECORD_ROUTES` (from Task 4 Step 2):

```js
async function _restoreDeepLinkedModal(view, recordType, rawId) {
  const route = MODAL_RECORD_ROUTES[recordType];
  if (!route || route.view !== view) {
    history.replaceState({ view }, '', '#/' + view);
    return;
  }
  try {
    if (recordType === 'cp') {
      const [clientId, cpId] = rawId.split(':');
      if (!clientId || !cpId) throw new Error('Malformed link');
      currentClient360Id = clientId;
      await loadClient360();
      await route.openFn(cpId);
    } else {
      await route.openFn(rawId);
    }
    if (!document.getElementById(_routeModalId(recordType))?.classList.contains('show')) {
      throw new Error('Record not found');
    }
  } catch (e) {
    showToast('That record no longer exists or you don\'t have access.', 'warn');
    history.replaceState({ view }, '', '#/' + view);
  }
}

function _routeModalId(recordType) {
  const map = {
    role: 'modal-role-edit', user: 'modal-edit-user', permissions: 'modal-edit-permissions',
    account: 'modal-account', po: 'modal-po', client: 'modal-client', vendor: 'modal-vendor',
    company: 'modal-erp-company', 'bank-account': 'modal-bank-account', bill: 'modal-bill',
    invoice: 'modal-invoice', quote: 'modal-quotation', opp: 'modal-opportunity',
    activity: 'modal-crm-activity', task: 'modal-crm-task', 'team-member': 'modal-crm-team-member',
    cp: 'modal-cp-form',
  };
  return map[recordType];
}
```

Every one of the 17 `openEditX(id)` functions already does its own `if (!record) return;` guard (confirmed in Task 4's table — e.g. `openEditPO`: `const po = purchaseOrders.find(p => p.id === id); if (!po) return;`), so a missing/deleted/inaccessible record simply results in the modal never getting `.show` added — the `if (!... .classList.contains('show')) throw` check above catches that silently-did-nothing case and turns it into the toast + URL cleanup.

- [ ] **Step 2: Hook `_restoreViewFromHash()` into the boot sequence**

`initApp()` (called from the `DOMContentLoaded` handler once session restore + `erp_users` profile lookup succeed) currently hard-codes landing on the workspace screen. Find (line 6263, the last line of `initApp()`):

```js
  navigate('workspace');
}
```

Replace with:

```js
  if (location.hash) {
    _restoreViewFromHash();
  } else {
    navigate('workspace');
  }
}
```

`loadCompanies()` (line 6248) already runs before this point, so `currentCompany` is set before `_restoreViewFromHash()` (and therefore any `openEditX(id)` fetch it triggers) runs. If a saved/bookmarked hash references a view scoped to a company other than the one `loadCompanies()` auto-selects, that's an existing pre-app-state limitation (view state has never tracked company scoping via URL) — out of scope for this plan.

- [ ] **Step 3: Manual verification — the full spec test plan**

1. Click through several views (AP → PO → AR → Dashboard); confirm Back/Forward move between them, URL bar reflects each.
2. Open Edit Bill on an existing bill, copy the URL, refresh the page — confirm it re-fetches and reopens the same bill's edit modal.
3. Open New Bill (not edit), press Back — confirm it closes without changing the view underneath.
4. Note a bill's `id` from Edit Bill's URL, then void/delete that bill, then load that same old URL directly — confirm the graceful-fallback toast and landing on the AP view (not a crash, not an infinite loop).
5. Log in as a non-admin role, confirm a hash URL for an admin-only view (e.g. `#/role-management`) still redirects to `dashboard` per the existing guard in `navigate()`.
6. Open a deep-linked modal (e.g. Edit PO), then trigger a marker-only confirm on top of it (e.g. a void/cancel confirmation), press Back once — confirm only the confirm dialog closes, Edit PO stays open. Press Back again — confirm Edit PO now closes, landing on the Purchase Orders view.
7. Test the Client 360 → Edit Contact Person deep link specifically (the composite `clientId:cpId` case) — confirm refresh restores both the correct client and the correct contact person's edit modal.

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat: refresh-restore deep-linked modals, graceful fallback for missing records"
```

---

## Task 6: Final review

- [ ] **Step 1: Read the full diff as one unit** (not per-task) — check for: any remaining `document.getElementById('modal-...').classList.add('show')` call that Task 3/4 missed (re-run the original `Grep` pattern from Task 3 Step 1 against the final state — it should return zero matches, since every open call site is now routed through `openModal()`); any place that still assumes `closeModal()` synchronously hides the modal in the same tick (the new `closeModal()` for tracked modals now goes through an async `history.back()` → `popstate` round trip — check whether any caller reads the modal's hidden state immediately after calling `closeModal()`, which would now be reading stale state).
- [ ] **Step 2: Confirm `docs/superpowers/specs/2026-08-14-browser-history-sync-design.md` and this plan's Reference section note the six reclassified modals** (already done in this plan's header — no action needed unless the spec file itself should be updated to match; if so, edit the spec's classification table for `modal-journal`, `modal-credit-note`, `modal-delivery-note`, `modal-bank-txn`, `modal-sales-leads`, `modal-contact` to marker-only and commit that separately).
- [ ] **Step 3: Update `handoff.md`** with a new session entry summarizing what shipped, matching this repo's existing handoff convention (see any recent session entry for the format/tone).
- [ ] **Step 4: Run `superpowers:finishing-a-development-branch`** to decide push/PR/merge, per this repo's existing workflow (every other feature in this codebase went through this).
