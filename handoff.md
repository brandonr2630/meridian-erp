# Meridian ERP — Handoff

*Last updated: 2026-06-10 · Session 14*

---

## Quick Reference

| Item | Value |
|------|-------|
| Live URL | `https://erp.terranresources.com` |
| GitHub repo | `brandonr2630/meridian-erp` |
| Deploy | Push to `master` via PR → GitHub Actions → GreenGeeks cPanel auto-deploys |
| Deploy workflow | `.github/workflows/deploy.yml` → cPanel Fileman API (`chi203.greengeeks.net`) |

---

## Session 14 — Collapsible sidebar nav & item reorder

**Date:** 2026-06-10
**Branches:** `feat/collapsible-sidebar-nav` → [PR #38](https://github.com/brandonr2630/meridian-erp/pull/38) · `chore/nav-reorder` → [PR #39](https://github.com/brandonr2630/meridian-erp/pull/39)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Collapsible nav sections | Finance, Sales & Marketing, Setup collapse/expand with `+`/`−` toggle | Collapsed state persisted to `localStorage` under key `erp_nav_state`; `restoreNavState()` called on init |
| Finance > Reports sub-group | Aged Receivables, Aged Payables, P&L, Balance Sheet, Trial Balance moved from top-level Reports section into a nested sub-group under Finance | Top-level Reports section dissolved; sub-group independently collapsible; `applyRoleNav()` hides the sub-header when all children are role-hidden |
| Auto-expand on navigate | `navigate()` calls `expandSection()` for each parent in `VIEW_SECTIONS[view]` | Clicking a collapsed section's item expands it before activating |
| Finance item order | AR → Credit Notes → AP → Bank & Cash → Journal Entries → Chart of Accounts | Transactional-first order consistent with Xero/QB/Sage |
| Sales item order | Sales Leads → Quotations → Delivery Notes | Workflow/funnel order; "Sales Lead Reports" renamed to "Sales Leads" |
| Handoff cleanup | Removed orphaned `## Sessions` header, stale Code Review Backlog section, duplicate References section; moved deploy path into Quick Reference | Structural issues from prior sessions |

### Outstanding

- CRM module — see **Next Up** below

---

## Session 13 — P&L bug fix & handoff cleanup

**Date:** 2026-06-10
**Branch:** `fix/pl-report-null-uuid-and-handoff` → [PR #36](https://github.com/brandonr2630/meridian-erp/pull/36)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| P&L null UUID error | `runPL()` now fetches `jeIds` once upfront and returns early with "No posted journal entries found for this period." when null | `getPostedJEIds` returns `null` when no posted JEs exist in the range; interpolating that into `journal_id=in.(null)` caused Postgres to throw `invalid input syntax for type uuid: "null"` — matching guard already existed in `runBS()` |
| Handoff header | Corrected `Session 11` → `Session 12`, date → 2026-06-10 | Stale from prior session |
| Handoff Next Up | Inlined full CRM architecture design — replaced "See memory for details" | Handoff must be self-contained without relying on session memory |

### Outstanding

- CRM module — see **Next Up** below

---

## Session 12 — Multi-company fixes & RLS hardening

**Date:** 2026-06-09
**Branches:** `fix/ar-receipts-overdue-status` → [PR #31](https://github.com/brandonr2630/meridian-erp/pull/31) · `fix/ar-payment-bank-account-filter` → [PR #32](https://github.com/brandonr2630/meridian-erp/pull/32) · `fix/bank-account-save-null-account-id` → [PR #33](https://github.com/brandonr2630/meridian-erp/pull/33) · `fix/bank-account-gl-optional` → [PR #34](https://github.com/brandonr2630/meridian-erp/pull/34) · `fix/bank-account-gl-soft-validation` → [PR #35](https://github.com/brandonr2630/meridian-erp/pull/35)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Receipts button on overdue invoices | Added `'overdue'` to status check in `renderARTable` line 7426 | Invoices marked overdue by pg_cron after a partial payment had lost their Receipts button |
| AR payment modal bank account filter | `openReceivePayment` now shows all accounts: matching currency first, others in an "Other currencies" optgroup | Terran Resources invoices showed "No matching bank accounts" due to currency mismatch |
| Bank account save NULL constraint | `saveBankAccount()` now sends `account_id: null` (was missing key); `account_id` column made nullable via migration | `null value in column "account_id"` error when no GL account selected |
| GL account soft-require | GL account required when asset accounts exist; optional (with hint) when CoA not set up; amber "No GL" badge on unlinked accounts in Settings table | Best-practice guard: ensures journal entries are always created for properly configured accounts |
| Chart of Accounts seeded | 47 standard accounts (1000–5300) created for TRL (TTD) and TRLLC (USD) via Supabase migration, mirroring QQL structure | Terran entities had no CoA — GL dropdowns were empty |
| Full RLS hardening | All 28 tables: 45 open `qual: true` policies replaced with 31 scoped policies; `my_company_ids()` and `is_super_admin()` SECURITY DEFINER helpers added | Supabase advisor flagged 3 tables with RLS disabled and others with open policies |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 11 — Backlog Items 7 & 13–17

**Date:** 2026-06-09
**Branch:** `fix/backlog-7-13-14-15-16-17` → [PR #30](https://github.com/brandonr2630/meridian-erp/pull/30)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| 7 | Accessibility | `aria-label` added to all icon-only buttons: 3 topbar (🔔 🌙 ⚙️) + 14 table action buttons (Edit, Delete, Preview, Print, Remove line) |
| 13 | Modal widths | `.modal` → `min(560px,95vw)`, `.modal-lg` → `min(800px,95vw)`, `.modal-xl` → `min(820px,95vw)`; 4 inline `max-width` overrides updated to use `min()`; redundant tablet media query rule removed |
| 14 | Contact search factory | `createContactSearch({ inputId, resultsId, typeFilter, showOnEmpty, queryFn, subtitleFn, onSelect })` replaces 4 separate search functions (`searchBillVendor`, `searchInvContact`, `searchQuoContact`, `searchDNContact`) — ~80 lines removed |
| 15 | Supabase filter constants | `Q` object with 6 query builders (`contacts`, `bankAccounts`, `salesLeads`, `clients`, `vendors`, `companies`) replaces hardcoded filter strings at ~20 call sites |
| 16 | In-view loading state | All 5 load functions (`loadAR`, `loadAP`, `loadClients`, `loadVendors`, `loadQuotations`) now dim the existing table (opacity 0.5, pointer-events none) when refreshing in-view; show spinner only on first load. `try/finally` ensures cleanup |
| 17 | Logo MIME validation | `previewCompanyLogo` now rejects non-image files (`image/jpeg`, `image/png`, `image/webp`) before the size check |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 10 — Backlog Items 8–12

**Date:** 2026-06-09
**Branch:** `fix/backlog-8-9-10-11-12` → [PR #29](https://github.com/brandonr2630/meridian-erp/pull/29)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| 8 | Date comparisons | `.slice(0,10)` on `due_date` / `valid_until` in `loadDashboard` — handles ISO timestamp suffixes, prevents overdue/due-soon miscounts |
| 9 | Null FK guards | `|| {}` added to `contacts.find()` in bill payment and history flows for consistency with PDF function pattern |
| 10 | Promise.all fetches | `contacts` + `bankAccounts` now fetched in parallel in `initApp()` and `switchCompany()` — saves one sequential round-trip per load/switch |
| 11 | Lazy logos | `loading="lazy"` on company logo `<img>` in the switcher dropdown and ERP companies table |
| 12 | PDF page size | New **Page Size** field (Letter / A4) in company modal, saved to `companies.pdf_page_size`. `coPageSize()` and `coPageDims()` helpers drive `@page` CSS and page container dimensions in all three PDF renderers |

### Outstanding

- Item 7 (High): `aria-label` on icon-only buttons
- Items 13–17 (Medium): modal widths, contact search factory, Supabase filter constants, loading states, logo MIME validation

---

## Session 9 — Z-index CSS Constants

**Date:** 2026-06-09
**Branch:** `fix/z-index-constants` → [PR #28](https://github.com/brandonr2630/meridian-erp/pull/28)

### What Changed

| Change | Detail |
|--------|--------|
| `--z-topbar: 100` | `.topbar` |
| `--z-dropdown: 200` | `.company-dropdown`, `.split-btn-menu`, `#report-dl-menu`, `.global-search-results`, `.contact-search-results` (corrected from 9999) |
| `--z-sidebar-overlay: 290` | `.sidebar-overlay` (mobile backdrop) |
| `--z-sidebar: 300` | `.sidebar` (mobile panel, media query) |
| `--z-modal: 600` | `.modal-overlay` |
| `--z-toast: 700` | `.toast` |
| `--z-login: 800` | `.login-overlay` |

All 11 hardcoded `z-index` values replaced. `.contact-search-results` was incorrectly set to `9999` (above modals); corrected to `var(--z-dropdown)`.

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 8 — Table Pagination

**Date:** 2026-06-08
**Branch:** `feat/table-pagination` → [PR #27](https://github.com/brandonr2630/meridian-erp/pull/27)

### What Changed

| Change | Detail |
|--------|--------|
| `PAGE_SIZE = 50` constant | Shared page size used across all paginated tables |
| `renderPager()` helper | Returns a `.table-pager` bar with "Showing X–Y of Z" and ← Prev / Next → buttons; returns empty string if data fits on one page |
| `.table-pager` CSS | Flex bar below each table; `border-top: 1px solid var(--border)` |
| AR Invoices pagination | `renderARTable` slices by `arPage`; `filterAR` resets page; `setArPage(n)` for nav |
| AP Bills pagination | `renderAPTable` extracted from inline `loadAP`; `filterAP` implemented (was empty stub — now searches bill no. / supplier, filters by status); `setApPage(n)` |
| Quotations pagination | `renderQuotationsTable` slices by `quoPage`; `filterQuotations` resets page; `setQuoPage(n)` |
| Clients pagination | `renderClientsTable` slices by `clientsPage`; `filterClients` resets page; `setClientsPage(n)` |
| Vendors pagination | `renderVendorsTable` slices by `vendorsPage`; `filterVendors` resets page; `setVendorsPage(n)` |

Summary stat cards and all global `.find()` lookups are unaffected — full datasets are still fetched.

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 7 — Receipt History Modal Layout

**Date:** 2026-06-08
**Branch:** `fix/receipt-history-modal-layout`

### What Changed

| Change | Detail |
|--------|--------|
| Modal wider | `max-width` increased from `700px` to `min(880px, 95vw)` — all 8 columns now fit without horizontal scrolling |
| Body padding removed horizontally | `modal-body` padding set to `16px 0` (top/bottom only) so table uses the full modal width |
| Compact cell padding | `.data-table-compact` class added: `9px 10px` padding vs the default `11px 16px`; applied to the receipts table only |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 6 — Receipt History Modal Fix

**Date:** 2026-06-08
**Branch:** `fix/receipt-history-modal-close`

### What Changed

| Change | Detail |
|--------|--------|
| Receipt history modal auto-close | 🖨 Print button in `modal-invoice-receipts` now calls `closeModal('modal-invoice-receipts')` before `openReceiptPDF()` — previously the history modal remained open and obscured the receipt preview |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 5 — AR Void + PDF Escaping

**Date:** 2026-06-08
**Branch:** `fix/ar-void-pdf-escaping`

### What Changed

| Change | Detail |
|--------|--------|
| AR receipt void | `voidARReceipt(receiptId, invoiceId)` — prompts for reason, reverses JE (Dr AR / Cr Bank), marks `payment_receipts.status = 'voided'`, restores invoice `balance_due` and recalculates status (`posted`/`partial`/`paid`), reverses bank account balance |
| Void button in receipt history | "Receipts" modal action column now shows a Void button (admin-only via `canVoid()`) alongside the print button for non-voided receipts |
| PDF metaRows HTML escaping | `escHTML()` applied to 12 user-entered fields across 6 PDF functions: `inv.client_ref`, `quo.client_ref`, `lead.name`, 6× DN fields (`client_ref`, `carrier`, `driver`, `vehicle_ref`, `recipient_name`, `delAddr`), `cn.reason`, `receipt.reference`, `incotermsPlace`, `notesText` |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 4 — Receipt PDF

**Date:** 2026-06-08
**Branch:** `feature/receipt-pdf`

### What Changed

Added a full receipt issuance system for AR client payments — PDF generation, post-payment confirmation modal, and receipt reprint history.

| Change | Detail |
|--------|--------|
| Supabase migration | Added `contact_id` (FK → contacts) and `status` (`posted`/`voided`) to `payment_receipts`; backfilled `contact_id` from invoices |
| Post-payment confirmation modal | `modal-payment-confirmed` — shows receipt no., invoice ref, amount, method, remaining balance with "Print Receipt" button |
| Receipt PDF | `openReceiptPDF(id)` + `buildReceiptPDFHTML()` — single-page receipt with company header, invoice table (No./Date/Total/This Payment/Balance After), amount in words, remarks, dual signature line |
| Amount in words | `amountToWords(amount, currency)` — handles TTD, USD, GYD |
| Receipt history | "Receipts" button on partial/paid AR invoice rows → `openInvoiceReceiptHistory()` → list of all receipts with per-row reprint button |
| Print CSS | `modal-receipt-pdf` added to all `@media print` rules |

### Outstanding

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built

---

## Session 3 — GitHub Infrastructure

**Date:** 2026-05-16
**Commit:** `f6ca401`

### What Changed

Switched to the centralised reusable deploy workflow. All deploy logic now lives in `brandonr2630/projects`.

| Change | Detail |
|--------|--------|
| Reusable deploy workflow | `deploy.yml` reduced from 130 lines to 14 — calls `brandonr2630/projects/.github/workflows/deploy.yml@master` |
| Auto-merge enabled | PRs merge as soon as opened (no required status checks) |
| GitHub Projects board | [github.com/users/brandonr2630/projects/1](https://github.com/users/brandonr2630/projects/1) — all 5 repos linked |

### Outstanding

- No known outstanding items

---

## Session 2 — Infrastructure Overhaul

**Date:** 2026-05-16
**Commits:** `7334849`, `3a23b33`, `7cc0edb`, `f227ba2`

### What Changed

Brought the deploy pipeline up to the same standard as q2m-website. Fixed binary file corruption, added manual redeploy trigger, moved credentials to secrets, cleaned up dead files.

### Changes Made

| Change | Commit |
|--------|--------|
| Deploy workflow: hybrid binary upload, directory creation, `workflow_dispatch` | `7334849` |
| Removed dead `.cpanel.yml` | `3a23b33` |
| Moved `HOST` and `CPANEL_USER` from hardcoded to GitHub Secrets | `7cc0edb` |
| README: corrected live URL and deploy section | `f227ba2` |
| Branch protection ruleset on `master` (requires PR) | — |

### Deploy Workflow Behaviour

| Trigger | Files uploaded |
|---------|---------------|
| Push to `master` (via PR) | Only files changed in the push |
| Manual `workflow_dispatch` | All tracked files (`git ls-files`) |

Binary files (images, fonts) go through `Fileman/upload_files` (multipart). Text files go through `Fileman/save_file_content`.

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `CPANEL_API_TOKEN` | cPanel API token (rotate in cPanel → Security → Manage API Tokens) |
| `CPANEL_HOST` | `https://chi203.greengeeks.net:2083` |
| `CPANEL_USER` | `terranre` |

### Outstanding

- No known outstanding items for this repo

---

## Session 1 — Deploy Pipeline Fix

**Date:** 2026-05-09
**Commit:** `c5ba3cf`

### What Changed

Replaced the original git-pull based deploy with direct Fileman API upload via GitHub Actions. The previous approach used cPanel Git Version Control which required server-side git access — unreliable on shared hosting.

### Fix Applied

Rewrote `.github/workflows/deploy.yml` to upload files directly via `Fileman/save_file_content` on push to `master`. Incremental deploy only (files changed in the push).

**Note:** This initial version used `save_file_content` for all files (text-only). Binary file support was added in Session 2.

---

## Architecture Reference

### Application

The entire app is `index.html` — approximately 8,400 lines of inline CSS and JavaScript. **Never edit `index2–5.html`; those are archives.**

### Backend

- **Supabase** — primary data store, called directly via a thin fetch wrapper
- All DB access goes through `sb()` → `sbGet / sbPost / sbPatch / sbPatchWhere / sbDelete / sbDeleteWhere`
- **Auth:** Supabase JWT. Session (access token + refresh token) persisted to `localStorage`, restored on load by `tryRestoreSession()`
- **Multi-company:** every record scoped to `currentCompany.id`. Company switcher in topbar; `switchCompany(id)` reloads view data

### Navigation & State

- `navigate(view)` sets `currentView` and calls `loadViewData(view)`
- Global state declared at `// ── STATE ──` (~line 3373): `currentUser`, `currentCompany`, `companies`, `accounts`, `contacts`, `journalEntries`, `bankAccounts`, etc.

### Roles

`super_admin` > `admin` > `sales` > `user`

Finance modules (AP, Bank, CoA, Journal, Reports) are admin-only. Check `canPost()`, `canVoid()`, `canFinance()` before rendering controls.

### Modules

Dashboard · Chart of Accounts · Journal Entries · AR · AP · Vendor Payments · Clients · Vendors · ERP Companies · Settings · Bank Accounts · Bank Transactions & Reconciliation · Bills · Financial Reports · Quotations · Sales Leads

### Currencies

TTD (`TT$`) · USD (`US$`) · GYD (`G$`) — formatted via `fmt(amount, currency)`

### PDF & Exports

PDFs rendered client-side with a custom multi-page renderer. SheetJS lazy-loaded from CDN on first Excel export. Report download menu is a shared fixed component.

---

## Known Issues

No known issues.

## Next Up

### CRM module — designed, not yet built

Architecture designed 2026-05-23. Parked for consideration before building.

#### 3 new Supabase tables

| Table | Purpose |
|-------|---------|
| `crm_opportunities` | Pipeline deals — stages: prospect → qualified → proposal → negotiation → won → lost. `type` field: `standard` \| `development`. Linked to `contacts`; optional `quotation_id` once converted. |
| `crm_activities` | Timeline log (call / email / meeting / note). Hangs off an opportunity or a contact directly. |
| `crm_tasks` | Assignable follow-ups with due dates. Hangs off an opportunity or contact. |

#### 3 views under a new top-level "CRM" nav section

1. **Pipeline** — deal list/board with stage filter; opportunity detail panel with inline activities + tasks; "Convert to Quote" on won deals
2. **Activities** — company-wide feed, filterable by type / date / user
3. **Tasks** — to-do list, filterable by assignee / due date / completion

#### Integration

Won opportunity → Convert to Quotation → pre-fills contact, currency, value → writes `quotation_id` back to opportunity; stage locks to `won`.

#### Dev inquiry handling

`type: development` on an opportunity covers this — no separate table needed. The `description` field captures evolving scope; activities log discovery conversations. Reaches `proposal` stage before a quote is raised.

