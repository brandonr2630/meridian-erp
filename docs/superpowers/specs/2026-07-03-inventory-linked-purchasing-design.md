# Inventory-Linked Purchasing — Design

*Date: 2026-07-03*

## Problem

Work Order Materials/Consumables (and Equipment) are entered manually in the Job Config form, with quantity, unit and cost typed by the user each time. The Finance/AP module already records every vendor purchase (`bills` → `bill_lines`), but the two systems have no connection — `bill_lines` are free-text, `config_materials`/`config_consumables`/`config_equipment` are static catalogs. Costs drift out of sync between what was actually paid and what's charged to jobs, and every purchase requires a second manual entry into Job Config to keep the dropdown usable.

## Goal

Link AP purchases to the job-costing catalogs so purchasing something updates the catalog automatically, phased toward full inventory (quantity on hand, drawn down per job) without requiring a single big-bang rebuild.

## Categories

Five parallel catalog + job-entry table pairs, mirroring the existing `config_materials`/`material_entries` pattern:

| Category | Catalog table | Job entry table | Status |
|---|---|---|---|
| Materials | `config_materials` | `material_entries` | existing |
| Hardware | `config_hardware` | `hardware_entries` | new |
| Consumables | `config_consumables` | `consumable_entries` | existing |
| Tooling | `config_tooling` | `tooling_entries` | new |
| Equipment | `config_equipment` | `equipment_entries` | existing |

Rationale for the split:
- **Hardware** separated from Materials: fasteners/bearings/bushings are bought by part number/size from different suppliers than raw stock, and machine-shop job costing typically reports them as a distinct BOM line from raw material.
- **Tooling** separated from Consumables: cutting tools/inserts have a materially different unit-cost profile (often $20–200/unit vs. bulk-cheap shop supplies) and are commonly reported as their own cost line, distinct from general shop consumables.
- **Fuel** is explicitly excluded from inventory scope — it's a just-in-time purchase, never stocked. `config_fuel` exists only as a price reference (name, default unit price), synced from AP purchases the same way as other categories (Phase 1 only), with no `qty_on_hand`/ledger. Fuel is logged as a sub-entry on `equipment_entries` (tied to the specific generator/vehicle that burned it), not as a top-level job-entry category, since it's an operating cost of running a specific asset rather than a BOM item.
- **Equipment** stays asset-registry only — never consumed, no quantity concept, no stock ledger (see Equipment rule below).

New catalog tables (`config_hardware`, `config_tooling`, `config_fuel`) mirror the existing shape: `item_name`, `unit`, `default_unit_cost_ttd`, `status`, `is_active`. `config_hardware` additionally gets `size`/`spec` fields since fasteners are selected by thread/size, not name alone.

Work Order Costing Summary gains two new line items to match: Labour · Materials · **Hardware** · Consumables · **Tooling** · Equipment · Sub-contractors.

## Equipment purchase rule

An AP bill line tagged as an Equipment purchase always creates a **new** `config_equipment` row (new asset_no, name, cost, workshop/onsite rate) — never links to/updates an existing row. Equipment purchases are asset acquisitions, not restocks; a major component replacement on an existing machine is a repair cost, not an equipment purchase, and belongs on a plain (unlinked) bill line or under Hardware/Consumables if the part itself is catalogued.

## Phase 1 — AP → Catalog Link (cost sync only, no stock)

**Schema:** `bill_lines` gains two nullable columns:
- `item_category` (`material` / `hardware` / `consumable` / `tooling` / `equipment`, null = today's plain free-text line — the default for every existing bill type: rent, subcontractor invoices, utilities, etc.)
- `item_id`

**UI:** each bill line gets a "Link to Inventory" toggle, off by default. When on:
- Materials/Hardware/Consumables/Tooling: searchable picker of existing catalog items, or "+ Add new item" inline to create the catalog row on the fly.
- Equipment: no picker — always the "new asset" fields (name, asset_no, workshop rate, onsite rate), per the Equipment purchase rule above.

**On bill approval** (`approveBill()`):
- Materials/Hardware/Consumables/Tooling lines → PATCH the linked catalog row's `default_unit_cost_ttd` to the bill's unit price; also stamp `last_purchased_date` and `last_vendor_id` for reference.
- Fuel lines → same cost-sync PATCH on `config_fuel`, no stock effect.
- Equipment lines → INSERT a new `config_equipment` row using the line's data. Done at **approval** time, not draft time, so an edited or voided draft bill never creates an orphaned asset.

End state: the Work Order form is functionally unchanged (still a plain dropdown, no qty-on-hand, nothing blocks). This phase only kills the duplicate typing and cost drift — every purchase keeps the catalog current automatically instead of a manual Job Config edit after the fact.

## Phase 2 — Stock Ledger (quantities on hand)

**New table `stock_moves`:** `company_id`, `item_category`, `item_id`, `move_type` (`purchase` / `consumption` / `adjustment`), `qty_delta` (positive for purchase/adjustment-in, negative for consumption), `unit_cost_ttd` (cost at the moment of the move), `ref_type`/`ref_id` (points back to the `bill_id` or `job_id` that caused the move), `moved_at`, `created_by`.

**Catalog tables gain two columns** — Materials, Hardware, Consumables, Tooling only (not Equipment, not Fuel):
- `qty_on_hand`
- `avg_unit_cost_ttd` — weighted-average cost, becomes the real job-costing rate. `default_unit_cost_ttd` (from Phase 1) remains as a "last purchase price" reference field, not the rate charged to jobs.

**Bill approval** now also inserts a `+qty` `stock_moves` row and recalculates the weighted average:
`new_avg = (qty_on_hand·avg_cost + purchased_qty·purchase_cost) / (qty_on_hand + purchased_qty)`

**Job save** (`jcSaveJobData()`) now also inserts a `−qty` `stock_moves` row per Materials/Hardware/Consumables/Tooling line entered, using the catalog's *current* `avg_unit_cost_ttd` as the job-charge rate instead of a user-typed cost. This is where manual cost entry is fully eliminated: the user still picks the item and types the quantity in the job form; cost is derived, not typed.

Job form UI is otherwise unchanged in this phase — still a plain catalog dropdown, no stock warnings yet, no blocking.

## Phase 3 — Enforcement in the Job Form

- Materials/Hardware/Consumables/Tooling dropdowns display `qty_on_hand` next to each item (e.g. "M8 Hex Bolt — 340 on hand").
- Entering a quantity greater than `qty_on_hand` shows a **warning, not a hard block** — shops routinely draw against stock that hasn't been logged yet, or need to work while temporarily negative. Blocking would stop real work over a data-entry lag rather than a genuine shortage.
- Saving still writes the `stock_moves` row and lets `qty_on_hand` go negative — a negative balance is itself the signal something's out of sync (missed purchase entry, miscount), not a state to prevent.

## Phase 4 (named, not designed)

Reorder points / low-stock alerts, once real usage data from Phases 1–3 exists to make thresholds meaningful. Out of scope for this spec; flagged so it isn't lost.

## Out of scope

- FIFO/lot-level costing (weighted-average only)
- Physical stock counts / cycle-count reconciliation UI
- Fuel quantity tracking (explicitly just-in-time, no stock)
- Reorder alerts (Phase 4)
