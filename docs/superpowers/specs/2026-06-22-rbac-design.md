# RBAC Design — Meridian ERP

**Date:** 2026-06-22  
**Status:** Approved for implementation  
**Scope:** `meridian-erp/index.html` + Supabase schema

---

## 1. Problem

The current system has four flat roles (`super_admin`, `admin`, `sales`, `user`) stored on `erp_users.role`. All seven `canX()` action guards map to `isAdmin()` — there is no granularity. Module flags (`module_finance`, `module_sales`, etc.) drive nav visibility but are not wired into action guards. Roles are global, not per-company, meaning an admin at one company is admin everywhere.

**Gaps this design closes:**
- Sales users cannot be granted AR write access without becoming full admins.
- Admins cannot be scoped to a single module (e.g. Finance only).
- Adding a new role or module requires code changes.
- No per-company role assignment.

---

## 2. Model

### Three-layer architecture

```
permission atom   →   finance:ar:write
role preset       →   "Finance Manager" = { finance:ar:read, finance:ar:write, finance:ar:approve }
user assignment   →   user X at company Y has role Z + overrides { finance:ap:approve: true }
```

### Permission atoms

Namespaced strings: `domain:module:action`.

| Domain | Module | Actions |
|--------|--------|---------|
| finance | ar | read, write, approve, void |
| finance | ap | read, write, approve, void |
| finance | bank | read, write |
| finance | ledger | read, write |
| finance | coa | read, write |
| finance | reports | read |
| sales | crm | read, write |
| sales | orders | read, write, approve |
| sales | quotes | read, write, approve |
| sales | clients | read, write |
| sales | vendors | read, write |
| sales | deliveries | read, write |
| ops | work-orders | read, write, approve |
| ops | costing | read, write |
| ops | delivery | read, write |
| admin | — | users, settings, roles, companies |

Total: ~40 atoms.

### Permission resolution

```js
// Built once at login and on every company switch. O(1) lookup thereafter.
let _perms = {};

function buildPerms(rolePermissions, overrides) {
  _perms = { ...rolePermissions, ...overrides };
}

function can(perm)          { return _perms[perm] === true; }
function canAny(...perms)   { return perms.some(p => can(p)); }
```

Override `true` grants a permission the role does not have.  
Override `false` explicitly strips a permission the role does have.  
Overrides always win.  
**Default deny:** any atom absent from both role permissions and overrides returns `false`.

---

## 3. Database schema

### New table: `erp_roles`

```sql
CREATE TABLE erp_roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid REFERENCES erp_companies(id) ON DELETE CASCADE,
  -- NULL = system template, visible to all companies
  name        text NOT NULL,
  is_system   boolean NOT NULL DEFAULT false,
  -- system roles cannot be edited or deleted
  permissions jsonb NOT NULL DEFAULT '{}',
  created_by  uuid REFERENCES erp_users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, name)
  -- Note: PostgreSQL treats NULL != NULL in UNIQUE, so two system roles (company_id = NULL)
  -- with the same name are NOT prevented by this constraint alone.
  -- Add a partial unique index for system roles:
  -- CREATE UNIQUE INDEX erp_roles_system_name_unique ON erp_roles (name) WHERE company_id IS NULL;
);
```

### New table: `erp_user_company_roles`

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
```

### Seeded system roles (`is_system = true`, `company_id = NULL`)

| Name | Key permissions |
|------|----------------|
| super_admin | All 40 atoms |
| company_admin | All except `admin:companies` |
| finance_manager | `finance:*:*` (all finance atoms) |
| sales_rep | `sales:*:*` + `finance:ar:read` |
| operations_tech | `ops:*:*` + `sales:deliveries:read/write` |
| viewer | All `:read` atoms only |

### Deprecated columns (kept during migration, removed in Phase 4)

- `erp_users.role`
- `erp_users.module_finance` and all `module_*` sub-flags

---

## 4. Frontend permission engine

### Replacement for `canX()` helpers

Old helpers become thin wrappers delegating to `can()`. No mass find-replace of ~31 call sites on day one — wrappers provide a safe bridge during Phase 3.

```js
// Thin wrappers — kept for backward compatibility during dual-read phase
function isAdmin()      { return can('admin:users') || can('admin:settings'); }
function isSuperAdmin() { return can('admin:companies'); }
// canPost/canVoid/canApprove are intentionally permissive during Phase 3:
// a user with ar:write passes canPost() even in an AP context. This is acceptable
// because AP nav items are hidden via data-perm for users without ap:read.
// Phase 4 replaces these call sites with direct can('finance:ar:write') etc.
function canPost()      { return canAny('finance:ar:write','finance:ap:write'); }
function canVoid()      { return canAny('finance:ar:void','finance:ap:void'); }
function canApprove()   { return canAny('finance:ar:approve','finance:ap:approve'); }
function canDelete()    { return can('admin:settings'); }
function canSettings()  { return can('admin:settings'); }
function canFinance()   { return canAny('finance:ar:read','finance:ap:read','finance:bank:read','finance:ledger:read','finance:reports:read'); }
function canViewAR()    { return can('finance:ar:read'); }
```

Call sites are replaced with direct `can()` calls in a separate cleanup pass after Phase 3 is stable.

### `applyRoleNav()` — data-driven replacement

Each `<div class="nav-item">` receives a `data-perm` attribute. `applyRoleNav()` becomes a single loop:

```js
function applyRoleNav() {
  document.querySelectorAll('.nav-item[data-perm]').forEach(el => {
    el.style.display = can(el.dataset.perm) ? '' : 'none';
  });
}
```

Adding a new module requires only a `data-perm` attribute on its nav item — no changes to `applyRoleNav()` itself.

---

## 5. Migration plan

### Phase 1 — Schema (no app changes)

1. Run SQL to create `erp_roles` and `erp_user_company_roles`.
2. Seed 6 system roles with full permissions jsonb.
3. Deploy to Supabase. App still uses old columns.

### Phase 2 — Backfill users (SQL script, no app changes)

Map existing `erp_users.role` to `erp_user_company_roles`:

| Old role | New role preset | Company |
|----------|----------------|---------|
| super_admin | super_admin | all companies |
| admin | company_admin | their `company_id` |
| sales | sales_rep | their `company_id` |
| user | viewer | their `company_id` |

Map `module_*` flags to `permission_overrides` only where flag is `false` (explicit denial):

Wildcard notation below is shorthand. The Phase 2 SQL script must expand each wildcard to the
individual atoms listed in §2 before writing to `permission_overrides` jsonb — `can()` does
exact string matching, not glob matching.

```
module_finance = false       → overrides all finance:*:* = false
module_finance_ar = false    → overrides finance:ar:* = false
module_finance_ap = false    → overrides finance:ap:* = false
module_finance_bank = false  → overrides finance:bank:* = false
module_finance_ledger = false → overrides finance:ledger:* = false
module_finance_reports = false → overrides finance:reports:read = false
module_sales = false         → overrides sales:*:* = false
module_sales_crm = false     → overrides sales:crm:* = false
module_sales_orders = false  → overrides sales:orders:* = false
module_operations = false    → overrides ops:*:* = false
```

### Phase 3 — Dual-read (app ships new engine)

- `buildPerms()` called at login and on every `switchCompany()`.
- All `can()` and `canX()` wrappers active.
- Old `erp_users.role` column still present — not read by app but not yet dropped.
- Verify prod access for all user types before Phase 4.
- Fully reversible: revert app deploy to restore old behavior.

### Phase 4 — Cutover (irreversible)

- Drop `erp_users.role`, `erp_users.module_*` columns.
- Remove legacy `isX()` role-based helpers.
- Replace remaining direct `canX()` call sites with `can('domain:module:action')`.

---

## 6. Role editor UI

**Location:** Settings → Role management (new nav item, `data-perm="admin:roles"`)

### Role list

Grid of role cards. Each card shows: name, system/custom badge, permission count, edit button (custom only). System roles show a lock icon — no edit, no delete.

### Permission matrix (create / edit role)

Table with rows = modules, columns = Read / Write / Approve / Void. Cells where an action does not exist for a module show `—`. Checkboxes are the only input. Name field at top. Save creates/updates `erp_roles` row.

### User assignment with overrides

Within each role card (or accessed from User Management), a list of users assigned that role at a given company. Each user row has:
- Role dropdown (per company — changes `erp_user_company_roles.role_id`)
- "Overrides" button — opens a focused modal showing only the delta permissions for that user, as toggle switches

### Access control for the editor

- `can('admin:roles')` required to view Role management.
- `can('admin:users')` required to change a user's role assignment.
- System roles are read-only regardless of permissions.
- A user cannot grant permissions they do not themselves hold (server-side enforcement via Supabase RLS).

---

## 7. Security

- Permission checks in JS are UI convenience only. Supabase RLS policies enforce the same rules server-side.
- RLS policies read from `erp_user_company_roles` joined to `erp_roles` to resolve effective permissions.
- A user cannot elevate their own permissions via the override UI — saves are rejected if the requesting user lacks the permission they are trying to grant.
- `admin:companies` is restricted to `super_admin` role only and cannot be granted via overrides by a `company_admin`.

---

## 8. Out of scope

- Time-bound permissions (expiry dates on roles).
- Audit log of permission changes (future phase).
- Row-level data scoping beyond company isolation (already handled by `company_id` on all records).
