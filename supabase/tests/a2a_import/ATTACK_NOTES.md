# import_job_schedule: attack notes for the independent reviewer

Target: `supabase/migrations/202610271300_a2a_import.sql` (SECURITY DEFINER `import_job_schedule(uuid, text, jsonb, text)` plus seven INVOKER helpers `import_sched_*`).
Tests: `supabase/tests/a2a_import/20_after.sql` (run: `bash supabase/tests/d0c_common/run.sh a2a_import`), mutants: `mutations.json`
(`node supabase/tests/d0c_common/mutate.mjs a2a_import`). Test names below are the label prefixes printed as `NOTICE: PASS <label>`.

## Attack classes tried

| # | Attack class | What was tried | Covering tests (label prefix) | Result |
|---|---|---|---|---|
| 1 | Privilege escalation through the definer | anon, client-shaped login (no `erp_users` row), inactive user, viewer, finance role, writer without approve calling replace or writing a baseline, direct call of the helpers by an API role | `exposure:`, `auth:`, `replace:` (viewer, writer, blank reasons), `baseline:` (writer file), `owner:` | Refused with 42501 or `job not found`; helpers are not executable by anon/authenticated/PUBLIC |
| 2 | Roles in the wrong company | A user who is writer+approver in company 1 but only viewer in company 2 importing into a company 2 job (`user_has_perm()` is not company scoped, so the RPC uses its own company-scoped atom check) | `auth: write in company 1 does not carry into a company 2 job` | Refused. Mutant "scoped atoms: role in ANY company counts" is caught |
| 3 | Cross-tenant data access | Importing into another company's job by id; merge payload whose uid equals a row in another company's job; replace on another company's job | `auth: other company approver ...`, `xco:` | `job not found`; other company rows untouched |
| 4 | search_path / object hijack | Function pins `search_path = public, pg_temp`; every working table is referenced as `pg_temp.<name>` and dropped before creation; helpers pinned too | `struct: ... pinned search_path` (RPC and 7 helpers) | OK. Residual: see R4 |
| 5 | SQL injection | Names, assignee, file name, reason and warning text containing `'); DROP TABLE job_tasks; --`, script tags; the RPC contains no dynamic SQL | `inert:`, `struct: no dynamic SQL`; mutant "dynamic SQL introduced" | Stored as inert text; table intact; no EXECUTE anywhere in the import code |
| 6 | Baseline guard bypass | Direct UPDATE/INSERT of baseline columns by authenticated and by the table owner after an import (setting must be back to off); `set_config('app.baseline_rpc','on')` from a client; the RPC re-owned to a role that does not own `lock_job_baseline` (owner rule is load-bearing); writer file with baselines; baseline on a job that already has one; partial baseline | `baseline:`, `owner:`, `struct: owner`; migration also raises at apply time if the owner differs | Guard stays closed: baselines are written only inside the RPC, only by an approver, only with the setting on for exactly one UPDATE |
| 7 | Cross-job leakage inside the job | Merge matching on msp_uid is filtered by job; phase uid never matches a task row and vice versa (kind change -> new row plus warning); a same-named row with another uid is not matched | `merge:`, `xco:` | OK |
| 8 | Merge forged as own file | Foreign project uid, missing project uid, `temporary_uids`, read-only export marker in `project.manager`, upper-case job id, project_uid and project.uid disagreeing | `merge: ...` | Merge refused (`merge requires a file exported from this job ...`) |
| 9 | Replace data loss | Replace by writer, without reason, with blank/control-character reason, with a stale preview, with a payload that fails after the delete (rolled back), with a bad payload, cross-company; recovery copy in audit metadata (ids, names, phase/parent/uid/published flag for tasks, links) | `replace:`, `atomic:`, `inert: reason` | Old schedule intact on any failure; success writes `schedule_imported` with `metadata.recovery` and `deleted` counts |
| 10 | Atomicity | A failure injected at the link insert (after phases and tasks are written) for append and for replace; bad rows anywhere in the payload | `atomic:`, `type:` (every refused file leaves 0 rows and 0 audit rows) | Zero writes |
| 11 | Graph attacks | Link cycles in the payload; a merge whose new link closes a cycle through a STORED link; self links; links to missing uid or to a phase uid; duplicate predecessor; parent cycles; self parent; parent in another phase; depth 7 with and without a phase; depth pushed over 6 through a stored descendant that is not in the file | `graph:`, `depth:`, `parent:`, `uid:` | All rejected before any write, with specific messages |
| 12 | Hostile strings | Control characters, bidi overrides (U+202E), zero width characters, line breaks, over-length names (256), empty names, phase names over 80, 7 MB padding key | `clean:`, `inert:`, `type:`, `bounds:`, `caps:` | Stripped / cut / refused as designed |
| 13 | Type confusion in the jsonb | About 190 wrong-type or out-of-range values across every key (uid, name, dates, progress, flags, links, project, top-level keys) plus non-object payloads (array, string, json null, SQL NULL) | `type:` | Each refused with `invalid payload: ...`; none echoes the offending value |
| 14 | DoS by size | 2001 tasks, 501 phases, more than 5000 links, payload over 6 MB, a 2000-task 1999-link chain (accepted, about 1.2 s) and the same chain closed into a ring (rejected), job total cap 10000 tasks | `caps:` | Caps enforced before the expensive steps; the cycle check peels edges and is linear per round |
| 15 | Lost update / races | Stale preview (`based_on`), missing `based_on`, millisecond tolerance, empty job with a non-empty `based_on`; advisory lock on the same key (`hashtext(job_id::text)`) that `prepare_schedule_export` will use | `stale:`, `append: the advisory lock ...` | OK. Two real sessions are not simulated (single session tests); see R3 |
| 16 | Publish bypass | Imported rows inserted unpublished; a merge that renames a published row auto-unpublishes (through `job_visibility_guard`, with the audit row), dates/progress edits do not; the RPC never sets `client_visible = true` | `append: imported rows ...`, `merge: ...`, `real fNN: nothing is published` | OK |
| 17 | Real codec payloads | Output of `MspCodec.toPayload(MspCodec.parse(fixture))` for the 7 ProjectLibre fixtures, imported unchanged (plus the two wrapper fields); fixture 04 as an own-file merge round trip; a read-only-export file refused for merge | `real fNN:`, `roundtrip:` | Rows, links (type and lag), hierarchy, dates, progress, milestones, phases, baselines and warnings all equal the payload |

## Rulings (decisions the spec does not make)

See the final report of the leaf for the list; the ones that matter to a reviewer are:
company-scoped atoms instead of `user_has_perm`; baseline written only for approvers on a job without a locked baseline (or replace), following the
"Baseline on import" prose rather than the pseudo-code; `based_on` defined as the greatest `updated_at` over the job's tasks, phases and links (ms precision);
replace and merge uid policy; empty names become `(unnamed)`.

## Residual risk (not closed by this migration)

* R1 **Audit log is not tamper proof.** `job_audit_log` has the legacy "authenticated users full access" policy (D0a restricts it to staff only), so any staff member can edit or delete the
  recovery copy that replace relies on. Closing that is a D0c/audit-table concern, not this function.
* R2 **Deleting from job_tasks cascades or nulls other tables.** Replace runs `DELETE FROM job_tasks`; tables added later that reference `job_tasks(id)` (A2b `labour_entries.task_id` is `ON DELETE SET NULL`, future B/C tables) will lose or null their link. Re-check when those land.
* R3 **Concurrency is serialised only against code that takes the same advisory lock.** UI row saves go straight to PostgREST without the lock; they are covered by the stale check (`updated_at`) except for deletions of rows that are not the newest. Real two-session races were reasoned about, not executed.
* R4 **Temp tables.** The RPC creates `ON COMMIT DROP` temp tables with fixed names in `pg_temp`. They are dropped (if present) before use and always referenced as `pg_temp.x`; another role cannot read them. If the function is ever called with `statement_timeout` shorter than the job it will roll back cleanly.
* R5 **uid reuse.** The counter is `max(msp_uid) + 1` over the job (the spec's rule); replace keeps the old floor, but a UI delete of the newest row followed by an import can reuse its uid. A persistent counter would need a column or table.
* R6 **Other leaf's guards.** The `a2a_schema` leaf adds parent same-job/cycle/depth triggers. The RPC pre-checks the whole final graph and detaches changed parents before attaching, so it should never trip them, but the two migrations were tested separately; run the combined suite at integration.
* R7 **Resources/assignments** in the payload are ignored with a warning (A2b not built); the RPC must be revisited then.
* R8 **Heavy but legitimate use.** A writer can import a 2000-task file repeatedly (about 1.2 s each); there is no rate limit.
* R9 **service_role** keeps EXECUTE (Supabase default); it has no `auth.uid()` so the RPC answers `job not found`.
* R10 **Permission overrides** (if the live `user_has_perm` ever honours per-user overrides) are not honoured by the company-scoped check, which reads role permissions only (same as `d0d_actor_has_atom`).
