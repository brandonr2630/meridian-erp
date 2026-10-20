# Project Portal — Overview and Contract

*Status: draft for review · 2026-10-19 · covers Phases A–D*

## 1. Goal

Give Q2 Machines clients a live, read-mostly view of their project (progress, schedule, quality, documents, messages), and give staff an internal dashboard of the same data. Reference mockup: "Belt Conveyor & Transfer Chute Package" (Meridian Project dashboard): KPI strip, grouped Gantt with milestones, progress curve, site/workshop updates, drawings and documents, quality and hold points, messages.

## 2. Decisions already made (do not re-litigate)

| # | Decision | Consequence |
|---|---|---|
| D1 | **Audience is the client portal.** Internal dashboard ships first. | Phases A–C are staff-side; Phase D exposes a client-safe subset. |
| D2 | **A job (work order) is a project.** No new parent "project" entity. `jobs.id` is the project id; `jobs.job_no` is the project number (the mockup's QM-2026-014). | Every new table keys on `job_id` and `company_id`, like `job_tasks`. |
| D3 | The portal is a **separate flat-file app** (own directory, own subdomain and deploy workflow) on the **same Supabase project**. The ERP `index.html` stays the staff tool. | Phase D defines the app shell; A–C add staff screens inside `index.html`. |
| D4 | Stack constraints of the monorepo apply: vanilla HTML/CSS/JS, no build step, Supabase REST via a thin fetch wrapper, deploy via GitHub Actions + rsync. | No frameworks, no bundler. CDN libs are pinned (as frappe-gantt 1.0.3 is). |
| D5 | Spec only in this PR. No code, no migrations applied. | Each phase must be independently shippable and reversible. |

## 3. Existing system the spec builds on (verified 2026-10-19)

- **Project = `jobs`** (Supabase `fcagxvjxfqqkmuposmcb`, "Terran Group ERP"). Relevant columns: `id, company_id, job_no, status, priority, customer (text), contact, email, date_received, due_date, date_completed, description, qc_state jsonb, drawings jsonb, specs jsonb, reports jsonb, quoted_ttd, costing_notes`. Statuses: Received, In Progress, On Hold, Completed, Invoiced, Closed. Cost fields (`quoted_ttd`, `misc_ttd`, `costing_notes`, rates in `labour_entries`, etc.) are **internal and must never reach a client**.
- **`job_tasks`** (shipped PR #143): `id, company_id, job_id, sort_order, task_name, start_date, end_date, progress 0-100, assignee, depends_on (self FK), created_at, updated_at`. RLS: SELECT company members; writes need `user_has_perm('ops:work-orders:write')`. **No `created_by`** on purpose.
- **`job_drawings`**: `drawing_no, drawing_title, revision_no, date, source, storage_key, archived`; private storage bucket `job-drawings` (PDF only, 20 MB). `created_by` references `erp_users(id)`.
- **Customers** are rows in `contacts` / `contact_persons`; `jobs.customer` is free text with **no FK to contacts**. A client user must be linked to a customer and a job set explicitly (Phase D).
- **Identity and permissions**: `erp_users (id, auth_user_id, company_id, is_active, …)`, `erp_roles (permissions jsonb of atoms like 'ops:work-orders:write')`, `erp_user_company_roles (user_id, company_id, role_id, permission_overrides)`, `user_company_access`. Helper functions (all `SECURITY DEFINER`): `my_company_ids()`, `user_has_perm(text)`, `is_company_admin(uuid)`, `is_super_admin()`. `user_has_perm` is **not** company-scoped. Always write `company_id IN (SELECT my_company_ids())`, never `= ANY(...)` (fails on this project).
- **Gotcha: `created_by` FK targets are inconsistent** (`jobs.created_by → auth.users`, `job_drawings.created_by → erp_users`, `purchase_orders.created_by → auth.users`). Check the live `pg_constraint` before adding any `created_by`; prefer omitting it, or name the target explicitly.
- **Notifications exist**: `erp_notifications`, `notification_log`, `notification_preferences`, `notification_types`, plus migrations `20260622_email_delivery.sql` and `20260622_pg_cron_overdue_notifications.sql` (email delivery via edge function; `pg_cron`).
- **Storage**: buckets `company-logos` (public) and `job-drawings` (private, signed URLs).
- **Gantt today**: portfolio Gantt on the Work Orders dashboard (frappe-gantt 1.0.3, read-only, list column) and a per-job "Schedule & Tasks" card. frappe cannot draw phase group headers, milestone diamonds, or a ghost "planned" bar behind "actual", so Phase A replaces it with a custom renderer for the per-job view.
- **UI conventions**: ERP is dark-themed with CSS variables (`--bg-2`, `--gold`, `--green`, …); the portal mockup is a separate light green identity. Inline-save row pattern (insert on add, PATCH on change) as in `job_drawings` and `job_tasks`.
- **Security rules**: escape every user string with `escHTML` before `innerHTML`; RLS on every table; verify RLS with a real non-privileged user, not only the service role.

## 4. Mockup block → phase map

| Mockup block | Phase |
|---|---|
| Grouped Gantt (phases, milestones, today line, critical path, planned vs actual) | A |
| KPI: overall progress, schedule status / handover forecast | A |
| KPI: ITP sign-off, hold points awaiting approval, open NCRs | B |
| Drawings & documents register with approval status | B |
| Progress curve (planned vs actual) | C |
| Latest from site & workshop (updates with photos) | C |
| Messages, Team, client login, client-scoped access, notifications | D |

## 5. Cross-cutting rules every phase spec must follow

1. **Migrations are additive and reversible.** Provide `up` SQL and a `down` note. No destructive change to a table the ERP currently reads.
2. **Every new table**: `id uuid pk default gen_random_uuid()`, `company_id` (FK companies), `job_id` (FK jobs ON DELETE CASCADE), `created_at`, `updated_at`; indexes on `job_id` and `(company_id, job_id)`; RLS enabled with explicit SELECT/INSERT/UPDATE/DELETE policies.
3. **Client visibility is explicit.** Any table a client may ever see carries a `client_visible boolean not null default false` (or is entirely client-facing). Staff-only data never relies on the UI to hide it.
4. **Never expose cost data** (see §3). Phase D must prefer **views / RPCs returning a whitelist of columns** over granting row access to base tables.
5. **Name every referenced table** that already exists using the exact live name; any new table must be defined in the spec that introduces it.
6. **No code in the spec**, other than SQL DDL/policy snippets, JSON shapes, and short pseudo-code. UI is described with wireframe-level structure and the data each element binds to.
7. Each phase spec uses the **same section structure** (see §6) so the roadmap can be assembled mechanically.
8. Flag decisions you could not settle under "Open questions" with a recommended default. Do not silently invent business rules.

## 6. Required structure of each phase spec

`# Phase X — <title>` then these `##` sections, in order: **Goal and scope**, **Out of scope**, **Data model** (SQL), **RLS and permissions**, **Staff UI (ERP)**, **Client-facing surface** (what, if anything, the client sees from this phase; "None" is valid for A–C only if explained), **Migration and rollout**, **Test plan**, **Risks**, **Open questions**, **Acceptance criteria**.

## 7. Phases

- **A — Schedule v2 and project KPIs** (internal)
- **B — Quality: ITP, hold points, NCRs, document approvals** (internal)
- **C — Site/workshop updates, progress history and S-curve** (internal)
- **D — Client portal** (separate app, client role, scoped access, messages, notifications)

### Reserved table names (prevents collisions between parallel phase specs)

| Phase | Owns / creates | Alters existing |
|---|---|---|
| A | `job_phases` (phase groups per job), `job_task_links` (multi-predecessor dependencies; added by Phase A author, accepted) | `job_tasks` (add phase, milestone, critical, baseline dates, weight) |
| B | `job_itp_items`, `job_hold_points`, `job_ncrs` | `job_drawings` (approval/issue status columns) |
| C | `job_updates`, `job_update_photos`, `job_progress_snapshots` | none (new private storage bucket `job-updates`) |
| D | `project_clients` (client user ↔ customer ↔ job access), `project_messages`, `project_message_reads`, all `portal_*` views/functions | `erp_roles` seed for a `client` role only if justified |

A spec may reference another phase's reserved table by name in a `REFERENCES` or in prose; it must not `CREATE` a table reserved to another phase. Phase D reads A–C tables **only through `portal_*` views/functions**.

Dependencies: B and C depend on A only for the shared "project overview" screen; their tables are independent. D depends on A–C tables (it reads them through views) and is the only phase with an external trust boundary.

**Correction to the dependency statement above (review round 1):** B is independent of A. **C requires A's migration applied first** (its SQL functions use A's `weight`, `baseline_start/end`, `is_milestone` at CREATE time). D0 (legacy RLS hardening) precedes D and is the sanctioned exception to rule 1 of section 5 (staged per table, with rollback SQL per stage). D reads A-C only through `portal_*` **functions** (no views).

## 8. Cross-phase decisions (review round 1, binding on all phase specs)

These resolve drift found by the consistency review. Each phase spec must follow them; where a rule names an owner, only that phase defines the object and the others reference it by name.

| # | Decision | Owner |
|---|---|---|
| X1 | **One progress rule.** Task weight = `COALESCE(weight, duration_days)` where duration = `end_date - start_date + 1` (min 1; undated task = 1). Milestones (`is_milestone`) are always excluded, whatever their `weight`. Planned % uses baseline dates, falling back to current dates. The same rule is implemented identically in JS (`jcSchedCompute`), SQL `job_progress_calc` and `plannedPctOn`; a shared fixture test must prove they agree. | A defines; C's SQL follows A |
| X2 | **One schedule-status source.** A defines SQL `job_schedule_status(job_id)` returning `(status, forecast_end, slip_days)` using A's rules and labels (On track / At risk / Late); JS mirrors it. C's `job_progress_snapshots` stores `schedule_status`, `forecast_end`, `slip_days` written by the snapshot function. D reads the stored values; it does not recompute. | A defines; C stores; D reads |
| X3 | **Planned curve is server-side.** C defines SQL `job_planned_curve(job_id, from, to)` returning `(date, planned_pct)` from client-visible tasks' baseline dates; re-baselining rewrites snapshot `planned_pct`. D wraps it as `portal_planned_curve`. | C |
| X4 | **Snapshot writes** are protected by a transaction-local flag `app.snapshot_rpc` set only inside the snapshot functions. `auth.uid()` is NOT a valid discriminator inside SECURITY DEFINER functions (it stays set). | C |
| X5 | **One publish rule.** Setting `client_visible = true` on any A-C table needs `ops:work-orders:approve` OR the table's domain atom (`quality:docs:issue` for documents). Enforced by one shared trigger function `job_visibility_guard()`. Editing the client-facing wording of a row that is already visible auto-unpublishes it. Every visibility change writes a `visibility_changed` row to `job_audit_log`. The atom `portal:publish` is dropped. | A defines the function; B, C, D reuse it |
| X6 | **`app.portal_rpc` guard (revised after security review).** B's guard triggers become **SECURITY INVOKER** (they only need `user_has_perm`, itself a definer). The bypass condition is `current_setting('app.portal_rpc', true) = '1' AND current_user <> 'authenticated'`: inside D's SECURITY DEFINER RPCs `current_user` is the function owner; on direct PostgREST access it is `authenticated`. Verified live: no function callable by `authenticated` uses `set_config` or dynamic SQL, and PostgREST cannot set the GUC. Clients also have no `erp_users` row, so `my_company_ids()` is empty and every A-C policy denies them. | B defines; D references |
| X7 | **`job_drawings` guards** apply to INSERT and UPDATE: on INSERT force `status='draft'`, `client_visible=false`, `requires_client_approval=false` unless the caller holds `quality:docs:issue`; the approval columns (`approved_*`, `approval_note`, `approval_requested_at`) are writable only via the D RPC path or `quality:docs:issue`. | B |
| X8 | **ITP counting** (B's rule): numerator = `passed`; `waived` shown separately; denominator = items with `status <> 'na'`. Client sign-off of ITP items is NOT a feature; staff record results. Remove client sign-off columns and claims from B and D. | B; D follows |
| X9 | **Document visibility to clients:** statuses `issued`, `for_approval`, `approved`, `rejected`, and `superseded` (kept visible for history, labelled). Draft never. | B; D follows |
| X10 | **Staff names to clients:** first name plus role label ("Q2 project engineer") only; never email or phone. Update C's whitelist rule accordingly. | D; C follows |
| X11 | **Atoms are seeded explicitly.** `erp_roles.permissions` is a JSON **object** `{atom: true}` (verified live, all 7 roles) and `user_has_perm` has no super_admin wildcard, so every new atom needs an `UPDATE erp_roles SET permissions = permissions \|\| jsonb_build_object(...)` for the roles named in the spec, with a `-- down`. D must seed `portal:read`, `portal:invite`, `portal:messages:reply`. | each phase seeds its own |
| X12 | **`job_audit_log` and storage hardening belong to D0 only.** D0 adds a stage replacing the `job-drawings` storage policies (they check only `bucket_id`: any logged-in user, including a client, can read, list and delete every company's drawings) and checks `company-logos` write policy. B4 and C defer to D0. The audit log insert policy must be verified against the ERP's own insert path. | D (D0) |
| X13 | **SECURITY DEFINER hygiene.** Every new definer function: fixed `search_path`, `REVOKE ALL ... FROM PUBLIC, anon` (and from `authenticated` unless intended as an RPC), authorization re-checked inside, and the D0-Q2 sweep re-run after each migration. `quality_next_no` is trigger-only (revoked from all). | all |
| X14 | **Notifications:** one convention, dotted event keys in `erp_notifications.type` with the job number in `title`. Client-originated decisions use D's `portal.*` keys; B does not define a second set for the same events. | D owns `portal.*`; B owns staff-only `quality.*` |
| X15 | **Naming:** D exposes `portal_*` **functions** (`portal_updates`, `portal_progress_curve`, `portal_quality`, `portal_documents`, `portal_schedule`, `portal_project_kpis`, `portal_planned_curve`); A, B, C refer to them by these names, not "views". | all |
| X16 | **Migrations** use timestamped names `YYYYMMDDHHMM_<slug>.sql` (date-only names collide) and this order: D0a staff-only restrictive policy + storage hardening; A; B (parallel with A); C (after A); D0c table-family RLS hardening (one PR per family); D portal_core; D portal_reads (after A-C); B4 NCR overdue cron. `updated_at` uses the existing `set_updated_at()` trigger everywhere. | all |
| X17 | **D0 scope is larger than the original `USING true` fix** (live-verified, see `live-facts.md` content summarised in the roadmap): (a) RESTRICTIVE staff-only policy on the 21 open tables plus `notification_types`; (b) **storage**: replace the `job-drawings` read/upload/delete policies (bucket-only today) with tenant-scoped, permission-checked policies (object path prefixed by company id, or joined via `job_drawings.storage_key`), add a RESTRICTIVE `is_erp_staff()` policy on `storage.objects` for `job-drawings` and `company-logos`, and lock `company-logos` writes (today any authenticated user can upload); (c) `REVOKE ... FROM PUBLIC, anon` on `next_job_no()` and `is_company_admin(uuid)` (both anon-executable today) and add an `is_erp_staff()` check to `next_job_no()`; (d) pin `search_path = public, pg_temp` on `my_company_ids()` and `is_super_admin()`; (e) NOT NEEDED: the live `my_company_ids()`, `is_super_admin()` and `user_has_perm()` already filter `is_active` (verified); (f) ban the Supabase auth user when staff are deactivated or removed (edge function), since `removeUser` today deletes only the `erp_users` row; (g) replace the D0 inventory query so it also finds tables with RLS off, definer views, bucket-only storage policies and permissive policies lacking an identity predicate (today: none for RLS-off tables or non-invoker views). D0 stage 1 is safe for current users: all 4 auth users have active `erp_users` rows. | D (D0) |
| X18 | **Staff identity edge cases:** the restrictive policies use `is_erp_staff()` = active `erp_users` row for `auth.uid()`; `service_role` and `postgres` bypass RLS and are unaffected (live-verified). Enable no public sign-up and no anonymous sign-ins (owner dashboard checklist in the roadmap). | D (D0) |
| X19 | **Guard call contract (round 2).** A's `job_visibility_guard()` is attached `BEFORE INSERT OR UPDATE` with exactly two trigger arguments: `TG_ARGV[0]` = comma-separated client-facing wording columns (editing any of them while `client_visible` is true auto-unpublishes), `TG_ARGV[1]` = optional domain atom that may publish besides `ops:work-orders:approve` (empty string if none). B and C MUST attach it with those arguments (B: ITP, hold points, NCRs, drawings, each with its own wording columns and domain atom; C: `('title,body,kind,occurred_on','')` on updates, `('','')` on photos and snapshots; recorded exception: the snapshots guard is `BEFORE UPDATE` only, because the definer upsert inserts with an inherited `client_visible = true` and an INSERT guard would reject on-save callers without approve and write a `visibility_changed` row every night; direct client INSERTs are blocked by `WITH CHECK (false)`). The guard and B's guards exempt `session_user IN ('postgres','supabase_admin')` so migrations and backfills are not silently downgraded. | A defines; B, C attach |
| X20 | **Single progress implementation in SQL.** C's `job_progress_calc` and `job_planned_pct_on` CALL A's `job_task_weight` and `job_task_planned_pct`; they do not re-derive the formula. SQL stores 2 decimal places; every UI rounds half-up to an integer for display; the shared fixture compares both representations. | A defines; C calls |
| X21 | **Schedule status labels** are A's five: On track, At risk, Late, Complete, On hold. `job_schedule_status` always returns a row (status never NULL; `forecast_end`/`slip_days` may be NULL). C stores them; D maps all five (and "Not published" is a D-only display state when no snapshot is client-visible). Planned handover shown to a client is NULL when slip is NULL. | A defines; C stores; D maps |
| X22 | **One client-visibility predicate for schedule data:** a task is client-visible only if `task.client_visible AND (task.phase_id IS NULL OR phase.client_visible)`. A defines it as a SQL function `job_task_client_visible(task_id)`; C's `job_planned_curve(..., client_only)` and D's `portal_schedule` both use it. | A defines; C, D use |
| X23 | **Ordering and prerequisites (round 2).** Strict order: D0a, A, B, C, D0c, D core, D reads, B4. B is applied AFTER A (its visibility triggers call A's function); B may be developed in parallel. **Owner prerequisite step 0 (before A and C):** enable `pg_cron` and `pg_net` in the dashboard and store the service key in Vault; migrations use only `CREATE EXTENSION IF NOT EXISTS`. The definer sweep is named **Q-D** (inventory queries Q-A..Q-E, Q-R, Q-S1) everywhere. Storage policies for `job-drawings`: membership-scoped plus `ops:work-orders:read` (select) / `ops:work-orders:write` (insert) / company admin (delete). | all |
