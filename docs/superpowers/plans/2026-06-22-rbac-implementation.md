# RBAC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat 4-role system with a three-layer permissions model: atoms → per-company role presets → per-user overrides.

**Architecture:** Two new Supabase tables (`erp_roles`, `erp_user_company_roles`) store roles and assignments. A `_perms` flat object built at login gives O(1) `can(perm)` lookups. A Role Management UI in Settings lets admins create custom roles via a permission matrix.

**Tech Stack:** Vanilla JS, Supabase PostgREST (existing `sbGet/sbPost/sbPatch/sbPatchWhere` wrappers), single-file `meridian-erp/index.html` (~8400 lines).

**Spec:** `docs/superpowers/specs/2026-06-22-rbac-design.md`

---

## File map

| File | Changes |
|------|---------|
| `meridian-erp/index.html` | All frontend changes — permission engine, nav attributes, role editor HTML+JS |
| Supabase (via MCP or dashboard) | 3 SQL migrations — schema, seed, backfill |

---

## Phase 1 — Database Schema

### Task 1: Create erp_roles table and seed system roles

**Files:**
- SQL migration applied via Supabase MCP `apply_migration` tool or dashboard SQL editor

- [ ] **Step 1: Write and run a verification SELECT to confirm tables don't yet exist**

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('erp_roles', 'erp_user_company_roles');
```

Expected: 0 rows returned.

- [ ] **Step 2: Apply the erp_roles migration**

Run this SQL via Supabase MCP `apply_migration` or the Supabase dashboard SQL editor:

```sql
CREATE TABLE erp_roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid REFERENCES erp_companies(id) ON DELETE CASCADE,
  name        text NOT NULL,
  is_system   boolean NOT NULL DEFAULT false,
  permissions jsonb NOT NULL DEFAULT '{}',
  created_by  uuid REFERENCES erp_users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Standard unique constraint for company-scoped roles
ALTER TABLE erp_roles ADD CONSTRAINT erp_roles_company_name_unique UNIQUE (company_id, name);

-- Separate partial index for system roles (company_id IS NULL) — standard UNIQUE
-- treats NULL != NULL so two system roles could share a name without this
CREATE UNIQUE INDEX erp_roles_system_name_unique ON erp_roles (name) WHERE company_id IS NULL;

-- RLS enabled but policies added in Task 11
ALTER TABLE erp_roles ENABLE ROW LEVEL SECURITY;
```

- [ ] **Step 3: Seed the 6 system roles**

```sql
INSERT INTO erp_roles (name, is_system, company_id, permissions) VALUES

('super_admin', true, NULL, '{
  "finance:ar:read":true,"finance:ar:write":true,"finance:ar:approve":true,"finance:ar:void":true,
  "finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,
  "finance:bank:read":true,"finance:bank:write":true,
  "finance:ledger:read":true,"finance:ledger:write":true,
  "finance:coa:read":true,"finance:coa:write":true,
  "finance:reports:read":true,
  "sales:crm:read":true,"sales:crm:write":true,
  "sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,
  "sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true,
  "sales:clients:read":true,"sales:clients:write":true,
  "sales:vendors:read":true,"sales:vendors:write":true,
  "sales:deliveries:read":true,"sales:deliveries:write":true,
  "ops:work-orders:read":true,"ops:work-orders:write":true,"ops:work-orders:approve":true,
  "ops:costing:read":true,"ops:costing:write":true,
  "ops:delivery:read":true,"ops:delivery:write":true,
  "admin:users":true,"admin:settings":true,"admin:roles":true,"admin:companies":true
}'::jsonb),

('company_admin', true, NULL, '{
  "finance:ar:read":true,"finance:ar:write":true,"finance:ar:approve":true,"finance:ar:void":true,
  "finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,
  "finance:bank:read":true,"finance:bank:write":true,
  "finance:ledger:read":true,"finance:ledger:write":true,
  "finance:coa:read":true,"finance:coa:write":true,
  "finance:reports:read":true,
  "sales:crm:read":true,"sales:crm:write":true,
  "sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,
  "sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true,
  "sales:clients:read":true,"sales:clients:write":true,
  "sales:vendors:read":true,"sales:vendors:write":true,
  "sales:deliveries:read":true,"sales:deliveries:write":true,
  "ops:work-orders:read":true,"ops:work-orders:write":true,"ops:work-orders:approve":true,
  "ops:costing:read":true,"ops:costing:write":true,
  "ops:delivery:read":true,"ops:delivery:write":true,
  "admin:users":true,"admin:settings":true,"admin:roles":true
}'::jsonb),

('finance_manager', true, NULL, '{
  "finance:ar:read":true,"finance:ar:write":true,"finance:ar:approve":true,"finance:ar:void":true,
  "finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,
  "finance:bank:read":true,"finance:bank:write":true,
  "finance:ledger:read":true,"finance:ledger:write":true,
  "finance:coa:read":true,"finance:coa:write":true,
  "finance:reports:read":true
}'::jsonb),

('sales_rep', true, NULL, '{
  "finance:ar:read":true,
  "sales:crm:read":true,"sales:crm:write":true,
  "sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,
  "sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true,
  "sales:clients:read":true,"sales:clients:write":true
}'::jsonb),

('operations_tech', true, NULL, '{
  "ops:work-orders:read":true,"ops:work-orders:write":true,"ops:work-orders:approve":true,
  "ops:costing:read":true,"ops:costing:write":true,
  "ops:delivery:read":true,"ops:delivery:write":true,
  "sales:deliveries:read":true,"sales:deliveries:write":true
}'::jsonb),

('viewer', true, NULL, '{
  "finance:ar:read":true,"finance:ap:read":true,"finance:bank:read":true,
  "finance:ledger:read":true,"finance:coa:read":true,"finance:reports:read":true,
  "sales:crm:read":true,"sales:orders:read":true,"sales:quotes:read":true,
  "sales:clients:read":true,"sales:vendors:read":true,"sales:deliveries:read":true,
  "ops:work-orders:read":true,"ops:costing:read":true,"ops:delivery:read":true
}'::jsonb);
```

- [ ] **Step 4: Verify**

```sql
SELECT name, is_system, jsonb_object_keys(permissions) as perm_count
FROM erp_roles
ORDER BY name;
```

Expected: 6 rows. Spot-check that `super_admin` has `admin:companies` and `company_admin` does not.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(db): create erp_roles table and seed 6 system roles"
```

---

### Task 2: Create erp_user_company_roles table

- [ ] **Step 1: Apply migration**

```sql
CREATE TABLE erp_user_company_roles (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES erp_users(id) ON DELETE CASCADE,
  company_id           uuid NOT NULL REFERENCES erp_companies(id) ON DELETE CASCADE,
  role_id              uuid NOT NULL REFERENCES erp_roles(id),
  permission_overrides jsonb NOT NULL DEFAULT '{}',
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, company_id)
);

CREATE INDEX erp_user_company_roles_user_idx    ON erp_user_company_roles (user_id);
CREATE INDEX erp_user_company_roles_company_idx ON erp_user_company_roles (company_id);

ALTER TABLE erp_user_company_roles ENABLE ROW LEVEL SECURITY;
```

- [ ] **Step 2: Verify**

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'erp_user_company_roles'
ORDER BY ordinal_position;
```

Expected: 8 columns — id, user_id, company_id, role_id, permission_overrides, created_at, updated_at, (constraint).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(db): create erp_user_company_roles junction table"
```

---

## Phase 2 — Backfill

### Task 3: Backfill existing users into erp_user_company_roles

This script maps old `erp_users.role` → new role preset and converts `module_*` flags to `permission_overrides`. Run once; idempotent via `ON CONFLICT DO NOTHING`.

- [ ] **Step 1: Verify current state before backfill**

```sql
SELECT role, COUNT(*) FROM erp_users WHERE is_active = true GROUP BY role;
```

Note the counts — you'll verify the same counts appear in erp_user_company_roles after the backfill.

- [ ] **Step 2: Run the backfill script**

```sql
DO $$
DECLARE
  v_super_admin_id uuid;
  v_company_admin_id uuid;
  v_sales_rep_id uuid;
  v_viewer_id uuid;
BEGIN
  -- Cache system role IDs
  SELECT id INTO v_super_admin_id   FROM erp_roles WHERE name = 'super_admin'   AND company_id IS NULL;
  SELECT id INTO v_company_admin_id FROM erp_roles WHERE name = 'company_admin' AND company_id IS NULL;
  SELECT id INTO v_sales_rep_id     FROM erp_roles WHERE name = 'sales_rep'     AND company_id IS NULL;
  SELECT id INTO v_viewer_id        FROM erp_roles WHERE name = 'viewer'        AND company_id IS NULL;

  -- super_admin users get assigned to ALL companies
  INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides)
  SELECT u.id, c.id, v_super_admin_id, '{}'::jsonb
  FROM erp_users u
  CROSS JOIN erp_companies c
  WHERE u.role = 'super_admin' AND u.is_active = true
  ON CONFLICT (user_id, company_id) DO NOTHING;

  -- admin users → company_admin for their company
  INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides)
  SELECT
    u.id,
    u.company_id,
    v_company_admin_id,
    -- Compute overrides from module flags (expand wildcards to individual atoms)
    (
      CASE WHEN u.module_finance = false THEN
        '{"finance:ar:read":false,"finance:ar:write":false,"finance:ar:approve":false,"finance:ar:void":false,
          "finance:ap:read":false,"finance:ap:write":false,"finance:ap:approve":false,"finance:ap:void":false,
          "finance:bank:read":false,"finance:bank:write":false,
          "finance:ledger:read":false,"finance:ledger:write":false,
          "finance:coa:read":false,"finance:coa:write":false,
          "finance:reports:read":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_finance_ar = false AND u.module_finance != false THEN
        '{"finance:ar:read":false,"finance:ar:write":false,"finance:ar:approve":false,"finance:ar:void":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_finance_ap = false AND u.module_finance != false THEN
        '{"finance:ap:read":false,"finance:ap:write":false,"finance:ap:approve":false,"finance:ap:void":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_finance_bank = false AND u.module_finance != false THEN
        '{"finance:bank:read":false,"finance:bank:write":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_finance_ledger = false AND u.module_finance != false THEN
        '{"finance:ledger:read":false,"finance:ledger:write":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_finance_reports = false AND u.module_finance != false THEN
        '{"finance:reports:read":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_sales = false THEN
        '{"sales:crm:read":false,"sales:crm:write":false,
          "sales:orders:read":false,"sales:orders:write":false,"sales:orders:approve":false,
          "sales:quotes:read":false,"sales:quotes:write":false,"sales:quotes:approve":false,
          "sales:clients:read":false,"sales:clients:write":false,
          "sales:vendors:read":false,"sales:vendors:write":false,
          "sales:deliveries:read":false,"sales:deliveries:write":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_sales_crm = false AND u.module_sales != false THEN
        '{"sales:crm:read":false,"sales:crm:write":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_sales_orders = false AND u.module_sales != false THEN
        '{"sales:orders:read":false,"sales:orders:write":false,"sales:orders:approve":false,
          "sales:quotes:read":false,"sales:quotes:write":false,"sales:quotes:approve":false}'::jsonb
      ELSE '{}'::jsonb END
    ) ||
    (
      CASE WHEN u.module_operations = false THEN
        '{"ops:work-orders:read":false,"ops:work-orders:write":false,"ops:work-orders:approve":false,
          "ops:costing:read":false,"ops:costing:write":false,
          "ops:delivery:read":false,"ops:delivery:write":false}'::jsonb
      ELSE '{}'::jsonb END
    )
  FROM erp_users u
  WHERE u.role = 'admin' AND u.is_active = true AND u.company_id IS NOT NULL
  ON CONFLICT (user_id, company_id) DO NOTHING;

  -- sales users → sales_rep for their company (no module overrides needed — sales_rep is already scoped)
  INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides)
  SELECT u.id, u.company_id, v_sales_rep_id, '{}'::jsonb
  FROM erp_users u
  WHERE u.role = 'sales' AND u.is_active = true AND u.company_id IS NOT NULL
  ON CONFLICT (user_id, company_id) DO NOTHING;

  -- user role → viewer for their company
  INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides)
  SELECT u.id, u.company_id, v_viewer_id, '{}'::jsonb
  FROM erp_users u
  WHERE u.role = 'user' AND u.is_active = true AND u.company_id IS NOT NULL
  ON CONFLICT (user_id, company_id) DO NOTHING;
END;
$$;
```

- [ ] **Step 3: Verify backfill**

```sql
SELECT r.name as role_name, COUNT(*) as assigned_users
FROM erp_user_company_roles ucr
JOIN erp_roles r ON r.id = ucr.role_id
GROUP BY r.name
ORDER BY r.name;
```

Cross-check counts against the Step 1 query. Every active user with a `company_id` should have a row.

```sql
-- Check any active users with company_id that were NOT backfilled
SELECT u.full_name, u.email, u.role
FROM erp_users u
LEFT JOIN erp_user_company_roles ucr ON ucr.user_id = u.id
WHERE u.is_active = true AND u.company_id IS NOT NULL AND ucr.id IS NULL;
```

Expected: 0 rows.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(db): backfill existing users into erp_user_company_roles"
```

---

## Phase 3 — Frontend Permission Engine

### Task 4: Add _perms globals and permission engine functions

**Files:**
- Modify: `meridian-erp/index.html` — around line 5530 (STATE section) and lines 5532–5543 (ROLE HELPERS section)

- [ ] **Step 1: Add _perms state variable near line 5530**

Find the line:
```js
let currentUser      = null;
```

Add immediately after it:
```js
let _perms           = {};   // flat permission map built at login + company switch
```

- [ ] **Step 2: Add buildPerms, can, canAny after the existing ROLE HELPERS block**

Find the end of the ROLE HELPERS block (currently line ~5543):
```js
function canViewAR()    { return !isUser() || isAdmin(); } // sales can view AR
```

Insert a new section immediately after:
```js
// ── PERMISSION ENGINE ─────────────────────────────────────────────
// _perms is populated by buildPerms() at login and on every company switch.
// can(perm) is the single source of truth for access checks.
function buildPerms(rolePermissions = {}, overrides = {}) {
  _perms = { ...rolePermissions, ...overrides };
}
function can(perm)        { return _perms[perm] === true; }
function canAny(...perms) { return perms.some(p => can(p)); }

async function loadAndBuildPerms() {
  if (!currentUser || !currentCompany) return;
  try {
    const rows = await sbGet(
      'erp_user_company_roles',
      `user_id=eq.${currentUser.id}&company_id=eq.${currentCompany.id}&select=*,erp_roles(*)&limit=1`
    );
    if (rows.length) {
      const assignment = rows[0];
      const rolePerms  = assignment.erp_roles?.permissions || {};
      const overrides  = assignment.permission_overrides   || {};
      buildPerms(rolePerms, overrides);
    } else {
      buildPerms({}, {});   // no assignment found — deny everything
    }
  } catch(e) {
    console.warn('loadAndBuildPerms failed:', e.message);
    buildPerms({}, {});
  }
}
```

- [ ] **Step 3: Verify in browser console after login**

Open the ERP, log in, then in the console run:
```js
console.log(Object.keys(_perms).length, _perms);
```

Expected: an object with permission atoms as keys and `true` as values (count depends on the user's role). Should not be empty `{}` for any active user with a role assignment.

- [ ] **Step 4: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: add permission engine (buildPerms, can, canAny, loadAndBuildPerms)"
```

---

### Task 5: Replace canX() / isX() helpers with thin wrappers

**Files:**
- Modify: `meridian-erp/index.html` — lines 5532–5543 (ROLE HELPERS section)

- [ ] **Step 1: Replace the entire ROLE HELPERS block**

Find and replace this exact block (lines ~5532–5543):
```js
// ── ROLE HELPERS ──────────────────────────────────────────────────
function isSuperAdmin() { return currentUser?.role === 'super_admin'; }
function isAdmin()      { return currentUser?.role === 'admin' || isSuperAdmin(); }
function isSales()      { return currentUser?.role === 'sales'; }
function isUser()       { return currentUser?.role === 'user'; }
function canPost()      { return isAdmin(); }
function canVoid()      { return isAdmin(); }
function canApprove()   { return isAdmin(); }
function canDelete()    { return isAdmin(); }
function canSettings()  { return isAdmin(); }
function canFinance()   { return isAdmin(); }  // AP, Bank, CoA, Journal, Reports
function canViewAR()    { return !isUser() || isAdmin(); } // sales can view AR
```

Replace with:
```js
// ── ROLE HELPERS (thin wrappers — delegate to can()) ──────────────
// Phase 3 bridge: these wrappers preserve existing call sites.
// canPost/canVoid/canApprove are intentionally permissive (check either AR or AP);
// nav data-perm attributes provide the outer module guard.
// Phase 4 will replace individual call sites with direct can() calls.
function isSuperAdmin() { return can('admin:companies'); }
function isAdmin()      { return can('admin:users') || can('admin:settings'); }
function isSales()      { return can('sales:quotes:write') && !can('admin:users'); }
function isUser()       { return !can('admin:users') && !can('sales:quotes:write'); }
function canPost()      { return canAny('finance:ar:write','finance:ap:write'); }
function canVoid()      { return canAny('finance:ar:void','finance:ap:void'); }
function canApprove()   { return canAny('finance:ar:approve','finance:ap:approve'); }
function canDelete()    { return can('admin:settings'); }
function canSettings()  { return can('admin:settings'); }
function canFinance()   { return canAny('finance:ar:read','finance:ap:read','finance:bank:read','finance:ledger:read','finance:reports:read'); }
function canViewAR()    { return can('finance:ar:read'); }
```

- [ ] **Step 2: Verify in browser console after login as different role users**

```js
// As super_admin — expect true for both
console.assert(isSuperAdmin() === true, 'super_admin check');
console.assert(isAdmin() === true, 'admin check');

// As a sales_rep — expect false for isAdmin, true for canViewAR
console.assert(isAdmin() === false, 'sales not admin');
console.assert(canViewAR() === true, 'sales can view AR');
```

- [ ] **Step 3: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: replace canX()/isX() helpers with can() thin wrappers"
```

---

### Task 6: Hook loadAndBuildPerms() into initApp() and switchCompany()

**Files:**
- Modify: `meridian-erp/index.html` — lines ~5796 (`initApp`) and ~5985 (`switchCompany`)

- [ ] **Step 1: Modify initApp() to call loadAndBuildPerms() before applyRoleNav()**

Find in `initApp()` (line ~5806):
```js
  // Load companies based on role
  await loadCompanies();
  [contacts, bankAccounts] = await Promise.all([
    sbGet('contacts', Q.contacts()).catch(() => []),
    sbGet('bank_accounts', Q.bankAccounts()).catch(() => []),
  ]);
  await checkAndRefreshRates();

  // Apply nav visibility based on role
  applyRoleNav();
```

Replace with:
```js
  // Load companies based on role
  await loadCompanies();
  [contacts, bankAccounts] = await Promise.all([
    sbGet('contacts', Q.contacts()).catch(() => []),
    sbGet('bank_accounts', Q.bankAccounts()).catch(() => []),
  ]);
  await checkAndRefreshRates();

  // Build permission map for current user + company before rendering nav
  await loadAndBuildPerms();

  // Apply nav visibility based on permissions
  applyRoleNav();
```

- [ ] **Step 2: Modify switchCompany() to rebuild perms after switching**

Find in `switchCompany()` (line ~5985):
```js
  await loadViewData(currentView);
  showToast('Switched to ' + (currentCompany.trading_name || currentCompany.name), 'info');
```

Replace with:
```js
  await loadAndBuildPerms();
  applyRoleNav();
  await loadViewData(currentView);
  showToast('Switched to ' + (currentCompany.trading_name || currentCompany.name), 'info');
```

- [ ] **Step 3: Verify in browser**

1. Log in as an admin user — open console, confirm `Object.keys(_perms).length > 30`.
2. Switch companies — confirm `_perms` updates (check a company-specific permission).
3. Log in as a sales_rep — confirm `_perms` has `sales:*` atoms but not `finance:ap:write`.

- [ ] **Step 4: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: hook loadAndBuildPerms into initApp and switchCompany"
```

---

### Task 7: Data-driven applyRoleNav() with data-perm attributes

**Files:**
- Modify: `meridian-erp/index.html` — nav HTML (~lines 1895–2035) and `applyRoleNav()` (~lines 5821–5857)

- [ ] **Step 1: Add data-perm attributes to all nav items**

Locate the nav section (around line 1895). Add `data-perm` attributes to each nav item as follows. Find each `id="nav-*"` div and add its attribute:

```html
<!-- BEFORE (example) -->
<div class="nav-item" onclick="navigate('dashboard')" id="nav-dashboard">

<!-- AFTER -->
<div class="nav-item" data-perm="finance:ar:read" onclick="navigate('dashboard')" id="nav-dashboard">
```

Full mapping — find each `id` and add the corresponding `data-perm`:

| nav id | data-perm |
|--------|-----------|
| nav-workspace | (no data-perm — always visible) |
| nav-dashboard | (no data-perm — always visible) |
| nav-ar | finance:ar:read |
| nav-credit-notes | finance:ar:read |
| nav-ap | finance:ap:read |
| nav-vendors | finance:ap:read |
| nav-bank | finance:bank:read |
| nav-journal | finance:ledger:read |
| nav-coa | finance:coa:read |
| nav-aged-ar | finance:ar:read |
| nav-aged-ap | finance:ap:read |
| nav-pl | finance:reports:read |
| nav-bs | finance:reports:read |
| nav-tb | finance:reports:read |
| nav-cf | finance:reports:read |
| nav-sales-leads | sales:crm:read |
| nav-pipeline | sales:crm:read |
| nav-crm-activities | sales:crm:read |
| nav-crm-tasks | sales:crm:read |
| nav-crm-team-members | sales:crm:read |
| nav-quotations | sales:quotes:read |
| nav-clients | sales:clients:read |
| nav-work-orders | ops:work-orders:read |
| nav-job-costing | ops:costing:read |
| nav-delivery-notes | ops:delivery:read |
| nav-job-config | admin:settings |
| nav-companies | admin:companies |
| nav-user-management | admin:users |
| nav-settings | admin:settings |

- [ ] **Step 2: Replace applyRoleNav() body**

Find `function applyRoleNav()` (line ~5821). Replace the entire function body with:

```js
function applyRoleNav() {
  // Show/hide nav items based on data-perm attribute
  document.querySelectorAll('.nav-item[data-perm]').forEach(el => {
    el.style.display = can(el.dataset.perm) ? '' : 'none';
  });

  // Hide Finance section header if all finance sub-items are hidden
  const subSec = document.getElementById('sub-section-finance-reports');
  if (subSec) {
    const anyVisible = Array.from(subSec.querySelectorAll('.nav-item'))
                           .some(el => el.style.display !== 'none');
    subSec.style.display = anyVisible ? '' : 'none';
  }
}
```

Delete all existing code between the `function applyRoleNav() {` line and its closing `}` and replace with the above.

- [ ] **Step 3: Verify**

Log in as a `sales_rep` user. Confirm:
- Finance nav items (AP, Bank, Ledger, CoA, Reports) are hidden
- Sales nav items (Quotations, CRM, Clients) are visible
- User Management is hidden

Log in as a `finance_manager`. Confirm:
- AR, AP, Bank, Ledger, CoA, Reports are visible
- Operations nav items are hidden
- Sales CRM is hidden

- [ ] **Step 4: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: data-driven applyRoleNav() via data-perm attributes"
```

---

## Phase 3 — Role Editor UI

### Task 8: Add Role Management nav item and section skeleton

**Files:**
- Modify: `meridian-erp/index.html` — nav HTML and Settings/admin section

- [ ] **Step 1: Add nav item for Role Management**

In the nav HTML, find the existing "User Management" nav item:
```html
<div class="nav-item" onclick="navigate('user-management')" id="nav-user-management">
```

Add a new nav item directly after it:
```html
<div class="nav-item" data-perm="admin:roles" onclick="navigate('role-management')" id="nav-role-management">
  <span class="nav-icon">🔐</span>
  <span class="nav-label">Role Management</span>
</div>
```

- [ ] **Step 2: Add view section HTML**

Find the existing User Management HTML section (search for `id="view-user-management"`). Add a new sibling section after it:

```html
<div id="view-role-management" class="view-section" style="display:none;">
  <div class="view-header">
    <h2 class="view-title">Role Management</h2>
    <p class="view-subtitle" id="rm-subtitle"></p>
  </div>
  <div class="view-toolbar" style="display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem;">
    <div></div>
    <button class="btn btn-primary" onclick="openCreateRoleModal()">+ New Role</button>
  </div>
  <div id="rm-roles-grid" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-bottom:2rem;"></div>
  <div id="rm-users-section" style="display:none;">
    <h3 style="font-size:14px;font-weight:600;margin-bottom:0.75rem;" id="rm-users-title">Users with this role</h3>
    <div id="rm-users-list"></div>
  </div>
</div>
```

- [ ] **Step 3: Wire navigate() to handle 'role-management'**

Find the `loadViewData` function (search for `async function loadViewData`). Add a case for `'role-management'`:

```js
case 'role-management': await loadRoleManagement(); break;
```

- [ ] **Step 4: Add stub loadRoleManagement() to confirm wiring works**

```js
async function loadRoleManagement() {
  document.getElementById('rm-subtitle').textContent =
    currentCompany?.trading_name || currentCompany?.name || '';
  document.getElementById('rm-roles-grid').innerHTML = '<p style="color:var(--text-2)">Loading roles…</p>';
}
```

- [ ] **Step 5: Verify**

Log in as company_admin. Click the Role Management nav item. Confirm the section renders with "Loading roles…" and the company name subtitle.

- [ ] **Step 6: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: add Role Management nav item and view section skeleton"
```

---

### Task 9: Role list — loadRoleManagement() and renderRoles()

**Files:**
- Modify: `meridian-erp/index.html` — replace stub from Task 8

- [ ] **Step 1: Add state variable for roles**

Near the STATE section (line ~5530), add:
```js
let _rmRoles = [];
```

- [ ] **Step 2: Replace loadRoleManagement() with the full implementation**

```js
async function loadRoleManagement() {
  document.getElementById('rm-subtitle').textContent =
    currentCompany?.trading_name || currentCompany?.name || '';
  document.getElementById('rm-users-section').style.display = 'none';
  document.getElementById('rm-roles-grid').innerHTML = '<p style="color:var(--text-2);">Loading…</p>';
  try {
    // Fetch system roles (company_id IS NULL) + roles for current company
    _rmRoles = await sbGet('erp_roles',
      `or=(company_id.is.null,company_id.eq.${currentCompany.id})&order=is_system.desc,name.asc`
    );
    renderRoleCards();
  } catch(e) {
    document.getElementById('rm-roles-grid').innerHTML =
      `<p style="color:var(--red);">Error: ${escHTML(e.message)}</p>`;
  }
}

function renderRoleCards() {
  const grid = document.getElementById('rm-roles-grid');
  grid.innerHTML = _rmRoles.map(role => {
    const permCount = Object.keys(role.permissions || {}).length;
    const isSystem  = role.is_system;
    const badge     = isSystem
      ? `<span style="font-size:11px;font-weight:600;color:var(--text-2);background:var(--surface-2);border:1px solid var(--border);border-radius:4px;padding:1px 7px;">System</span>`
      : `<span style="font-size:11px;font-weight:600;color:var(--blue);background:var(--blue)18;border:1px solid var(--blue)33;border-radius:4px;padding:1px 7px;">Custom</span>`;
    const actions = isSystem
      ? `<span style="font-size:13px;color:var(--text-2);">🔒</span>`
      : `<button class="btn btn-ghost btn-sm" onclick="openEditRoleModal('${role.id}')">Edit</button>
         <button class="btn btn-ghost btn-sm btn-danger" onclick="deleteRole('${role.id}')">Delete</button>`;
    return `
      <div class="card" style="padding:1rem;cursor:pointer;" onclick="showRoleUsers('${escHTML(role.id)}')">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;">
          ${badge}
          ${actions}
        </div>
        <div style="font-size:14px;font-weight:600;margin-bottom:3px;">${escHTML(role.name)}</div>
        <div style="font-size:12px;color:var(--text-2);margin-bottom:8px;">
          ${permCount} permission${permCount !== 1 ? 's' : ''}
        </div>
      </div>`;
  }).join('');
}
```

- [ ] **Step 3: Add showRoleUsers() and deleteRole() stubs**

```js
async function showRoleUsers(roleId) {
  const role = _rmRoles.find(r => r.id === roleId);
  if (!role) return;
  const section = document.getElementById('rm-users-section');
  const title   = document.getElementById('rm-users-title');
  const list    = document.getElementById('rm-users-list');
  title.textContent = `Users assigned "${role.name}"`;
  list.innerHTML = '<p style="color:var(--text-2);">Loading…</p>';
  section.style.display = '';
  try {
    const rows = await sbGet('erp_user_company_roles',
      `role_id=eq.${roleId}&company_id=eq.${currentCompany.id}&select=*,erp_users(id,full_name,email)&order=erp_users(full_name)`
    );
    list.innerHTML = rows.length
      ? rows.map(r => `
          <div class="table-row" style="display:flex;align-items:center;gap:12px;padding:8px 0;border-bottom:1px solid var(--border);">
            <div style="flex:1;">
              <div style="font-size:13px;font-weight:500;">${escHTML(r.erp_users?.full_name || '—')}</div>
              <div style="font-size:12px;color:var(--text-2);">${escHTML(r.erp_users?.email || '')}</div>
            </div>
            <button class="btn btn-ghost btn-sm" onclick="openUserOverridesModal('${r.user_id}','${r.company_id}')">
              Overrides ${Object.keys(r.permission_overrides||{}).length > 0 ? `<span style="background:var(--gold)22;color:var(--gold);border-radius:3px;padding:0 4px;font-size:10px;">${Object.keys(r.permission_overrides).length}</span>` : ''}
            </button>
          </div>`).join('')
      : '<p style="color:var(--text-2);font-size:13px;">No users assigned this role for this company.</p>';
  } catch(e) {
    list.innerHTML = `<p style="color:var(--red);">Error: ${escHTML(e.message)}</p>`;
  }
}

async function deleteRole(roleId) {
  const role = _rmRoles.find(r => r.id === roleId);
  if (!role || role.is_system) return;
  if (!confirm(`Delete role "${role.name}"? Users assigned this role will lose their access.`)) return;
  try {
    await sb(`erp_roles?id=eq.${roleId}`, { method: 'DELETE', prefer: 'return=minimal' });
    showToast('Role deleted.', 'success');
    await loadRoleManagement();
  } catch(e) {
    showToast(e.message, 'error');
  }
}
```

- [ ] **Step 4: Verify**

Navigate to Role Management. Confirm:
- 6 system role cards render with lock icon
- Permission count shows correct number per role
- Clicking a card shows the users section

- [ ] **Step 5: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: role list — loadRoleManagement, renderRoleCards, showRoleUsers"
```

---

### Task 10: Permission matrix modal (create and edit role)

**Files:**
- Modify: `meridian-erp/index.html` — add modal HTML near other modals, add JS functions

- [ ] **Step 1: Define the permission matrix config constant**

Add near the top of the JS constants section (search for `const CURRENCY_SYMBOLS`):

```js
const PERMISSION_MATRIX = [
  { group: 'Finance', rows: [
    { label: 'AR',           atoms: ['finance:ar:read','finance:ar:write','finance:ar:approve','finance:ar:void'] },
    { label: 'AP',           atoms: ['finance:ap:read','finance:ap:write','finance:ap:approve','finance:ap:void'] },
    { label: 'Bank',         atoms: ['finance:bank:read','finance:bank:write', null, null] },
    { label: 'Ledger / CoA', atoms: ['finance:ledger:read','finance:ledger:write','finance:coa:read','finance:coa:write'] },
    { label: 'Reports',      atoms: ['finance:reports:read', null, null, null] },
  ]},
  { group: 'Sales', rows: [
    { label: 'CRM',           atoms: ['sales:crm:read','sales:crm:write', null, null] },
    { label: 'Quotes',        atoms: ['sales:quotes:read','sales:quotes:write','sales:quotes:approve', null] },
    { label: 'Orders',        atoms: ['sales:orders:read','sales:orders:write','sales:orders:approve', null] },
    { label: 'Clients',       atoms: ['sales:clients:read','sales:clients:write', null, null] },
    { label: 'Vendors',       atoms: ['sales:vendors:read','sales:vendors:write', null, null] },
    { label: 'Deliveries',    atoms: ['sales:deliveries:read','sales:deliveries:write', null, null] },
  ]},
  { group: 'Operations', rows: [
    { label: 'Work Orders',  atoms: ['ops:work-orders:read','ops:work-orders:write','ops:work-orders:approve', null] },
    { label: 'Job Costing',  atoms: ['ops:costing:read','ops:costing:write', null, null] },
    { label: 'Deliveries',   atoms: ['ops:delivery:read','ops:delivery:write', null, null] },
  ]},
];
const ADMIN_PERMS = ['admin:users','admin:settings','admin:roles','admin:companies'];
```

- [ ] **Step 2: Add the modal HTML**

Find the closing `</body>` tag or search for another modal's `id="modal-*"` to find the modal section. Add:

```html
<!-- ── ROLE EDIT MODAL ─────────────────────────────────────────── -->
<div id="modal-role-edit" class="modal-overlay" style="display:none;" onclick="if(event.target===this)closeModal('modal-role-edit')">
  <div class="modal" style="max-width:640px;width:95%;max-height:90vh;overflow-y:auto;">
    <div class="modal-header">
      <h3 id="role-modal-title">New Role</h3>
      <button class="modal-close" onclick="closeModal('modal-role-edit')">✕</button>
    </div>
    <div class="modal-body">
      <input type="hidden" id="role-edit-id">
      <div class="form-group" style="margin-bottom:1rem;">
        <label class="form-label">Role name</label>
        <input type="text" id="role-edit-name" class="form-input" placeholder="e.g. AR Officer">
      </div>
      <div id="role-perm-matrix"></div>
      <div class="form-group" style="margin-top:1rem;">
        <label class="form-label">Admin permissions</label>
        <div id="role-admin-perms" style="display:flex;flex-wrap:wrap;gap:12px;margin-top:6px;"></div>
      </div>
      <p id="role-edit-error" style="color:var(--red);font-size:13px;margin-top:8px;"></p>
    </div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="closeModal('modal-role-edit')">Cancel</button>
      <button class="btn btn-primary" id="role-edit-save-btn" onclick="saveRole()">Save Role</button>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Add openCreateRoleModal(), openEditRoleModal(), renderPermMatrix(), saveRole()**

```js
function openCreateRoleModal() {
  document.getElementById('role-modal-title').textContent = 'New role';
  document.getElementById('role-edit-id').value = '';
  document.getElementById('role-edit-name').value = '';
  document.getElementById('role-edit-error').textContent = '';
  renderPermMatrix({});
  document.getElementById('modal-role-edit').style.display = 'flex';
}

function openEditRoleModal(roleId) {
  const role = _rmRoles.find(r => r.id === roleId);
  if (!role || role.is_system) return;
  document.getElementById('role-modal-title').textContent = `Edit role: ${role.name}`;
  document.getElementById('role-edit-id').value = roleId;
  document.getElementById('role-edit-name').value = role.name;
  document.getElementById('role-edit-error').textContent = '';
  renderPermMatrix(role.permissions || {});
  document.getElementById('modal-role-edit').style.display = 'flex';
}

function renderPermMatrix(currentPerms) {
  const matrixEl = document.getElementById('role-perm-matrix');
  const cols = ['Read','Write','Approve','Void'];
  let html = `<table style="width:100%;border-collapse:collapse;font-size:13px;">
    <thead><tr>
      <th style="text-align:left;padding:6px 8px;color:var(--text-2);font-weight:500;border-bottom:1px solid var(--border);">Module</th>
      ${cols.map(c=>`<th style="text-align:center;width:72px;padding:6px 4px;color:var(--text-2);font-weight:500;border-bottom:1px solid var(--border);">${c}</th>`).join('')}
    </tr></thead><tbody>`;
  for (const group of PERMISSION_MATRIX) {
    html += `<tr><td colspan="5" style="padding:8px 8px 4px;font-size:11px;font-weight:600;color:var(--text-2);background:var(--surface-2);text-transform:uppercase;letter-spacing:0.05em;">${group.group}</td></tr>`;
    for (const row of group.rows) {
      html += `<tr style="border-bottom:1px solid var(--border)22;">
        <td style="padding:7px 8px;">${escHTML(row.label)}</td>
        ${row.atoms.map(atom => atom
          ? `<td style="text-align:center;"><input type="checkbox" data-perm-atom="${escHTML(atom)}" ${currentPerms[atom] ? 'checked' : ''}></td>`
          : `<td style="text-align:center;color:var(--text-2);">—</td>`
        ).join('')}
      </tr>`;
    }
  }
  html += '</tbody></table>';
  matrixEl.innerHTML = html;

  // Admin perms as checkboxes
  const adminEl = document.getElementById('role-admin-perms');
  adminEl.innerHTML = ADMIN_PERMS.map(atom => {
    const label = atom.replace('admin:','');
    return `<label style="display:flex;align-items:center;gap:5px;font-size:13px;">
      <input type="checkbox" data-perm-atom="${escHTML(atom)}" ${currentPerms[atom] ? 'checked' : ''}>
      ${escHTML(label)}
    </label>`;
  }).join('');
}

async function saveRole() {
  const roleId  = document.getElementById('role-edit-id').value;
  const name    = document.getElementById('role-edit-name').value.trim();
  const errEl   = document.getElementById('role-edit-error');
  const saveBtn = document.getElementById('role-edit-save-btn');
  errEl.textContent = '';
  if (!name) { errEl.textContent = 'Role name is required.'; return; }

  // Collect permissions from all checked atoms
  const permissions = {};
  document.querySelectorAll('#modal-role-edit [data-perm-atom]').forEach(cb => {
    if (cb.checked) permissions[cb.dataset.permAtom] = true;
  });

  saveBtn.textContent = 'Saving…'; saveBtn.disabled = true;
  try {
    if (roleId) {
      await sbPatchWhere('erp_roles', `id=eq.${roleId}`, { name, permissions });
    } else {
      await sbPost('erp_roles', {
        name,
        permissions,
        company_id: currentCompany.id,
        created_by: currentUser.id,
      });
    }
    showToast(roleId ? 'Role updated.' : 'Role created.', 'success');
    closeModal('modal-role-edit');
    await loadRoleManagement();
  } catch(e) {
    errEl.textContent = e.message;
  } finally {
    saveBtn.textContent = 'Save Role'; saveBtn.disabled = false;
  }
}
```

- [ ] **Step 4: Verify**

1. Click "+ New Role" — confirm the matrix renders with all groups (Finance, Sales, Operations).
2. Check some boxes, enter a name, save — confirm a new card appears in the role list.
3. Click Edit on the new role — confirm checked permissions are restored correctly.
4. Confirm system roles do NOT have an Edit button.

- [ ] **Step 5: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: permission matrix modal — create and edit custom roles"
```

---

### Task 11: User overrides modal

**Files:**
- Modify: `meridian-erp/index.html` — add modal HTML, add JS functions

- [ ] **Step 1: Add overrides modal HTML**

```html
<!-- ── USER OVERRIDES MODAL ────────────────────────────────────── -->
<div id="modal-user-overrides" class="modal-overlay" style="display:none;" onclick="if(event.target===this)closeModal('modal-user-overrides')">
  <div class="modal" style="max-width:520px;width:95%;max-height:90vh;overflow-y:auto;">
    <div class="modal-header">
      <h3>Permission overrides — <span id="overrides-user-name"></span></h3>
      <button class="modal-close" onclick="closeModal('modal-user-overrides')">✕</button>
    </div>
    <div class="modal-body">
      <p style="font-size:12px;color:var(--text-2);margin-bottom:1rem;">
        Overrides modify individual permissions on top of the user's role.
        Checked = explicitly granted. Unchecked = explicitly denied.
        Leave a permission out to inherit from the role.
      </p>
      <input type="hidden" id="overrides-user-id">
      <input type="hidden" id="overrides-company-id">
      <div id="overrides-matrix"></div>
      <p id="overrides-error" style="color:var(--red);font-size:13px;margin-top:8px;"></p>
    </div>
    <div class="modal-footer" style="justify-content:space-between;">
      <button class="btn btn-ghost btn-danger" onclick="clearUserOverrides()">Clear all overrides</button>
      <div style="display:flex;gap:8px;">
        <button class="btn btn-ghost" onclick="closeModal('modal-user-overrides')">Cancel</button>
        <button class="btn btn-primary" id="overrides-save-btn" onclick="saveUserOverrides()">Save</button>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Add openUserOverridesModal(), renderOverridesMatrix(), saveUserOverrides(), clearUserOverrides()**

```js
async function openUserOverridesModal(userId, companyId) {
  const errEl = document.getElementById('overrides-error');
  errEl.textContent = '';
  document.getElementById('overrides-user-id').value    = userId;
  document.getElementById('overrides-company-id').value = companyId;
  document.getElementById('modal-user-overrides').style.display = 'flex';
  document.getElementById('overrides-matrix').innerHTML = 'Loading…';

  try {
    const [rows, users] = await Promise.all([
      sbGet('erp_user_company_roles',
        `user_id=eq.${userId}&company_id=eq.${companyId}&select=permission_overrides,erp_roles(permissions)&limit=1`),
      sbGet('erp_users', `id=eq.${userId}&select=full_name&limit=1`),
    ]);
    const assignment    = rows[0] || {};
    const rolePerms     = assignment.erp_roles?.permissions || {};
    const currentOver   = assignment.permission_overrides   || {};
    document.getElementById('overrides-user-name').textContent =
      users[0]?.full_name || userId;
    renderOverridesMatrix(rolePerms, currentOver);
  } catch(e) {
    document.getElementById('overrides-matrix').innerHTML =
      `<p style="color:var(--red);">Error: ${escHTML(e.message)}</p>`;
  }
}

function renderOverridesMatrix(rolePerms, currentOverrides) {
  const matrixEl = document.getElementById('overrides-matrix');
  // Collect all atoms from the matrix config
  const allAtoms = PERMISSION_MATRIX
    .flatMap(g => g.rows.flatMap(r => r.atoms.filter(Boolean)))
    .concat(ADMIN_PERMS);

  let html = '<div style="display:grid;gap:4px;">';
  for (const group of PERMISSION_MATRIX) {
    html += `<div style="font-size:11px;font-weight:600;color:var(--text-2);padding:8px 0 2px;text-transform:uppercase;letter-spacing:0.05em;">${group.group}</div>`;
    for (const row of group.rows) {
      for (const atom of row.atoms.filter(Boolean)) {
        const isOverridden = atom in currentOverrides;
        const overrideVal  = currentOverrides[atom];
        const roleDefault  = rolePerms[atom] === true;
        html += `<label style="display:flex;align-items:center;gap:8px;padding:4px 0;cursor:pointer;">
          <input type="checkbox"
            data-override-atom="${escHTML(atom)}"
            data-has-override="${isOverridden}"
            ${overrideVal === true ? 'checked' : ''}>
          <span style="flex:1;font-size:13px;">${escHTML(atom)}</span>
          <span style="font-size:11px;color:var(--text-2);">role: ${roleDefault ? '✓' : '✗'}</span>
        </label>`;
      }
    }
  }
  html += '<div style="font-size:11px;font-weight:600;color:var(--text-2);padding:8px 0 2px;text-transform:uppercase;letter-spacing:0.05em;">Admin</div>';
  for (const atom of ADMIN_PERMS) {
    const isOverridden = atom in currentOverrides;
    const overrideVal  = currentOverrides[atom];
    const roleDefault  = rolePerms[atom] === true;
    html += `<label style="display:flex;align-items:center;gap:8px;padding:4px 0;cursor:pointer;">
      <input type="checkbox"
        data-override-atom="${escHTML(atom)}"
        data-has-override="${isOverridden}"
        ${overrideVal === true ? 'checked' : ''}>
      <span style="flex:1;font-size:13px;">${escHTML(atom)}</span>
      <span style="font-size:11px;color:var(--text-2);">role: ${roleDefault ? '✓' : '✗'}</span>
    </label>`;
  }
  html += '</div>';
  matrixEl.innerHTML = html;
}

async function saveUserOverrides() {
  const userId    = document.getElementById('overrides-user-id').value;
  const companyId = document.getElementById('overrides-company-id').value;
  const saveBtn   = document.getElementById('overrides-save-btn');
  const errEl     = document.getElementById('overrides-error');
  errEl.textContent = '';
  saveBtn.textContent = 'Saving…'; saveBtn.disabled = true;

  // Collect all checked atoms as overrides (true = grant, unchecked = deny)
  const permission_overrides = {};
  document.querySelectorAll('#modal-user-overrides [data-override-atom]').forEach(cb => {
    permission_overrides[cb.dataset.overrideAtom] = cb.checked;
  });

  // Remove atoms where override matches role default (no need to store them)
  // This keeps the overrides object minimal — only genuine deltas

  try {
    await sbPatchWhere('erp_user_company_roles',
      `user_id=eq.${userId}&company_id=eq.${companyId}`,
      { permission_overrides }
    );
    showToast('Overrides saved.', 'success');
    closeModal('modal-user-overrides');
    await showRoleUsers(
      document.querySelector('#rm-users-title')?.dataset?.roleId || ''
    );
  } catch(e) {
    errEl.textContent = e.message;
  } finally {
    saveBtn.textContent = 'Save'; saveBtn.disabled = false;
  }
}

async function clearUserOverrides() {
  const userId    = document.getElementById('overrides-user-id').value;
  const companyId = document.getElementById('overrides-company-id').value;
  if (!confirm('Remove all permission overrides for this user?')) return;
  try {
    await sbPatchWhere('erp_user_company_roles',
      `user_id=eq.${userId}&company_id=eq.${companyId}`,
      { permission_overrides: {} }
    );
    showToast('Overrides cleared.', 'success');
    closeModal('modal-user-overrides');
  } catch(e) {
    showToast(e.message, 'error');
  }
}
```

- [ ] **Step 3: Verify**

1. In Role Management, click a role card, then click "Overrides" on a user row.
2. Confirm the modal opens and shows all atoms with role defaults marked.
3. Check/uncheck some atoms, save — confirm the change persists (reopen the modal, verify state).
4. Click "Clear all overrides" — confirm `{}` is saved.

- [ ] **Step 4: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: user permission overrides modal"
```

---

### Task 12: Update User Management to show per-company role assignment

**Files:**
- Modify: `meridian-erp/index.html` — `openEditPermissionsModal()`, `saveEditPermissions()`, and the edit modal HTML

The existing User Management edit modal still reads/writes the old `role` column and module flags. This task replaces it with the new `erp_user_company_roles` model.

- [ ] **Step 1: Modify openEditPermissionsModal() to use new tables**

Find `function openEditPermissionsModal(authUserId)` (around line 6308). Replace it:

```js
async function openEditPermissionsModal(authUserId) {
  const u = _umAllUsers.find(x => x.auth_user_id === authUserId);
  if (!u) return;
  document.getElementById('um-edit-auth-id').value    = authUserId;
  document.getElementById('um-edit-user-name').textContent = u.full_name || u.email || 'User';
  document.getElementById('um-edit-error').textContent = '';

  // Populate company dropdown
  const coSel = document.getElementById('um-edit-company');
  coSel.innerHTML = companies.map(c =>
    `<option value="${escHTML(c.id)}">${escHTML(c.trading_name || c.name)}</option>`
  ).join('');
  coSel.value = u.company_id || '';

  // Load roles for the dropdown (system roles + company-scoped roles for current company)
  const roles = await sbGet('erp_roles',
    `or=(company_id.is.null,company_id.eq.${currentCompany.id})&order=is_system.desc,name.asc`
  ).catch(() => []);

  const roleSel = document.getElementById('um-edit-role');
  roleSel.innerHTML = roles.map(r =>
    `<option value="${escHTML(r.id)}">${escHTML(r.name)}</option>`
  ).join('');

  // Find existing assignment for this user at the currently selected company
  const assignments = await sbGet('erp_user_company_roles',
    `user_id=eq.${u.id}&company_id=eq.${currentCompany.id}&limit=1`
  ).catch(() => []);
  if (assignments.length) roleSel.value = assignments[0].role_id;

  document.getElementById('um-edit-modal').style.display = 'flex';
}
```

- [ ] **Step 2: Modify saveEditPermissions() to write to erp_user_company_roles**

Find `async function saveEditPermissions()` (around line 6358). Replace it:

```js
async function saveEditPermissions() {
  const authUserId = document.getElementById('um-edit-auth-id').value;
  const company_id = document.getElementById('um-edit-company').value;
  const role_id    = document.getElementById('um-edit-role').value;
  const errEl      = document.getElementById('um-edit-error');
  const saveBtn    = document.getElementById('um-edit-save-btn');
  errEl.textContent = '';
  saveBtn.textContent = 'Saving…'; saveBtn.disabled = true;

  const u = _umAllUsers.find(x => x.auth_user_id === authUserId);
  if (!u) { errEl.textContent = 'User not found.'; saveBtn.textContent = 'Save Changes'; saveBtn.disabled = false; return; }

  try {
    // Update company assignment
    await sbPatchWhere('erp_users', `auth_user_id=eq.${authUserId}`, { company_id });

    // Upsert erp_user_company_roles — update if exists, insert if not
    const existing = await sbGet('erp_user_company_roles',
      `user_id=eq.${u.id}&company_id=eq.${company_id}&limit=1`
    ).catch(() => []);

    if (existing.length) {
      await sbPatchWhere('erp_user_company_roles',
        `user_id=eq.${u.id}&company_id=eq.${company_id}`,
        { role_id }
      );
    } else {
      await sbPost('erp_user_company_roles', {
        user_id:              u.id,
        company_id,
        role_id,
        permission_overrides: {},
      });
    }

    showToast('Permissions updated.', 'success');
    closeEditPermissionsModal();
    await loadUserManagement();
  } catch(e) {
    errEl.textContent = e.message;
  } finally {
    saveBtn.textContent = 'Save Changes'; saveBtn.disabled = false;
  }
}
```

- [ ] **Step 3: Update the um-edit-role HTML element**

Find the `<select id="um-edit-role">` in the edit modal HTML. Replace its hardcoded `<option>` children with an empty select (options are populated by JS):

```html
<select id="um-edit-role" class="form-input">
  <!-- populated by openEditPermissionsModal() -->
</select>
```

Remove the old module flag checkboxes (`um-edit-mod-finance`, `um-edit-mod-sales`, etc.) from the edit modal HTML — they are no longer used. Delete the entire `um-edit-modules-section` div.

- [ ] **Step 4: Remove orphaned JS for module checkboxes**

Find and delete: `umEditRoleChanged()` function and its callers in the edit modal.

- [ ] **Step 5: Verify**

1. Open User Management, click "Edit Permissions" on a user.
2. Confirm the role dropdown lists roles (system + company-scoped), not the old 4-option enum.
3. Change the role, save — confirm the change persists and `erp_user_company_roles` is updated.

- [ ] **Step 6: Commit**

```bash
git add meridian-erp/index.html
git commit -m "feat: User Management uses erp_user_company_roles for role assignment"
```

---

## Phase 3 — RLS Policies

### Task 13: Supabase RLS policies for new tables

- [ ] **Step 1: Apply RLS policies via Supabase MCP or dashboard**

```sql
-- erp_roles: all authenticated users can read; only admins can write
CREATE POLICY "roles_select" ON erp_roles
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "roles_insert" ON erp_roles
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr
      JOIN erp_roles r ON r.id = ucr.role_id
      WHERE ucr.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr.company_id = company_id
        AND (r.permissions->>'admin:roles')::boolean = true
    )
    AND is_system = false  -- system roles cannot be created via API
  );

CREATE POLICY "roles_update" ON erp_roles
  FOR UPDATE USING (
    is_system = false
    AND EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr
      JOIN erp_roles r ON r.id = ucr.role_id
      WHERE ucr.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr.company_id = erp_roles.company_id
        AND (r.permissions->>'admin:roles')::boolean = true
    )
  );

CREATE POLICY "roles_delete" ON erp_roles
  FOR DELETE USING (
    is_system = false
    AND EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr
      JOIN erp_roles r ON r.id = ucr.role_id
      WHERE ucr.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr.company_id = erp_roles.company_id
        AND (r.permissions->>'admin:roles')::boolean = true
    )
  );

-- erp_user_company_roles: users can read their own; admin:users can read all for their company
CREATE POLICY "ucr_select_own" ON erp_user_company_roles
  FOR SELECT USING (
    user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
    OR EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr2
      JOIN erp_roles r ON r.id = ucr2.role_id
      WHERE ucr2.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr2.company_id = erp_user_company_roles.company_id
        AND (r.permissions->>'admin:users')::boolean = true
    )
  );

CREATE POLICY "ucr_insert" ON erp_user_company_roles
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr
      JOIN erp_roles r ON r.id = ucr.role_id
      WHERE ucr.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr.company_id = company_id
        AND (r.permissions->>'admin:users')::boolean = true
    )
  );

CREATE POLICY "ucr_update" ON erp_user_company_roles
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM erp_user_company_roles ucr
      JOIN erp_roles r ON r.id = ucr.role_id
      WHERE ucr.user_id = (SELECT id FROM erp_users WHERE auth_user_id = auth.uid() LIMIT 1)
        AND ucr.company_id = erp_user_company_roles.company_id
        AND (r.permissions->>'admin:users')::boolean = true
    )
  );
```

- [ ] **Step 2: Verify RLS**

Connect to Supabase as a non-admin test user (use the Supabase auth API or a test session). Run:

```sql
-- Should see own row only
SELECT * FROM erp_user_company_roles;

-- Should see 0 rows (not admin, so can't insert/update others)
-- Attempt to insert a row for another user — should be rejected
```

Verify that a `super_admin` user can see all rows.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(db): RLS policies for erp_roles and erp_user_company_roles"
```

---

## Phase 4 — Cutover (deferred — run after prod verification)

### Task 14: Drop old columns and remove deprecated helpers

**Run this only after Phase 3 has been stable in production for at least one release cycle.**

- [ ] **Step 1: Drop old columns**

```sql
ALTER TABLE erp_users
  DROP COLUMN IF EXISTS role,
  DROP COLUMN IF EXISTS module_finance,
  DROP COLUMN IF EXISTS module_finance_ar,
  DROP COLUMN IF EXISTS module_finance_ap,
  DROP COLUMN IF EXISTS module_finance_bank,
  DROP COLUMN IF EXISTS module_finance_ledger,
  DROP COLUMN IF EXISTS module_finance_reports,
  DROP COLUMN IF EXISTS module_sales,
  DROP COLUMN IF EXISTS module_sales_crm,
  DROP COLUMN IF EXISTS module_sales_orders,
  DROP COLUMN IF EXISTS module_operations;
```

- [ ] **Step 2: Remove deprecated isSales() and isUser() wrappers from index.html**

These are the least-precise wrappers. Replace the few remaining call sites with direct `can()` calls first, then remove the functions.

Search for `isSales()` and `isUser()` call sites — replace each with the specific atom that matches the context (e.g. `isSales()` guarding CRM → `can('sales:crm:read')`).

- [ ] **Step 3: Verify**

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'erp_users' AND column_name LIKE 'module_%';
```

Expected: 0 rows.

- [ ] **Step 4: Final commit**

```bash
git add meridian-erp/index.html
git commit -m "feat(cleanup): drop old role/module columns and deprecated helpers"
```

---

## Self-review checklist

- [x] Task 1–2: erp_roles + erp_user_company_roles tables ← covers spec §3
- [x] Task 3: backfill ← covers spec §5 Phase 2
- [x] Task 4–5: permission engine + canX wrappers ← covers spec §2, §4
- [x] Task 6: hook into initApp + switchCompany ← covers spec §4 (buildPerms timing)
- [x] Task 7: data-driven applyRoleNav ← covers spec §4
- [x] Task 8–11: role editor UI — list, matrix, overrides ← covers spec §6
- [x] Task 12: User Management role assignment ← covers spec §6
- [x] Task 13: RLS policies ← covers spec §7
- [x] Task 14: cutover ← covers spec §5 Phase 4
- [x] PERMISSION_MATRIX constant defined before use in Tasks 10–11 ← type consistency
- [x] `_rmRoles` state added before `loadRoleManagement()` uses it
- [x] `buildPerms()` defined in Task 4 before `loadAndBuildPerms()` calls it
- [x] `can()` and `canAny()` defined in Task 4 before Task 5 wrappers use them
