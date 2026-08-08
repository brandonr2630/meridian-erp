# Purchase Orders — Design

*Date: 2026-08-08*

## Purpose

Meridian ERP's AP module currently starts at Bills — a vendor invoice already in hand, with no upstream record of what was ordered. This adds a Purchase Order (PO) module upstream of Bills: raise a PO, send it to the vendor, then match the vendor's invoice back to it when creating the Bill. Also splits multi-delivery/partial-supply purchases across several Bills against one PO.

## Placement

New "Purchase Orders" nav item under **Finance → Transactions**, positioned between Accounts Payable and Vendors. Gated on the existing `finance:ap:read` / `finance:ap:write` permission atoms — no new RBAC atoms, no role-JSONB migration required for existing companies/roles.

## Data model

New tables (Supabase migration via MCP, following this project's established conventions: `for all to authenticated using (true) with check (true)` RLS scoped `to authenticated`, `company_id` FK on every row, indexes matching sibling tables):

### `purchase_orders`
| Column | Notes |
|---|---|
| `id` | PK |
| `company_id` | FK, scopes to current company |
| `po_no` | Sequential, e.g. `PO-0001`. Assigned via the existing `sequence_counters` table (`company_id` + `sequence_type`), same client-side fetch-increment-patch used by `approveBill()` — new row with `sequence_type: 'po'`, `prefix: 'PO-'`. **Assigned on Send, not on Draft save** — mirrors Bill numbering (assigned at approval) so abandoned drafts don't burn sequence numbers, same rationale as the Session 36 job-numbering fix |
| `vendor_id` | FK → vendors |
| `po_date` | |
| `expected_date` | nullable |
| `currency` | TTD/USD/GYD, matches vendor/company convention |
| `notes` | |
| `status` | `draft` \| `open` \| `closed` \| `cancelled` |
| `created_by`, `created_at`, `updated_at` | standard audit columns |

### `po_lines`
| Column | Notes |
|---|---|
| `id` | PK |
| `po_id` | FK → purchase_orders, `ON DELETE CASCADE` |
| `company_id` | FK |
| `line_no` | Sequential integer per PO, auto-assigned on line add (the "Ref" column) |
| `description` | free text |
| `unit` | free text |
| `rate` | numeric |
| `qty` | numeric |
| `amount` | `rate * qty`, stored for display/PDF consistency with other line-item tables in this app |

### `bill_lines` (existing table — additive only)
| Column | Notes |
|---|---|
| `po_id` | nullable FK → purchase_orders |
| `po_line_id` | nullable FK → po_lines |

No other changes to `bill_lines` or to `saveBill()`'s core write path. A Bill line with `po_line_id = null` behaves exactly as it does today.

### Remaining quantity — computed, not stored

```
remaining(po_line) = po_lines.qty − SUM(bill_lines.qty
  WHERE bill_lines.po_line_id = po_line.id
  AND bill.status != 'voided')
```

Computed on read (PO detail view, Bill's PO-line picker), not maintained as a running counter. This means Void Bill and Edit Bill need **zero** special-case logic for PO consumption — voiding or editing a bill simply changes what the aggregate sums over. A PO auto-transitions to `closed` when every line's remaining qty is 0; recomputed after each Bill save that references the PO. Manual early-close also available (escape hatch for a PO the user considers done despite qty remaining, e.g. vendor substitution).

## PO modal

- **Header fields:** Vendor, PO# (shows "Draft" until Send; assigned at Send), PO Date, Expected Date, Currency, Notes.
- **Line items table:** Ref (auto line_no) | Description | Unit | Rate | Qty | Amount, add/remove rows, running total footer.
- **Actions:** Save as Draft. **Send** — transitions `draft → open`, triggers the PDF/email flow (see below). **Duplicate as new** — available from any status, creates a fresh Draft PO copying vendor + all lines (qty editable, new PO# assigned), used as a template for repeat orders. Manual **Close** / **Cancel** actions per status rules above.

## PDF & email

Reuses the existing `generatePDFBase64()` + `send-document-email` Edge Function pipeline already serving invoice/quotation/delivery-note/credit-note/receipt/work-order-receipt/AR-statement — PO becomes the 8th document type in `_buildEmailPDF`. Print (🖨) and email (✉️) buttons on the PO detail view, same UI pattern as AR/Quotations.

## Bill integration

1. User opens a new/draft Bill, selects a Vendor.
2. A "Link Purchase Order" dropdown appears, listing that vendor's `open`-status POs (scoped to `currentCompany.id`).
3. Selecting a PO auto-populates the Bill's line items from that PO's lines where remaining qty > 0 — description/unit/rate pre-filled, qty defaulted to the remaining amount. Each auto-populated row carries an **exclude** checkbox so the user can drop lines not yet supplied in this delivery (they remain available on the PO for a future Bill).
4. User may still add extra manual lines with no `po_line_id` (freight, misc charges) alongside the PO-sourced ones.
5. On save, each Bill line carries `po_id`/`po_line_id` where applicable. The AP record/detail view displays PO# and PO date for any bill that references one.
6. After save, the linked PO(s) are recomputed for auto-close per the remaining-qty rule above.
7. If a Bill line's qty exceeds that PO line's current remaining qty, the save is **not** blocked — a warning is shown and the user may proceed (handles vendor over-delivery / substitutions).

## What stays untouched

- Existing Bill create/edit/void/approve logic — unchanged except for the two new optional columns and the pre-fill step, which only activates when a PO is explicitly selected.
- Existing inventory-linked catalog sync (Session 43's `item_category`/`item_id` on `bill_lines`) — entirely separate concept from PO lines; both can coexist on the same bill line if needed later, but this phase does not connect them.
- No changes to RBAC atoms, roles, or any other module's nav/permissions.

## Manual verification plan (no automated tests exist in this repo)

1. Create a Draft PO with 3 lines, save, confirm PO# assigned.
2. Send it — confirm status → `open`, PDF renders correctly, email delivers via Resend.
3. Create a Bill for the same vendor, confirm the PO appears in the picker, select it, confirm lines auto-populate with correct remaining qty.
4. Exclude one line, reduce qty on another (partial), save the Bill — confirm PO stays `open`, remaining qty on the picker reflects the partial consumption on a second Bill attempt.
5. Fully consume all lines across one or more Bills — confirm PO auto-closes.
6. Void one of the Bills — confirm the PO's remaining qty recomputes back up (reopens if it had auto-closed).
7. Duplicate a Closed PO as a new template — confirm new Draft PO with fresh PO#, same vendor/lines, qty editable.
8. Regression: create/edit/void a plain Bill with no PO link — confirm unchanged behavior.
9. Delete all test data (POs, po_lines, test bills/JEs) via SQL, confirm zero residue — matching this project's existing live-verification convention.
