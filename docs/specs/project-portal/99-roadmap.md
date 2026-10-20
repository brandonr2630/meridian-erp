# Project Portal — Roadmap, Decisions and Risks

*Status: draft for owner review · 2026-10-19 · assembles [00-overview.md](00-overview.md) (contract and binding decisions X1–X23) and the four phase specs. All SQL in the specs is **desk-checked only**: nothing has been executed against a database.*

## Summary

Four phases take Meridian from an internal job tracker to a client-facing project portal where **a job is a project**. A **prerequisite stage, D0**, comes first. Live database checks (2026-10-19, read-only) found:

- 21 tables (`jobs`, every cost-entry table, `employees`, `config_*`, `job_audit_log`, `bill_edit_events`, `bill_lines_archive`) plus `notification_types` carry policies with `USING true` for any logged-in user.
- The `job-drawings` storage policies check only the bucket: any logged-in user can read, list, upload and delete every company's drawings; `company-logos` accepts uploads from any logged-in user.
- `next_job_no()` and `is_company_admin()` can be executed without logging in.
- Removing or deactivating a staff member in the ERP leaves their Supabase login working.

Good news from the same checks: every table has RLS enabled, no view bypasses RLS, all 4 login accounts have active staff records (so a staff-only policy locks nobody out today), and `pg_graphql` is not installed.

| Phase | Spec | Delivers | Audience |
|---|---|---|---|
| D0 | [phase-d-client-portal.md](phase-d-client-portal.md) (D0 section) | Staff-only and tenant-scoped security hardening, storage policies, function hardening | Everyone |
| A | [phase-a-schedule-v2.md](phase-a-schedule-v2.md) | Grouped Gantt, phases, milestones, baseline, weighted progress, schedule status, shared publish guard | Staff |
| B | [phase-b-quality.md](phase-b-quality.md) | ITP, hold points, NCRs, document register and approvals | Staff |
| C | [phase-c-updates-progress.md](phase-c-updates-progress.md) | Site and workshop updates with photos, progress snapshots, S-curve | Staff |
| D | [phase-d-client-portal.md](phase-d-client-portal.md) | Separate client app, client login, function-only client access, messages, notifications | Clients |

## Sequencing

Binding order (X23): **owner prerequisites, D0a, A, B, C, D0c, D core, D reads, B4.** Each migration uses a timestamped file name; rollback runs in reverse.

| Step | Work | Depends on | Parallel with | Gate to proceed |
|---|---|---|---|---|
| 0 | **Owner prerequisites** (dashboard): disable public sign-up and anonymous sign-ins; enable `pg_cron` and `pg_net`; store the service key in Vault; auth settings checklist (Phase D, pre-pilot gate) | none | everything | Checklist ticked and recorded in the D0 PR |
| 1 | **D0a**: `is_erp_staff()`, RESTRICTIVE staff-only policy on the 21 open tables plus `notification_types`, tenant-scoped `job-drawings` and locked `company-logos` storage policies, `next_job_no` staff check and anon revokes, `search_path` pinning; then **D0b** edge function to ban the auth user when staff are removed or deactivated | step 0 | A development | Real `operations_tech` and `viewer` login tested; storage test as a staff JWT and a non-staff JWT; ERP unchanged for staff |
| 2 | **Phase A** migration and the custom Gantt with KPI tiles (also creates the shared functions: `job_visibility_guard`, `job_task_weight`, `job_task_planned_pct`, `job_schedule_status`, `job_task_client_visible`, `lock_job_baseline`) | none | D0a, B development | Fixture test (JS and SQL progress agree) passes; live test on a real job |
| 3 | **Phase B** quality tables and guards, Quality card; applied **after A** (its visibility triggers call A's guard) | A applied | C development | Live RLS test as viewer and as operations_tech; forged INSERT of an approved document rejected |
| 4 | **Phase C** updates, photos, snapshots, S-curve; applied after A | A applied, `pg_cron` enabled | B | First nightly snapshot lands; same-day double save succeeds; staff S-curve loads |
| 5 | **D0c**: per-family tenant- and permission-scoped RLS replacing the restrictive stopgap (`job_audit_log`, `*_entries`, `jobs`, `employees`/`config_*`/`notification_types`, bill tables), one pull request per family | D0a | A to C | Each ERP screen still loads as each role; cross-company read returns nothing |
| 6 | **D core**: client grants, messages, `portal_*` core functions, staff RPCs, seeds for the portal atoms | D0c done; A to C applied | none | Penetration and abuse test plan passed |
| 7 | **D reads**: schedule, quality, documents, updates readers and client decision RPCs; edge functions; `portal-notify` | D core; A, B, C | none | Client sees only their job; kill-switch drill |
| 8 | **B4** overdue NCR cron | `pg_net`, Vault key | none | Cron fires once in test |
| 9 | **Pilot**: one client, one real job | all above | none | Dashboard checklist re-confirmed; revoke-all drill |

Re-run the definer sweep (**Q-D**; inventory queries Q-A to Q-E) after every step from 1 to 8.

## First slice (recommended)

Small, shippable and reversible, in this order:

1. **Owner prerequisites** (step 0): they cost nothing and close the sign-up exposure immediately.
2. **D0a** on its own, including the storage policies and anon revokes. This fixes real exposures that exist today.
3. **Phase A migration plus its shared functions** and the per-job custom Gantt. This is the visible win and the foundation every other phase reuses. Run the progress fixture test before relying on it.

## Before any migration is applied

1. **Execute the SQL once on a throwaway Postgres** (a local container or a Supabase branch). Every migration in the specs is currently untested code. Do not apply any of it to the live project first.
2. Run the Phase D read-only inventory queries (Q-A to Q-E, Q-R, Q-S1) and attach the output to the D0 pull request. The review already ran several of them and recorded the results in the specs.
3. Tick the owner dashboard checklist.

## Decisions needed from you

Defaults apply if you do not object.

| # | Decision | Phase | Recommended default |
|---|---|---|---|
| 1 | Upgrade the Supabase org to Pro (staging project, leaked-password protection, session time-boxing) | D | Yes, before the pilot |
| 2 | Portal subdomain | D | `projects.q2m.io` |
| 3 | Portal repo: separate `meridian-project` repo vs a folder in `meridian-erp` (a folder would be deployed into the ERP doc root) | D | Separate repo |
| 4 | MFA for client approvers | D | Optional in the pilot, required for approval actions at general availability |
| 5 | Client invite link lifetime | D | 1 hour (matches the Supabase OTP default; resend is one click) |
| 6 | Staff role labels shown to clients | D | First name plus role label (for example "Q2 project engineer"); never email or phone (X10) |
| 7 | Client-facing project name stored on `project_clients.project_title` | D | Yes (D may not alter `jobs`) |
| 8 | Jobs that have portal grants or messages cannot be hard-deleted from the ERP (retention) | D | Yes, block deletion |
| 9 | Message retention | D | Job life plus 7 years; client accounts deleted 90 days after the last grant ends |
| 10 | Schedule status thresholds: slip over 5 days = Late; 1 to 5 days or a progress gap below -10 points = At risk | A | Use as written, revisit after a month |
| 11 | List the real `jobs.job_type` values and map them to phase templates | A | Ship the default five-phase template only; add types as ops names them |
| 12 | Progress rule (X1): milestones always excluded; weight blank means task duration | A, C | As written |
| 13 | Who may re-baseline a schedule | A | `ops:work-orders:approve` (company_admin, operations_tech, super_admin), reason mandatory |
| 14 | Publish rule (X5): setting a row client-visible needs `ops:work-orders:approve` or the table's domain atom; editing the wording of a visible row unpublishes it | A, B, C | As written |
| 15 | Document visibility to clients (X9): issued, for approval, approved, rejected, superseded; never draft | B | As written |
| 16 | ITP counting (X8): only "passed" counts; waived shown separately; N/A excluded; staff record sign-offs | B | As written |
| 17 | Existing drawings with a stored file become `issued` on backfill | B | Yes; staff then bulk-set `client_visible` |
| 18 | Who may close NCRs | B | Admin roles only for all severities |
| 19 | Block job completion with open NCRs or unreleased hold points | B | Warn, do not block |
| 20 | Client planned curve covers visible tasks only while actual progress covers all tasks | C | Accept, label the chart accordingly |
| 21 | Photo retention after a job closes | C | Keep; revisit at 70 percent of plan storage |
| 22 | Who gets the new atoms: portal atoms to super_admin, company_admin, Office Admin (and operations_tech, sales_rep, viewer for read); quality atoms to super_admin, company_admin, operations_tech; `quality:ncr:close` to admins only | B, D | As written |
| 23 | **Drawing access will narrow** (D0a, X23): today any logged-in user can read every drawing; afterwards only holders of `ops:work-orders:read` (select) and `ops:work-orders:write` (insert), company admins for delete. `sales_rep`, `finance_manager` and `Office Admin` do not hold those atoms and would lose access to drawings. Run the atom-coverage query in the Phase D spec first | D0 | Intended; grant the atom to any role that needs drawings, before applying D0a |

## Cross-phase rules the roadmap enforces

| Rule | Where it bites |
|---|---|
| Clients get no `erp_users` row and no direct grants on base tables | D reads A to C only through `portal_*` functions with fixed columns |
| Every client-visible row carries `client_visible` defaulting to false, with an explicit publish step through one shared guard | A defines the guard; B, C, D reuse it with the exact two-argument contract (X19) |
| Cost and commercial columns never appear in any `portal_*` object | Verified for the specs by `scripts/verify-spec.mjs`; at build time by a definition-grep test |
| One progress implementation | A defines the SQL helpers; C calls them; JS mirrors them; a fixture test proves agreement (X20) |
| Guard bypass for client RPCs is `app.portal_rpc='1' AND current_user <> 'authenticated'`, with SECURITY INVOKER guards and definer RPCs owned by `postgres` | B documents, D references (X6) |
| `created_by` omitted or its FK target verified live; `updated_at` uses `set_updated_at()` | Every new table |
| Migrations are additive with a `-- down` section, except D0 which is the staged, rollback-backed exception | All phases |

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| D0 locks current staff out of the ERP | High | RESTRICTIVE policy first; live check shows all 4 accounts have active staff records; test with real non-admin logins per role; rollback SQL per stage |
| A client login reaches cost data or other companies' files through a missed table, function or storage policy | Critical | D0 before D; live inventory queries; function-only client access; storage policies tenant-scoped; penetration test |
| Publish rule silently not enforced (wrong guard arguments) | High | Contract X19 fixes the argument contract; tests that a wording edit unpublishes and that a domain-atom holder can publish |
| Staff-only guards bypassed by forging the `app.portal_rpc` setting | Medium | Guards are SECURITY INVOKER with a `current_user` check; no function callable by `authenticated` can set it (verified live); residual risk is limited to trusted staff |
| Untested SQL fails or misbehaves on first run | High | Execute everything on a throwaway Postgres first; two-run fixture test for the progress rule; staged rollout |
| Removed or deactivated staff keep a working login | Medium | D0b edge function bans the auth user; Q-E check for strays before the pilot |
| Staff data-entry burden makes the portal look empty or stale | Medium | Phase A templates, one-click publish, KPI tiles that degrade gracefully |
| Single Supabase project for staging and production | Medium | Dark-launch plan; Pro upgrade; kill-switch through `project_clients.revoked_at` |
| Photos expose other clients' equipment or people | Medium | Default internal, per-photo release, EXIF stripped by canvas re-encode |
| Quotas on the current plan (storage, email) | Low | Client-side photo downscaling; digest notifications |

## Effort (rough planning estimates, single developer with Claude, focused calendar days)

| Phase | Estimate | Notes |
|---|---|---|
| D0 (a, b, c) | 6 to 9 days | 22 tables, storage, functions, edge function, six D0c families; most time is testing each family with real role logins |
| A | 6 to 9 days | Custom Gantt renderer plus the shared functions and fixture harness |
| B | 6 to 9 days | Three tables, guard triggers, bridge from `qc_state` |
| C | 5 to 8 days | Photo upload, chart renderer, `pg_cron` |
| D build | 15 to 20 days | New app, five edge functions, functions and RPCs, invites, messages, notifications, sweep and CI scripts |
| Pilot and hardening | 5 days | One client, kill-switch drill |

These are estimates, not measurements; the first slice will calibrate them.

## Review status

Two independent reviews (cross-phase consistency, and security with live database checks) were run, two full revision rounds applied, and a mechanical cross-spec check (`scripts/verify-guards.mjs`) now guards the publish-guard argument contract and the live role name. Findings and binding decisions are recorded in section 8 of the overview (X1 to X23). Remaining unknowns that only execution can settle: SQL behaviour, whether the migration role may create policies on `storage.objects`, and the dashboard auth settings.
