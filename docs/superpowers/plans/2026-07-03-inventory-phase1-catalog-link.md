# Inventory-Linked Purchasing — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hardware, Tooling and Fuel as first-class job-costing categories alongside Materials/Consumables/Equipment, and link AP bill lines to all five catalogs so approving a purchase automatically updates catalog cost (or creates a new asset, for Equipment) instead of requiring a manual Job Config edit.

**Architecture:** `index.html` is a single-file vanilla JS app (no build step, no test runner — see project `CLAUDE.md`). Every change below follows an existing pattern already in the file: new categories mirror `config_materials`/`material_entries`/`jcAddMaterialRow`; the AP-link mechanism is new (two nullable columns on `bill_lines` + a small UI added to `addBillLine()`). All schema changes go through the Supabase MCP (`apply_migration`) against project `fcagxvjxfqqkmuposmcb`. Verification is manual (query via `execute_sql` / run app via the dev-preview tool) since this codebase has no automated test suite — do not introduce one as part of this plan.

**Tech Stack:** Vanilla JS, Supabase (Postgres + PostgREST), no bundler.

**Spec:** `docs/superpowers/specs/2026-07-03-inventory-linked-purchasing-design.md` — read this first if anything below is ambiguous. This plan covers Phase 1 only (cost-sync, no stock ledger).

---

## Task 0: Confirm environment

- [ ] **Step 1: Confirm current schema hasn't drifted**

Run via Supabase MCP `execute_sql` on project `fcagxvjxfqqkmuposmcb`:

```sql
select table_name from information_schema.tables
where table_schema='public' and table_name in
('config_hardware','hardware_entries','config_tooling','tooling_entries','config_fuel');
```

Expected: empty result (none of these tables exist yet). If any already exist, stop and re-read the spec — someone else may have started this work.

---

## Task 1: Schema — new catalog tables

**Files:** none (Supabase MCP `apply_migration` only — no local migration files exist for the sibling tables `config_materials`/`material_entries`, so don't create one here either; stay consistent with how those were applied).

- [ ] **Step 1: Create `config_hardware` and `config_tooling`**

Apply via MCP (`apply_migration`, project `fcagxvjxfqqkmuposmcb`, name `add_config_hardware_tooling`):

```sql
create table config_hardware (
  id uuid primary key default gen_random_uuid(),
  item_name text not null,
  spec text,
  unit text,
  default_unit_cost_ttd numeric not null default 0,
  sort_order integer not null default 0,
  status text not null default 'approved',
  is_active boolean not null default true,
  submitted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table config_hardware enable row level security;
create policy "authenticated users full access" on config_hardware
  for all using (true) with check (true);

create table config_tooling (
  id uuid primary key default gen_random_uuid(),
  item_name text not null,
  stock_code text,
  unit text,
  default_unit_cost_ttd numeric not null default 0,
  sort_order integer not null default 0,
  status text not null default 'approved',
  is_active boolean not null default true,
  submitted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table config_tooling enable row level security;
create policy "authenticated users full access" on config_tooling
  for all using (true) with check (true);
```

- [ ] **Step 2: Create `config_fuel` (price reference only — no stock columns, per spec)**

```sql
create table config_fuel (
  id uuid primary key default gen_random_uuid(),
  item_name text not null,
  unit text not null default 'litre',
  default_unit_cost_ttd numeric not null default 0,
  sort_order integer not null default 0,
  status text not null default 'approved',
  is_active boolean not null default true,
  submitted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table config_fuel enable row level security;
create policy "authenticated users full access" on config_fuel
  for all using (true) with check (true);
```

- [ ] **Step 3: Verify**

```sql
select table_name from information_schema.tables where table_name in ('config_hardware','config_tooling','config_fuel');
```
Expected: all three rows returned.

- [ ] **Step 4: Commit** (no local file changed — nothing to commit for this task; migrations are tracked in Supabase only, matching sibling tables)

---

## Task 2: Schema — new job-entry tables + equipment fuel columns

**Files:** none (Supabase MCP `apply_migration` only)

- [ ] **Step 1: Create `hardware_entries` and `tooling_entries`**

Apply via MCP (name `add_hardware_tooling_entries`):

```sql
create table hardware_entries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  sort_order integer not null default 0,
  entry_date date,
  description text,
  spec text,
  quantity numeric not null default 0,
  unit text,
  unit_cost_ttd numeric not null default 0,
  total_cost_ttd numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table hardware_entries enable row level security;
create policy "authenticated users full access" on hardware_entries
  for all using (true) with check (true);

create table tooling_entries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  sort_order integer not null default 0,
  entry_date date,
  description text,
  stock_code text,
  quantity numeric not null default 0,
  unit text,
  unit_cost_ttd numeric not null default 0,
  total_cost_ttd numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table tooling_entries enable row level security;
create policy "authenticated users full access" on tooling_entries
  for all using (true) with check (true);
```

- [ ] **Step 2: Add fuel columns to `equipment_entries`**

```sql
alter table equipment_entries
  add column fuel_type text,
  add column fuel_qty numeric not null default 0,
  add column fuel_unit_cost_ttd numeric not null default 0,
  add column fuel_amount_ttd numeric not null default 0;
```

- [ ] **Step 3: Verify**

```sql
select column_name from information_schema.columns where table_name='equipment_entries' and column_name like 'fuel_%';
```
Expected: `fuel_type`, `fuel_qty`, `fuel_unit_cost_ttd`, `fuel_amount_ttd`.

```sql
select table_name from information_schema.tables where table_name in ('hardware_entries','tooling_entries');
```
Expected: both rows returned.

---

## Task 3: Schema — bill_lines inventory link columns

**Files:** none (Supabase MCP `apply_migration` only)

- [ ] **Step 1: Add link columns**

Apply via MCP (name `add_bill_lines_inventory_link`):

```sql
alter table bill_lines
  add column item_category text check (item_category in ('material','hardware','consumable','tooling','equipment')),
  add column item_id uuid;
```

No FK constraint on `item_id` — it points to one of five different tables depending on `item_category` (app-enforced, same non-FK pattern used elsewhere in this schema for polymorphic references).

- [ ] **Step 2: Verify**

```sql
select column_name, data_type from information_schema.columns where table_name='bill_lines' and column_name in ('item_category','item_id');
```
Expected: both columns present.

---

## Task 4: Job Config admin — Hardware, Tooling, Fuel catalog CRUD

This gives admins a place to seed/manage the three new catalogs, exactly like the existing Materials/Consumables tabs.

**Files:**
- Modify: `meridian-erp/index.html:6899-6907` (`JC_CFG_TABS`)
- Modify: `meridian-erp/index.html:6950-7017` (`jcCfgRenderTab`)
- Modify: `meridian-erp/index.html:7044-7217` (`jcCfgBuildModalBody`)
- Modify: `meridian-erp/index.html:7244-7296` (`jcCfgSave`)

- [ ] **Step 1: Register the three new tabs**

In `JC_CFG_TABS` (`index.html:6899`), add after the `consumables` entry:

```js
  { id:'hardware',    label:'Hardware',        table:'config_hardware' },
  { id:'tooling',     label:'Tooling',         table:'config_tooling' },
  { id:'fuel',        label:'Fuel',            table:'config_fuel' },
```

- [ ] **Step 2: Add render branches in `jcCfgRenderTab`**

After the existing `else if (tab === 'consumables') { ... }` block (`index.html:6984-6992`), add:

```js
  } else if (tab === 'hardware') {
    head = '<th>Item Name</th><th>Size / Spec</th><th>Unit</th><th class="right">Default Unit Cost</th><th>Active</th><th class="right">Actions</th>';
    body = rows.map(r => `<tr>
      <td style="font-weight:500;">${escHTML(r.item_name||'')}</td>
      <td>${escHTML(r.spec||'—')}</td>
      <td>${escHTML(r.unit||'—')}</td>
      <td class="right mono">${jcFmtTTD(r.default_unit_cost_ttd)}</td>
      <td><span class="badge ${r.is_active?'badge-posted':'badge-void'}">${r.is_active?'Active':'Inactive'}</span></td>
      <td class="right">${jcCfgActions(tab,r.id)}</td></tr>`).join('');
  } else if (tab === 'tooling') {
    head = '<th>Item Name</th><th>Stock Code</th><th>Unit</th><th class="right">Default Unit Cost</th><th>Active</th><th class="right">Actions</th>';
    body = rows.map(r => `<tr>
      <td style="font-weight:500;">${escHTML(r.item_name||'')}</td>
      <td class="mono">${escHTML(r.stock_code||'—')}</td>
      <td>${escHTML(r.unit||'—')}</td>
      <td class="right mono">${jcFmtTTD(r.default_unit_cost_ttd)}</td>
      <td><span class="badge ${r.is_active?'badge-posted':'badge-void'}">${r.is_active?'Active':'Inactive'}</span></td>
      <td class="right">${jcCfgActions(tab,r.id)}</td></tr>`).join('');
  } else if (tab === 'fuel') {
    head = '<th>Item Name</th><th>Unit</th><th class="right">Default Unit Cost</th><th>Active</th><th class="right">Actions</th>';
    body = rows.map(r => `<tr>
      <td style="font-weight:500;">${escHTML(r.item_name||'')}</td>
      <td>${escHTML(r.unit||'—')}</td>
      <td class="right mono">${jcFmtTTD(r.default_unit_cost_ttd)}</td>
      <td><span class="badge ${r.is_active?'badge-posted':'badge-void'}">${r.is_active?'Active':'Inactive'}</span></td>
      <td class="right">${jcCfgActions(tab,r.id)}</td></tr>`).join('');
```

- [ ] **Step 3: Add modal-body branches in `jcCfgBuildModalBody`**

After the existing `if (tab === 'consumables') return ...` block (`index.html:7129-7147`), add:

```js
  if (tab === 'hardware') return `<div class="form-grid" style="grid-template-columns:1fr 1fr;">
    <div class="field" style="grid-column:span 2;">
      <label class="field-label">Item Name <span style="color:var(--red)">*</span></label>
      <input type="text" id="jc-cfg-f1" value="${escHTML(r.item_name||'')}" placeholder="e.g. M8 Hex Bolt Stainless">
    </div>
    <div class="field">
      <label class="field-label">Size / Spec</label>
      <input type="text" id="jc-cfg-f2" value="${escHTML(r.spec||'')}" placeholder="e.g. M8 x 40mm">
    </div>
    <div class="field">
      <label class="field-label">Unit</label>
      <input type="text" id="jc-cfg-f3" value="${escHTML(r.unit||'')}" placeholder="e.g. pc, box">
    </div>
    <div class="field">
      <label class="field-label">Default Unit Cost (TTD)</label>
      <input type="number" id="jc-cfg-f4" value="${r.default_unit_cost_ttd??0}" min="0" step="0.01" class="mono">
    </div>
    ${sortField}${activeField}
  </div>`;

  if (tab === 'tooling') return `<div class="form-grid" style="grid-template-columns:1fr 1fr;">
    <div class="field" style="grid-column:span 2;">
      <label class="field-label">Item Name <span style="color:var(--red)">*</span></label>
      <input type="text" id="jc-cfg-f1" value="${escHTML(r.item_name||'')}" placeholder="e.g. 10mm Carbide End Mill">
    </div>
    <div class="field">
      <label class="field-label">Stock Code</label>
      <input type="text" id="jc-cfg-f2" value="${escHTML(r.stock_code||'')}" class="mono" placeholder="e.g. EM-10C">
    </div>
    <div class="field">
      <label class="field-label">Unit</label>
      <input type="text" id="jc-cfg-f3" value="${escHTML(r.unit||'')}" placeholder="e.g. pc">
    </div>
    <div class="field">
      <label class="field-label">Default Unit Cost (TTD)</label>
      <input type="number" id="jc-cfg-f4" value="${r.default_unit_cost_ttd??0}" min="0" step="0.01" class="mono">
    </div>
    ${sortField}${activeField}
  </div>`;

  if (tab === 'fuel') return `<div class="form-grid" style="grid-template-columns:1fr 1fr;">
    <div class="field" style="grid-column:span 2;">
      <label class="field-label">Item Name <span style="color:var(--red)">*</span></label>
      <input type="text" id="jc-cfg-f1" value="${escHTML(r.item_name||'')}" placeholder="e.g. Diesel">
    </div>
    <div class="field">
      <label class="field-label">Unit</label>
      <input type="text" id="jc-cfg-f2" value="${escHTML(r.unit||'litre')}" placeholder="litre, gallon">
    </div>
    <div class="field">
      <label class="field-label">Default Unit Cost (TTD)</label>
      <input type="number" id="jc-cfg-f3" value="${r.default_unit_cost_ttd??0}" min="0" step="0.01" class="mono">
    </div>
    ${sortField}${activeField}
  </div>`;
```

- [ ] **Step 4: Add save branches in `jcCfgSave`**

After the existing `} else if (tab === 'consumables') { ... }` block (`index.html:7266-7268`), add:

```js
    } else if (tab === 'hardware') {
      if (!gv('jc-cfg-f1')) { showToast('Item name is required.', 'warn'); return; }
      record = { item_name:gv('jc-cfg-f1'), spec:gv('jc-cfg-f2')||null, unit:gv('jc-cfg-f3')||null, default_unit_cost_ttd:gn('jc-cfg-f4'), sort_order:gi('jc-cfg-sort'), is_active:gc('jc-cfg-active') };
    } else if (tab === 'tooling') {
      if (!gv('jc-cfg-f1')) { showToast('Item name is required.', 'warn'); return; }
      record = { item_name:gv('jc-cfg-f1'), stock_code:gv('jc-cfg-f2')||null, unit:gv('jc-cfg-f3')||null, default_unit_cost_ttd:gn('jc-cfg-f4'), sort_order:gi('jc-cfg-sort'), is_active:gc('jc-cfg-active') };
    } else if (tab === 'fuel') {
      if (!gv('jc-cfg-f1')) { showToast('Item name is required.', 'warn'); return; }
      record = { item_name:gv('jc-cfg-f1'), unit:gv('jc-cfg-f2')||null, default_unit_cost_ttd:gn('jc-cfg-f3'), sort_order:0, is_active:gc('jc-cfg-active') };
```

Note: the `fuel` branch has no `sortField`/`activeField` mismatch to worry about — `jcCfgBuildModalBody`'s fuel form above only includes `${sortField}${activeField}` at the end same as others, so `jc-cfg-sort` still exists; the `sort_order:0` here is fine either way but for consistency use `gi('jc-cfg-sort')` instead — **use `sort_order:gi('jc-cfg-sort')`**, not the literal `0` (fixing this inline since it's copy-paste drift from writing the plan, not intentional).

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: add Hardware, Tooling, Fuel to Job Config admin catalogs"
```

- [ ] **Step 6: Manual verify**

Run the app (dev-preview), log in as admin, go to Work Orders → Job Config → confirm "Hardware", "Tooling", "Fuel" tabs appear after "Consumables", each with a working "+ Add" that saves a row and shows it in the table.

---

## Task 5: Load new catalogs into `jcConfig`

**Files:** Modify `meridian-erp/index.html:7316-7363` (`jcLoadConfig`, `jcRefreshRowDropdowns`)

- [ ] **Step 1: Extend `jcLoadConfig`**

Replace the function body (`index.html:7316-7337`) with:

```js
async function jcLoadConfig() {
  jcConfig = { labour:[], equipment:[], tasks:[], materials:[], consumables:[], hardware:[], tooling:[], fuel:[], qcChecklists:[], employees:[] };
  try {
    const [labRows, eqRows, matRows, conRows, hwRows, toolRows, fuelRows, taskRows, qcRows, empRows] = await Promise.all([
      sbGet('config_labour',       'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_equipment',    'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_materials',    'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_consumables',  'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_hardware',     'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_tooling',      'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_fuel',         'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_tasks',        'status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('config_qc_checklists','status=eq.approved&is_active=eq.true&order=sort_order'),
      sbGet('employees',           'order=name'),
    ]);
    jcConfig.labour      = (labRows ||[]).map(r => ({ classification:r.classification, workshopRate:parseFloat(r.workshop_rate_ttd)||0, onsiteRate:parseFloat(r.onsite_rate_ttd)||0 }));
    jcConfig.equipment   = (eqRows  ||[]).map(r => ({ name:r.equipment_name, assetNo:r.asset_no||'', workshopRate:parseFloat(r.workshop_rate_ttd)||0, onsiteRate:parseFloat(r.onsite_rate_ttd)||0 }));
    jcConfig.materials   = (matRows ||[]).map(r => ({ id:r.id, name:r.item_name, unit:r.unit||'', cost:parseFloat(r.default_unit_cost_ttd)||0 }));
    jcConfig.consumables = (conRows ||[]).map(r => ({ id:r.id, name:r.item_name, unit:r.unit||'', cost:parseFloat(r.default_unit_cost_ttd)||0 }));
    jcConfig.hardware    = (hwRows  ||[]).map(r => ({ id:r.id, name:r.item_name, spec:r.spec||'', unit:r.unit||'', cost:parseFloat(r.default_unit_cost_ttd)||0 }));
    jcConfig.tooling     = (toolRows||[]).map(r => ({ id:r.id, name:r.item_name, code:r.stock_code||'', unit:r.unit||'', cost:parseFloat(r.default_unit_cost_ttd)||0 }));
    jcConfig.fuel        = (fuelRows||[]).map(r => ({ id:r.id, name:r.item_name, unit:r.unit||'', cost:parseFloat(r.default_unit_cost_ttd)||0 }));
    jcConfig.tasks       = (taskRows||[]).map(r => r.task_name);
    jcConfig.qcChecklists= (qcRows  ||[]).map(r => ({ item:r.checklist_item, jobType:r.job_type||'All' }));
    jcConfig.employees   = (empRows ||[]).map(r => ({ name:r.name, classification:r.job_classification||'' }));
    jcRefreshRowDropdowns();
  } catch(e) { console.error('jcLoadConfig:', e); }
}
```

- [ ] **Step 2: Extend `jcRefreshRowDropdowns`**

In the same function (`index.html:7338-7363`), after the `matOpts`/`conOpts` declarations add:

```js
  const hwOpts   = '<option value="">Select…</option>' + jcConfig.hardware.map(r => `<option value="${escHTML(r.name)}">${escHTML(r.name)}</option>`).join('');
  const toolOpts = '<option value="">Select…</option>' + jcConfig.tooling.map(r => `<option value="${escHTML(r.name)}">${escHTML(r.name)}</option>`).join('');
```

And after the existing `#jc-consumables-body` refresh block, add:

```js
  document.querySelectorAll('#jc-hardware-body tr').forEach(tr => {
    const sel = tr.querySelector('select'); if (!sel) return;
    const cur = sel.value; sel.innerHTML = hwOpts; sel.value = cur;
  });
  document.querySelectorAll('#jc-tooling-body tr').forEach(tr => {
    const sel = tr.querySelector('select'); if (!sel) return;
    const cur = sel.value; sel.innerHTML = toolOpts; sel.value = cur;
  });
```

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "feat: load Hardware/Tooling/Fuel catalogs into jcConfig"
```

---

## Task 6: Hardware & Tooling row functions (Work Order form)

Mirrors `jcAddMaterialRow`/`jcAddConsumableRow` exactly (`index.html:8287-8362`).

**Files:** Modify `meridian-erp/index.html` — insert after the existing Consumables block (after `jcUpdateConTotals`, `index.html:8356-8362`)

- [ ] **Step 1: Add Hardware row functions**

```js
// ── HARDWARE ──────────────────────────────────────────────────────
function jcAddHardwareRow(d) {
  const tbody=document.getElementById('jc-hardware-body'); if (!tbody) return;
  const rid='jc-hr-'+Date.now()+Math.random().toString(36).substr(2,4);
  const hwOpts='<option value="">Select…</option>'+jcConfig.hardware.map(r => `<option value="${escHTML(r.name)}" data-unit="${escHTML(r.unit)}" data-cost="${r.cost}" data-spec="${escHTML(r.spec)}">${escHTML(r.name)}</option>`).join('');
  const tr=document.createElement('tr'); tr.id=rid;
  tr.innerHTML=`
    <td><input type="date" value="${d&&d.date||''}"></td>
    <td><select onchange="jcOnHardwareChange(this,'${rid}')">${hwOpts}</select></td>
    <td><input type="text" placeholder="Size / Spec" id="${rid}-spec" value="${d&&d.spec||''}"></td>
    <td><input type="number" class="num" placeholder="0" value="${d&&d.qty||''}" step="1" oninput="jcUpdateHardwareRow('${rid}')"></td>
    <td><input type="text" placeholder="Unit" id="${rid}-unit" value="${d&&d.unit||''}" style="width:60px;"></td>
    <td><input type="number" class="num" placeholder="0.00" id="${rid}-cost" value="${d&&d.unitCost||''}" oninput="jcUpdateHardwareRow('${rid}')"></td>
    <td><span class="row-total" id="${rid}-amount">$0.00</span></td>
    <td><button class="btn-del" onclick="document.getElementById('${rid}').remove();jcUpdateHwTotals();jcUpdateCostSummary();">✕</button></td>`;
  tbody.appendChild(tr);
  if (d&&d.desc) tr.querySelector('select').value=d.desc;
  jcUpdateHardwareRow(rid);
}
function jcOnHardwareChange(sel, rid) {
  const opt=sel.options[sel.selectedIndex];
  if (opt) {
    const u=document.getElementById(rid+'-unit'),c=document.getElementById(rid+'-cost'),s=document.getElementById(rid+'-spec');
    if(u)u.value=opt.dataset.unit||''; if(c)c.value=parseFloat(opt.dataset.cost||0).toFixed(2); if(s&&!s.value)s.value=opt.dataset.spec||'';
  }
  jcUpdateHardwareRow(rid);
}
function jcUpdateHardwareRow(rid) {
  const tr=document.getElementById(rid); if (!tr) return;
  const qty=parseFloat(tr.querySelectorAll('input[type="number"]')[0]?.value)||0;
  const cost=parseFloat(document.getElementById(rid+'-cost')?.value)||0;
  const el=document.getElementById(rid+'-amount'); if(el) el.textContent='$'+(qty*cost).toFixed(2);
  jcUpdateHwTotals(); jcUpdateCostSummary();
}
function jcUpdateHwTotals() {
  let total=0;
  document.querySelectorAll('#jc-hardware-body tr').forEach(tr => {
    if (!tr.id) return; total+=parseFloat(document.getElementById(tr.id+'-amount')?.textContent.replace('$',''))||0;
  });
  const el=document.getElementById('jc-hardware-cost-total'); if(el) el.textContent='$'+total.toFixed(2);
}
```

- [ ] **Step 2: Add Tooling row functions**

```js
// ── TOOLING ───────────────────────────────────────────────────────
function jcAddToolingRow(d) {
  const tbody=document.getElementById('jc-tooling-body'); if (!tbody) return;
  const rid='jc-tr-'+Date.now()+Math.random().toString(36).substr(2,4);
  const toolOpts='<option value="">Select…</option>'+jcConfig.tooling.map(r => `<option value="${escHTML(r.name)}" data-unit="${escHTML(r.unit)}" data-cost="${r.cost}" data-code="${escHTML(r.code)}">${escHTML(r.name)}</option>`).join('');
  const tr=document.createElement('tr'); tr.id=rid;
  tr.innerHTML=`
    <td><input type="date" value="${d&&d.date||''}"></td>
    <td><select onchange="jcOnToolingChange(this,'${rid}')">${toolOpts}</select></td>
    <td><input type="text" placeholder="Stock code" id="${rid}-code" value="${d&&d.code||''}"></td>
    <td><input type="number" class="num" placeholder="0" value="${d&&d.qty||''}" step="1" oninput="jcUpdateToolingRow('${rid}')"></td>
    <td><input type="text" placeholder="Unit" id="${rid}-unit" value="${d&&d.unit||''}" style="width:60px;"></td>
    <td><input type="number" class="num" placeholder="0.00" id="${rid}-cost" value="${d&&d.unitCost||''}" oninput="jcUpdateToolingRow('${rid}')"></td>
    <td><span class="row-total" id="${rid}-amount">$0.00</span></td>
    <td><button class="btn-del" onclick="document.getElementById('${rid}').remove();jcUpdateToolTotals();jcUpdateCostSummary();">✕</button></td>`;
  tbody.appendChild(tr);
  if (d&&d.desc) tr.querySelector('select').value=d.desc;
  jcUpdateToolingRow(rid);
}
function jcOnToolingChange(sel, rid) {
  const opt=sel.options[sel.selectedIndex];
  if (opt) {
    const u=document.getElementById(rid+'-unit'),c=document.getElementById(rid+'-cost'),code=document.getElementById(rid+'-code');
    if(u)u.value=opt.dataset.unit||''; if(c)c.value=parseFloat(opt.dataset.cost||0).toFixed(2); if(code&&!code.value)code.value=opt.dataset.code||'';
  }
  jcUpdateToolingRow(rid);
}
function jcUpdateToolingRow(rid) {
  const tr=document.getElementById(rid); if (!tr) return;
  const qty=parseFloat(tr.querySelectorAll('input[type="number"]')[0]?.value)||0;
  const cost=parseFloat(document.getElementById(rid+'-cost')?.value)||0;
  const el=document.getElementById(rid+'-amount'); if(el) el.textContent='$'+(qty*cost).toFixed(2);
  jcUpdateToolTotals(); jcUpdateCostSummary();
}
function jcUpdateToolTotals() {
  let total=0;
  document.querySelectorAll('#jc-tooling-body tr').forEach(tr => {
    if (!tr.id) return; total+=parseFloat(document.getElementById(tr.id+'-amount')?.textContent.replace('$',''))||0;
  });
  const el=document.getElementById('jc-tooling-cost-total'); if(el) el.textContent='$'+total.toFixed(2);
}
```

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "feat: add Hardware and Tooling row functions to Work Order form"
```

---

## Task 7: Hardware & Tooling cards (Work Order form HTML)

**Files:** Modify `meridian-erp/index.html:3327-3373` (between the Materials card and the Sub-contractors card)

- [ ] **Step 1: Insert Hardware card after the Materials card** (after line 3349, before the `<!-- 6. Consumables -->` comment)

```html
            <!-- 5b. Hardware -->
            <div class="card">
              <div class="card-header"><span class="card-header-icon">🔩</span><span class="card-header-title">Hardware &amp; Fasteners Used</span></div>
              <div class="card-body">
                <p class="scroll-hint">← scroll to see all columns →</p>
                <div class="dyn-table-wrap">
                  <table class="dyn-table">
                    <thead><tr>
                      <th style="width:110px">Date</th><th>Hardware / Description</th>
                      <th style="width:130px">Size / Spec</th><th style="width:60px">Qty</th>
                      <th style="width:70px">Unit</th><th style="width:110px" class="right">Unit Cost (TTD)</th>
                      <th style="width:110px" class="right">Total Cost</th><th style="width:28px"></th>
                    </tr></thead>
                    <tbody id="jc-hardware-body"></tbody>
                    <tfoot><tr>
                      <td colspan="6" class="right" style="font-size:11px;">Total Hardware:</td>
                      <td id="jc-hardware-cost-total" class="right" style="font-family:'DM Mono',monospace;font-size:12px;font-weight:700;color:var(--gold);">$0.00</td><td></td>
                    </tr></tfoot>
                  </table>
                </div>
                <button class="btn-add-row" onclick="jcAddHardwareRow()">+ Add Hardware</button>
              </div>
            </div>
```

- [ ] **Step 2: Insert Tooling card after the Consumables card** (after line 3373, before the `<!-- 7. Sub-contractors -->` comment)

```html
            <!-- 6b. Tooling -->
            <div class="card">
              <div class="card-header"><span class="card-header-icon">⚙️</span><span class="card-header-title">Tooling Used</span></div>
              <div class="card-body">
                <p class="scroll-hint">← scroll to see all columns →</p>
                <div class="dyn-table-wrap">
                  <table class="dyn-table">
                    <thead><tr>
                      <th style="width:110px">Date</th><th>Tool / Description</th>
                      <th style="width:110px">Stock Code</th><th style="width:60px">Qty</th>
                      <th style="width:70px">Unit</th><th style="width:110px" class="right">Unit Cost (TTD)</th>
                      <th style="width:110px" class="right">Total Cost</th><th style="width:28px"></th>
                    </tr></thead>
                    <tbody id="jc-tooling-body"></tbody>
                    <tfoot><tr>
                      <td colspan="6" class="right" style="font-size:11px;">Total Tooling:</td>
                      <td id="jc-tooling-cost-total" class="right" style="font-family:'DM Mono',monospace;font-size:12px;font-weight:700;color:var(--gold);">$0.00</td><td></td>
                    </tr></tfoot>
                  </table>
                </div>
                <button class="btn-add-row" onclick="jcAddToolingRow()">+ Add Tool</button>
              </div>
            </div>
```

- [ ] **Step 3: Add Hardware and Tooling rows to the Costing Summary table** (`index.html:3404-3411`)

Change:
```html
                        <tr><td>Materials &amp; Stock</td><td id="jc-cs-materials">$0.00</td></tr>
                        <tr><td>Consumables</td><td id="jc-cs-consumables">$0.00</td></tr>
```
to:
```html
                        <tr><td>Materials &amp; Stock</td><td id="jc-cs-materials">$0.00</td></tr>
                        <tr><td>Hardware</td><td id="jc-cs-hardware">$0.00</td></tr>
                        <tr><td>Consumables</td><td id="jc-cs-consumables">$0.00</td></tr>
                        <tr><td>Tooling</td><td id="jc-cs-tooling">$0.00</td></tr>
```

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "feat: add Hardware and Tooling cards to Work Order form"
```

- [ ] **Step 5: Manual verify**

Run the app, open a Work Order, confirm "Hardware & Fasteners Used" card appears after Materials, "Tooling Used" appears after Consumables, "+ Add Hardware"/"+ Add Tool" add rows, and the Costing Summary shows Hardware/Tooling lines (both `$0.00` until a row has qty+cost).

---

## Task 8: Equipment row — fuel sub-fields

**Files:** Modify `meridian-erp/index.html:3301-3325` (Equipment card HTML) and `index.html:8231-8284` (`jcAddEquipRow` and related functions)

- [ ] **Step 1: Add fuel columns to the Equipment table header** (`index.html:3308-3313`)

Change:
```html
                    <thead><tr>
                      <th style="width:110px">Date</th><th style="width:180px">Machine / Equipment</th>
                      <th style="width:100px">Asset No.</th><th style="width:110px">Location</th>
                      <th style="width:85px" class="right">Setup (hrs)</th><th style="width:85px" class="right">Run (hrs)</th>
                      <th style="width:105px" class="right">Rate/hr (TTD)</th><th style="width:95px" class="right">Amount</th>
                      <th style="width:28px"></th>
                    </tr></thead>
```
to:
```html
                    <thead><tr>
                      <th style="width:110px">Date</th><th style="width:180px">Machine / Equipment</th>
                      <th style="width:100px">Asset No.</th><th style="width:110px">Location</th>
                      <th style="width:85px" class="right">Setup (hrs)</th><th style="width:85px" class="right">Run (hrs)</th>
                      <th style="width:105px" class="right">Rate/hr (TTD)</th><th style="width:95px" class="right">Amount</th>
                      <th style="width:110px">Fuel Type</th><th style="width:70px" class="right">Fuel Qty</th>
                      <th style="width:100px" class="right">Fuel Cost</th><th style="width:100px" class="right">Fuel Amount</th>
                      <th style="width:28px"></th>
                    </tr></thead>
```

Also update the `<tfoot>` colspan (`index.html:3316-3320`) from `colspan="7"` to `colspan="11"` so the "Total Machine Cost" label still spans correctly up to the amount column — actually the total column itself stays put; change the label cell colspan from 7 to 7 (unchanged, it precedes the original Amount column) and add three empty `<td>` after the total cell to cover the new Fuel columns before the trailing blank delete-button column:

```html
                    <tfoot><tr>
                      <td colspan="7" class="right" style="font-size:11px;">Total Machine Cost:</td>
                      <td id="jc-equip-cost-total" class="right" style="font-family:'DM Mono',monospace;font-size:12px;font-weight:700;color:var(--gold);">$0.00</td>
                      <td colspan="4"></td>
                    </tr></tfoot>
```

- [ ] **Step 2: Update `jcAddEquipRow` to render the fuel cells**

In `index.html:8237-8248`, change the row `innerHTML` from:
```js
  tr.innerHTML=`
    <td><input type="date" value="${d&&d.date||''}"></td>
    <td><select onchange="jcOnEquipChange(this,'${rid}')">${eqOpts}</select></td>
    <td><input type="text" placeholder="Asset No." value="${d&&d.asset||''}"></td>
    <td><select onchange="jcOnEquipChange(document.getElementById('${rid}').querySelectorAll('select')[0],'${rid}')">
      <option value="Workshop">Workshop</option><option value="Onsite">Onsite</option><option value="Other">Other</option>
    </select></td>
    <td><input type="number" class="num" placeholder="0.00" value="${d&&d.setup||''}" step="0.25" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><input type="number" class="num" placeholder="0.00" value="${d&&d.run||''}" step="0.25" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><input type="number" class="num" placeholder="0.00" id="${rid}-rate" value="${d&&d.rate||''}" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><span class="row-total" id="${rid}-amount">$0.00</span></td>
    <td><button class="btn-del" onclick="jcRemoveEquipRow('${rid}')">✕</button></td>`;
```
to:
```js
  const fuelOpts = '<option value="">None</option>'+jcConfig.fuel.map(r => `<option value="${escHTML(r.name)}" data-cost="${r.cost}">${escHTML(r.name)}</option>`).join('');
  tr.innerHTML=`
    <td><input type="date" value="${d&&d.date||''}"></td>
    <td><select onchange="jcOnEquipChange(this,'${rid}')">${eqOpts}</select></td>
    <td><input type="text" placeholder="Asset No." value="${d&&d.asset||''}"></td>
    <td><select onchange="jcOnEquipChange(document.getElementById('${rid}').querySelectorAll('select')[0],'${rid}')">
      <option value="Workshop">Workshop</option><option value="Onsite">Onsite</option><option value="Other">Other</option>
    </select></td>
    <td><input type="number" class="num" placeholder="0.00" value="${d&&d.setup||''}" step="0.25" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><input type="number" class="num" placeholder="0.00" value="${d&&d.run||''}" step="0.25" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><input type="number" class="num" placeholder="0.00" id="${rid}-rate" value="${d&&d.rate||''}" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><span class="row-total" id="${rid}-amount">$0.00</span></td>
    <td><select id="${rid}-fueltype" onchange="jcOnFuelTypeChange('${rid}')">${fuelOpts}</select></td>
    <td><input type="number" class="num" placeholder="0" id="${rid}-fuelqty" value="${d&&d.fuelQty||''}" step="0.1" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><input type="number" class="num" placeholder="0.00" id="${rid}-fuelcost" value="${d&&d.fuelUnitCost||''}" oninput="jcUpdateEquipRow('${rid}')"></td>
    <td><span class="row-total" id="${rid}-fuelamount">$0.00</span></td>
    <td><button class="btn-del" onclick="jcRemoveEquipRow('${rid}')">✕</button></td>`;
```

And after the row is appended (after the existing `if (d&&d.location) ...` line, `index.html:8254`), add:

```js
  if (d&&d.fuelType) document.getElementById(rid+'-fueltype').value = d.fuelType;
```

- [ ] **Step 3: Add `jcOnFuelTypeChange` and extend `jcUpdateEquipRow`**

Add new function after `jcOnEquipChange` (`index.html:8258-8265`):

```js
function jcOnFuelTypeChange(rid) {
  const sel = document.getElementById(rid+'-fueltype');
  const opt = sel?.options[sel.selectedIndex];
  const costEl = document.getElementById(rid+'-fuelcost');
  if (opt && costEl) costEl.value = parseFloat(opt.dataset.cost||0).toFixed(2);
  jcUpdateEquipRow(rid);
}
```

Replace `jcUpdateEquipRow` (`index.html:8266-8272`) with:

```js
function jcUpdateEquipRow(rid) {
  const tr=document.getElementById(rid); if (!tr) return;
  const nums=tr.querySelectorAll('input[type="number"]');
  const amt=((parseFloat(nums[0]?.value)||0)+(parseFloat(nums[1]?.value)||0))*(parseFloat(document.getElementById(rid+'-rate')?.value)||0);
  const amtEl=document.getElementById(rid+'-amount'); if (amtEl) amtEl.textContent='$'+amt.toFixed(2);
  const fuelQty=parseFloat(document.getElementById(rid+'-fuelqty')?.value)||0;
  const fuelCost=parseFloat(document.getElementById(rid+'-fuelcost')?.value)||0;
  const fuelAmtEl=document.getElementById(rid+'-fuelamount'); if (fuelAmtEl) fuelAmtEl.textContent='$'+(fuelQty*fuelCost).toFixed(2);
  jcUpdateEquipTotals(); jcUpdateCostSummary();
}
```

- [ ] **Step 4: Extend `jcUpdateEquipTotals` to fold fuel amount into the Equipment total**

Replace (`index.html:8277-8284`):

```js
function jcUpdateEquipTotals() {
  let total=0;
  document.querySelectorAll('#jc-equip-body tr:not(.jc-task-subrows)').forEach(tr => {
    const rid=tr.id; if (!rid||!rid.startsWith('jc-er-')) return;
    total+=parseFloat(document.getElementById(rid+'-amount')?.textContent.replace('$',''))||0;
    total+=parseFloat(document.getElementById(rid+'-fuelamount')?.textContent.replace('$',''))||0;
  });
  const el=document.getElementById('jc-equip-cost-total'); if (el) el.textContent='$'+total.toFixed(2);
}
```

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: add fuel sub-fields to Equipment rows in Work Order form"
```

- [ ] **Step 6: Manual verify**

Run the app, open a Work Order, add an Equipment row, confirm Fuel Type/Qty/Cost/Amount columns render, selecting a fuel type autofills cost from `config_fuel` (add a test fuel row via Job Config first if none exist), and the equipment total includes the fuel amount.

---

## Task 9: Save — `jcCollectFormData` and `jcSaveJobData`

**Files:** Modify `meridian-erp/index.html:7861-7955` (`jcCollectFormData`), `index.html:7590-7689` (`jcSaveJobData`)

- [ ] **Step 1: Collect Hardware/Tooling rows and equipment fuel fields in `jcCollectFormData`**

After the `matsDetail`/`consDetail` blocks (`index.html:7891-7900`), add:

```js
  const hwDetail = [];
  document.querySelectorAll('#jc-hardware-body tr').forEach(tr => {
    if (!tr.id) return; const inputs=tr.querySelectorAll('input');
    hwDetail.push({ date:inputs[0]?.value||'', desc:tr.querySelector('select')?.value||'', spec:document.getElementById(tr.id+'-spec')?.value||'', qty:inputs[1]?.value||'0', unit:document.getElementById(tr.id+'-unit')?.value||'', unitCost:document.getElementById(tr.id+'-cost')?.value||'0' });
  });
  const toolDetail = [];
  document.querySelectorAll('#jc-tooling-body tr').forEach(tr => {
    if (!tr.id) return; const inputs=tr.querySelectorAll('input');
    toolDetail.push({ date:inputs[0]?.value||'', desc:tr.querySelector('select')?.value||'', code:document.getElementById(tr.id+'-code')?.value||'', qty:inputs[1]?.value||'0', unit:document.getElementById(tr.id+'-unit')?.value||'', unitCost:document.getElementById(tr.id+'-cost')?.value||'0' });
  });
```

Note: unlike Materials/Consumables (where qty is `inputs[2]` because Stock Code/Category is a plain text `<input>` at index 1), Hardware's Spec field uses a dedicated `id`-based lookup (`${rid}-spec`) rather than a positional input — so qty is `inputs[1]` here (date is `inputs[0]`, qty is the only other plain unlabeled number input at position 1 since spec/unit/cost all have ids). Same reasoning for Tooling's `code` field.

Extend `equipDetail` collection (`index.html:7883-7890`) — replace with:

```js
  const equipDetail = [];
  document.querySelectorAll('#jc-equip-body tr:not(.jc-task-subrows)').forEach(tr => {
    const rid = tr.id; if (!rid||!rid.startsWith('jc-er-')) return;
    const inputs=tr.querySelectorAll('input'), sels=tr.querySelectorAll('select'), tasks=[];
    const tc = document.getElementById(rid+'-taskcontainer');
    if (tc) tc.querySelectorAll('.jc-task-subrow').forEach(d => tasks.push({ task:d.querySelector('select')?.value||'', note:d.querySelector('input')?.value||'' }));
    equipDetail.push({
      date:inputs[0]?.value||'', machine:sels[0]?.value||'', asset:inputs[1]?.value||'', location:sels[1]?.value||'Workshop',
      setup:inputs[2]?.value||'0', run:inputs[3]?.value||'0', rate:document.getElementById(rid+'-rate')?.value||'0',
      amount:(document.getElementById(rid+'-amount')?.textContent||'$0').replace('$',''), tasks,
      fuelType: document.getElementById(rid+'-fueltype')?.value||'',
      fuelQty: document.getElementById(rid+'-fuelqty')?.value||'0',
      fuelUnitCost: document.getElementById(rid+'-fuelcost')?.value||'0',
      fuelAmount: (document.getElementById(rid+'-fuelamount')?.textContent||'$0').replace('$',''),
    });
  });
```

Add `hwDetail`/`toolDetail` to the returned object (`index.html:7951-7953`):

```js
    labourDetail:  JSON.stringify(labourDetail), equipDetail: JSON.stringify(equipDetail),
    matsDetail:    JSON.stringify(matsDetail),   consDetail:  JSON.stringify(consDetail),
    hwDetail:      JSON.stringify(hwDetail),     toolDetail:  JSON.stringify(toolDetail),
    subsDetail:    JSON.stringify(subsDetail),
```

- [ ] **Step 2: Persist Hardware/Tooling entries and equipment fuel columns in `jcSaveJobData`**

Add `'hardware_entries','tooling_entries'` to the cleanup array (`index.html:7641-7642`):

```js
  await Promise.all(['labour_entries','equipment_entries','material_entries','consumable_entries','hardware_entries','tooling_entries','subcontractor_entries']
    .map(t => sbDeleteWhere(t, `job_id=eq.${savedId}`)));
```

Extend the `equip` insert block (`index.html:7649-7654`) to include fuel columns:

```js
  const equip = parse(data.equipDetail);
  if (equip.length) await sbPost('equipment_entries', equip.map((r,i) => ({
    job_id:savedId, sort_order:i, entry_date:r.date||null, machine_name:r.machine||null,
    asset_no:r.asset||null, location:r.location||'Workshop', setup_hours:parseFloat(r.setup)||0,
    run_hours:parseFloat(r.run)||0, rate_ttd:parseFloat(r.rate)||0, amount_ttd:parseFloat(r.amount)||0, tasks:r.tasks||[],
    fuel_type:r.fuelType||null, fuel_qty:parseFloat(r.fuelQty)||0, fuel_unit_cost_ttd:parseFloat(r.fuelUnitCost)||0,
    fuel_amount_ttd:parseFloat(r.fuelAmount)||0
  })));
```

After the existing `cons` insert block (`index.html:7661-7666`), add:

```js
  const hw = parse(data.hwDetail);
  if (hw.length) await sbPost('hardware_entries', hw.map((r,i) => ({
    job_id:savedId, sort_order:i, entry_date:r.date||null, description:r.desc||null, spec:r.spec||null,
    quantity:parseFloat(r.qty)||0, unit:r.unit||null, unit_cost_ttd:parseFloat(r.unitCost)||0,
    total_cost_ttd:(parseFloat(r.qty)||0)*(parseFloat(r.unitCost)||0)
  })));
  const tool = parse(data.toolDetail);
  if (tool.length) await sbPost('tooling_entries', tool.map((r,i) => ({
    job_id:savedId, sort_order:i, entry_date:r.date||null, description:r.desc||null, stock_code:r.code||null,
    quantity:parseFloat(r.qty)||0, unit:r.unit||null, unit_cost_ttd:parseFloat(r.unitCost)||0,
    total_cost_ttd:(parseFloat(r.qty)||0)*(parseFloat(r.unitCost)||0)
  })));
```

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "feat: persist Hardware/Tooling entries and equipment fuel data on job save"
```

---

## Task 10: Load — `jcOpenJob`, `jcPopulateForm`, `jcDuplicateJob`

**Files:** Modify `meridian-erp/index.html:7692-7804` (`jcOpenJob`, `jcPopulateForm`), `index.html:7826-7858` (`jcDuplicateJob`)

- [ ] **Step 1: Fetch new entry tables in `jcOpenJob`**

Replace the `Promise.all` array (`index.html:7698-7706`):

```js
    const [jr, lr, er, mr, cr, hr, tr2, sr, dr] = await Promise.all([
      sbGet('jobs',                  `id=eq.${jobId}&limit=1`),
      sbGet('labour_entries',        `job_id=eq.${jobId}&order=sort_order`),
      sbGet('equipment_entries',     `job_id=eq.${jobId}&order=sort_order`),
      sbGet('material_entries',      `job_id=eq.${jobId}&order=sort_order`),
      sbGet('consumable_entries',    `job_id=eq.${jobId}&order=sort_order`),
      sbGet('hardware_entries',      `job_id=eq.${jobId}&order=sort_order`),
      sbGet('tooling_entries',       `job_id=eq.${jobId}&order=sort_order`),
      sbGet('subcontractor_entries', `job_id=eq.${jobId}&order=sort_order`),
      sbGet('job_drawings',          `job_id=eq.${jobId}&order=created_at.asc`),
    ]);
```

(`tr2` avoids shadowing the outer `tr` used elsewhere in the file's row-builder helpers — this variable is local to `jcOpenJob` only.)

Extend the `Equipment Detail` mapping (`index.html:7731`) to include fuel fields:

```js
      'Equipment Detail': JSON.stringify((er||[]).map(r => ({ date:r.entry_date||'', machine:r.machine_name||'', asset:r.asset_no||'', location:r.location||'Workshop', setup:String(r.setup_hours||0), run:String(r.run_hours||0), rate:String(r.rate_ttd||0), amount:String(r.amount_ttd||0), tasks:r.tasks||[], fuelType:r.fuel_type||'', fuelQty:String(r.fuel_qty||0), fuelUnitCost:String(r.fuel_unit_cost_ttd||0), fuelAmount:String(r.fuel_amount_ttd||0) }))),
```

After the `Consumables Detail` line (`index.html:7733`), add:

```js
      'Hardware Detail': JSON.stringify((hr||[]).map(r => ({ date:r.entry_date||'', desc:r.description||'', spec:r.spec||'', qty:String(r.quantity||0), unit:r.unit||'', unitCost:String(r.unit_cost_ttd||0) }))),
      'Tooling Detail': JSON.stringify((tr2||[]).map(r => ({ date:r.entry_date||'', desc:r.description||'', code:r.stock_code||'', qty:String(r.quantity||0), unit:r.unit||'', unitCost:String(r.unit_cost_ttd||0) }))),
```

- [ ] **Step 2: Populate the new rows in `jcPopulateForm`**

Add the two new tbody ids to the clear list (`index.html:7773`):

```js
  ['jc-labour-body','jc-equip-body','jc-materials-body','jc-consumables-body','jc-hardware-body','jc-tooling-body','jc-subs-body','jc-drawings-body','jc-specs-body','jc-reports-body']
    .forEach(id => { const el=document.getElementById(id); if (el) el.innerHTML=''; });
```

After `parse(row['Consumables Detail']).forEach(d => jcAddConsumableRow(d));` (`index.html:7780`), add:

```js
  parse(row['Hardware Detail']).forEach(d => jcAddHardwareRow(d));
  parse(row['Tooling Detail']).forEach(d => jcAddToolingRow(d));
```

- [ ] **Step 3: Extend `jcDuplicateJob`**

Add the two new tbody ids to its clear list (`index.html:7843`):

```js
  ['jc-labour-body','jc-equip-body','jc-materials-body','jc-consumables-body','jc-hardware-body','jc-tooling-body','jc-subs-body','jc-drawings-body','jc-specs-body','jc-reports-body']
    .forEach(id => { const el=document.getElementById(id); if(el) el.innerHTML=''; });
```

After `parse(original.consDetail).forEach(d => jcAddConsumableRow(d));` (`index.html:7850`), add:

```js
  parse(original.hwDetail).forEach(d => jcAddHardwareRow(d));
  parse(original.toolDetail).forEach(d => jcAddToolingRow(d));
```

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "feat: load Hardware/Tooling entries and equipment fuel on job open/duplicate"
```

---

## Task 11: Costing Summary — Hardware and Tooling totals

**Files:** Modify `meridian-erp/index.html:8727-8755` (`jcUpdateCostSummary`)

- [ ] **Step 1: Replace `jcUpdateCostSummary`**

```js
function jcUpdateCostSummary() {
  const getNum = id => parseFloat(document.getElementById(id)?.textContent.replace('$',''))||0;
  const labour=getNum('jc-labour-cost-total'), equip=getNum('jc-equip-cost-total'),
        mats  =getNum('jc-materials-cost-total'), cons=getNum('jc-consumables-cost-total'),
        hw    =getNum('jc-hardware-cost-total'), tool=getNum('jc-tooling-cost-total'),
        subs  =getNum('jc-subs-cost-total'), misc=parseFloat(document.getElementById('jc-cs-misc')?.value)||0;
  const total = labour+equip+mats+cons+hw+tool+subs+misc;
  const setText=(id,v)=>{ const el=document.getElementById(id); if(el) el.textContent=v; };
  setText('jc-cs-labour','$'+labour.toFixed(2)); setText('jc-cs-equip','$'+equip.toFixed(2));
  setText('jc-cs-materials','$'+mats.toFixed(2)); setText('jc-cs-consumables','$'+cons.toFixed(2));
  setText('jc-cs-hardware','$'+hw.toFixed(2));    setText('jc-cs-tooling','$'+tool.toFixed(2));
  setText('jc-cs-subs','$'+subs.toFixed(2));      setText('jc-cs-total','$'+total.toFixed(2));
  const markup  = parseFloat(document.getElementById('jc-markup-pct')?.value)||0;
  const selling = total*(1+markup/100), profit=selling-total;
  const spEl=document.getElementById('jc-selling-price'), gpEl=document.getElementById('jc-gross-profit');
  if (spEl) spEl.value=selling.toFixed(2); if (gpEl) gpEl.value=profit.toFixed(2);
  const pi=document.getElementById('jc-profit-indicator');
  if (pi) {
    if (markup<=0)    { pi.className='profit-indicator neutral'; pi.textContent='— Enter markup to see margin'; }
    else if (markup>=20){ pi.className='profit-indicator healthy'; pi.textContent=`✓ Healthy: ${markup}% markup — $${profit.toFixed(2)} profit`; }
    else if (markup>=10){ pi.className='profit-indicator warn';    pi.textContent=`⚡ Low: ${markup}% markup — $${profit.toFixed(2)} profit`; }
    else               { pi.className='profit-indicator danger';  pi.textContent=`⚠ Very low: ${markup}% markup`; }
  }
  const quoted=parseFloat(document.getElementById('jc-f-quoted-2')?.value)||0;
  const overEl=document.getElementById('jc-cost-over'), nearEl=document.getElementById('jc-cost-near');
  if (overEl&&nearEl) {
    if (quoted>0&&total>quoted) { overEl.classList.add('show'); nearEl.classList.remove('show'); overEl.textContent=`⚠ Job cost ($${total.toFixed(2)}) exceeds quoted ($${quoted.toFixed(2)}) by $${(total-quoted).toFixed(2)}!`; }
    else if (quoted>0&&total>=quoted*0.85) { nearEl.classList.add('show'); overEl.classList.remove('show'); nearEl.textContent=`⚡ Job cost is ${Math.round((total/quoted)*100)}% of quoted amount.`; }
    else { overEl.classList.remove('show'); nearEl.classList.remove('show'); }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add index.html
git commit -m "feat: fold Hardware and Tooling into job Costing Summary"
```

- [ ] **Step 3: Manual verify (Tasks 5-11 combined)**

Run the app: open a Work Order, add one Hardware row (qty 10, cost 5.00) and one Tooling row (qty 2, cost 50.00), confirm Costing Summary shows Hardware `$50.00`, Tooling `$100.00`, and Total Job Cost includes both. Save the job, reload the page, reopen the same job, confirm both rows persist with correct values. Query directly to confirm:

```sql
select * from hardware_entries where job_id = '<job-id>';
select * from tooling_entries where job_id = '<job-id>';
```

---

## Task 12: AP Bill Lines — inventory link UI

This is the core of Phase 1: letting a bill line optionally point at a catalog item.

**Files:** Modify `meridian-erp/index.html:11299-11313` (`addBillLine`), add new functions near it, modify `index.html:11370-11428` (`saveBill`)

- [ ] **Step 1: Add a shared catalog-loader guard for the AP module**

`jcConfig` is populated by `jcLoadConfig()`, which today is only called when the Work Orders module loads. If a user opens a bill without ever visiting Work Orders, `jcConfig.materials` etc. will be empty. Add this helper near `openNewBill` (`index.html:11274`):

```js
async function ensureJobConfigLoaded() {
  if (!jcConfig || !jcConfig.materials || !jcConfig.materials.length) {
    await jcLoadConfig();
  }
}
```

Call it at the top of `openNewBill()` (`index.html:11274`) — change the function signature and first line:

```js
async function openNewBill() {
  await ensureJobConfigLoaded();
  document.getElementById('bill-vendor-search').value   = '';
```

(the rest of `openNewBill` is unchanged)

- [ ] **Step 2: Rewrite `addBillLine` to include the inventory-link toggle**

Replace (`index.html:11299-11313`):

```js
const BILL_LINE_CATEGORIES = [
  { value:'material',   label:'Material',   cfgKey:'materials'   },
  { value:'hardware',   label:'Hardware',   cfgKey:'hardware'    },
  { value:'consumable', label:'Consumable', cfgKey:'consumables' },
  { value:'tooling',    label:'Tooling',    cfgKey:'tooling'     },
  { value:'equipment',  label:'Equipment',  cfgKey:null          },
];

function addBillLine() {
  const tbody = document.getElementById('bill-lines-body');
  const n     = tbody.rows.length ? tbody.rows.length / 2 + 1 : 1;
  const lid   = 'billl-' + Date.now() + '-' + Math.random().toString(36).substr(2,4);
  const tr    = document.createElement('tr');
  tr.id = lid;
  tr.innerHTML = `
    <td style="padding:6px 8px;color:var(--text-3);font-size:11px;font-family:'DM Mono',monospace;">${n}</td>
    <td><input type="text" placeholder="Item description…" style="min-width:200px;" id="${lid}-desc"></td>
    <td><input type="number" class="mono" placeholder="1" value="1" min="0" step="any" oninput="recalcBillTotals()"></td>
    <td><input type="number" class="mono" placeholder="0.00" min="0" step="0.01" oninput="recalcBillTotals()" id="${lid}-rate"></td>
    <td><div class="inv-line-amount" id="${lid}-amt">0.00</div></td>
    <td><button class="btn btn-ghost btn-icon btn-sm" onclick="document.getElementById('${lid}').remove();document.getElementById('${lid}-link').remove();recalcBillTotals();" style="color:var(--text-3);">✕</button></td>`;
  tbody.appendChild(tr);

  const linkTr = document.createElement('tr');
  linkTr.id = lid + '-link';
  linkTr.innerHTML = `<td></td><td colspan="5" style="padding:2px 8px 10px;">
    <label style="font-size:10px;color:var(--text-3);display:inline-flex;align-items:center;gap:6px;cursor:pointer;">
      <input type="checkbox" onchange="jcToggleBillLineLink('${lid}',this.checked)"> Link to Inventory
    </label>
    <div id="${lid}-linkbody" style="display:none;margin-top:6px;"></div>
  </td>`;
  tbody.appendChild(linkTr);
}

function jcToggleBillLineLink(lid, on) {
  const body = document.getElementById(lid+'-linkbody');
  if (!body) return;
  if (!on) { body.style.display='none'; body.innerHTML=''; return; }
  body.style.display='';
  const catOpts = BILL_LINE_CATEGORIES.map(c => `<option value="${c.value}">${c.label}</option>`).join('');
  body.innerHTML = `
    <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
      <select id="${lid}-cat" onchange="jcOnBillLineCategoryChange('${lid}')" style="max-width:140px;">
        <option value="">Category…</option>${catOpts}
      </select>
      <div id="${lid}-itemwrap" style="flex:1;min-width:200px;"></div>
    </div>`;
}

function jcOnBillLineCategoryChange(lid) {
  const cat = document.getElementById(lid+'-cat')?.value;
  const wrap = document.getElementById(lid+'-itemwrap');
  if (!wrap) return;
  const meta = BILL_LINE_CATEGORIES.find(c => c.value === cat);
  if (!meta) { wrap.innerHTML=''; return; }
  if (cat === 'equipment') {
    wrap.innerHTML = `
      <div style="display:flex;gap:6px;flex-wrap:wrap;">
        <input type="text" id="${lid}-eq-name" placeholder="Equipment name" style="min-width:140px;">
        <input type="text" id="${lid}-eq-asset" placeholder="Asset No.">
        <input type="number" id="${lid}-eq-wsrate" placeholder="Workshop rate/hr">
        <input type="number" id="${lid}-eq-osrate" placeholder="Onsite rate/hr">
      </div>
      <div style="font-size:9px;color:var(--text-3);margin-top:3px;">Approving this bill will create a new Equipment asset with these details.</div>`;
    return;
  }
  const items = jcConfig[meta.cfgKey] || [];
  const opts = items.map((r,i) => `<option value="${i}">${escHTML(r.name)}</option>`).join('');
  wrap.innerHTML = `
    <select id="${lid}-item" onchange="jcOnBillLineItemChange('${lid}')" style="min-width:180px;">
      <option value="">Select existing item…</option>${opts}
      <option value="__new__">+ Add new item…</option>
    </select>
    <div id="${lid}-newitemwrap" style="margin-top:6px;"></div>`;
}

function jcOnBillLineItemChange(lid) {
  const sel = document.getElementById(lid+'-item');
  const newWrap = document.getElementById(lid+'-newitemwrap');
  if (sel?.value === '__new__') {
    newWrap.innerHTML = `<input type="text" id="${lid}-newitem-name" placeholder="New item name" style="min-width:180px;">`;
  } else {
    newWrap.innerHTML = '';
  }
}
```

- [ ] **Step 3: Collect the link data in `saveBill`**

Replace the line-collection loop (`index.html:11377-11387`):

```js
  const lines = []; let subtotal = 0;
  document.querySelectorAll('#bill-lines-body tr[id^="billl-"]:not([id$="-link"])').forEach(tr => {
    const idx = lines.length;
    const inputs = tr.querySelectorAll('input[type="number"]');
    const descEl = document.getElementById(tr.id+'-desc');
    const qty = parseFloat(inputs[0]?.value)||0, rate = parseFloat(inputs[1]?.value)||0;
    const desc = descEl?.value.trim()||'';
    if (!desc && !qty && !rate) return;
    if (!desc) { showToast(`Line ${idx+1}: description required.`, 'warn'); return; }
    const amt = round2(qty * rate); subtotal += amt;
    const line = { description: desc, quantity: qty, unit_price: rate, amount: amt, line_order: idx };

    const cat = document.getElementById(tr.id+'-cat')?.value;
    if (cat) {
      line.item_category = cat;
      if (cat === 'equipment') {
        line._newEquipment = {
          name: document.getElementById(tr.id+'-eq-name')?.value.trim() || desc,
          asset_no: document.getElementById(tr.id+'-eq-asset')?.value.trim() || null,
          workshop_rate_ttd: parseFloat(document.getElementById(tr.id+'-eq-wsrate')?.value) || 0,
          onsite_rate_ttd: parseFloat(document.getElementById(tr.id+'-eq-osrate')?.value) || 0,
        };
      } else {
        const itemSel = document.getElementById(tr.id+'-item');
        if (itemSel?.value === '__new__') {
          line._newItemName = document.getElementById(tr.id+'-newitem-name')?.value.trim() || desc;
          line._newItemTable = { material:'config_materials', hardware:'config_hardware', consumable:'config_consumables', tooling:'config_tooling' }[cat];
        } else if (itemSel?.value) {
          const meta = BILL_LINE_CATEGORIES.find(c => c.value === cat);
          const catalogItem = (jcConfig[meta.cfgKey]||[])[parseInt(itemSel.value)];
          if (catalogItem) line.item_id = catalogItem.id;
        }
      }
    }
    lines.push(line);
  });
```

- [ ] **Step 4: Verify manually**

Run the app, open Finance → AP → New Bill, check "Link to Inventory" on a line, pick "Material" category, confirm the item picker populates from `config_materials` (add one via Job Config first if empty), select "+ Add new item…", confirm a name field appears. Pick "Equipment" category, confirm the name/asset/rate fields appear instead of a picker.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: add inventory-link UI to AP bill lines"
```

---

## Task 13: Approval-time catalog sync

This is where the actual "eliminate duplicate entry" behavior lands: approving a bill pushes cost/asset data into the relevant catalog.

**Known gap, designed around rather than solved:** a bill saved as **draft** with a line linked to "+ Add new item…" (or a new Equipment asset) has nowhere to persist the intended new-item name until the catalog row actually exists — `bill_lines.item_id` is null until then. Replaying "create new catalog item" from a stored `bill_lines` row alone isn't possible. So for Phase 1: **new catalog items / new equipment assets can only be created via the immediate "Save & Approve" path.** Saving as a draft with a "+ Add new item…" line strips the link and warns the user; existing-item links (picking an already-created row) work fine on drafts since `item_id` is stored and resolved later at approval time. This is why the two entry points below (`saveBill` and `approveBill`) end up doing different things — `saveBill` handles both new-item creation and existing-item cost sync (immediate-approve only), `approveBill` only ever handles existing-item cost sync (drafts can't carry new-item data forward).

**Files:** Modify `meridian-erp/index.html:11370-11428` (`saveBill`), `index.html:9493-9513` (`approveBill`)

- [ ] **Step 1: Guard against "new item" links on a draft save**

In `saveBill`, inside the line-building loop from Task 12 Step 3, right before `lines.push(line);`, add:

```js
    if (cat && status === 'draft' && (line._newEquipment || line._newItemName)) {
      showToast(`Line ${idx+1}: new catalog items can only be linked when saving with "Save & Approve". Saved without an inventory link.`, 'warn');
      delete line.item_category;
      delete line._newEquipment;
      delete line._newItemName;
      delete line._newItemTable;
    }
```

- [ ] **Step 2: Add the immediate-approve sync function**

Add this new function near `saveBill` (`index.html:11370`):

```js
async function jcSyncBillLineCatalog(line) {
  // line: one entry from the `lines` array built in saveBill(), carrying
  // _newEquipment (new asset) or _newItemName+_newItemTable (new catalog item)
  // or item_category+item_id (existing catalog item, cost sync only)
  if (line._newEquipment) {
    await sbPost('config_equipment', {
      equipment_name: line._newEquipment.name,
      shop_number: line._newEquipment.asset_no,
      workshop_rate_ttd: line._newEquipment.workshop_rate_ttd,
      onsite_rate_ttd: line._newEquipment.onsite_rate_ttd,
      status: 'approved', is_active: true,
      submitted_by: currentUser.auth_user_id,
    });
    return;
  }
  if (line._newItemTable && line._newItemName) {
    await sbPost(line._newItemTable, {
      item_name: line._newItemName,
      default_unit_cost_ttd: line.unit_price,
      status: 'approved', is_active: true,
      submitted_by: currentUser.auth_user_id,
    });
    return;
  }
  if (line.item_category && line.item_category !== 'equipment' && line.item_id) {
    const table = { material:'config_materials', hardware:'config_hardware', consumable:'config_consumables', tooling:'config_tooling' }[line.item_category];
    await sbPatch(table, line.item_id, { default_unit_cost_ttd: line.unit_price });
  }
}

async function jcSyncBillCatalogOnApproval(lines) {
  const linked = (lines||[]).filter(l => l.item_category);
  if (!linked.length) return;
  await Promise.all(linked.map(l => jcSyncBillLineCatalog(l).catch(e => console.error('jcSyncBillLineCatalog:', e))));
  jcLoadConfig().catch(() => {});
}
```

- [ ] **Step 3: Call it from `saveBill`, and strip helper fields before the `bill_lines` insert**

Replace `await sbPost('bill_lines', lines.map(l => ({ bill_id: bill.id, ...l })));` (`index.html:11421`) with:

```js
    await sbPost('bill_lines', lines.map(l => {
      const { _newEquipment, _newItemName, _newItemTable, ...clean } = l;
      return { bill_id: bill.id, ...clean };
    }));
    if (status === 'approved') {
      await jcSyncBillCatalogOnApproval(lines);
    }
```

(the helper fields — `_newEquipment`, `_newItemName`, `_newItemTable` — aren't real `bill_lines` columns and must not be posted to Supabase; `item_category`/`item_id` *are* real columns from Task 3 and stay in `clean`.)

- [ ] **Step 4: Sync on `approveBill` (approving a previously-saved draft)**

Replace `approveBill` (`index.html:9493-9513`):

```js
async function approveBill(id) {
  try {
    const bills = await sbGet('bills', `id=eq.${id}`);
    const bill  = bills[0];
    let billNo  = bill?.bill_no;
    if (!billNo) {
      let counters = await sbGet('sequence_counters', `company_id=eq.${currentCompany.id}&sequence_type=eq.bill`);
      let counter  = counters[0];
      if (!counter) {
        const cr = await sbPost('sequence_counters', { company_id: currentCompany.id, sequence_type: 'bill', prefix: 'BILL-', last_number: 999, padding: 4 });
        counter = cr[0];
      }
      const nextNum = (counter.last_number||0) + 1;
      billNo = `${counter.prefix||'BILL-'}${String(nextNum).padStart(counter.padding||4,'0')}`;
      await sbPatch('sequence_counters', counter.id, { last_number: nextNum });
    }
    await sbPatch('bills', id, { status: 'approved', bill_no: billNo, approved_at: nowISO() });
    const billLines = await sbGet('bill_lines', `bill_id=eq.${id}`);
    await jcSyncBillCatalogOnApproval(billLines || []);
    showToast(`Bill ${billNo} approved.`, 'success');
    await loadAP();
  } catch(e) { showToast('Error: ' + e.message, 'error'); }
}
```

`jcSyncBillCatalogOnApproval` only checks `item_category`/`item_id` on each line (real DB columns already present on rows fetched from `bill_lines`), so it works unchanged whether called with the in-memory `lines` array from `saveBill` or rows freshly fetched from the DB in `approveBill`. A draft's linked lines never carry `_newEquipment`/`_newItemName` (Step 1 stripped those at draft-save time), so `jcSyncBillLineCatalog` correctly falls through to the existing-item cost-sync branch only.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: sync catalog cost/assets when an AP bill is approved"
```

---

## Task 14: End-to-end manual verification

No automated test suite exists for this codebase — run through all four scenarios against the live dev preview.

- [ ] **Step 1: New catalog item via immediate-approve**

Finance → AP → New Bill → add a line, description "Test Grommet", qty 100, rate 2.50 → check "Link to Inventory" → Category "Hardware" → "+ Add new item…" → name "Test Grommet" → Save & Approve.

Verify:
```sql
select item_name, default_unit_cost_ttd from config_hardware where item_name = 'Test Grommet';
```
Expected: one row, `default_unit_cost_ttd = 2.50`.

- [ ] **Step 2: Existing catalog item cost sync**

Job Config → Materials → add "Test Steel Plate" with cost 10.00. Finance → AP → New Bill → line "Test Steel Plate" qty 5 rate 12.00 → Link to Inventory → Material → select "Test Steel Plate" → Save & Approve.

Verify:
```sql
select default_unit_cost_ttd from config_materials where item_name = 'Test Steel Plate';
```
Expected: `12.00` (updated from 10.00).

- [ ] **Step 3: New equipment asset**

Finance → AP → New Bill → line "Test Bench Grinder" qty 1 rate 1500 → Link to Inventory → Equipment → fill name/asset/rates → Save & Approve.

Verify:
```sql
select equipment_name, workshop_rate_ttd from config_equipment where equipment_name = 'Test Bench Grinder';
```
Expected: one new row.

- [ ] **Step 4: Draft-then-approve with existing-item link**

Job Config → Consumables → add "Test Coolant" cost 5.00. Finance → AP → New Bill → line "Test Coolant" qty 20 rate 6.00 → Link to Inventory → Consumable → select "Test Coolant" → **Save Draft** (not approve). Confirm no cost sync happened yet:
```sql
select default_unit_cost_ttd from config_consumables where item_name = 'Test Coolant';
```
Expected: still `5.00`. Then go to AP list, find the draft bill, click Approve. Re-run the query — expected: now `6.00`.

- [ ] **Step 5: Regression check — plain bills still work**

Finance → AP → New Bill → add a line with description only (e.g. "Office rent"), no "Link to Inventory" checked → Save & Approve. Confirm it saves normally with no errors and no catalog side effects (this is the overwhelming majority of existing bill traffic — must be unaffected).

- [ ] **Step 6: Work Order regression check**

Open any existing Work Order created before this change, confirm it still opens without errors (no Hardware/Tooling rows, since none exist for it — that's correct), add one Hardware and one Tooling row, save, reload, confirm they persist.

---

## Notes for whoever picks this up

- Phase 2 (stock ledger / `qty_on_hand`) and Phase 3 (enforcement warnings in the job form) are **not** part of this plan — see the spec. Don't add `stock_moves` or `qty_on_hand` columns as part of this work.
- The "draft bill + new catalog item" gap (Task 13) is real and intentionally narrowed to "new items require immediate approve" rather than solved with a more complex staging mechanism — revisit only if this friction turns out to matter in practice.
- `bill_lines.account_id` and `bill_lines.tax_rate`/`line_total` columns exist in the DB but are unused by current app code (not populated by `saveBill`) — don't confuse them with the new `item_category`/`item_id` columns added here.
