# Meridian ERP — Handoff

*Last updated: 2026-06-08 · Session 8*

---

## Quick Reference

| Item | Value |
|------|-------|
| Live URL | `https://erp.terranresources.com` |
| GitHub repo | `brandonr2630/meridian-erp` |
| Deploy | Push to `master` via PR → GitHub Actions → GreenGeeks cPanel auto-deploys |

---

## Sessions

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

- CRM module (3 tables: contacts, activities, deals) — design drafted, not yet built. See memory for details.

## To Do — Code Review Backlog

Items 1–5 from the June 2026 code review are resolved (PRs #22–#25, #27). Items 6–17 remain:

| # | Priority | Area | Task |
|---|----------|------|------|
| 6 | High | Maintainability | Z-index constants — define `--z-dropdown: 100; --z-modal: 600; --z-overlay: 700; --z-toast: 1000` in CSS vars and replace all magic numbers |
| 7 | High | Accessibility | Add `aria-label` to all icon-only buttons (topbar `🔔`, `🌙`, `⚙️` and table action icons) |
| 8 | Medium | Correctness | Date string comparisons — replace `i.due_date < today` with `new Date(i.due_date) < new Date(today)` to handle ISO timestamp suffixes |
| 9 | Medium | Correctness | Null-coalesce all foreign-key dereferences — deleted contacts/accounts produce silent `undefined` crashes (e.g. `contactMap[inv.contact_id].trading_name`) |
| 10 | Medium | Performance | Collapse N+1 fetches in dashboard load — companies → contacts, bank accounts, exchange rates should be `Promise.all()` where not already |
| 11 | Medium | Performance | Add `loading="lazy"` to company logo `<img>` tags — currently all logos are fetched on app load |
| 12 | Medium | Design | Change `@page { size: letter portrait }` to A4 (or make it a company setting) — US Letter clips output for Caribbean/UK users |
| 13 | Medium | Design | Standardise modal max-width — apply `min(560px, 95vw)` (or appropriate size) to all modals; Session 7 already uses the right pattern |
| 14 | Medium | Maintainability | Refactor `searchInvContact` / `searchBillVendor` / `searchQuoContact` / `searchDNContact` into a single `createContactSearch(inputId, resultsId, filter)` factory (~120 lines removed) |
| 15 | Medium | Maintainability | Extract repeated Supabase filter strings (`'is_active=eq.true&order=code'` etc.) as named constants — currently hardcoded inline 50+ times |
| 16 | Medium | UX | Add in-flight loading state during in-view data refreshes — e.g. `table.style.opacity = '0.5'` while fetch is pending |
| 17 | Medium | UX | Validate MIME type on logo file upload — size is checked but not type; add `['image/jpeg','image/png','image/webp'].includes(file.type)` guard |

## References

- **Repository:** https://github.com/brandonr2630/meridian-erp
- **Live Site:** https://erp.terranresources.com
- **Deploy workflow:** `.github/workflows/deploy.yml`
- **Deployment:** cPanel Fileman API → GreenGeeks (`chi203.greengeeks.net`)
