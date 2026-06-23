# Meridian ERP — Handoff

*Last updated: 2026-06-22 · Session 35*

---

## Session 35 — Email Delivery + Notification System

**Date:** 2026-06-22
**Branch:** `feat/email-delivery` (open PR pending)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `supabase/migrations/20260622_email_delivery.sql` | New migration (applied) | Adds `companies.send_from_email`, `notification_types` (7 seeded rows), `notification_preferences`, `notification_log` tables; `overdue_notified_at` on `crm_tasks`, `jobs`, `invoices`; RLS policies |
| `supabase/functions/send-document-email/` | New Edge Function (deployed ACTIVE) | Validates caller JWT → resolves company → strips data URI prefix → calls Resend API with PDF attachment. Falls back to `accounts@terranresources.com` if `send_from_email` unset |
| `supabase/functions/send-notification/` | New Edge Function (deployed ACTIVE) | Handles 7 notification event types; cron auth (source=cron requires SERVICE_ROLE_KEY bearer); preference opt-out check; interpolates `{{double_brace}}` templates; logs all sends to `notification_log` |
| `index.html` — html2pdf.js | `_loadHtml2Pdf()` + `generatePDFBase64(source)` | Lazy CDN loader; A4/scale:2; accepts DOM element or HTML string; returns data URI. Off-screen staging div `#email-pdf-staging` at line 4583 |
| `index.html` — Email modal | `#modal-send-email` | To / Subject / Message fields; pre-filled from `_resolveEmailMeta(type, id)`; send button calls `sendEmailDocument()` |
| `index.html` — Email functions | `openEmailDocument`, `_resolveEmailMeta`, `_buildEmailPDF`, `sendEmailDocument` | Core email flow. `_buildEmailPDF` handles 7 doc types (invoice, quotation, delivery-note, credit-note, receipt, work-order, ar-statement) |
| `index.html` — ✉️ buttons | AR, Quotations, DN, CN, Receipt tables | 5 email buttons added next to existing 🖨 buttons |
| `index.html` — Work Order Receipt | `buildWorkOrderReceiptHTML(job, labour, materials, consumables, company)` | Renders labour/materials/consumables tables + sign-off block. ✉️ button in WO dashboard for Completed/Invoiced jobs (stopPropagation) |
| `index.html` — AR Statement | `buildARStatementHTML(contact, invoices, company)` + contact filter | Contact filter dropdown `#ar-contact-filter` in AR toolbar; `#ar-email-stmt-btn` visible when contact selected; `_emailARStatement()` helper |
| `index.html` — Settings | `send_from_email` field in Company Settings modal | Load / save / reset wired to `erp-co-send-from` input |
| `index.html` — Notification triggers | `_sendNotification()` + 3 trigger sites | `task.assigned` in `saveTask()`; `deal.won`/`deal.lost` in `saveOpportunity()` + `quickMarkOpp()` |
| `index.html` — Notification prefs UI | `loadSettingsNotifications()` + `toggleNotificationPref()` | "Email Notifications" section in Settings; toggle grid; admin sees all 7 types, non-admin sees 5 (direct only); upsert via `resolution=merge-duplicates` |
| `supabase/migrations/20260622_pg_cron_overdue_notifications.sql` | Manual-apply SQL file | pg_cron jobs for overdue tasks (07:00), jobs (07:05), invoices (07:10) UTC daily. One-shot via `overdue_notified_at`. **Replace `{SERVICE_ROLE_KEY}` before applying.** |

### DB migrations applied (production)

- `20260622_email_delivery` — notification tables, sentinels, `send_from_email`

### Manual steps remaining (Task 1)

1. Verify `terranresources.com` + `q2m.io` in [Resend dashboard](https://resend.com/domains) (DNS TXT records)
2. Create Resend API key → add as `RESEND_API_KEY` in Supabase → Edge Functions → Secrets
3. Apply `supabase/migrations/20260622_pg_cron_overdue_notifications.sql` in Supabase SQL Editor after replacing `{SERVICE_ROLE_KEY}`
4. Set `send_from_email` per company in ERP → ERP Companies → Edit → "Send From Email" field

### Notes

- `job.assigned` trigger skipped — jobs form uses free-text `accepted_by`, no user UUID linkage
- Work-order + AR-statement email paths in `_buildEmailPDF` were forward references (added in Tasks 7+8 — both now resolved)
- Edge Functions deployed with `verify_jwt: false` (functions do their own JWT validation internally)

### Outstanding (carried forward)

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords
- **Job → Invoice link** — completed job pre-fills Meridian invoice (Session 21)
- **Job Cards PDF** — printable work order report
- **Work Orders in Client 360** — requires `contact_id` FK on `jobs`

---

## Session 34 — RBAC RLS infinite recursion fix

**Date:** 2026-06-22
**Branch / PRs:** [PR #86](https://github.com/brandonr2630/meridian-erp/pull/86) · [PR #87](https://github.com/brandonr2630/meridian-erp/pull/87)

---

## Quick Reference

| Item | Value |
|------|-------|
| Live URL | `https://erp.terranresources.com` |
| GitHub repo | `brandonr2630/meridian-erp` |
| Deploy | Push to `master` via PR → GitHub Actions → GreenGeeks cPanel auto-deploys |
| Deploy workflow | `.github/workflows/deploy.yml` → cPanel Fileman API (`chi203.greengeeks.net`) |

---

## Session 34 — RBAC RLS infinite recursion fix

**Date:** 2026-06-22
**Branch / PRs:** [PR #86](https://github.com/brandonr2630/meridian-erp/pull/86) · [PR #87](https://github.com/brandonr2630/meridian-erp/pull/87)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `erp_user_company_roles` RLS policies | Replaced inline self-referential EXISTS subqueries with `user_has_perm()` SECURITY DEFINER helper | All three policies (`ucr_select_own`, `ucr_insert`, `ucr_update`) contained inline EXISTS subqueries that queried `erp_user_company_roles` from within an `erp_user_company_roles` policy — causing infinite recursion on every login. PR #86's two-query `loadAndBuildPerms` surfaced this via the debug toasts. |
| `user_has_perm(perm text)` DB function | New SECURITY DEFINER helper | Checks whether the current user has a given permission atom by joining `erp_users → erp_user_company_roles → erp_roles`. Runs as definer (superuser), bypassing RLS — no recursion. `REVOKE` from anon/public; `GRANT` to authenticated. Applied via migration `fix_ucr_rls_infinite_recursion_use_secdef_helper`. |
| Debug toasts removed from `loadAndBuildPerms` | Cleanup — PR #87 | "RBAC debug: loaded 40 permissions" confirmed green. Removed all three diagnostic `showToast` paths. |

### DB migrations applied (production)

- `fix_ucr_rls_infinite_recursion_use_secdef_helper`

### Root cause chain (Sessions 33–34)

1. Phase 4 dropped `erp_users.role` column → `is_super_admin()` and `my_company_ids()` broke (Session 33 fixed)
2. PostgREST embedded join `erp_roles(*)` silently returned null → `loadAndBuildPerms` got `buildPerms({},{})` (Session 33 fixed with two-query approach + debug toasts)
3. Two-query fix hit the actual DB call → RLS policy on `erp_user_company_roles` self-references `erp_user_company_roles` → infinite recursion (Session 34 fixed with `user_has_perm()`)

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (Session 21)
- **Job Cards PDF** — printable job card / work order report
- **Work Orders in Client 360** — requires adding `contact_id` FK to `jobs` table

---

## Session 33 — RBAC Phase 4 cutover bug fixes

**Date:** 2026-06-22
**Branch / PR:** [PR #86](https://github.com/brandonr2630/meridian-erp/pull/86)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `is_super_admin()` DB function | Rewrote to use `erp_user_company_roles` | Was `WHERE erp_users.role = 'super_admin'` — Phase 4 dropped that column. Fixed to JOIN `erp_user_company_roles` → `erp_roles` and check `(permissions->>'admin:companies')::boolean = true`. Applied via Supabase migration. |
| `my_company_ids()` DB function | Rewrote to use `erp_user_company_roles` | Was querying dead `user_company_access` table. Fixed to `SELECT ucr.company_id FROM erp_users eu JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id WHERE eu.auth_user_id = auth.uid()`. Applied via Supabase migration. |
| `erp_roles` SELECT RLS policy | `auth.role()='authenticated'` → `auth.uid() IS NOT NULL` | `auth.role()` reads `request.jwt.claim.role` which can be null in some Supabase JWT configurations. `auth.uid() IS NOT NULL` is universally reliable. Applied via Supabase migration. |
| `loadAndBuildPerms()` | Split embedded join into two explicit queries | PostgREST embedded join `erp_roles(*)` was silently returning null (schema cache + RLS interaction). Now: (1) fetch UCR row, (2) fetch `erp_roles` by `id`. Prevents `buildPerms({},{})` silent fallback. |

### DB migrations applied (production)

- `fix_is_super_admin_and_my_company_ids_drop_role_column_ref`
- `fix_erp_roles_select_policy_use_uid_not_null`

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (Session 21)
- **Job Cards PDF** — printable job card / work order report
- **Work Orders in Client 360** — requires adding `contact_id` FK to `jobs` table

---

## Session 32 — Aesthetic redesign + Companies page fix

**Date:** 2026-06-20
**Branch / PRs:** [PR #78](https://github.com/brandonr2630/meridian-erp/pull/78) · [PR #79](https://github.com/brandonr2630/meridian-erp/pull/79)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `index.html` promoted from `index2.html` | Aesthetic redesign goes live | `index2.html` was a UI/UX enhancement of `index.html`. Pre-promotion diff: 211 lines added (pure CSS + minor layout). All JS functions, Supabase calls, localStorage keys, nav routes, and event listeners verified identical between old and new. Zero functional changes. |
| `index-archive-20260620.html` | Previous `index.html` archived locally | Kept as an untracked file — same convention as the existing `index2–5.html` archives. Not committed to git. |
| `design.md` | New design system doc | Full design system markdown (colors, typography, spacing, components, screens) written to project root for use with Google Stitch. Not deployed. |
| `view-erp-companies` → `view-companies` | Companies page restored | `navigate('companies')` activates `#view-companies` but the div had `id="view-erp-companies"` after the redesign merge, rendering a blank page. Renamed the div ID (single character change, line 2805). No callers of `navigate('erp-companies')` in the file; legacy switch alias in `loadViewData` is harmless. |

### Deploy notes

- PR #79 auto-deploy failed with HTTP 415 (WAF blocked the Fileman upload — transient). Manual `workflow_dispatch` immediately after succeeded and delivered the fix.

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (Session 21)
- **Job Cards PDF** — printable job card / work order report
- **Work Orders in Client 360** — requires adding `contact_id` FK to `jobs` table

---

## Session 31 — Client 360 view

**Date:** 2026-06-20
**Branch / PR:** [PR #76](https://github.com/brandonr2630/meridian-erp/pull/76)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `360` button on Clients table | New action button per row | Calls `open360(clientId)` → sets `currentClient360Id` → `navigate('client-360')`. |
| `view-client-360` | New full-page view | Static container (`#c360-root`) rendered entirely by JS. Shares the `.page-body` scroll wrapper; no static page-header (header is part of the dynamic render). |
| `loadClient360()` | Parallel fetch of 9 tables | `Promise.all` over `contact_persons`, `crm_opportunities`, `crm_activities`, `crm_tasks`, `invoices`, `payment_receipts`, `quotations`, `delivery_notes`, `credit_notes` — all filtered by `contact_id=eq.{id}`. `payment_receipts` and `credit_notes` use `.catch(() => [])` for graceful fallback. Client header comes from the existing `contacts` global (no extra fetch). |
| `_render360(d)` | Main renderer | Left sidebar: avatar initials, financial summary (total billed, balance due, open deals, pipeline value in client's currency, open tasks, last activity, credit limit), contact persons with title/phone/email. Right: `table-wrap` with tab bar + `#c360-content` div. |
| `_build360Timeline(d)` | Timeline merge function | Normalises all 8 record types to `{ date, icon, title, meta, amount, amountStyle }` and sorts by `date` descending. Payment receipts with `status='voided'` excluded. |
| `_render360TL(items)` | Timeline renderer | `.c360-tl` list with emoji icon, title, muted meta line, right-aligned amount (coloured for payments/credit notes). |
| `switch360Tab(tab, el)` | Tab switching | Reads `_c360Data` (module-level); re-renders `#c360-content` from already-fetched data — no re-fetch on tab switch. |
| `_render360Deals/Invs/Quotes/DNs/CNs/Tasks` | Per-tab table renderers | Standard `.data-table` tables. Delivery Notes and Credit Notes tabs only rendered in the tab bar when `d.dns.length` / `d.cns.length > 0`. Tasks empty state links to `openNewTask(null, clientId)`. |
| `_open360NewOpp(clientId)` | New deal shortcut | Calls `openNewOpportunity()` then immediately sets `#opp-contact` dropdown value to the client — no modal changes needed. |
| `.c360-*` CSS | 36-line block | Grid layout (240px sidebar + `minmax(0,1fr)`), panel cards, avatar, stat rows, contact person rows, tab bar with gold active indicator, timeline item rows. Collapses to single-column below 900 px. |
| Module / sub-module guard | `client-360` added | Added to `sales` module guard and `module_sales_orders` sub-guard — same access level as Clients view. Added to `VIEW_SECTIONS['client-360'] = ['sales']`. |
| State vars | `currentClient360Id`, `_c360Data` | Added alongside existing CRM state (line ~11531). |

### Architecture notes

- **Jobs not included** — `jobs.customer` is a free-text field, not a `contact_id` FK. To add Work Orders to the 360 view, add a `contact_id` column to the `jobs` table and filter by it here.
- **No re-fetch on tab switch** — all data is held in `_c360Data` after the initial load. Switching tabs is instant.
- **`_oppEffectiveStatus(o)`** — reused from the Pipeline module (already global) for deal status badges in the timeline and Deals tab.
- **Payments currency** — `payment_receipts` has no `currency` column; amounts are shown via `fmtNum` (no currency symbol) rather than `fmt`. The currency is implied by the linked invoice.

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (Session 21)
- **Job Cards PDF** — printable job card / work order report
- **Work Orders in Client 360** — requires adding `contact_id` FK to `jobs` table

---

## Session 30 — Fix voidVendorPayment status value

**Date:** 2026-06-20
**Branch / PR:** [PR #74](https://github.com/brandonr2630/meridian-erp/pull/74)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `voidVendorPayment()` — status value | `'void'` → `'voided'` | The patch to `payments` was writing `status: 'void'` but the render guard in `openBillPaymentHistory` (`p.status === 'voided'`) and the re-void guard in `voidVendorPayment` (`payment.status === 'voided'`) both checked against `'voided'`. After a successful void, the Void button remained active and the double-void guard never fired — enabling duplicate JE reversals. One-character fix. |

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice
- **Job Cards PDF** — printable job card / work order report

---

## Session 29 — Nav and Dashboard layout tweaks

**Date:** 2026-06-20
**Branch / PRs:** [PR #71](https://github.com/brandonr2630/meridian-erp/pull/71) · [PR #72](https://github.com/brandonr2630/meridian-erp/pull/72)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Sidebar: "Sales" → "CRM" | Section label renamed; CRM sub-menu dissolved | "Sales" heading renamed to "CRM". The collapsible CRM sub-section (with its own header and toggle) was removed — Sales Leads, Pipeline, Activities, Tasks are now flat top-level items in the section alongside Quotations and Clients. `VIEW_SECTIONS` updated to remove `'sales-crm'` from auto-expand arrays; stale `sub-section-sales-crm` hide logic removed from `applyRoleNav`. |
| Dashboard: Sales Pipeline zone moved | Promoted to just below Business Snapshot | Zone 3c (Sales Pipeline stat cards + funnel) moved from between Exchange Rates and Recent Activity to immediately after the Business Snapshot zone. New order: Attention Required → Business Snapshot → **Sales Pipeline** → Operations → Exchange Rates → Recent Activity. |

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice
- **Job Cards PDF** — printable job card / work order report

---

## Session 28 — Convert to Quote + CRM Dashboard Widget

**Date:** 2026-06-20
**Branch / PR:** TBD — all changes to `index.html` only.

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `_quoFromOppId` | New state var | Holds the opportunity ID being converted while the quotation modal is open. Reset to `null` by `openNewQuotation()` and cleared immediately before the write-back in `saveQuotation()`. |
| `openConvertToQuote(oppId)` | New function | Calls `openNewQuotation()` (initialises blank form), then sets `_quoFromOppId = oppId` and pre-fills: contact (id + search display), currency from the opportunity, notes from opportunity `description`, and first line item (opportunity name as description, qty=1, unit_price=opportunity value if set). |
| `saveQuotation()` write-back | Conditional PATCH after save | If `_quoFromOppId` is set when `saveQuotation()` completes: PATCHes `crm_opportunities.quotation_id = quoId`, updates the in-memory `crmOpps` array entry, resets `_quoFromOppId`, shows a "created and linked" toast instead of the normal one. |
| Pipeline table — Convert button | 📝 button on won deals | Shown when `effStatus === 'won' && !o.quotation_id`. Calls `openConvertToQuote(o.id)`. |
| Pipeline table — Quote linked badge | `✓ Quote` badge on linked deals | Shown when `effStatus === 'won' && o.quotation_id`. Green text, no action. |
| Dashboard Zone 3c | New "Sales Pipeline" zone | Inserted between the Forex zone and Recent Activity. Four stat cards: Open Deals (count + open value in base currency), Won This Month (count + value), Win Rate (all-time %, won ÷ (won + lost)), Open Tasks (count + "N overdue" if any, red border when overdue). Stage funnel below the cards: Prospect › Qualified › Proposal › Negotiation counts for open deals. Entire zone hidden when `module_sales_crm === false`. |
| `loadDashboardCRM()` | New async function | Called fire-and-forget from `loadDashboard()`. Fetches `crm_opportunities` (Q.crmOpps()) and `crm_tasks` (open only). Computes all KPIs and renders the zone. |

### Architecture notes

- **`_quoFromOppId` lifecycle:** set by `openConvertToQuote` after the modal is ready; cleared at the start of `saveQuotation`'s success branch (before the PATCH) so a modal close without saving leaves no stale state.
- **In-memory sync:** after the `quotation_id` write-back, `crmOpps[oppIdx]` is updated in place — so if the user navigates to Pipeline on the same session, the "✓ Quote" badge renders immediately without a round-trip.
- **Dashboard CRM zone** uses `_oppEffectiveStatus(o)` for backward compat (same as the Pipeline view). Win rate denominator is `won.length + lost.length`; shows `—` if both are zero (no closed deals yet).
- **Open Tasks card** overdue check uses `todayDate()` and compares `t.due_date`. Red border applied via `.stat-card` `borderColor` (same pattern as overdue invoices card).

### Outstanding

- **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords (manual toggle only)
- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice
- **Job Cards PDF** — printable job card / work order report

---

## Session 27 — CRM module UI (pipeline enhancements + contact persons + contact linking)

**Date:** 2026-06-20
**Branch / PR:** TBD — all changes to `index.html` only.

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Opportunity modal | Status, Source, Probability, Lost Reason fields added | Status (open/won/lost) is now separate from Stage. Stage dropdown removes won/lost — those are outcomes, not pipeline positions. Source: referral/cold_call/website/repeat/other. Probability: 0–100 integer %. Lost Reason: text field, shown only when status=lost. |
| `oppStatusChange()` | Show/hide Lost Reason field | Called on status dropdown change; hides Lost Reason unless status=lost. |
| `_oppEffectiveStatus(o)` | Backward-compat status resolver | Returns `o.status` if not 'open'; falls back to legacy `o.stage` ('won'/'lost') for records created before Session 26. |
| `openEditOpportunity()` | Populates new fields on edit | Maps legacy stage='won'/'lost' to status; sets stage to 'negotiation' for legacy won/lost records (since won/lost removed from stage dropdown). |
| `saveOpportunity()` | Writes status, source, probability, lost_reason, won_at, lost_at | Sets `won_at` / `lost_at` to `nowISO()` only when status first transitions to that value. |
| `quickMarkOpp(id, status)` | One-click Won / Lost from table row | 🏆 and ✗ buttons shown on open deals in the pipeline table; fires a confirm then patches status + won_at/lost_at. |
| Pipeline table | Added Status + Probability columns | Status badge shows effective status; Prob. column shows `—` when null. Quick Won/Lost buttons only on open deals. |
| Pipeline filter | Status filter added | All Status / Open / Won / Lost; filters on `_oppEffectiveStatus`. |
| `renderPipelineStats()` | Updated to use effective status | Won This Month now reads `won_at` for timestamping (falls back to `updated_at`). |
| Activity modal | Contact + Contact Person fields | Contact dropdown (from global `contacts`); Contact Person loaded async from `contact_persons` on contact selection via `onActContactChange()`. Opportunity remains optional. Validation: at least one of contact or opportunity required. |
| Activities table | Contact column added | Shows trading_name/name for `contact_id`; Contact column added between Subject and Opportunity. |
| `filterActivities()` | Searches contact name | Contact name included in full-text search. |
| Task modal | Contact + Contact Person fields | Same pattern as activity modal: contact select → `onTaskContactChange()` → CP select populates. Validation: contact or opportunity required. |
| Tasks table | Contact column added | Between Title and Opportunity columns. |
| `filterTasks()` | Searches contact name | Contact name included in full-text search. |
| Contact Persons modal | New `modal-contact-persons` | Opens per client from the Clients table (👥 button). Shows all contact persons with Primary badge, status, and edit/delete/set-primary actions. |
| Contact Person form | New `modal-cp-form` | Add/edit a contact person: name, title, email, phone, is_primary checkbox, notes. Setting primary auto-clears is_primary on all other persons for that contact (bulk PATCH then individual PATCH). |
| Client table | 👥 Persons button | Each client row now has a Contact Persons button before the Edit button. |
| State vars | `contactPersons`, `_editCPId`, `_cpClientId` | Added alongside existing CRM state. |

### Architecture notes

- **`_oppEffectiveStatus(o)`** — the canonical way to determine a deal's outcome. Always call this rather than reading `o.status` directly, to handle the pre-Session-26 dataset where status defaults to 'open' even for deals with stage='won'/'lost'.
- **Activity / Task validation** — both modals now require at least one of `contact_id` or `opportunity_id`. The "None" option is still available in each dropdown; the save function checks both before submitting.
- **Contact Person CP select (activities/tasks)** — `_refreshActCPSelect` / `_refreshTaskCPSelect` fire an async `sbGet('contact_persons', ...)` each time a contact is selected. The field (`act-cp-field` / `task-cp-field`) is hidden when no contact is selected, visible when one is.
- **Bulk is_primary reset** — `saveContactPerson()` and `setPrimaryCP()` both call `sbPatchWhere('contact_persons', 'contact_id=eq.${id}', { is_primary: false })` before setting the new primary. This is not atomic but safe for a single-user session; a race would be caught on the next load.

### Outstanding

- **"Convert to Quote" on won deals** — carried from Session 18
- **CRM pipeline KPI widget on Dashboard** — carried from Session 18
- **`voidVendorPayment()` untested** — carried from Session 22

---

## Session 26 — CRM schema migration (contact_persons + enriched CRM tables)

**Date:** 2026-06-20
**Branch / PR:** No code change to `index.html` this session — schema-only. Supabase migration `crm_schema_v1` applied directly to `fcagxvjxfqqkmuposmcb`.

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `contact_persons` table | New | Multiple people per company/contact. Replaces flat `contact_person_*` columns on `contacts` (those columns kept for backward compat — deprecate later). Columns: `id`, `company_id`, `contact_id` (FK → contacts, cascade), `name`, `title`, `email`, `phone`, `is_primary`, `notes`, `is_active`, `created_at`, `updated_at`. Indexes on `contact_id` and `company_id`. |
| Existing contact persons | Migrated | `contact_person_name/title/email/phone` from `contacts` copied into `contact_persons` as `is_primary=true` records. **20 records migrated.** |
| `crm_activities` | 2 columns added | `contact_id` (FK → contacts, set null on delete), `contact_person_id` (FK → contact_persons, set null on delete). Activities can now be logged against a client directly, without requiring an opportunity. App rule: at least one of `contact_id` or `opportunity_id` must be set. |
| `crm_tasks` | 2 columns added | Same pattern as `crm_activities` — `contact_id` and `contact_person_id` added. |
| `crm_opportunities` | 6 columns added | `status` text NOT NULL default `'open'` check (`open`/`won`/`lost`) — outcome, separate from `stage` which tracks pipeline position; `probability` integer 0–100; `source` text (referral, cold_call, website, repeat, etc.); `lost_reason` text; `won_at` timestamptz; `lost_at` timestamptz. Indexes on `status` and `company_id`. |

### Architecture notes

- **`contact_persons` vs flat columns:** The old `contact_person_*` fields on `contacts` still exist and all existing save/load paths still write to them. `contact_persons` is additive — the CRM UI will read from it; the accounting UI still uses the flat columns. Clean-up pass deferred until after the CRM module UI is built.
- **`sales_leads` is NOT a CRM prospect table.** It is an internal salesperson/account-executive roster used to attribute quotations to reps (`quotations.sales_lead_id`). The CRM pipeline lives entirely in `crm_opportunities`, with `stage='prospect'` as the entry point. No changes to `sales_leads`.
- **status vs stage on opportunities:** `stage` = where in the sales process (prospect → qualified → proposal → negotiation); `status` = outcome (open / won / lost). A deal moves through stages while `status='open'`, then closes as won or lost.
- **Reference doc:** `crm-reference/twenty-capabilities.md` — full feature catalogue of Twenty CRM (twentyhq/twenty), retained as a build reference for the native CRM module.

### Outstanding

- **CRM module UI** — schema is ready; no JS changes made this session. Next: build the enhanced Pipeline, Activities, Tasks, and Contact Persons views in `index.html`.
- **"Convert to Quote" on won deals** — carried from Session 18
- **CRM pipeline KPI widget on Dashboard** — carried from Session 18
- **`voidVendorPayment()` untested** — carried from Session 22

---

## Session 25 — Labour table redesign in Work Orders

**Date:** 2026-06-18
**Branch / PR:** [PR #67](https://github.com/brandonr2630/meridian-erp/pull/67)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Employee column | Replaces free-text Technician field | Dropdown populated from `employees` table (Job Config); `jcConfig.employees` added to config load |
| Classification | Now autofill (read-only display) | Autofills from employee's `job_classification` on selection; hidden `<input type="hidden">` holds value for collect |
| Tasks column | New inline column | Modal multi-select from `config_tasks`; button shows count ("2 tasks") with gold border when populated; replaces the old "Add Task" sub-row pattern under each labour entry |
| Start / End | Now true time pickers | Were already `type="time"` but Hrs calculation now rounds to nearest **whole number** (was 2 decimal places) |
| Hrs | Auto-calculate | Derived from End−Start difference; user can still override manually |
| Type | Unchanged | Reg/OT auto-detected at >8 hrs |
| Rate | Autofills on employee/location change | Workshop vs Onsite rate from `config_labour`; re-fires on Location dropdown change |
| Date sort | Sort dropdown on Date column header | Click opens "↓ Newest First / ↑ Oldest First" menu; default `desc`; icon updates to reflect state |
| Add Labour Entry | Moved above table | Button sits above the table; new rows prepend to `<tbody>` (newest at top); matches default sort direction |
| Data collect | ID-based selectors | `jcCollectFormData` now uses element IDs (`${rid}-date`, `${rid}-emp`, etc.) instead of fragile positional `querySelectorAll` |
| Save path | `technician` column | `r.employee \|\| r.tech` — backward compatible with rows created before this session |
| Load path | `Labour Detail` JSON | `tech:` key renamed to `employee:` in the DB→form mapping |
| Sort on load | `jcSortLabour(jcLabourSortDir)` | Called in `jcPopulateForm` and `jcDuplicateJob` after rows are added, ensuring saved jobs always open sorted newest-first |

### Architecture notes

- **`jcConfig.employees`** loaded alongside other config in `jcLoadConfig()` via `sbGet('employees','order=name')`. Carries `{ name, classification }`.
- **Classification chain:** Employee select → `jcOnLabourEmpChange(rid)` → `jcSetLabourClassification(rid, cls)` → looks up rate in `jcConfig.labour` → fills `${rid}-rate`.
- **Location change** fires `jcOnLabourLocChange2(rid)` → reads hidden classification value → `jcSetLabourClassification` → recalculates rate.
- **Tasks modal** is dynamically appended to `<body>` as `#jc-tasks-modal-overlay`; saves JSON to `data-tasks` attribute on the tasks button cell.
- **`jcAddTaskSubRow`** is still present and unchanged — still used by Equipment rows which retain the sub-row task pattern.
- **Backward compat:** old `tech` field in stored Labour Detail falls through to `r.employee||r.tech` on save. On load, `r.technician` (DB column) maps to `employee` key; the employee dropdown is set to that string value (may not match if name changed).

### Outstanding

- **Job Costing module** — placeholder nav item in place; full build not yet scheduled
- **voidVendorPayment() untested** — carried over from Session 22

---

## Session 24 — Sub-module permissions & Edit Permissions flow

**Date:** 2026-06-17
**Branch / PR:** [PR #66](https://github.com/brandonr2630/meridian-erp/pull/66)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Sub-module permissions | 7 new boolean columns on `erp_users` | `module_finance_ar`, `module_finance_ap`, `module_finance_bank`, `module_finance_ledger`, `module_finance_reports`, `module_sales_crm`, `module_sales_orders` — all default `true`. Applied via Supabase MCP migration. |
| Hierarchical module checkboxes | Create User modal redesigned | Finance and Sales parent checkboxes now expand to sub-checkboxes. Unchecking a parent disables and clears its children. Sub-items: Finance → AR & Credit Notes / AP & Vendors / Bank & Cash / Ledger / Reports; Sales → CRM / Orders. |
| Edit Permissions modal | New flow for existing users | "Edit" button added to each user row. Opens a modal with Role, Company, and the full hierarchical module tree pre-populated from the user's current flags. Saves via `sbPatchWhere` directly to `erp_users`. |
| `applyRoleNav()` | Per-nav-item visibility | Sub-flags now hide individual nav items within enabled modules (e.g. `module_finance_bank=false` hides `nav-bank`). Reports sub-section header hidden when `module_finance_reports=false`; CRM sub-section header hidden when `module_sales_crm=false`. |
| `navigate()` guard | Sub-flag route blocking | Sub-module guard added below the module-level guard. Blocked views redirect to dashboard. |
| `umFormatModules()` | Modules column shows sub-access | Table column now shows e.g. `Finance (AR, Bank) · Sales` instead of just `Finance · Sales` when partial access is granted. |
| Edge Function v2 | Accepts and stores all 7 new flags | `create-erp-user` updated and redeployed (version 2). |

### Architecture notes

- **Sub-flags are only enforced when the parent module is enabled.** If `module_finance=false`, all finance sub-flags are irrelevant (entire section is hidden). Sub-flags only narrow access within an enabled module.
- **Existing users** get all sub-flags defaulting to `true` via SQL `DEFAULT true`, so no access regression for users created before this session.
- **Edit Permissions** PATCHes `erp_users` directly with the caller's user token — RLS on `erp_users` allows admins to update any row in their company.

### Outstanding

- **Job Costing module** — placeholder nav item in place; full build not yet scheduled
- **voidVendorPayment() untested** — carried over from Session 22

---

## Session 23 — Nav restructure, User Management, module access control, forex widget

**Date:** 2026-06-17
**Branch / PR:** [PR #65](https://github.com/brandonr2630/meridian-erp/pull/65)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Navigation restructured | Full sidebar reorganisation | Finance: added "Transactions" sub-label, Vendors moved in from Setup. Sales: Sales Leads moved into CRM sub-section as first item, Clients moved in from Setup, Delivery Notes moved out. Workshop → **Operations**: renamed throughout; Job Cards → **Work Orders** (all UI labels updated, internal function names unchanged). Delivery Notes moved to Operations. Operations gains Job Costing placeholder. Setup: ERP Companies → **Companies**, Clients/Vendors removed, User Management added. |
| User Management | New admin-only view under Setup | View all users (name, role, module access, company, last login, status). Create user via Edge Function (name, email, temp password, role, module flags). Deactivate/reactivate and remove with confirmation. Module checkboxes dimmed for admin/super_admin roles (they have full access regardless). |
| Module-based access control | New permission layer on top of roles | `erp_users` gains `module_finance`, `module_sales`, `module_operations` boolean columns (default `true`). Non-admin users only see the sidebar sections their profile permits. Navigation guard in `navigate()` redirects restricted views to dashboard. Admins bypass module flags entirely. |
| Force password change | First-login password intercept | `erp_users` gains `force_password_change` boolean (default `false`). New users created with this flag set. `doLogin()` and session-restore both check the flag and show a change-password screen before `initApp()`. Supabase `PUT /auth/v1/user` updates the password; flag cleared in `erp_users` on success. |
| Forex rates widget | Dashboard Zone 3b | Three rate cards (TTD/USD, USD/TTD, GYD/USD) rendered below the Operations stats zone. Feeds from existing `exchangeRates` object and `exchange_rates` table. Shows effective date and a Refresh button (`refreshForexRates()` → `fetchAndSaveRates()` → re-render). |
| Supabase Edge Function | `create-erp-user` deployed | Validates caller is admin/super_admin using their JWT, creates Supabase auth user via service role, inserts `erp_users` profile. Cleans up auth user if profile insert fails. Service role key never touches the browser. |
| SQL migration | 4 columns added to `erp_users` | `module_finance`, `module_sales`, `module_operations` (boolean, default true); `force_password_change` (boolean, default false). Applied via Supabase MCP. |

### Architecture notes

- **Module vs role:** roles determine what a user can *do* (post, void, finance); module flags determine what sections they can *see*. Admins see everything regardless of flags.
- **Edge Function:** deployed at `fcagxvjxfqqkmuposmcb/functions/v1/create-erp-user`. Called from `saveNewUser()` with the user's bearer token (`_accessToken`). `verify_jwt: false` — the function validates the caller manually to support CORS preflight.
- **Route aliases:** `'job-cards'` and `'erp-companies'` kept as legacy aliases in `loadViewData()` to handle any cached/bookmarked routes.
- **Job Costing:** nav item added under Operations; view is a placeholder ("Coming soon"). Full module not yet built.

### Outstanding

- **Job Costing module** — placeholder nav item in place; full build not yet scheduled
- **voidVendorPayment() untested** — carried over from Session 22

---

## Session 22 — JWT auto-refresh & escHTML bug fix

**Date:** 2026-06-17
**Branch / PR:** [PR #64](https://github.com/brandonr2630/meridian-erp/pull/64)

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| `sb()` — JWT auto-refresh | Added retry-on-401 logic | When a Supabase REST call returns 401 (expired access token), `sb()` now silently calls `sbAuthRefresh()` with the stored refresh token, calls `persistSession()` with the new token, then retries the original request once. If refresh fails, `clearSession()` is called and the login overlay is shown — user sees "Session expired. Please log in again." instead of a generic save error. |
| `escHtml` → `escHTML` in job cards module | Fixed 28 call sites in the Workshop / Job Cards module (lines 5671–6676) | Session 21 introduced the module using `escHtml()` (mixed case), but the ERP only defines `escHTML()` (all caps). This caused "Save failed: escHtml is not defined" on any job card save. Fixed via `replace_all` in [PR #63](https://github.com/brandonr2630/meridian-erp/pull/63). |

### Architecture notes

- **Token lifetime:** Supabase access tokens expire after 1 hour. `tryRestoreSession()` already proactively refreshes within 5 minutes of expiry on page load. The new 401-retry in `sb()` covers tokens that expire mid-session (e.g., a tab left open past 1 hour).
- **Retry is single-shot:** if the retry also returns non-OK, the error propagates normally. This prevents infinite loops if there's a genuine auth issue.

### Outstanding

- No new outstanding items (escHTML and JWT expiry both resolved this session)

---

## Session 21 — Workshop / Job Cards module

**Date:** 2026-06-17
**Branch / PR:** [PR #61](https://github.com/brandonr2630/meridian-erp/pull/61) · Supabase migration applied directly

### What Changed

| Item | Change | Detail |
|------|--------|--------|
| Workshop nav section | New collapsible sidebar section with **Job Cards** and **Job Config** | Job Config hidden for non-admin roles via `applyRoleNav()`; `sales` role can see Job Cards |
| `view-job-cards` | Full job management view — dashboard + 10-card job form | Dashboard: KPI strip (open / overdue / in-progress / completed), sortable/searchable register table, status pills. Form cards: Job Details, Labour, Equipment, Materials, Consumables, Sub-contractors, QC Checklist, Costing Summary, Drawings/Specs/Reports, Sign-off & Completion |
| `view-job-config` | Tabbed config manager (admin-only) | 7 tabs: Labour · Equipment · Materials · Consumables · Tasks · QC Checklists · Employees — full add/edit/delete, shared `#jc-cfg-modal` |
| Dashboard Workshop zone | New stat row on the ERP main dashboard | 4 cards: Open Jobs, Overdue, Due This Week, Completed This Month — overdue card gets red border when count > 0 |
| Supabase schema | 14 new tables applied to ERP project (`fcagxvjxfqqkmuposmcb`) | `jobs`, `labour_entries`, `equipment_entries`, `material_entries`, `consumable_entries`, `subcontractor_entries`, `job_audit_log`, `employees`, `config_labour`, `config_materials`, `config_consumables`, `config_tasks`, `config_qc_checklists`, `config_equipment` |
| `next_job_no()` RPC | Postgres sequence `job_no_seq` → `JC-0001`, `JC-0002`, … | Called via `sb('rpc/next_job_no', { method:'POST', body:{} })` when opening a new job form |
| Multi-company scoping | All job queries include `company_id=eq.${currentCompany.id}` | `UNIQUE (company_id, job_no)` constraint on `jobs` |
| API pattern | All Supabase SDK calls converted to ERP raw-fetch wrappers | `sbGet / sbPost / sbPatch / sbDelete / sbDeleteWhere` throughout; no Supabase JS SDK dependency |
| Namespace | All DOM IDs prefixed `jc-`; all JS functions/vars prefixed `jc` or `jcCfg` | Prevents collision with existing ERP identifiers |

### Architecture notes

- **Entry points:** `loadJobCards()` (dashboard) and `loadJobConfig()` (config manager)
- **Config cache:** `jcConfig` object loaded on every `loadJobCards()` call; also refreshed after any add/edit/delete in Job Config so form dropdowns stay current
- **Save pattern:** job header PATCH/POST, then parallel DELETE + re-INSERT for all entry child tables (labour, equipment, materials, consumables, sub-contractors)
- **QC state** stored as JSONB on the `jobs` row; drawings/specs/reports likewise
- **Job audit log** fires fire-and-forget on every save; failures do not block the save

### Outstanding

- **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (replaces the old "Q2M Job Cards link" backlog item)
- **Job Cards PDF** — printable job card / work order report
- **Job number prefix per company** — currently hardcoded `JC-`; may want company-configurable prefix like invoice numbering

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

**`crm_opportunities`:** id · company_id · contact_id · name · stage (prospect/qualified/proposal/negotiation/won/lost) · type (standard/development) · value · currency · expected_close · description · quotation_id · owner_id (erp_users) · created_at · updated_at · **status** (open/won/lost) · **probability** (0–100) · **source** · **lost_reason** · **won_at** · **lost_at** *(bold = added Session 26)*

**`crm_activities`:** id · company_id · opportunity_id · type · subject · notes · activity_date · user_id (erp_users) · created_at · **contact_id** · **contact_person_id** *(bold = added Session 26)*

**`crm_tasks`:** id · company_id · opportunity_id · title · description · due_date · assignee_id (erp_users) · completed · completed_at · created_at · **contact_id** · **contact_person_id** *(bold = added Session 26)*

**`contact_persons`** *(new Session 26):* id · company_id · contact_id · name · title · email · phone · is_primary · notes · is_active · created_at · updated_at

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

The entire app is `index.html` — approximately 15,200 lines of inline CSS and JavaScript. **Never edit `index-archive-*.html` or `index2–5.html`; those are archives.**

### Backend

- **Supabase** — primary data store, called directly via a thin fetch wrapper
- All DB access goes through `sb()` → `sbGet / sbPost / sbPatch / sbPatchWhere / sbDelete / sbDeleteWhere`
- **Auth:** Supabase JWT. Session (access token + refresh token) persisted to `localStorage`, restored on load by `tryRestoreSession()`
- **Multi-company:** every record scoped to `currentCompany.id`. Company switcher in topbar; `switchCompany(id)` reloads view data

### Navigation & State

- `navigate(view)` sets `currentView` and calls `loadViewData(view)`
- Global state declared at `// ── STATE ──` (~line 3373): `currentUser`, `currentCompany`, `companies`, `accounts`, `contacts`, `journalEntries`, `bankAccounts`, etc.

### Roles (RBAC — Phase 4 complete)

Roles now live in `erp_roles` (jsonb permissions) + `erp_user_company_roles` (user↔company↔role assignment). The old `erp_users.role` column and all `module_*` columns were dropped in Phase 4.

Permission engine: `loadAndBuildPerms()` → `buildPerms(rolePerms, overrides)` → `_perms = {...rolePerms, ...overrides}`. Lookup: `can('domain:module:action')`.

Thin wrappers still exist for legacy call sites: `isAdmin()`, `isSuperAdmin()`, `canPost()`, `canVoid()`, `canFinance()`, etc.

System roles: `super_admin` · `company_admin` · `finance_manager` · `sales_rep` · `operations_tech` · `viewer`. Custom roles per company also supported.

### Modules

Dashboard · Chart of Accounts · Journal Entries · AR · AP · Vendor Payments · Clients · Vendors · ERP Companies · Settings · Bank Accounts · Bank Transactions & Reconciliation · Bills · Financial Reports (P&L · Balance Sheet · Trial Balance · Cash Flow · Aged AR/AP) · Quotations · Delivery Notes · Credit Notes · Sales Leads · CRM (Pipeline · Activities · Tasks) · **Workshop (Job Cards · Job Config)**

### Currencies

TTD (`TT$`) · USD (`US$`) · GYD (`G$`) — formatted via `fmt(amount, currency)`

### PDF & Exports

PDFs rendered client-side with a custom multi-page renderer. SheetJS lazy-loaded from CDN on first Excel export. Report download menu is a shared fixed component.

---

## Known Issues

*(none)*

## Backlog

Items are grouped by theme and ordered by suggested priority within each group. Tick them off as sessions complete them.

### Sales & CRM

- [x] **CRM module** — Pipeline, Activities, Tasks views under the Sales nav; `type: development` for dev inquiry handling. Built in Session 18.
- [x] **"Convert to Quote" on won deals** — write `quotation_id` back to the opportunity and pre-fill the quote form. Built in Session 28.
- [x] **Client 360 view** — unified client profile (timeline, financials, deals, invoices, quotes, tasks). Built in Session 31. Work Orders excluded pending `contact_id` FK on `jobs`.
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
- [x] **Sales pipeline KPIs** — deals by stage, conversion rate, average deal size. Dashboard Zone 3c built in Session 28.

### Usability

- [ ] **Keyboard shortcuts** — `N` new record in current view, `S` save, `/` focus search. High ROI for daily users.
- [ ] **Bulk operations** — multi-select rows in AR/AP to mark as sent, batch-apply a payment, or export selected.
- [ ] **Global search / command palette** — `Ctrl+K` to jump to any client, invoice, or bill by number/name.

### Integration

- [x] **Workshop / Job Cards module** — fully assimilated into the ERP in Session 21; no longer a separate app integration. Schema lives in the ERP Supabase project.
- [ ] **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice. Now feasible as a same-project query (no cross-project integration needed).

---

## Next Up

### To Do

- [ ] **Enable leaked password protection** — Supabase Dashboard → Authentication → Passwords. Cannot be set via SQL/MCP — requires a manual dashboard toggle.
- [ ] **Job → Invoice link** — completed job's costing summary pre-fills a Meridian invoice (Session 21)
- [ ] **Job Cards PDF** — printable job card / work order report for the workshop floor
- [ ] **Work Orders in Client 360** — add `contact_id` FK to `jobs` table then wire into `loadClient360()`

