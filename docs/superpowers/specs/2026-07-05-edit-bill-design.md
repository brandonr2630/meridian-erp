# Edit Bill (AP) — Design

*Date: 2026-07-05 · Session 44*

## Problem

AP bills have no edit path once created — bill rows only ever expose Pay/Void/History. Discovered when a user tried to open an approved bill to retroactively link its lines to the inventory catalog (a capability that only exists in the New Bill creation modal). Bills also can't have simple errors (wrong qty, wrong description, unlinked line) corrected without voiding and recreating the whole document.

## Goals

- Let an admin edit a Draft or Approved bill's line items and notes.
- Preserve a full audit trail: who edited, when, why, and what the lines looked like before.
- Reuse existing patterns (New Bill modal, approval-time catalog sync) rather than building parallel machinery.

## Non-goals

- Editing header fields (vendor, bill date, due date, currency, tax rate) — out of scope for this feature.
- Editing bills with payments recorded (Partial/Paid) or Void bills — these stay locked, matching the existing safety boundary in `voidBill()`.
- Row-level locking / concurrent-edit conflict detection — not present anywhere else in this app; not introduced here either.

## Editable statuses

Only `draft` and `approved` bills are editable — i.e., bills with zero payments recorded. This matches `voidBill()`'s existing refusal to void a bill with payments, so the "no payments yet" boundary is consistent across void and edit.

## Data model

Two new tables, both scoped by RLS to `to authenticated using (true) with check (true)` (this table family's established convention — must specify `to authenticated` explicitly or Postgres silently widens the policy to `public`).

### `bill_edit_events`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `bill_id` | uuid, FK → `bills(id)` ON DELETE CASCADE | |
| `edited_by` | uuid, FK → `auth.users(id)` ON DELETE SET NULL | |
| `edited_at` | timestamptz, default `now()` | |
| `reason` | text, NOT NULL | Required — UI blocks save on empty. |

One row per edit-save.

### `bill_lines_archive`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `edit_event_id` | uuid, FK → `bill_edit_events(id)` ON DELETE CASCADE | |
| `original_line_id` | uuid | The `bill_lines.id` this row was copied from, pre-delete. |
| `description`, `quantity`, `unit_price`, `amount`, `line_order`, `item_category`, `item_id` | same types as `bill_lines` | Snapshot of the line as it existed immediately before this edit. |

No header-snapshot table. Header fields (`bills` row) never change post-creation under this feature, so there's nothing to archive there — `bill_edit_events` already captures who/when/why per edit.

## UI

**Entry point:** a new "Edit" button on bill rows, next to Pay/Void/History, shown only when `status IN ('draft','approved')` and `isAdmin()` is true.

**Modal:** reuses the existing New Bill modal in an edit mode:
- Vendor, bill date, due date, currency, tax rate — rendered disabled/read-only, pre-filled from the bill.
- Line items (description/qty/price, item-link picker) — editable, pre-filled. The item-link picker pre-fills each line's existing `item_category`/`item_id` so admins can add links to previously-unlinked lines without disturbing already-linked ones.
- Notes — editable, pre-filled.
- New required **"Reason for edit"** textarea. Save is blocked client-side if empty.

**History modal:** the existing History modal (currently payment history only) gets a second tab, "Edits":
- Lists `bill_edit_events` for the bill (who/when/reason), newest first.
- Expanding a row shows that event's `bill_lines_archive` rows — the lines as they existed right before that edit was saved.

## Save sequence

1. Client validates the reason field is non-empty; blocks submit otherwise.
2. INSERT into `bill_edit_events` (`bill_id`, `edited_by`, `edited_at`, `reason`) → capture returned `id` as `edit_event_id`.
3. Fetch the bill's current `bill_lines` rows; bulk-INSERT copies into `bill_lines_archive`, each tagged with `edit_event_id` and `original_line_id`.
4. `sbDeleteWhere` the bill's existing `bill_lines`; `sbPost` the new edited set. Every inserted line object uses the same explicit 8-key shape (defaulting `item_category`/`item_id` to `null` where unset) established in PR #119, to avoid PostgREST's "All object keys must match" bulk-insert rejection.
5. Recalculate `subtotal`, `tax_amount`, `total` on the `bills` row from the new lines. `balance_due` is set equal to `total` — safe because editable bills by definition have zero payments recorded.
6. PATCH the bill's `notes` field.
7. Re-run the Phase-1 `jcSyncBillCatalogOnApproval` catalog-sync logic across every line carrying a non-null `item_id` — idempotent (re-patches current cost, or creates the catalog item if still unset), identical to the approval-time behavior from Session 43.
8. Show a success toast, close the modal, reload the bill list.

If any step after (2) fails, the archive row from step (2)/(3) remains — this is acceptable: an orphaned archive/edit-event with no corresponding line change is a hint for manual review, not a data-integrity break, and matches this codebase's existing no-cross-call-transaction pattern (there is no cross-REST-call transaction anywhere else in this app either).

## Permissions

Both the Edit button's visibility and the save action are gated on `isAdmin()` (`can('admin:users') || can('admin:settings')`) — the established pattern for admin-only actions in this codebase (e.g. Job Config, User Management). No new RLS restriction beyond standard `to authenticated` on the two new tables; enforcement is client-side, consistent with how the rest of this app gates admin actions.

## Out-of-scope follow-ups (not part of this spec)

- Editing bills after payments exist (would require payment/GL reversal logic — a much larger feature).
- Concurrent-edit conflict detection.
- Bulk/multi-bill edit.
