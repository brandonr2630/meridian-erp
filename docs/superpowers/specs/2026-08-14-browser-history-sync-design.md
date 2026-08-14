# Browser History Sync — Design Spec

**Date:** 2026-08-14
**App:** Meridian ERP (`index.html`)
**Status:** Draft, pending user review

## Problem

`navigate(view)` is pure DOM toggling — it swaps `.active` classes and calls `loadViewData(view)`, with zero History API involvement. The browser's Back, Forward, and Refresh buttons are completely disconnected from in-app navigation:

- **Back/Forward** do nothing — the URL never changes, so there's nothing for the browser to step through.
- **Refresh** reloads the whole app and always lands on the workspace/company-picker screen, discarding whatever view or modal the user was on.

Modals are opened via ~40 scattered `document.getElementById('modal-X').classList.add('show')` call sites (no central open function — `openModal()` is referenced in one place but was never defined, which was itself a live bug fixed this session). Closing is already centralized through a single `closeModal(id)` function used everywhere.

## Goal

Sync in-app navigation with the browser's native Back, Forward, and Refresh:

- Views get real, bookmarkable URLs. Back/Forward move between them natively.
- Opening a modal is a "back step" too — pressing Back while a modal is open closes the modal first, before it affects the view underneath.
- A defined set of "primary record" modals (Bill, Invoice, PO, etc.) are deep-linkable: their URL encodes the record's ID, so Refresh re-fetches the record and reopens the modal exactly where the user was.
- Everything else (create-new forms, confirmations, payment/void actions, PDF previews) gets simple Back-to-close behavior only — no ID in the URL, not restored on Refresh.

## URL scheme

- Views: `#/<view>` — e.g. `#/dashboard`, `#/ap`, `#/purchase-orders`. Matches the existing `view` identifiers used throughout `navigate()`/`VIEW_SECTIONS`/`loadViewData()`.
- `client-360` already carries `currentClient360Id` as separate state — becomes `#/client-360/<id>`.
- Deep-linked record modals: `#/<view>/<record-type>/<id>` — e.g. `#/ap/bill/<uuid>`, `#/purchase-orders/po/<uuid>`, `#/ar/invoice/<uuid>`.
- Everything else (create-new modals, confirmations, action modals, PDF previews): **no URL segment.** They use an invisible `history.pushState` marker — same visible URL, a hidden `state` object — purely so Back closes them before touching the view.

No `#/.../new` segment for create flows. A create-new modal that's interrupted by Refresh is simply gone, same as today.

## Navigation core

`navigate(view, opts = {})` — `opts.push` defaults to `true`.

- Keeps all existing behavior (permission guards, `.active` class toggling, `VIEW_SECTIONS` auto-expand, `loadViewData(view)`).
- When `opts.push` is true: `history.pushState({view}, '', '#/' + view)`.
- All ~50 existing call sites (`onclick="navigate('ap')"`, etc.) are unchanged — they get `push:true` by default, no edits needed there.

New `window.onpopstate` handler:

- Reads `event.state`.
- State names a view only → `navigate(state.view, { push: false })`.
- State names a deep-linked modal (`{view, modal, recordType, recordId}`) → ensure the view is active, then re-fetch `recordType`/`recordId` and open that modal via its existing "open for edit" entry point (reusing `openEditPO`, `openEditBill`, `openEditUserModal`, etc. where they already exist; new thin wrappers where they don't).
- State names a marker-only modal (`{view, modal}`, no `recordType`) → just hide that modal (DOM-only — see Modal lifecycle below for why this must not re-trigger `history.back()`).
- No state (user paged back past the app's own history into whatever was before) → fall back to `dashboard`.

**Boot-time restore:** after session restore and company load, parse `location.hash` once:

- `#/<view>` → `navigate(view, { push: false })`.
- `#/<view>/<type>/<id>` → navigate to view, then attempt the same re-fetch-and-open path used by `popstate`.
- Unrecognized/malformed hash → fall back to `dashboard` (today's existing default), and `history.replaceState` to clean the URL.

## Modal lifecycle

This is the structurally biggest part of the change — not conceptually hard, but wide (touches ~40 call sites).

**`openModal(id, opts)`** — implemented for real for the first time (it was called once in the codebase but never defined; that ReferenceError was fixed earlier this session by removing the call rather than adding the function — this spec supersedes that fix by giving it a real implementation).

- `opts` optionally carries `{ recordType, recordId }` for deep-linked modals.
- Adds `.show` to the modal (same visible effect as every existing open call site today).
- If `opts.recordType`/`recordId` given: `history.pushState({ view: currentView, modal: id, recordType: opts.recordType, recordId: opts.recordId }, '', '#/' + currentView + '/' + opts.recordType + '/' + opts.recordId)`.
- Otherwise: `history.pushState({ view: currentView, modal: id }, '', location.href)` — same URL, invisible marker, exists purely so a subsequent Back has something to pop.

All ~40 existing `document.getElementById('modal-X').classList.add('show')` sites get mechanically replaced with `openModal('modal-X')` (marker-only) or `openModal('modal-X', { recordType: '...', recordId: id })` (deep-linked, per the classification table below).

**`closeModal(id)`** — one addition to the existing function used everywhere:

- If `history.state?.modal === id`: call `history.back()` instead of directly removing `.show`. This pops the entry `openModal` pushed for it, keeping the history stack clean no matter *how* the modal closes — X button, Cancel, outside-click overlay click, or a successful Save that calls `closeModal` itself.
- The resulting `popstate` event is what actually removes `.show` (via the DOM-only path in the `popstate` handler above) — `closeModal` itself no longer touches `.show` directly once this ships, to avoid double-handling.
- If `history.state?.modal !== id` (e.g. `closeModal` called on a modal that was never opened through `openModal`, or history has already moved on) — falls back to just removing `.show` directly, no history interaction. Keeps `closeModal` safe to call defensively, as a few call sites do today.

**Guarding the double-close:** because `closeModal` → `history.back()` → `popstate` → DOM-hide is a round trip, the `popstate` handler must not call `closeModal` again (which would re-trigger `history.back()` and desync the stack). It calls the DOM-hide step directly instead.

## Modal classification

Rule: modals that **edit or view an existing record with a stable ID** are deep-linked. Everything else — create-new forms, confirmations, payment/void/status-change actions, PDF previews, pickers — is marker-only.

PDF preview modals (`modal-po-pdf`, `modal-pdf-preview`, `modal-cn-pdf`, `modal-dn-pdf`, `modal-quo-pdf`, `modal-receipt-pdf`) technically *view* an existing record, but they're a derived/secondary view, not the primary edit surface for that record — classified marker-only. Flagged here as the one genuinely debatable call; move to deep-linked in review if that's wrong.

| Modal ID | Deep-linked? | URL (if deep-linked) | Notes |
|---|---|---|---|
| `modal-bill` | Yes (edit only) | `#/ap/bill/<id>` | New Bill (no id) is marker-only |
| `modal-invoice` | Yes (edit only) | `#/ar/invoice/<id>` | New Invoice is marker-only |
| `modal-quotation` | Yes (edit only) | `#/quotations/quote/<id>` | New Quotation is marker-only |
| `modal-po` | Yes (edit only) | `#/purchase-orders/po/<id>` | New PO is marker-only; `openEditPO` already exists |
| `modal-credit-note` | Yes (edit only) | `#/credit-notes/cn/<id>` | New CN is marker-only |
| `modal-delivery-note` | Yes (edit only) | `#/delivery-notes/dn/<id>` | New DN is marker-only |
| `modal-client` | Yes (edit only) | `#/clients/client/<id>` | Add Client is marker-only |
| `modal-vendor` | Yes (edit only) | `#/vendors/vendor/<id>` | Add Vendor is marker-only |
| `modal-account` | Yes (edit only) | `#/coa/account/<id>` | Add Account is marker-only |
| `modal-journal` | Yes (edit only) | `#/journal/entry/<id>` | New Entry is marker-only |
| `modal-bank-account` | Yes (edit only) | `#/bank/account/<id>` | Add Bank Account is marker-only |
| `modal-bank-txn` | Yes, if editing an existing txn is supported | `#/bank/txn/<id>` | Confirm in plan phase whether this modal ever opens in an "edit existing" mode |
| `modal-erp-company` | Yes | `#/erp-companies/company/<id>` | Always edits an existing company |
| `modal-role-edit` | Yes | `#/role-management/role/<id>` | |
| `modal-edit-user` | Yes | `#/user-management/user/<id>` | `openEditUserModal` already exists |
| `modal-user-overrides` | Yes | `#/user-management/user/<id>/overrides` | |
| `modal-opportunity` | Yes (edit only) | `#/pipeline/opp/<id>` | New Opportunity is marker-only |
| `modal-crm-task` | Yes (edit only) | `#/pipeline/task/<id>` | New Task is marker-only |
| `modal-crm-activity` | Yes (edit only) | `#/pipeline/activity/<id>` | Log Activity (new) is marker-only |
| `modal-crm-team-member` | Yes (edit only) | `#/pipeline/team-member/<id>` | Low-traffic; candidate to demote to marker-only if scope needs trimming |
| `modal-cp-form` | Yes (edit only) | `#/client-360/<clientId>/contact-person/<id>` | Nested under Client 360 |
| `modal-sales-leads` | Yes (edit only) | `#/sales-leads/lead/<id>` | New lead is marker-only |
| `modal-create-user` | No | — | No id until saved |
| `modal-edit-permissions` | No | — | Confirm exact scope (role vs user) in plan phase |
| `modal-dn-status` | No | — | Status-change action |
| `modal-dn-pdf` | No | — | Preview, see note above |
| `modal-cn-pdf` | No | — | Preview |
| `modal-report-preview` | No | — | Preview |
| `modal-confirm` | No | — | Generic confirm dialog |
| `modal-bill-payment` | No | — | Payment-recording action |
| `modal-bill-pay-history` | No | — | History popup |
| `modal-void-reason` | No | — | Action |
| `modal-payment` | No | — | AR receive-payment action |
| `modal-post-review` | No | — | Action |
| `modal-fy` | No | — | Low-traffic admin action |
| `modal-contact` | No | — | Confirm exact usage in plan phase |
| `modal-pdf-preview` | No | — | Invoice PDF preview |
| `modal-po-pdf` | No | — | PO PDF preview |
| `modal-quo-pdf` | No | — | Quote PDF preview |
| `modal-quo-status` | No | — | Status-change action |
| `modal-quo-template-picker` | No | — | Picker |
| `modal-receipt-pdf` | No | — | Preview |
| `modal-payment-confirmed` | No | — | Confirmation |
| `modal-invoice-receipts` | No | — | History/list popup |
| `modal-contact-persons` | No | — | List popup (the individual `modal-cp-form` edit is deep-linked; this list wrapper isn't) |
| `modal-send-email` | No | — | Action |

## Error handling

- **Deep-link record not found / deleted / RLS-denied on refresh:** toast (`"That record no longer exists or you don't have access."`), fall back to the underlying view, `history.replaceState` to drop the modal segment from the URL so a repeat refresh doesn't repeat the failed fetch.
- **Malformed or unrecognized hash:** fall back to `dashboard`, matching today's default landing view.
- **Permission-guarded view reached via hash** (e.g. a non-admin's saved bookmark to a finance view): the existing `navigate()` module/permission guard already redirects to `dashboard` — unchanged, just now also reachable via a typed/bookmarked URL rather than only a nav click.

## Testing / verification

No automated test suite exists for this app (matches project convention — manual click-through is standard here). Verification plan:

1. Click through several views (AP → PO → AR → Dashboard); confirm browser Back/Forward move between them correctly, URL bar reflects each view.
2. Open a deep-linked modal (Edit Bill), refresh the page, confirm it re-fetches and reopens with the correct data.
3. Open a non-deep-linked modal (New Bill), press Back, confirm it closes without changing the underlying view.
4. Delete a record, then load its old deep-link URL directly; confirm the graceful-fallback toast and landing on the view (not a crash).
5. Regression-check the module/permission guards in `navigate()` still redirect correctly when a restricted view is reached via a hash URL rather than a nav click.
6. Test as a non-admin role to confirm nothing in the guard logic changed.
7. Spot-check nested Back sequences: open a deep-linked modal, then a marker-only confirmation on top of it (e.g. Edit Bill → Void confirm) — Back should close the confirm first, then the Edit Bill modal, then step to the previous view.

## Open questions for plan phase

- Confirm `modal-bank-txn` actually supports editing an existing transaction (vs. entry-only); demote to marker-only if not.
- Confirm `modal-edit-permissions` and `modal-contact`'s exact scope/usage before assigning a URL shape.
- `modal-crm-team-member` is flagged as a candidate to demote to marker-only if the full 20-modal deep-link surface proves too large for one implementation pass — can be split into a follow-up phase.
