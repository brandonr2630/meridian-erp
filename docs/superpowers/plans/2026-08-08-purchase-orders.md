# Purchase Orders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Purchase Orders module to Meridian ERP — raise a PO with vendor/line items, send it (PDF+email), and link it to a Bill so the Bill's AP record carries the PO reference and PO line quantities are consumed as bills are recorded against them.

**Architecture:** Two new tables (`purchase_orders`, `po_lines`) plus two nullable columns on the existing `bill_lines` table (`po_id`, `po_line_id`). Remaining quantity is computed on read (never a stored counter), so Void Bill and Edit Bill need no special-case PO logic. Everything else — nav, modal, PDF/email, permissions — clones an existing pattern already in `index.html` (Quotation modal, Bill numbering via `sequence_counters`, `_buildEmailPDF` dispatcher, `deleteDocument()`), so the diff style matches the rest of the file.

**Tech Stack:** Vanilla HTML/CSS/JS (single file `index.html`), Supabase (Postgres + PostgREST + Edge Functions), no build step, no test framework — verification is manual SQL + live click-through, per this repo's existing convention (see Task 15).

**Reference:** Design spec at `docs/superpowers/specs/2026-08-08-purchase-orders-design.md`. Supabase project ID: `fcagxvjxfqqkmuposmcb` (same project referenced in Session 43/45 of `handoff.md`).

---

## Task 1: Database schema

**Files:** None (Supabase migration applied via MCP `apply_migration` tool, matching the existing convention for this table family — no local `.sql` migration files, per `handoff.md` Session 43's note: "no local migration files — matches existing convention for this table family").

- [ ] **Step 1: Apply the `purchase_orders` + `po_lines` migration**

Call `mcp__cbe5a78d-ee58-4abb-96d1-379347f3fbe3__apply_migration` with project_id `fcagxvjxfqqkmuposmcb`, name `add_purchase_orders`, and this SQL:

```sql
create table purchase_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  po_no text,
  vendor_id uuid not null references contacts(id),
  po_date date not null default current_date,
  expected_date date,
  currency text not null default 'TTD',
  payment_terms text,
  incoterms text,
  incoterms_place text,
  vendor_quote_basis text check (vendor_quote_basis in ('written','verbal')),
  vendor_quote_ref text,
  vendor_quote_date date,
  notes text,
  prepared_by text,
  status text not null default 'draft' check (status in ('draft','open','closed','cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_purchase_orders_company on purchase_orders(company_id);
create index idx_purchase_orders_vendor on purchase_orders(vendor_id);

alter table purchase_orders enable row level security;

create policy po_select on purchase_orders for select to authenticated
  using (company_id in (select my_company_ids()));
create policy po_insert on purchase_orders for insert to authenticated
  with check (company_id in (select my_company_ids()));
create policy po_update on purchase_orders for update to authenticated
  using (company_id in (select my_company_ids()))
  with check (company_id in (select my_company_ids()));
create policy po_delete on purchase_orders for delete to authenticated
  using (company_id in (select my_company_ids()));

create table po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references purchase_orders(id) on delete cascade,
  company_id uuid not null references companies(id),
  line_no int not null,
  description text not null,
  unit text,
  rate numeric not null default 0,
  qty numeric not null default 0,
  amount numeric not null default 0
);

create index idx_po_lines_po on po_lines(po_id);
create index idx_po_lines_company on po_lines(company_id);

alter table po_lines enable row level security;

create policy po_lines_select on po_lines for select to authenticated
  using (company_id in (select my_company_ids()));
create policy po_lines_insert on po_lines for insert to authenticated
  with check (company_id in (select my_company_ids()));
create policy po_lines_update on po_lines for update to authenticated
  using (company_id in (select my_company_ids()))
  with check (company_id in (select my_company_ids()));
create policy po_lines_delete on po_lines for delete to authenticated
  using (company_id in (select my_company_ids()));

alter table bill_lines add column po_id uuid references purchase_orders(id);
alter table bill_lines add column po_line_id uuid references po_lines(id);
create index idx_bill_lines_po_line on bill_lines(po_line_id);
```

- [ ] **Step 2: Verify the migration**

Call `mcp__cbe5a78d-ee58-4abb-96d1-379347f3fbe3__list_tables` with project_id `fcagxvjxfqqkmuposmcb`, schema `public`. Confirm `purchase_orders` and `po_lines` appear with RLS enabled, and that `bill_lines` now has `po_id`/`po_line_id` columns.

- [ ] **Step 3: Check advisors**

Call `mcp__cbe5a78d-ee58-4abb-96d1-379347f3fbe3__get_advisors` with project_id `fcagxvjxfqqkmuposmcb`, type `security`. Confirm no new warnings referencing `purchase_orders` or `po_lines` (e.g. no "RLS enabled, no policy" — all 4 policies per table are in place above).

- [ ] **Step 4: Add `NO_UPDATED_AT` check**

`po_lines` has no `updated_at` column (matching the `bill_lines` sibling table, which also has none — confirm by checking whether `bill_lines` is in the `NO_UPDATED_AT` set at `index.html` — grep `NO_UPDATED_AT`). If `bill_lines` is listed there, add `'po_lines'` to the same `Set`. `purchase_orders` DOES have `updated_at`, so it does NOT go in that set.

No commit yet — this task has no file changes in the repo (migration lives in Supabase only, consistent with existing convention). Proceed to Task 2.

---

## Task 2: State, Q helper, loadPurchaseOrders(), DELETE_CONFIG entry

**Files:**
- Modify: `meridian-erp/index.html` (state block near line 12889 `// ── AP STATE ──`, `Q` object near line 5691, `DELETE_CONFIG` at line ~16496)

- [ ] **Step 1: Add state variables**

Find the `// ── AP STATE ──` comment block (line 12889-12894):
```js
// ── AP STATE ──────────────────────────────────────────────────────
let bills = [], _apFiltered = []; let apPage = 0;
let _billsWithEditHistory = new Set();
let _billEditId = null;
let _apRowMenuActions = {};
let apSortCol = null, apSortDir = 'asc';
```

Add immediately after it:
```js

// ── PURCHASE ORDER STATE ────────────────────────────────────────────
let purchaseOrders = [], poLines = [];
let _poEditId = null;
let _poRowMenuActions = {};
let poSortCol = null, poSortDir = 'asc';
```

- [ ] **Step 2: Add a `Q.purchaseOrders` fetch helper**

Find the `Q` object (starts line 5691). Add a new entry alongside `vendors`:
```js
purchaseOrders: () => `company_id=eq.${currentCompany.id}&order=po_date.desc`,
```

- [ ] **Step 3: Write `loadPurchaseOrders()`**

Add this function near `loadVendors()` (search for `async function loadVendors()`):
```js
async function loadPurchaseOrders() {
  purchaseOrders = await sbGet('purchase_orders', Q.purchaseOrders());
  renderPOTable(purchaseOrders);
}
```
(`renderPOTable` is written in Task 4 — this will show as undefined until then; that's expected mid-plan.)

- [ ] **Step 4: Register PO in `DELETE_CONFIG`**

Find `DELETE_CONFIG` (line ~16496):
```js
const DELETE_CONFIG = {
  invoice:       { table: 'invoices',       linesTable: 'invoice_lines',       linesCol: 'invoice_id',  reload: () => loadAR() },
  quotation:     { table: 'quotations',     linesTable: 'quotation_lines',     linesCol: 'quotation_id', reload: () => loadQuotations() },
  bill:          { table: 'bills',          linesTable: 'bill_lines',          linesCol: 'bill_id',     reload: () => loadAP() },
  delivery_note: { table: 'delivery_notes', linesTable: 'delivery_note_lines', linesCol: 'dn_id',       reload: () => loadDeliveryNotes() },
  credit_note:   { table: 'credit_notes',   linesTable: 'credit_note_lines',   linesCol: 'cn_id',       reload: () => loadCreditNotes() },
};
```
Add a `purchase_order` entry:
```js
  purchase_order: { table: 'purchase_orders', linesTable: 'po_lines',           linesCol: 'po_id',       reload: () => loadPurchaseOrders() },
```

- [ ] **Step 5: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): add PO state, Q helper, loadPurchaseOrders, delete config"
```

---

## Task 3: Nav item, VIEW_SECTIONS, module guard, view dispatch

**Files:**
- Modify: `meridian-erp/index.html` (sidebar ~line 1981, `VIEW_SECTIONS` ~line 6179, `navigate()` guard ~line 6239, `loadViewData()` switch ~line 6313)

- [ ] **Step 1: Add sidebar nav item**

Find the Vendors nav item (line 1981-1983):
```html
<div class="nav-item sub-item" data-perm="finance:ap:read" onclick="navigate('vendors')" id="nav-vendors">
  <span class="nav-item-icon">🏭</span> Vendors
</div>
```
Insert a new item immediately **before** it (so order is AP → Purchase Orders → Vendors):
```html
<div class="nav-item sub-item" data-perm="finance:ap:read" onclick="navigate('purchase-orders')" id="nav-purchase-orders">
  <span class="nav-item-icon">📑</span> Purchase Orders
</div>
```

- [ ] **Step 2: Add to `VIEW_SECTIONS`**

Find line 6182 (`vendors: ['finance', 'finance-transactions'],`) and add a sibling entry:
```js
'purchase-orders': ['finance', 'finance-transactions'],
```

- [ ] **Step 3: Add to `navigate()`'s module/subGuard**

Find the `moduleGuard.finance` array (line ~6242) and add `'purchase-orders'`:
```js
finance:    ['coa','journal','ar','credit-notes','ap','vendors','purchase-orders','bank','pl','bs','tb','cf','aged-ar','aged-ap'],
```
Find the `subGuard` row `[['ap','vendors'], u.module_finance_ap === false]` (line ~6255) and extend it:
```js
[['ap','vendors','purchase-orders'],   u.module_finance_ap      === false],
```
(This means Purchase Orders shares the same `module_finance_ap` toggle as AP/Vendors — no new per-company module flag needed.)

- [ ] **Step 4: Add to `loadViewData()` dispatch**

Find `case 'vendors':   await loadVendors(); break;` (line ~6313) and add immediately after:
```js
case 'purchase-orders': await loadPurchaseOrders(); break;
```

- [ ] **Step 5: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): wire Purchase Orders into nav, view sections, and dispatch"
```

---

## Task 4: PO list view + `renderPOTable()`

**Files:**
- Modify: `meridian-erp/index.html` (add a new `<div id="view-purchase-orders">` alongside `<div id="view-ap">` / `<div id="view-vendors">` in the views markup, and a `renderPOTable()` function near `renderAPTable()`)

- [ ] **Step 1: Find the AP view's page markup structure**

Grep `id="view-ap"` in `index.html` to find its containing `<div class="page-body">...<div class="table-wrap">...<table>...` structure (same wrapper `renderAPTable()` targets). Copy that structural skeleton (header row with a "+ New Purchase Order" button in place of AP's equivalent add button, and a `<div class="table-wrap"><table id="po-table">...<tbody id="po-table-body"></tbody></table></div>`).

- [ ] **Step 2: Add `<div id="view-purchase-orders">`**

Immediately after the closing `</div>` of `<div id="view-vendors">` (or immediately before it — placement in the DOM doesn't affect nav order, only the sidebar markup from Task 3 does), add:

```html
<div id="view-purchase-orders" class="view">
  <div class="page-header">
    <div class="page-title">Purchase Orders</div>
    <button class="btn btn-primary btn-sm" data-perm="finance:ap:write" onclick="openNewPO()">+ New Purchase Order</button>
  </div>
  <div class="page-body">
    <div class="table-wrap">
      <table class="data-table" id="po-table">
        <thead>
          <tr>
            <th>PO No.</th><th>Vendor</th><th>Date</th><th>Expected</th>
            <th>Currency</th><th class="right">Total</th><th>Status</th><th class="right">Actions</th>
          </tr>
        </thead>
        <tbody id="po-table-body"></tbody>
      </table>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Write `renderPOTable(list)`**

Add near `renderAPTable()`. Uses the same row-local status-derived-booleans pattern documented in `renderAPTable` (not global `canApprove()`), plus the `contactMap`/vendor-name-join pattern:

```js
function renderPOTable(list) {
  const contactMap = Object.fromEntries(contacts.map(c => [c.id, c.trading_name || c.name]));
  const tbody = document.getElementById('po-table-body');
  if (!list.length) {
    tbody.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--text-3);padding:24px;">No purchase orders yet.</td></tr>`;
    return;
  }
  tbody.innerHTML = list.map(po => {
    const canSend   = po.status === 'draft'  && can('finance:ap:approve');
    const canEdit   = po.status === 'draft'  && can('finance:ap:write');
    const canClose  = po.status === 'open'   && can('finance:ap:approve');
    const canCancel = ['draft','open'].includes(po.status) && can('finance:ap:approve');

    const primaryBtn = canSend
      ? `<button class="btn btn-outline btn-sm" onclick="sendPO('${po.id}')">Send</button>`
      : '';

    const menuActions = [];
    if (po.status === 'draft' && can('finance:ap:write')) menuActions.push({ label: 'Delete', onclick: `deleteDocument('purchase_order','${po.id}','${po.po_no||'this draft PO'}')` });
    if (canEdit)   menuActions.push({ label: 'Edit',       onclick: `openEditPO('${po.id}')` });
    menuActions.push({ label: 'Duplicate as new', onclick: `duplicatePO('${po.id}')` });
    if (po.status !== 'draft') {
      menuActions.push({ label: 'Print',  onclick: `openPOPDF('${po.id}')` });
      menuActions.push({ label: 'Email',  onclick: `openEmailDocument('purchase-order','${po.id}')` });
    }
    if (canClose)  menuActions.push({ label: 'Close PO',  onclick: `closePO('${po.id}')` });
    if (canCancel) menuActions.push({ label: 'Cancel PO', onclick: `cancelPO('${po.id}')` });

    _poRowMenuActions[po.id] = menuActions;

    return `<tr>
      <td class="mono bold">${po.po_no || '<span style="color:var(--text-3);font-style:italic;font-size:11px;">Draft</span>'}</td>
      <td>${escHTML(contactMap[po.vendor_id] || '—')}</td>
      <td>${formatDateDisplay(po.po_date)}</td>
      <td>${po.expected_date ? formatDateDisplay(po.expected_date) : '—'}</td>
      <td>${po.currency}</td>
      <td class="right mono">${fmt(po._total ?? 0, po.currency)}</td>
      <td><span class="badge badge-${po.status}">${po.status}</span></td>
      <td class="right">${primaryBtn} <button class="btn btn-ghost btn-icon btn-sm" onclick="togglePORowMenu('${po.id}', this)">⋯</button></td>
    </tr>`;
  }).join('');
}
```

Note: `po._total` is not a DB column — Step 4 below covers computing/attaching it after fetch (line-item totals live in `po_lines`, not on the header row). `togglePORowMenu` should reuse whatever the existing AP row-menu toggler does (grep `toggleApRowMenu` from `handoff.md`'s Session 46 note — clone it as `togglePORowMenu` reading from `_poRowMenuActions` instead of `_apRowMenuActions`). `badge-draft`/`badge-open`/`badge-closed`/`badge-cancelled` CSS classes don't exist yet — Step 5 adds them.

- [ ] **Step 4: Attach computed totals in `loadPurchaseOrders()`**

Update the function from Task 2 Step 3 to fetch lines and sum them per PO:

```js
async function loadPurchaseOrders() {
  purchaseOrders = await sbGet('purchase_orders', Q.purchaseOrders());
  if (purchaseOrders.length) {
    const ids = purchaseOrders.map(p => p.id).join(',');
    const lines = await sbGet('po_lines', `po_id=in.(${ids})`);
    const totalsByPO = {};
    lines.forEach(l => { totalsByPO[l.po_id] = (totalsByPO[l.po_id] || 0) + parseFloat(l.amount || 0); });
    purchaseOrders.forEach(p => { p._total = totalsByPO[p.id] || 0; });
  }
  renderPOTable(purchaseOrders);
}
```

- [ ] **Step 5: Add badge CSS**

Find the existing `.badge-*` CSS rules (grep `.badge-void` or `.badge-paid` to find the block) and add alongside them:
```css
.badge-draft { background: var(--bg-3); color: var(--text-2); }
.badge-open { background: #2a4d3a; color: #7fd99a; }
.badge-closed { background: var(--bg-3); color: var(--text-3); }
.badge-cancelled { background: #4d2a2a; color: #d97f7f; }
```
(Match the exact color values used by the nearest existing status-badge rule instead of these placeholders — copy the file's real `--bg-3`/success/danger tone pairing so it's visually consistent, not a guess.)

- [ ] **Step 6: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): add Purchase Orders list view and table renderer"
```

---

## Task 5: PO modal HTML

**Files:**
- Modify: `meridian-erp/index.html` (new `#modal-po` block, placed near `#modal-quotation`)

- [ ] **Step 1: Add the modal skeleton**

Clone the `#modal-quotation` wrapper structure (lines 4747-4761) for a new `#modal-po`:

```html
<div class="modal-overlay" id="modal-po" onclick="if(event.target===this)closeModal('modal-po')">
  <div class="modal modal-lg" style="max-width:880px;">
    <div class="modal-header">
      <div>
        <div class="modal-title" id="modal-po-title">New Purchase Order</div>
        <div style="font-size:11px;color:var(--text-3);margin-top:3px;">
          PO Number: <span style="font-family:'DM Mono',monospace;color:var(--gold);" id="po-number-label">assigned on send</span>
        </div>
      </div>
      <button class="modal-close" onclick="closeModal('modal-po')">✕</button>
    </div>
    <input type="hidden" id="po-edit-id">
    <div class="modal-body">
```

- [ ] **Step 2: Header fields**

```html
      <div class="form-grid grid-3">
        <div class="field span-2">
          <label class="field-label">Vendor</label>
          <div class="contact-search-wrap">
            <input type="text" id="po-vendor-search" placeholder="Search vendor…" autocomplete="off"
                   oninput="searchPOVendor()" onfocus="searchPOVendor()">
            <div class="contact-search-results" id="po-vendor-results"></div>
          </div>
          <input type="hidden" id="po-vendor-id">
          <div style="font-size:11px;color:var(--gold);margin-top:4px;" id="po-vendor-selected"></div>
        </div>
        <div class="field">
          <label class="field-label">Currency</label>
          <select id="po-currency">
            <option value="TTD">TTD — Trinidad Dollar</option>
            <option value="USD">USD — US Dollar</option>
            <option value="GYD">GYD — Guyana Dollar</option>
          </select>
        </div>
        <div class="field">
          <label class="field-label">PO Date</label>
          <input type="date" id="po-date" class="mono">
        </div>
        <div class="field">
          <label class="field-label">Expected Date</label>
          <input type="date" id="po-expected-date" class="mono">
        </div>
        <div class="field">
          <label class="field-label">Payment Terms</label>
          <select id="po-terms">
            <option value="0">Due on Receipt</option>
            <option value="7">Net 7</option>
            <option value="14">Net 14</option>
            <option value="30" selected>Net 30</option>
            <option value="60">Net 60</option>
          </select>
        </div>
      </div>

      <div class="form-grid grid-2" style="margin-top:10px;">
        <div class="field">
          <label class="field-label">Incoterms 2020 <span style="color:var(--text-3);font-weight:400;">(optional)</span></label>
          <select id="po-incoterms">
            <option value="">— None —</option>
            <option value="EXW">EXW — Ex Works</option>
            <option value="FCA">FCA — Free Carrier</option>
            <option value="CPT">CPT — Carriage Paid To</option>
            <option value="CIP">CIP — Carriage and Insurance Paid To</option>
            <option value="DAP">DAP — Delivered at Place</option>
            <option value="DPU">DPU — Delivered at Place Unloaded</option>
            <option value="DDP">DDP — Delivered Duty Paid</option>
            <option value="FAS">FAS — Free Alongside Ship</option>
            <option value="FOB">FOB — Free On Board</option>
            <option value="CFR">CFR — Cost and Freight</option>
            <option value="CIF">CIF — Cost, Insurance and Freight</option>
          </select>
        </div>
        <div class="field">
          <label class="field-label">Named Place / Port</label>
          <input type="text" id="po-incoterms-place" placeholder="e.g. Port of Spain, Trinidad" class="mono">
        </div>
      </div>

      <div class="form-grid grid-3" style="margin-top:10px;">
        <div class="field">
          <label class="field-label">Vendor Quote Basis</label>
          <select id="po-quote-basis" onchange="togglePOQuoteFields()">
            <option value="">— None —</option>
            <option value="written">Written</option>
            <option value="verbal">Verbal</option>
          </select>
        </div>
        <div class="field" id="po-quote-ref-field" style="display:none;">
          <label class="field-label">Vendor Quote Ref</label>
          <input type="text" id="po-quote-ref" class="mono">
        </div>
        <div class="field" id="po-quote-date-field" style="display:none;">
          <label class="field-label">Vendor Quote Date</label>
          <input type="date" id="po-quote-date" class="mono">
        </div>
      </div>

      <div class="field" style="margin-top:10px;">
        <label class="field-label">Notes</label>
        <textarea id="po-notes" rows="2" placeholder="Delivery instructions, special conditions, etc."></textarea>
      </div>
```

- [ ] **Step 3: Line items table + totals + footer**

```html
      <div style="font-size:10px;font-weight:600;letter-spacing:1px;text-transform:uppercase;color:var(--text-3);margin:16px 0 8px;">Line Items</div>
      <div class="table-wrap" style="margin-bottom:10px;">
        <table class="inv-lines-table">
          <thead>
            <tr>
              <th style="width:40px;">Ref</th><th>Description</th><th style="width:90px;">Unit</th>
              <th class="right" style="width:100px;">Rate</th><th class="right" style="width:90px;">Qty</th>
              <th class="right" style="width:120px;">Amount</th><th style="width:36px;"></th>
            </tr>
          </thead>
          <tbody id="po-lines-body"></tbody>
        </table>
      </div>
      <button class="btn btn-ghost btn-sm" onclick="addPOLine()" style="margin-bottom:16px;">+ Add Line</button>

      <div style="display:flex;justify-content:flex-end;">
        <div style="min-width:260px;">
          <div class="inv-totals">
            <div class="inv-totals-row total-row">
              <span class="label">Total</span>
              <span class="val" id="po-grand-total">0.00</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="closeModal('modal-po')">Cancel</button>
      <button class="btn btn-primary" id="po-save-draft-btn" onclick="savePODraft()">Save as Draft</button>
    </div>
  </div>
</div>
```

- [ ] **Step 4: Add `togglePOQuoteFields()`**

```js
function togglePOQuoteFields() {
  const basis = document.getElementById('po-quote-basis').value;
  document.getElementById('po-quote-ref-field').style.display  = basis === 'written' ? '' : 'none';
  document.getElementById('po-quote-date-field').style.display = basis ? '' : 'none';
}
```

- [ ] **Step 5: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): add Purchase Order modal markup"
```

---

## Task 6: PO modal JS — vendor search, lines, save draft

**Files:**
- Modify: `meridian-erp/index.html`

- [ ] **Step 1: Vendor search (clone `createContactSearch` usage from Bill)**

Add near `searchBillVendor`/`selectBillVendor` (line ~11964):
```js
const searchPOVendor = createContactSearch({
  inputId:    'po-vendor-search',
  resultsId:  'po-vendor-results',
  typeFilter: c => (c.contact_type === 'supplier' || c.contact_type === 'both') && c.is_active !== false,
  subtitleFn: c => escHTML(c.name),
  onSelect:   c => selectPOVendor(c.id, c.trading_name || c.name, c.name, c.payment_terms),
});

function selectPOVendor(id, displayName, legalName, paymentTermsDays) {
  document.getElementById('po-vendor-id').value     = id;
  document.getElementById('po-vendor-search').value = displayName;
  document.getElementById('po-vendor-selected').textContent = '✓ ' + legalName;
  document.getElementById('po-vendor-results').classList.remove('open');
  if (paymentTermsDays != null) document.getElementById('po-terms').value = String(paymentTermsDays);
}
```

- [ ] **Step 2: `addPOLine()`**

Clone `addBillLine()`'s structure (no inventory-link row needed — PO lines are plain, per spec's "Ref" = sequential line number, no catalog link):
```js
function addPOLine() {
  const tbody = document.getElementById('po-lines-body');
  const n     = tbody.rows.length + 1;
  const lid   = 'pol-' + Date.now() + '-' + Math.random().toString(36).substr(2,4);
  const tr    = document.createElement('tr');
  tr.id = lid;
  tr.innerHTML = `
    <td style="padding:6px 8px;color:var(--text-3);font-size:11px;font-family:'DM Mono',monospace;">${n}</td>
    <td><input type="text" placeholder="Item description…" style="min-width:200px;" id="${lid}-desc"></td>
    <td><input type="text" class="mono" placeholder="ea" id="${lid}-unit"></td>
    <td><input type="number" class="mono" placeholder="0.00" min="0" step="0.01" oninput="recalcPOTotals()" id="${lid}-rate"></td>
    <td><input type="number" class="mono" placeholder="1" value="1" min="0" step="any" oninput="recalcPOTotals()" id="${lid}-qty"></td>
    <td><div class="inv-line-amount" id="${lid}-amt">0.00</div></td>
    <td><button class="btn btn-ghost btn-icon btn-sm" onclick="document.getElementById('${lid}').remove();recalcPOTotals();" style="color:var(--text-3);">✕</button></td>`;
  tbody.appendChild(tr);
}
```
Note: unlike `addBillLine()`, qty and rate both have explicit `id`s here (`${lid}-qty`, `${lid}-rate`) rather than relying on positional `input[type=number]` lookups — this is what lets Task 12's Bill-side auto-populate code set values by predictable id when it clones this row pattern for PO-sourced Bill lines. (Bill's own line rows keep their existing positional convention unchanged — only new PO-native rows use ids.)

- [ ] **Step 3: `recalcPOTotals()`**

```js
function recalcPOTotals() {
  let total = 0;
  document.querySelectorAll('#po-lines-body tr').forEach(tr => {
    const rate = parseFloat(document.getElementById(tr.id + '-rate')?.value) || 0;
    const qty  = parseFloat(document.getElementById(tr.id + '-qty')?.value) || 0;
    const amt  = round2(rate * qty);
    document.getElementById(tr.id + '-amt').textContent = fmtNum(amt);
    total += amt;
  });
  document.getElementById('po-grand-total').textContent = fmtNum(total);
}
```

- [ ] **Step 4: `collectPOFormLines()`**

```js
function collectPOFormLines() {
  const lines = [];
  document.querySelectorAll('#po-lines-body tr').forEach((tr, idx) => {
    const desc = document.getElementById(tr.id + '-desc')?.value.trim() || '';
    const unit = document.getElementById(tr.id + '-unit')?.value.trim() || '';
    const rate = parseFloat(document.getElementById(tr.id + '-rate')?.value) || 0;
    const qty  = parseFloat(document.getElementById(tr.id + '-qty')?.value) || 0;
    if (!desc && !rate && !qty) return;
    if (!desc) { showToast(`Line ${idx+1}: description required.`, 'warn'); return; }
    lines.push({ line_no: idx + 1, description: desc, unit, rate, qty, amount: round2(rate * qty) });
  });
  if (!lines.length) { showToast('Add at least one line item.', 'warn'); return null; }
  return lines;
}
```

- [ ] **Step 5: `openNewPO()`**

```js
function openNewPO() {
  _poEditId = null;
  document.getElementById('modal-po-title').textContent = 'New Purchase Order';
  document.getElementById('po-number-label').textContent = 'assigned on send';
  document.getElementById('po-edit-id').value = '';
  document.getElementById('po-vendor-id').value = '';
  document.getElementById('po-vendor-search').value = '';
  document.getElementById('po-vendor-selected').textContent = '';
  document.getElementById('po-currency').value = 'TTD';
  document.getElementById('po-date').value = new Date().toISOString().slice(0,10);
  document.getElementById('po-expected-date').value = '';
  document.getElementById('po-terms').value = '30';
  document.getElementById('po-incoterms').value = '';
  document.getElementById('po-incoterms-place').value = '';
  document.getElementById('po-quote-basis').value = '';
  document.getElementById('po-quote-ref').value = '';
  document.getElementById('po-quote-date').value = '';
  document.getElementById('po-notes').value = '';
  togglePOQuoteFields();
  document.getElementById('po-lines-body').innerHTML = '';
  addPOLine();
  recalcPOTotals();
  document.getElementById('modal-po').classList.add('show');
}
```

- [ ] **Step 6: `savePODraft()`**

```js
async function savePODraft() {
  const vendorId = document.getElementById('po-vendor-id').value;
  if (!vendorId) { showToast('Select a vendor.', 'warn'); return; }
  const lines = collectPOFormLines();
  if (!lines) return;

  const basis = document.getElementById('po-quote-basis').value || null;
  const payload = {
    company_id: currentCompany.id,
    vendor_id: vendorId,
    po_date: document.getElementById('po-date').value,
    expected_date: document.getElementById('po-expected-date').value || null,
    currency: document.getElementById('po-currency').value,
    payment_terms: document.getElementById('po-terms').value,
    incoterms: document.getElementById('po-incoterms').value || null,
    incoterms_place: document.getElementById('po-incoterms-place').value.trim() || null,
    vendor_quote_basis: basis,
    vendor_quote_ref: basis === 'written' ? (document.getElementById('po-quote-ref').value.trim() || null) : null,
    vendor_quote_date: basis ? (document.getElementById('po-quote-date').value || null) : null,
    notes: document.getElementById('po-notes').value.trim() || null,
    prepared_by: currentUser.name,
    created_by: currentUser.auth_user_id,
  };

  const btn = document.getElementById('po-save-draft-btn');
  btn.disabled = true; btn.textContent = 'Saving…';
  try {
    const editId = document.getElementById('po-edit-id').value;
    let poId = editId;
    if (editId) {
      await sbPatch('purchase_orders', editId, payload);
      await sbDeleteWhere('po_lines', `po_id=eq.${editId}`);
    } else {
      const [created] = await sbPost('purchase_orders', { ...payload, status: 'draft' });
      poId = created.id;
    }
    await sbPost('po_lines', lines.map(l => ({ ...l, po_id: poId, company_id: currentCompany.id })));
    showToast('Purchase order saved as draft.', 'success');
    closeModal('modal-po');
    await loadPurchaseOrders();
  } catch(e) {
    showToast('Error: ' + e.message, 'error');
  } finally {
    btn.disabled = false; btn.textContent = 'Save as Draft';
  }
}
```

- [ ] **Step 7: `openEditPO(id)`**

```js
async function openEditPO(id) {
  const po = purchaseOrders.find(p => p.id === id);
  if (!po) return;
  if (po.status !== 'draft') { showToast('Only Draft purchase orders can be edited.', 'warn'); return; }

  const vendor = contacts.find(c => c.id === po.vendor_id) || {};
  openNewPO();
  _poEditId = id;
  document.getElementById('modal-po-title').textContent = `Edit Purchase Order — Draft`;
  document.getElementById('po-edit-id').value = id;
  document.getElementById('po-vendor-id').value = po.vendor_id;
  document.getElementById('po-vendor-search').value = vendor.trading_name || vendor.name || '';
  document.getElementById('po-vendor-selected').textContent = vendor.name ? '✓ ' + vendor.name : '';
  document.getElementById('po-currency').value = po.currency;
  document.getElementById('po-date').value = po.po_date;
  document.getElementById('po-expected-date').value = po.expected_date || '';
  document.getElementById('po-terms').value = po.payment_terms || '30';
  document.getElementById('po-incoterms').value = po.incoterms || '';
  document.getElementById('po-incoterms-place').value = po.incoterms_place || '';
  document.getElementById('po-quote-basis').value = po.vendor_quote_basis || '';
  document.getElementById('po-quote-ref').value = po.vendor_quote_ref || '';
  document.getElementById('po-quote-date').value = po.vendor_quote_date || '';
  document.getElementById('po-notes').value = po.notes || '';
  togglePOQuoteFields();

  const existingLines = await sbGet('po_lines', `po_id=eq.${id}&order=line_no.asc`);
  document.getElementById('po-lines-body').innerHTML = '';
  (existingLines.length ? existingLines : [{}]).forEach(l => {
    addPOLine();
    const rows = document.querySelectorAll('#po-lines-body tr');
    const tr = rows[rows.length - 1];
    document.getElementById(tr.id + '-desc').value = l.description || '';
    document.getElementById(tr.id + '-unit').value = l.unit || '';
    document.getElementById(tr.id + '-rate').value = l.rate ?? '';
    document.getElementById(tr.id + '-qty').value  = l.qty ?? '';
  });
  recalcPOTotals();
  document.getElementById('modal-po').classList.add('show');
}
```

(Note `openNewPO()` is called first to reset the form, then overwritten with edit values — mirrors the reset-then-populate pattern used by other edit flows in this file.)

- [ ] **Step 8: Manual verification**

Open the app locally (or via `preview_start` against a checkout), log in as an admin, navigate to Purchase Orders, click **+ New Purchase Order**, pick a vendor, add 2 lines, Save as Draft. Confirm it appears in the list with status `draft` and correct total. Edit it, change a line's qty, save, confirm the total updates.

- [ ] **Step 9: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): PO modal vendor search, line items, save/edit draft"
```

---

## Task 7: Send action — PO numbering + status transition

**Files:**
- Modify: `meridian-erp/index.html`

- [ ] **Step 1: `sendPO(id)`**

Clone the `sequence_counters` idiom from `approveBill()`/`saveQuotation()`:
```js
async function sendPO(id) {
  const ok = await showConfirm('Send this purchase order? A PO number will be assigned.', 'Send Purchase Order', 'Send');
  if (!ok) return;
  try {
    const po = purchaseOrders.find(p => p.id === id);
    let poNo = po?.po_no;
    if (!poNo) {
      let counters = await sbGet('sequence_counters', `company_id=eq.${currentCompany.id}&sequence_type=eq.purchase_order`);
      let counter  = counters[0];
      if (!counter) {
        const created = await sbPost('sequence_counters', { company_id: currentCompany.id, sequence_type: 'purchase_order', prefix: 'PO-', last_number: 0, padding: 4 });
        counter = created[0];
      }
      const nextNum = (counter.last_number || 0) + 1;
      poNo = `${counter.prefix || 'PO-'}${String(nextNum).padStart(counter.padding || 4, '0')}`;
      await sbPatch('sequence_counters', counter.id, { last_number: nextNum });
    }
    await sbPatch('purchase_orders', id, { status: 'open', po_no: poNo });
    showToast(`Purchase Order ${poNo} sent.`, 'success');
    await loadPurchaseOrders();
  } catch(e) { showToast('Error: ' + e.message, 'error'); }
}
```
(`last_number: 0` rather than Bill's `999` — Bill's counter starting at 999 was presumably an intentional numbering-continuity choice for that specific document type; PO is a brand-new series with no prior numbering history, so it should start at `PO-0001`.)

- [ ] **Step 2: Manual verification**

Send the Draft PO created in Task 6. Confirm status flips to `open`, PO# shows as `PO-0001` (or next in sequence if a prior test PO was sent), and the "Send" button disappears from that row (since `canSend` requires `status === 'draft'`).

- [ ] **Step 3: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): Send action assigns PO number via sequence_counters"
```

---

## Task 8: Duplicate as template

**Files:**
- Modify: `meridian-erp/index.html`

- [ ] **Step 1: `duplicatePO(id)`**

```js
async function duplicatePO(id) {
  const po = purchaseOrders.find(p => p.id === id);
  if (!po) return;
  const lines = await sbGet('po_lines', `po_id=eq.${id}&order=line_no.asc`);
  const vendor = contacts.find(c => c.id === po.vendor_id) || {};

  openNewPO();
  document.getElementById('po-vendor-id').value = po.vendor_id;
  document.getElementById('po-vendor-search').value = vendor.trading_name || vendor.name || '';
  document.getElementById('po-vendor-selected').textContent = vendor.name ? '✓ ' + vendor.name : '';
  document.getElementById('po-currency').value = po.currency;
  document.getElementById('po-terms').value = po.payment_terms || '30';
  document.getElementById('po-incoterms').value = po.incoterms || '';
  document.getElementById('po-incoterms-place').value = po.incoterms_place || '';
  document.getElementById('po-notes').value = po.notes || '';

  document.getElementById('po-lines-body').innerHTML = '';
  (lines.length ? lines : [{}]).forEach(l => {
    addPOLine();
    const rows = document.querySelectorAll('#po-lines-body tr');
    const tr = rows[rows.length - 1];
    document.getElementById(tr.id + '-desc').value = l.description || '';
    document.getElementById(tr.id + '-unit').value = l.unit || '';
    document.getElementById(tr.id + '-rate').value = l.rate ?? '';
    document.getElementById(tr.id + '-qty').value  = l.qty ?? '';
  });
  recalcPOTotals();
  document.getElementById('modal-po-title').textContent = `New Purchase Order (from ${po.po_no || 'draft'})`;
  document.getElementById('modal-po').classList.add('show');
}
```
Note: `vendor_quote_basis`/`ref`/`date` are deliberately NOT copied — a duplicated PO is a new order and any prior vendor quote reference doesn't necessarily still apply; `_poEditId`/`po-edit-id` stay unset (via `openNewPO()`'s reset) so Save creates a new row with its own PO# assigned at its own Send.

- [ ] **Step 2: Manual verification**

Duplicate a Sent (`open`) PO. Confirm a new Draft modal opens pre-filled with the same vendor/lines, save it, confirm it's a distinct row with its own (unassigned) PO#.

- [ ] **Step 3: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): Duplicate as new (template reuse)"
```

---

## Task 9: Close / Cancel + remaining-qty computation

**Files:**
- Modify: `meridian-erp/index.html`

- [ ] **Step 1: `computePORemaining(poId)`**

This is the core computed (non-counter) remaining-qty function used by both the Bill-linking UI (Task 12) and the auto-close recompute (Step 2):

```js
async function computePORemaining(poId) {
  const lines = await sbGet('po_lines', `po_id=eq.${poId}&order=line_no.asc`);
  const consumed = await sbGet('bill_lines', `po_id=eq.${poId}&select=po_line_id,quantity,bills(status)`);
  const consumedByLine = {};
  consumed.forEach(c => {
    if (c.bills?.status === 'void') return;
    consumedByLine[c.po_line_id] = (consumedByLine[c.po_line_id] || 0) + parseFloat(c.quantity || 0);
  });
  return lines.map(l => ({
    ...l,
    consumed: consumedByLine[l.id] || 0,
    remaining: Math.max(0, parseFloat(l.qty || 0) - (consumedByLine[l.id] || 0)),
  }));
}
```
(Uses a PostgREST embedded join `bills(status)` on `bill_lines` — confirm this embed works given `bill_lines.bill_id → bills.id` FK already exists per the schema this table was built on; if PostgREST's schema cache needs a refresh after Task 1's migration, call `mcp__cbe5a78d-ee58-4abb-96d1-379347f3fbe3__get_advisors` type `performance` or simply retry after a few seconds — schema cache reloads automatically on DDL in this project per existing session notes.)

- [ ] **Step 2: `recomputePOStatus(poId)`**

```js
async function recomputePOStatus(poId) {
  const po = purchaseOrders.find(p => p.id === poId) || (await sbGet('purchase_orders', `id=eq.${poId}`))[0];
  if (!po || !['open','closed'].includes(po.status)) return; // don't touch draft/cancelled
  const withRemaining = await computePORemaining(poId);
  const fullyConsumed = withRemaining.every(l => l.remaining <= 0);
  if (fullyConsumed && po.status !== 'closed') {
    await sbPatch('purchase_orders', poId, { status: 'closed' });
  } else if (!fullyConsumed && po.status === 'closed') {
    await sbPatch('purchase_orders', poId, { status: 'open' });
  }
}
```

- [ ] **Step 3: `closePO(id)` / `cancelPO(id)`**

```js
async function closePO(id) {
  const ok = await showConfirm('Close this purchase order early? Any remaining quantity will no longer be available to link on a Bill.', 'Close Purchase Order', 'Close PO');
  if (!ok) return;
  try {
    await sbPatch('purchase_orders', id, { status: 'closed' });
    showToast('Purchase order closed.', 'success');
    await loadPurchaseOrders();
  } catch(e) { showToast('Error: ' + e.message, 'error'); }
}

async function cancelPO(id) {
  const ok = await showConfirm('Cancel this purchase order? This cannot be undone.', 'Cancel Purchase Order', 'Cancel PO', true);
  if (!ok) return;
  try {
    await sbPatch('purchase_orders', id, { status: 'cancelled' });
    showToast('Purchase order cancelled.', 'success');
    await loadPurchaseOrders();
  } catch(e) { showToast('Error: ' + e.message, 'error'); }
}
```

- [ ] **Step 4: Manual verification**

Manually close an `open` PO with no bills against it — confirm status → `closed`. Manually cancel a different draft PO — confirm status → `cancelled` and it no longer offers Send/Edit (only Duplicate).

- [ ] **Step 5: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): computed remaining-qty, auto-close recompute, manual Close/Cancel"
```

---

## Task 10: PDF generation

**Files:**
- Modify: `meridian-erp/index.html` (add `#modal-po-pdf`, `buildPurchaseOrderPDFHTML`-equivalent using `buildPDFHeader`/`renderMultiPagePDF`, `openPOPDF()`)

- [ ] **Step 1: Add `#modal-po-pdf` markup**

Clone whatever `#modal-quo-pdf` looks like (referenced in `openQuoPDF()` — grep `id="modal-quo-pdf"` for its exact wrapper) as `#modal-po-pdf` with an inner `<div id="po-pdf-content"></div>` target and the same `⬇ Download PDF` button calling `onclick="printPDF(this)"`.

- [ ] **Step 2: `openPOPDF(id)`**

Adapted from `openQuoPDF()` (lines 16126-16155):
```js
async function openPOPDF(id) {
  const po = purchaseOrders.find(p => p.id === id) || (await sbGet('purchase_orders', `id=eq.${id}`))[0];
  if (!po) return;
  const lines = await sbGet('po_lines', `po_id=eq.${id}&order=line_no.asc`);
  const vendor = contacts.find(c => c.id === po.vendor_id) || {};
  const co = currentCompany;

  const total = lines.reduce((s,l) => s + parseFloat(l.amount||0), 0);
  const totalsH = calcTotalsH(po.incoterms, po.notes, null);
  const pages = splitLinesIntoPages(lines, calcFirstRows(totalsH), calcContRows(totalsH));

  const metaRows = [
    ['PO Date :', formatDateDisplay(po.po_date)],
    ['Expected :', po.expected_date ? formatDateDisplay(po.expected_date) : '—'],
    ['Terms :', BILL_TERMS_LABELS[po.payment_terms] || (po.payment_terms + ' days')],
    ...(po.vendor_quote_basis === 'written' && po.vendor_quote_ref ? [['Vendor Quote Ref :', escHTML(po.vendor_quote_ref)]] : []),
    ...(po.vendor_quote_basis === 'verbal' ? [['Vendor Quote :', 'Verbal' + (po.vendor_quote_date ? ' — ' + formatDateDisplay(po.vendor_quote_date) : '')]] : []),
    ['Prepared By :', escHTML(po.prepared_by || '—')],
  ];

  const headerHTML = buildPDFHeader(co, 'Purchase Order', po.po_no || 'DRAFT', 'Total Value',
    fmt(total, po.currency), vendor, metaRows);

  renderMultiPagePDF('po-pdf-content', pages, headerHTML, true, po.currency,
    total, 0, 0, total, po.incoterms, po.incoterms_place, po.notes, null, co.name, po.po_no);

  document.getElementById('modal-po-pdf').classList.add('show');
}
```
Note: `BILL_TERMS_LABELS` doesn't exist yet — add a small lookup object near `addPOLine()`:
```js
const BILL_TERMS_LABELS = { '0': 'Due on Receipt', '7': 'Net 7', '14': 'Net 14', '30': 'Net 30', '60': 'Net 60' };
```
`po_lines` uses `{description, unit, rate, qty, amount}` field names, whereas `renderMultiPagePDF`'s line rendering (built for invoice/quote lines) likely expects `{description, quantity, unit_price, amount}` — check `splitLinesIntoPages`'s consumer inside `renderMultiPagePDF` (grep how it reads `l.quantity`/`l.unit_price` inside that function) and if so, map PO lines before passing them in: `const lines = rawLines.map(l => ({ ...l, quantity: l.qty, unit_price: l.rate }));`. Confirm field names by reading `renderMultiPagePDF`'s body in full before finalizing this step — the field-name assumption here is the one part of this task most likely to need adjustment once the executing engineer reads the real function body.

- [ ] **Step 3: Wire Print buttons**

Task 4's `renderPOTable()` already calls `openPOPDF('${po.id}')` from the row menu for non-draft POs — no further wiring needed there.

- [ ] **Step 4: Manual verification**

Click Print on the `open`-status PO from Task 7. Confirm the PDF preview modal renders company header, vendor block, line items, total, incoterms (if set), and the vendor-quote/prepared-by meta rows correctly. Download and open the PDF, confirm it's legible and correctly paginated.

- [ ] **Step 5: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): PDF generation and print preview"
```

---

## Task 11: Email delivery

**Files:**
- Modify: `meridian-erp/index.html` (`_resolveEmailMeta`, `_buildEmailPDF`)

- [ ] **Step 1: Add to `_resolveEmailMeta(type, id)`**

Following the `'quotation'` case pattern (lines 15640-15644):
```js
if (type === 'purchase-order') {
  const po = purchaseOrders.find(x => x.id === id) || {};
  const v  = contacts.find(x => x.id === po.vendor_id) || {};
  const co = currentCompany;
  return { to: v.email || '', subject: `Purchase Order ${po.po_no || ''} from ${escHTML(co.name)}`, filename: `${po.po_no || 'purchase-order'}.pdf` };
}
```

- [ ] **Step 2: Add to `_buildEmailPDF(type, id)`**

Mirror the `'quotation'` block (line 15944) — build the same staging content `openPOPDF()` builds (reuse its header/pages/renderMultiPagePDF calls against an off-screen staging element per the existing convention — read the `'quotation'` block in full first since it likely calls a shared internal render helper rather than duplicating `openQuoPDF`'s body; if so, extract the shared parts of Task 10 Step 2 into a small `_buildPOPDFParts(po)` helper both `openPOPDF()` and this `_buildEmailPDF` block can call, to avoid duplicating the metaRows/pages logic twice):
```js
if (type === 'purchase-order') {
  const po = purchaseOrders.find(x => x.id === id) || (await sbGet('purchase_orders', `id=eq.${id}`))[0];
  const lines = await sbGet('po_lines', `po_id=eq.${id}&order=line_no.asc`);
  const vendor = contacts.find(x => x.id === po.vendor_id) || {};
  const co = currentCompany;
  const total = lines.reduce((s,l) => s + parseFloat(l.amount||0), 0);
  const totalsH = calcTotalsH(po.incoterms, po.notes, null);
  const pages = splitLinesIntoPages(lines, calcFirstRows(totalsH), calcContRows(totalsH));
  const metaRows = [
    ['PO Date :', formatDateDisplay(po.po_date)],
    ['Terms :', BILL_TERMS_LABELS[po.payment_terms] || (po.payment_terms + ' days')],
    ['Prepared By :', escHTML(po.prepared_by || '—')],
  ];
  const headerHTML = buildPDFHeader(co, 'Purchase Order', po.po_no || 'DRAFT', 'Total Value', fmt(total, po.currency), vendor, metaRows);
  const staging = document.getElementById('email-pdf-staging');
  renderMultiPagePDF('email-pdf-staging', pages, headerHTML, true, po.currency, total, 0, 0, total, po.incoterms, po.incoterms_place, po.notes, null, co.name, po.po_no);
  return await generatePDFBase64(staging);
}
```
(Confirm `'email-pdf-staging'` is the actual staging element id by reading the `'quotation'` block's exact usage — this is named from the CLAUDE.md reference "Off-screen staging div `#email-pdf-staging` at line 4583" from Session 35's notes; verify it still matches before using it.)

- [ ] **Step 2: Manual verification**

From the PO list row menu, click **Email** on the sent PO. Confirm the send-email modal opens pre-filled with the vendor's email and correct subject/filename, send it, confirm delivery via Resend (check `notification_log` or the vendor's inbox) matching the existing 7-doc-type email flow.

- [ ] **Step 3: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): wire PO into email delivery pipeline (8th doc type)"
```

---

## Task 12: Bill integration — PO picker + auto-populate lines

**Files:**
- Modify: `meridian-erp/index.html` (Bill modal HTML near line 4288-4372, `selectBillVendor()` near line 11972)

- [ ] **Step 1: Add the PO picker field to the Bill modal**

Find the Bill modal's vendor field block (lines 4304-4308) and add immediately after it:
```html
<div class="field span-2" id="bill-po-picker-wrap" style="display:none;">
  <label class="field-label">Link Purchase Order <span style="color:var(--text-3);font-weight:400;">(optional)</span></label>
  <select id="bill-po-picker" onchange="onBillPOPicked()">
    <option value="">— None —</option>
  </select>
</div>
```

- [ ] **Step 2: Populate the picker when a vendor is selected**

Modify `selectBillVendor()` (line 11972) to also load that vendor's open POs:
```js
async function selectBillVendor(id, displayName, legalName) {
  document.getElementById('bill-vendor-id').value     = id;
  document.getElementById('bill-vendor-search').value = displayName;
  document.getElementById('bill-vendor-selected').textContent = '✓ ' + legalName;
  document.getElementById('bill-vendor-results').classList.remove('open');
  await loadOpenPOsForBillVendor(id);
}

async function loadOpenPOsForBillVendor(vendorId) {
  const wrap = document.getElementById('bill-po-picker-wrap');
  const sel  = document.getElementById('bill-po-picker');
  sel.innerHTML = '<option value="">— None —</option>';
  const openPOs = await sbGet('purchase_orders', `company_id=eq.${currentCompany.id}&vendor_id=eq.${vendorId}&status=eq.open`);
  if (!openPOs.length) { wrap.style.display = 'none'; return; }
  openPOs.forEach(po => {
    const opt = document.createElement('option');
    opt.value = po.id;
    opt.textContent = `${po.po_no} — ${formatDateDisplay(po.po_date)}`;
    sel.appendChild(opt);
  });
  wrap.style.display = '';
}
```

- [ ] **Step 3: Auto-populate Bill lines from the selected PO**

```js
async function onBillPOPicked() {
  const poId = document.getElementById('bill-po-picker').value;
  if (!poId) return;
  const withRemaining = await computePORemaining(poId);
  const openLines = withRemaining.filter(l => l.remaining > 0);
  if (!openLines.length) { showToast('This PO has no remaining quantity to bill.', 'warn'); return; }

  document.getElementById('bill-po-id').value = poId;
  const po = purchaseOrders.find(p => p.id === poId);
  document.getElementById('bill-currency').value = po.currency;
  document.getElementById('bill-terms').value = po.payment_terms || '30';

  document.getElementById('bill-lines-body').innerHTML = '';
  openLines.forEach(l => {
    addBillLine();
    const rows = document.querySelectorAll('#bill-lines-body tr[id^="billl-"]:not([id$="-link"])');
    const tr = rows[rows.length - 1];
    document.getElementById(tr.id + '-desc').value = l.description;
    tr.querySelectorAll('input[type="number"]')[0].value = l.remaining;
    document.getElementById(tr.id + '-rate').value = l.rate;
    tr.dataset.poId = poId;
    tr.dataset.poLineId = l.id;
    document.getElementById(tr.id + '-link').dataset.poId = poId;
  });
  recalcBillTotals();
}
```
A hidden `<input type="hidden" id="bill-po-id">` needs adding next to `#bill-vendor-id` in the Bill modal HTML for this to work — add it in Step 1's edit.

The exclude behavior (per spec) is the existing per-row ✕ remove button already wired in `addBillLine()` — no new control needed. If the user removes an auto-populated row, that PO line simply stays available (its `remaining` unaffected since nothing was ever saved).

- [ ] **Step 4: Reset the picker in `openNewBill()`**

Find wherever the "new bill" reset function is (grep for the function that resets `#modal-bill` for a fresh Bill — likely `openNewBill()`) and add:
```js
document.getElementById('bill-po-picker-wrap').style.display = 'none';
document.getElementById('bill-po-picker').innerHTML = '<option value="">— None —</option>';
document.getElementById('bill-po-id').value = '';
```

- [ ] **Step 5: Manual verification**

Create a new Bill, select the vendor from the `open` PO created earlier. Confirm the "Link Purchase Order" field appears with that PO listed. Select it, confirm Bill lines auto-populate with correct description/rate/remaining-qty. Remove one line via ✕, reduce qty on another, and proceed (save happens in Task 13/14).

- [ ] **Step 6: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): Bill modal PO picker and line auto-populate"
```

---

## Task 13: Over-billing warning

**Files:**
- Modify: `meridian-erp/index.html`

- [ ] **Step 1: `checkPOOverbill(billId)`**

A separate async pre-check called from `saveBill()`/`saveBillEdit()` before their existing (synchronous) `collectBillFormLines()` call — kept separate specifically so `collectBillFormLines()`'s signature and every existing call site stay untouched:

```js
async function checkPOOverbill() {
  const rows = document.querySelectorAll('#bill-lines-body tr[id^="billl-"]:not([id$="-link"])');
  const byPOLine = {};
  rows.forEach(tr => {
    if (!tr.dataset.poLineId) return;
    const qty = tr.querySelectorAll('input[type="number"]')[0]?.value;
    byPOLine[tr.dataset.poLineId] = (byPOLine[tr.dataset.poLineId] || 0) + (parseFloat(qty) || 0);
  });
  const poLineIds = Object.keys(byPOLine);
  if (!poLineIds.length) return true;

  const lines = await sbGet('po_lines', `id=in.(${poLineIds.join(',')})`);
  const overLines = lines.filter(l => byPOLine[l.id] > parseFloat(l.qty || 0));
  if (!overLines.length) return true;

  const msg = overLines.map(l => `"${l.description}" — billing ${byPOLine[l.id]}, PO line qty is ${l.qty}`).join('\n');
  return await showConfirm(`This bill exceeds the ordered quantity on ${overLines.length} PO line(s):\n\n${msg}\n\nProceed anyway?`, 'Quantity Exceeds PO', 'Bill Anyway');
}
```
Note: this compares against the PO line's total `qty`, not `remaining` — intentionally, since "remaining" already accounts for prior bills and the current in-progress bill's own qty for that line is what's being entered right now (comparing against total `qty` on a single-bill line is the simple, correct check for the common one-bill-per-line-item case; multi-bill partial-then-over-bill on the same line is a rarer edge case the warning message's phrasing already covers honestly by naming the PO line's total ordered qty).

- [ ] **Step 2: Call it from `saveBill()` and `saveBillEdit()`**

At the top of `saveBill(status)` (before its `collectBillFormLines` call, per the research), insert:
```js
if (!(await checkPOOverbill())) return;
```
Same insertion at the top of `saveBillEdit()`, before its `collectBillFormLines(bill.status)` call.

- [ ] **Step 3: Manual verification**

On the Bill from Task 12, manually raise one line's qty above its PO line's ordered qty. Attempt to save — confirm the warning dialog appears listing the specific over-billed line(s), with the exact PO qty and attempted bill qty shown. Confirm "Bill Anyway" proceeds and Cancel aborts the save.

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): warn (not block) when a Bill line exceeds its PO line's ordered qty"
```

---

## Task 14: Persist PO linkage on Bill save/edit/void + auto-recompute

**Files:**
- Modify: `meridian-erp/index.html` (`saveBill()` ~line 12066-12127, `saveBillEdit()` ~line 12129-12206, `voidBill()` ~line 12871, `collectBillFormLines()` ~line 12016-12064, `openEditBill()` ~line 11761-11800)

This is the task most likely to touch shared code — kept last among the Bill-side tasks precisely so Tasks 1-13 are fully working and reviewed first, minimizing what's left to verify once this lands.

- [ ] **Step 1: Extend `collectBillFormLines()` to read PO linkage from the row**

Find the line-object construction inside `collectBillFormLines()` (research shows: `const line = { description: desc, quantity: qty, unit_price: rate, amount: amt, line_order: idx };`). Change it to:
```js
const line = { description: desc, quantity: qty, unit_price: rate, amount: amt, line_order: idx, po_id: tr.dataset.poId || null, po_line_id: tr.dataset.poLineId || null };
```

- [ ] **Step 2: Extend `saveBill()`'s `bill_lines` insert**

Find the bulk insert (research shows lines 12108-12117):
```js
await sbPost('bill_lines', lines.map(l => ({
  bill_id: bill.id,
  description: l.description,
  quantity: l.quantity,
  unit_price: l.unit_price,
  amount: l.amount,
  line_order: l.line_order,
  item_category: l.item_category || null,
  item_id: l.item_id || null,
})));
```
Add the two new keys (every object must share identical keys — the exact constraint this codebase already works around for `item_category`/`item_id`):
```js
await sbPost('bill_lines', lines.map(l => ({
  bill_id: bill.id,
  description: l.description,
  quantity: l.quantity,
  unit_price: l.unit_price,
  amount: l.amount,
  line_order: l.line_order,
  item_category: l.item_category || null,
  item_id: l.item_id || null,
  po_id: l.po_id || null,
  po_line_id: l.po_line_id || null,
})));
```

- [ ] **Step 3: Recompute PO status after `saveBill()` succeeds**

After the existing `showToast('Bill saved...', 'success')`/`loadAP()` calls at the end of `saveBill()` (or right after the `bill_lines` insert, before the toast — insert wherever the function's success path already sits), add:
```js
const poIds = [...new Set(lines.map(l => l.po_id).filter(Boolean))];
for (const poId of poIds) await recomputePOStatus(poId);
```

- [ ] **Step 4: Same two additions in `saveBillEdit()`**

The archive insert (research lines 12159-12169) and the new-lines insert (12172-12181) both need `po_id: l.po_id || null, po_line_id: l.po_line_id || null` added, identical to Step 2. Then after the function's existing `await loadAP();` call, add the same recompute loop as Step 3.

- [ ] **Step 5: Preserve PO linkage across Edit Bill's line-rebuild**

Find `openEditBill()`'s line-population loop (research lines 11789-11797):
```js
(existingLines.length ? existingLines : [{}]).forEach(l => {
  addBillLine();
  const rows = document.querySelectorAll('#bill-lines-body tr[id^="billl-"]:not([id$="-link"])');
  const tr = rows[rows.length - 1];
  document.getElementById(tr.id + '-desc').value = l.description || '';
  tr.querySelectorAll('input[type="number"]')[0].value = l.quantity ?? '';
  document.getElementById(tr.id + '-rate').value = l.unit_price ?? '';
  if (l.item_category) jcPrefillBillLineLink(tr.id, l.item_category, l.item_id);
});
```
Add, inside the same forEach:
```js
  if (l.po_line_id) { tr.dataset.poId = l.po_id; tr.dataset.poLineId = l.po_line_id; }
```
This is the critical line preventing PO linkage from silently vanishing on edit — without it, `collectBillFormLines()` (Step 1) would read `tr.dataset.poLineId` as `undefined` for a re-saved existing line, orphaning that consumption and inflating the PO's remaining qty back up incorrectly.

- [ ] **Step 6: Recompute PO status after `voidBill()`**

```js
async function voidBill(id) {
  const ok = await showConfirm('Void this bill? This cannot be undone.', 'Void Bill', 'Void Bill');
  if (!ok) return;
  try {
    const linkedLines = await sbGet('bill_lines', `bill_id=eq.${id}&po_id=not.is.null`);
    await sbPatch('bills', id, { status: 'void' });
    const poIds = [...new Set(linkedLines.map(l => l.po_id))];
    for (const poId of poIds) await recomputePOStatus(poId);
    showToast('Bill voided.', 'success');
    await loadAP();
  } catch(e) { showToast('Error: ' + e.message, 'error'); }
}
```
(Fetch the linked lines BEFORE the status patch, since `computePORemaining()` inside `recomputePOStatus()` queries `bill_lines(...).bills(status)` live — patching first then recomputing works too since the query re-reads fresh state either way, but fetching `linkedLines` first is needed regardless just to know which PO ids to recompute.)

- [ ] **Step 7: Manual verification (full lifecycle)**

1. Save the Bill from Task 13 (with the warning dismissed or avoided). Confirm `bill_lines` rows carry the correct `po_id`/`po_line_id` (spot-check via Supabase `execute_sql` or the AP detail view once Task 15 lands).
2. Confirm the PO's status: if all its lines are now fully consumed, it should show `closed`; if not, stays `open`.
3. Edit that Bill (Session 45's Edit Bill flow) without changing the PO-linked line's qty — confirm the PO's remaining qty is unchanged after the edit (this is the specific regression Step 5 prevents).
4. Void the Bill — confirm the PO's remaining qty recomputes back up, and reopens to `open` if it had auto-closed.
5. Regression check: create, edit, and void a separate Bill with **no** PO selected at all — confirm it behaves identically to before this task (no errors, no unexpected PO-related fields referenced).

- [ ] **Step 8: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): persist PO linkage through Bill save/edit/void, auto-recompute PO status"
```

---

## Task 15: AP table — show PO # / PO Date

**Files:**
- Modify: `meridian-erp/index.html` (`loadAP()` ~line 9716-9739, `renderAPTable()` ~line 9740-9820)

- [ ] **Step 1: Fetch PO data alongside bills**

In `loadAP()`, after the existing `bills = await sbGet(...)` line, add:
```js
purchaseOrders = await sbGet('purchase_orders', `company_id=eq.${currentCompany.id}&select=id,po_no,po_date`);
```
(Reuses the same global `purchaseOrders` array from Task 2 — fine since AP and the PO list view are never rendered simultaneously, and this partial-select fetch is cheap. If `purchaseOrders` already holds full rows from a prior PO-view visit, this overwrites it with the lighter AP-scoped version, which is harmless since nothing depends on stale full rows persisting across views.)

- [ ] **Step 2: Add a `poMap` join and two `<th>`/`<td>` pairs**

In `renderAPTable()`, alongside the existing `contactMap` line (research line 9743), add:
```js
const poMap = Object.fromEntries(purchaseOrders.map(p => [p.id, p]));
```
In the `<thead>` (research lines 9775-9779), insert a new column after "Invoice No.":
```html
<thead><tr>
  ${thAP('bill_no','Bill No.')}<th>Invoice No.</th><th>PO #</th>${thAP('supplier','Supplier')}${thAP('bill_date','Date')}${thAP('due_date','Due Date')}
  <th>Currency</th><th class="right">Total</th><th class="right">Balance Due</th>
  <th>Status</th><th class="right">Actions</th>
</tr></thead>
```
In the row-render body, alongside the existing `bill_no`/`vendor_ref` cells, add a matching `<td>`:
```html
<td class="mono">${b.po_id && poMap[b.po_id] ? `${poMap[b.po_id].po_no || 'Draft'} <span style="color:var(--text-3);font-size:10px;">(${formatDateDisplay(poMap[b.po_id].po_date)})</span>` : '—'}</td>
```
`b.po_id` on a `bills` row itself doesn't exist — only `bill_lines.po_id` does (per Task 1's schema, PO linkage lives on the line, not the bill header). Resolve this by deriving a per-bill PO id when bills are loaded: after fetching `bills`, also fetch `bill_lines` with `po_id` set and attach the first found `po_id` to its parent bill object for display purposes:
```js
const linkedLines = await sbGet('bill_lines', `bill_id=in.(${bills.map(b=>b.id).join(',')})&po_id=not.is.null&select=bill_id,po_id`);
const poIdByBill = Object.fromEntries(linkedLines.map(l => [l.bill_id, l.po_id]));
bills.forEach(b => { b.po_id = poIdByBill[b.id] || null; });
```
Add this snippet in `loadAP()` right after the `bills = await sbGet(...)` line (guard the `in.()` call with `bills.length ? ... : []` to avoid an empty-IN-clause query when there are zero bills).

- [ ] **Step 3: Manual verification**

Open AP, confirm the PO-linked bill from Task 14 shows its PO#/date in the new column, and every other (non-PO) bill shows `—` with no layout break — check specifically that the Actions column (subject of the Session 46 overflow-menu fix) doesn't regress into horizontal-scroll territory now that one more column exists; if it's tight, this is exactly the kind of table-width issue Session 46 already solved once via the `#ap-row-menu` overflow pattern — confirm the existing overflow menu still absorbs the extra column without needing a new fix.

- [ ] **Step 4: Commit**

```bash
cd meridian-erp
git add index.html
git commit -m "feat(po): show PO # / PO Date on the AP bills table"
```

---

## Task 16: Full end-to-end manual verification + test data cleanup

**Files:** None (verification only, matching this repo's no-automated-tests convention).

- [ ] **Step 1: Full lifecycle click-through**

Following the spec's verification plan exactly:
1. Create a Draft PO with 3 lines, save, confirm PO# is unassigned (shows "Draft").
2. Send it — confirm status → `open`, PDF renders, email delivers.
3. Create a Bill for the same vendor — confirm the PO appears in the picker, lines auto-populate correctly.
4. Remove one auto-populated line, reduce qty on another (partial), save — confirm PO stays `open`; open a second Bill against the same PO and confirm the picker/auto-populate reflects the now-reduced remaining qty.
5. Fully consume all lines across the two Bills — confirm PO auto-closes.
6. Void one of the two Bills — confirm the PO's remaining qty recomputes upward and it reopens to `open`.
7. Duplicate the (now open again) PO as a new template — confirm a fresh Draft with new PO# on its own future Send, same vendor/lines.
8. Create/edit/void a plain Bill with no PO link — confirm zero regressions in that path.
9. As a non-admin test user with only `finance:ap:write` (not `:approve`): confirm they can create/edit/duplicate a Draft PO, but Send/Close/Cancel buttons don't render for them.

- [ ] **Step 2: SQL cleanup**

Use `mcp__cbe5a78d-ee58-4abb-96d1-379347f3fbe3__execute_sql` against project `fcagxvjxfqqkmuposmcb` to delete all test rows created above — `purchase_orders`/`po_lines` (cascade handles lines), the test bills/`bill_lines`/any journal entries they generated — confirming zero residue, matching every prior session's verification convention in `handoff.md`.

- [ ] **Step 3: Update `handoff.md`**

Add a new session entry to `meridian-erp/handoff.md` at the top (above Session 47), documenting the PO module: what was built, the PR number(s) once opened, and any outstanding follow-ups discovered during verification. Per the existing convention (`docs/superpowers/specs/` and `docs/superpowers/plans/` files referenced from the entry), link both `2026-08-08-purchase-orders-design.md` and this plan file.

- [ ] **Step 4: Commit the handoff update**

```bash
cd meridian-erp
git add handoff.md
git commit -m "docs: add Session 48 handoff entry for Purchase Orders module"
```

---

## Self-review notes (writing-plans checklist, already applied above)

- **Spec coverage:** every section of `2026-08-08-purchase-orders-design.md` maps to a task — placement/nav (Task 3), data model (Task 1), PO modal (Tasks 5-8), PDF/email (Tasks 10-11), Bill integration (Tasks 12-14), prepare/approve RBAC split (Task 4's `can('finance:ap:write'/'approve')` gating), incoterms/payment-terms/vendor-quote fields (Task 5), AP display (Task 15), manual verification (Task 16).
- **Corrected during research** (both the spec and this plan were updated to match real code, not assumptions): bill status value is `'void'` not `'voided'`; the "exclude" UI is the existing per-line ✕ button, not a new checkbox; PO# assignment matches Bill's assign-at-commit convention exactly via `sequence_counters`.
- **Known verification-time risk flagged inline, not hidden:** Task 10 Step 2 and Task 11 Step 2 both flag the one place (PDF line-field-name mapping, staging element id) where the plan's code is a best-effort adaptation pending the implementing engineer reading the exact `renderMultiPagePDF`/`'quotation'` `_buildEmailPDF` block bodies in full — called out explicitly rather than presented as fully certain, per this codebase's own past-bug pattern (Session 41's IntersectionObserver bug came from an assumption not verified live).
