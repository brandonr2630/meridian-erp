# Meridian ERP — Handoff

*Last updated: 2026-06-11 · Session 20*

---

## Quick Reference

| Item | Value |
|------|-------|
| Live URL | `https://erp.terranresources.com` |
| GitHub repo | `brandonr2630/meridian-erp` |
| Deploy | Push to `master` via PR → GitHub Actions → GreenGeeks cPanel auto-deploys |
| Deploy workflow | `.github/workflows/deploy.yml` → cPanel Fileman API (`chi203.greengeeks.net`) |

---

## Session 20 — Security hardening (XSS, CSV injection, Supabase)

**Date:** 2026-06-11
**Branch / PR:** [PR #58](https://github.com/brandonr2630/meridian-erp/pull/58) · 3 Supabase migrations (applied directly)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Stored XSS | ~70 interpolation sites wrapped in `escHTML` | User-entered fields (names, descriptions, references, addresses, logo URLs) were rendered raw into `innerHTML` across tables, dropdown builders, global search, dashboard activity feed, report views, and PDF/report HTML builders. `escHTML` itself now also escapes `'` |
| CSV exports | Formula-injection guard + `String(cell ?? '')` coercion | Report CSV and CoA CSV prefix `'` on cells starting `=` `+` `@` or non-numeric `-`; CoA export also gained quote doubling (was producing corrupt CSV); fixes crash on numeric cells and `0` exporting as empty |
| `filterJE` crash | Null guard on `entry_no` / `description` | Search threw when a JE had a null description |
| AR customer cell | Dropped raw `contact_id` fallback | Unknown contact now shows `—` instead of the raw UUID |
| Supabase: function `search_path` | `my_company_ids`, `is_super_admin`, `set_line_total` pinned to `search_path = public` | Advisor `function_search_path_mutable` |
| Supabase: anon EXECUTE revoked | RLS helper functions no longer callable by `anon`/`public`; `authenticated` keeps EXECUTE (required for policy evaluation) | Anon REST/RPC now gets explicit 401/42501 |
| Supabase: storage policies | Logo uploads now require authentication (INSERT policy was open to `anon`); broad SELECT policy dropped so the public bucket can no longer be listed | Public object URLs unaffected (verified 200 after change) |
| `.gitignore` | `node_modules/` added | Local tooling scratch from slide generation |

### Verification

All inline `<script>` blocks parse clean under Node; public logo URL serves (200); anonymous storage upload rejected (400); anonymous RPC rejected; security advisors re-run clean apart from intentional `authenticated` EXECUTE on RLS helpers.

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (cannot be set via SQL/MCP)
- Auth tokens live in `localStorage` (`erp_session`) — standard for a static-host Supabase app, but means any future XSS regression exposes the JWT; keep escaping discipline for new renderers
- No CSP meta tag — of limited value while all CSS/JS is inline (`unsafe-inline` would be required), revisit if the app is ever split into files

---

## Session 19 — Custom SVG nav icons

**Date:** 2026-06-10
**Branches / PRs:** [PR #55](https://github.com/brandonr2630/meridian-erp/pull/55) · [PR #56](https://github.com/brandonr2630/meridian-erp/pull/56)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `assets/` directory | New | Holds custom SVG icon files deployed alongside `index.html` |
| Accounts Receivable nav icon | `📤` → `assets/Acc Receivables Icon.svg` | Green dollar-sign split icon |
| Accounts Payable nav icon | `📥` → `assets/Acc Payables Icon.svg` | Red dollar-sign split icon |
| Cash Flow nav icon | `💸` → `assets/Cash Flow Icon.svg` | Yellow dollar-sign with + symbol |
| Credit Notes nav icon | `↩️` → `assets/Credit Note.svg` | Custom credit note icon |

Icons are rendered as `<img src="assets/..." style="width:18px;height:18px;vertical-align:middle;">` inside the existing `.nav-item-icon` spans.

### Outstanding

- No new outstanding items

---

## Session 18 — CRM Module & Sales nav amalgamation

**Date:** 2026-06-10
**Branch / PR:** [PR #53](https://github.com/brandonr2630/meridian-erp/pull/53)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Nav section renamed | "Sales & Marketing" → "Sales" | Amalgamates the old section with the new CRM sub-group |
| CRM sub-group | New collapsible "CRM" sub-group under Sales with Pipeline, Activities, Tasks | Mirrors the Finance > Reports sub-group pattern; auto-expands via `VIEW_SECTIONS` |
| `view-pipeline` | New page — stat cards (Open Deals, Open Value, Won This Month, Win Rate) + filterable Opportunities table | Filters: search, stage, type, owner; inline 📅 / ✅ buttons to log activity or add task from a deal row |
| `view-crm-activities` | New page — Activity Log table | Filters: search, type (call/email/meeting/note), date range; type badges use new CSS classes |
| `view-crm-tasks` | New page — Tasks table with stat cards (Overdue, Due Today, Due This Week, Completed) | Inline ✓ button marks task complete without opening modal; overdue dates highlighted red |
| 3 new Supabase tables | `crm_opportunities`, `crm_activities`, `crm_tasks` | RLS via `rls_crm_*` ALL policies using existing `my_company_ids()` / `is_super_admin()` helpers; cascade delete on activities and tasks when an opportunity is deleted |
| Badge CSS | 14 new badge classes: prospect, qualified, proposal, negotiation, won, lost, standard, development, call, email, meeting, note | Added after existing badge rules |
| `Q` object | `crmOpps`, `crmActivities`, `crmTasks` query builders added | Company-scoped, ordered by `created_at.desc` / `activity_date.desc` / `due_date.asc` |
| `NO_UPDATED_AT` | `crm_activities` and `crm_tasks` added | Neither table has an `updated_at` column |
| `applyRoleNav` `salesVisible` | `nav-pipeline`, `nav-crm-activities`, `nav-crm-tasks` added | Sales role can access all CRM views |

### Schema

**`crm_opportunities`:** id · company_id · contact_id · name · stage (prospect→won/lost) · type (standard/development) · value · currency · expected_close · description · quotation_id · owner_id (erp_users) · created_at · updated_at

**`crm_activities`:** id · company_id · opportunity_id · contact_id · type · subject · notes · activity_date · user_id (erp_users) · created_at

**`crm_tasks`:** id · company_id · opportunity_id · contact_id · title · description · due_date · assignee_id (erp_users) · completed · completed_at · created_at

### Outstanding

- "Convert to Quote" on a won opportunity (write `quotation_id` back to opportunity, pre-fill quote form)
- CRM pipeline KPI widget on the Dashboard (deals by stage, conversion rate)

---

## Session 17 — Cash Flow Statement

**Date:** 2026-06-10
**Branch / PR:** [PR #49](https://github.com/brandonr2630/meridian-erp/pull/49)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Cash Flow Statement view | New `view-cf` page with From/To date pickers, Preview, Download ▾, and Run Report | Matches the exact structure of P&L / BS / TB views |
| Nav item | "💸 Cash Flow" added under Finance → Reports sub-menu after Trial Balance | Wired to `navigate('cf')` |
| `VIEW_SECTIONS` | `cf: ['finance', 'finance-reports']` added | Auto-expands the Finance and Reports sections on navigation |
| `loadViewData` | `case 'cf': initReportDates()` | Populates default date range on first visit |
| `initReportDates` | `cf-date-from` / `cf-date-to` added to the date-init arrays | Defaults to current calendar year |
| `downloadReportAs` titleMap | `cf: 'Cash Flow Statement'` | Enables PDF, HTML, CSV, and Excel export |
| `getBSBalances(coId, date)` | New helper — returns a `{ account_id: debit-credit balance }` map for all posted JEs up to `date` | Shared by both opening and closing balance snapshots |
| `runCF()` | Indirect method: Net Income → Depreciation add-back → Working Capital changes → Investing (fixed assets) → Financing (long-term debt + equity movements) → Net Change in Cash → Reconciliation against actual bank/cash balances | WC lines filtered to non-zero only; reconciliation banner green (✓) or amber (⚠ with gap amount) |

### Logic notes

- **Sign convention:** `chg(open, close) = -(close - open)` works for both asset and liability accounts using raw debit-credit balances — asset decrease and liability increase both yield positive cash flow.
- **Cash accounts:** identified as `account_type='asset'` AND (`account_subtype='cash'` OR `is_bank=true`).
- **Depreciation:** detected by account name regex `/depreciation|amortiz/i` within expense accounts; added back in the operating section.
- **Reconciliation gap:** if `calcNet ≠ actualNet`, an amber banner shows the gap and prompts the user to check account sub-type assignments or unposted entries.

### Outstanding

- CRM module — designed, not yet built at the time (built in Session 18)

---

## Session 16 — Typography preferences

**Date:** 2026-06-10
**Branches / PRs:** [PR #46](https://github.com/brandonr2630/meridian-erp/pull/46) · [PR #47](https://github.com/brandonr2630/meridian-erp/pull/47)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Typography section in Settings | Three range sliders — UI Text (12–18 px), Headings (16–28 px), Table Numbers (11–17 px) — let each user adjust font sizes independently | Prefs stored in `localStorage` under `erp_font_prefs`; applied via CSS custom properties `--fs-ui`, `--fs-heading`, `--fs-mono`; Reset to defaults button; sliders sync when Settings view opens |
| Early font apply | Font prefs applied in an IIFE before first paint, same pattern as the existing theme toggle | Prevents flash of default sizes on reload |
| CSS vars wired to key rules | `body`, `.btn`, `.page-title`, `.modal-title`, `.data-table td`, `.data-table td.mono`, `.field input/select/textarea`, `.filter-select` all consume the new vars | PR #47 extended coverage after UI Text slider appeared unresponsive — most elements had explicit `13px` overrides blocking body inheritance |

### Outstanding

- CRM module — designed, not yet built at the time (built in Session 18)

---

## Session 15 — AR / AP table sorting & date range filter

**Date:** 2026-06-10
**Branches / PRs:** [PR #41](https://github.com/brandonr2630/meridian-erp/pull/41) · [PR #42](https://github.com/brandonr2630/meridian-erp/pull/42) · [PR #43](https://github.com/brandonr2630/meridian-erp/pull/43) · [PR #44](https://github.com/brandonr2630/meridian-erp/pull/44)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| AR sortable columns | Invoice No., Customer, Date, Due Date headers are clickable asc/desc sort toggles | `arSortCol` / `arSortDir` state vars; `sortAR(col)` toggles direction; sort applied to filtered list before page slice |
| AP sortable columns | Bill No., Supplier, Date, Due Date headers are clickable asc/desc sort toggles | `apSortCol` / `apSortDir` state vars; `sortAP(col)` toggles direction; same pattern as AR |
| AP Invoice No. column | Vendor's own invoice reference (`vendor_ref`) shown between Bill No. and Supplier | Field already captured in the bill form; was not displayed in the table |
| AR / AP date range filter | From / To date pickers added to both table toolbars | `ar-date-from`, `ar-date-to` filter by `invoice_date`; `ap-date-from`, `ap-date-to` filter by `bill_date`; either bound optional; works alongside search and status filters |

### Outstanding

- CRM module — designed, not yet built at the time (built in Session 18)

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

- CRM module — designed, not yet built at the time (built in Session 18)

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

- CRM module — designed, not yet built at the time (built in Session 18)

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

The entire app is `index.html` — approximately 10,200 lines of inline CSS and JavaScript. **Never edit `index2–5.html`; those are archives.**

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

Dashboard · Chart of Accounts · Journal Entries · AR · AP · Vendor Payments · Clients · Vendors · ERP Companies · Settings · Bank Accounts · Bank Transactions & Reconciliation · Bills · Financial Reports (P&L · Balance Sheet · Trial Balance · Cash Flow · Aged AR/AP) · Quotations · Delivery Notes · Credit Notes · Sales Leads · CRM (Pipeline · Activities · Tasks)

### Currencies

TTD (`TT$`) · USD (`US$`) · GYD (`G$`) — formatted via `fmt(amount, currency)`

### PDF & Exports

PDFs rendered client-side with a custom multi-page renderer. SheetJS lazy-loaded from CDN on first Excel export. Report download menu is a shared fixed component.

---

## Known Issues

No known issues.

## Backlog

Items are grouped by theme and ordered by suggested priority within each group. Tick them off as sessions complete them.

### Sales & CRM

- [x] **CRM module** — Pipeline, Activities, Tasks views under the Sales nav; `type: development` for dev inquiry handling. Built in Session 18.
- [ ] **"Convert to Quote" on won deals** — write `quotation_id` back to the opportunity and pre-fill the quote form. The remaining piece of the CRM module.
- [ ] **Email delivery** — send invoices, quotes, and receipts directly from the app via Supabase Edge Function → Resend/SendGrid. Closes the biggest day-to-day manual step.
- [ ] **Recurring invoices** — flag an invoice as recurring with a frequency; auto-generate the next one on due date. Useful for retainer/monthly clients.
- [ ] **Overdue reminders** — automated or one-click email reminder for outstanding AR balances. Drives off existing `balance_due` and `due_date` fields.

### Finance

- [x] **Cash Flow Statement** — indirect method; `runCF()` + `getBSBalances()` helper. See Session 17.
- [ ] **Purchase Orders** — PO that a bill can be matched against; enables approval-before-spend workflows and 3-way matching.
- [ ] **VAT / Tax report** — output tax vs input tax by period; useful for filing. Derived from tax-category accounts already in the CoA.
- [ ] **Spend approval thresholds** — bills/POs above a configurable amount require admin approval before payment is released. Ties into existing role system.
- [ ] **Credit limit management** — configurable credit limit per client; warning or block when a new invoice would exceed it.

### Dashboard & Reporting

- [ ] **Cash position widget** — sum of all bank account balances by currency on the dashboard. Data already in `bank_accounts`.
- [ ] **Receivables / payables aging chart** — visual bar chart version of the aged AR/AP reports shown on the dashboard.
- [ ] **Sales pipeline KPIs** — deals by stage, conversion rate, average deal size. Builds on CRM module.

### Usability

- [ ] **Keyboard shortcuts** — `N` new record in current view, `S` save, `/` focus search. High ROI for daily users.
- [ ] **Bulk operations** — multi-select rows in AR/AP to mark as sent, batch-apply a payment, or export selected.
- [ ] **Global search / command palette** — `Ctrl+K` to jump to any client, invoice, or bill by number/name.

### Integration

- [ ] **Q2M Job Cards link** — cost summary from a job card pre-fills a Meridian invoice. Note: the apps use **separate** Supabase projects (verified Session 20), so this needs a cross-project integration rather than a shared-table join.

---

## Next Up

### To Do

- [ ] **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords. Checks new passwords against HaveIBeenPwned; flagged by the security advisors in Session 20 and cannot be enabled via SQL/MCP — requires a manual dashboard toggle.
- [ ] **"Convert to Quote" on a won opportunity** — pre-fill the quote form from the deal; write `quotation_id` back to the opportunity (carried over from Session 18)
- [ ] **CRM pipeline KPI widget on the Dashboard** — deals by stage, conversion rate (carried over from Session 18; same item as "Sales pipeline KPIs" in the Backlog)

