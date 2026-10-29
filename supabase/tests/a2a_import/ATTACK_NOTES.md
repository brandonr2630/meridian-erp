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
| 9 | Replace data loss | Replace by writer, without reason, with blank/control-character reason, with a stale preview, with a payload that fails after the delete (rolled back), with a bad payload, cross-company; recovery copy in audit metadata (full rows of everything deleted, see the review findings L5) | `replace:`, `atomic:`, `inert: reason` | Old schedule intact on any failure; success writes `schedule_imported` with `metadata.recovery` and `deleted` counts |
| 10 | Atomicity | A failure injected at the link insert (after phases and tasks are written) for append and for replace; bad rows anywhere in the payload | `atomic:`, `type:` (every refused file leaves 0 rows and 0 audit rows) | Zero writes |
| 11 | Graph attacks | Link cycles in the payload; a merge whose new link closes a cycle through a STORED link; self links; links to missing uid or to a phase uid; duplicate predecessor; parent cycles; self parent; parent in another phase; depth 7 with and without a phase; depth pushed over 6 through a stored descendant that is not in the file | `graph:`, `depth:`, `parent:`, `uid:` | All rejected before any write, with specific messages |
| 12 | Hostile strings | Control characters, bidi overrides (U+202E), zero width characters, line breaks, over-length names (256), empty names, phase names over 80, 7 MB padding key | `clean:`, `inert:`, `type:`, `bounds:`, `caps:` | Stripped / cut / refused as designed |
| 13 | Type confusion in the jsonb | About 190 wrong-type or out-of-range values across every key (uid, name, dates, progress, flags, links, project, top-level keys) plus non-object payloads (array, string, json null, SQL NULL) | `type:` | Each refused with `invalid payload: ...`; none echoes the offending value |
| 14 | DoS by size | 2001 tasks, 501 phases, more than 5000 links, payload over 6 MB, a 2000-task 1999-link chain (accepted, about 1.2 s) and the same chain closed into a ring (rejected), job total cap 10000 tasks | `caps:` | Caps enforced before the expensive steps; the cycle check peels edges and is linear per round |
| 15 | Lost update / races | Stale preview (`based_on`), missing `based_on`, millisecond tolerance, empty job with a non-empty `based_on`; advisory lock on the same key (`hashtext(job_id::text)`) that `prepare_schedule_export` will use | `stale:`, `append: the advisory lock ...` | OK. Two real sessions are not simulated (single session tests); see R3 (closed for replace by row locks) |
| 16 | Publish bypass | Imported rows inserted unpublished; a merge that renames a published row auto-unpublishes (through `job_visibility_guard`, with the audit row), dates/progress edits do not; the RPC never sets `client_visible = true` | `append: imported rows ...`, `merge: ...`, `real fNN: nothing is published` | OK |
| 17 | Real codec payloads | Output of `MspCodec.toPayload(MspCodec.parse(fixture))` for the 7 ProjectLibre fixtures, imported unchanged (plus the two wrapper fields); fixture 04 as an own-file merge round trip; a read-only-export file refused for merge | `real fNN:`, `roundtrip:` | Rows, links (type and lag), hierarchy, dates, progress, milestones, phases, baselines and warnings all equal the payload |

## Rulings (decisions the spec does not make)

See the final report of the leaf for the list; the ones that matter to a reviewer are:
company-scoped atoms instead of `user_has_perm`; baseline written only for approvers on a job without a locked baseline (or replace), following the
"Baseline on import" prose rather than the pseudo-code; `based_on` defined as the greatest `updated_at` over the job's tasks, phases and links (ms precision);
replace and merge uid policy; empty names become `(unnamed)`.

## Residual risk (not closed by this migration)

* R1 **The recovery copy in the audit row must not be trusted blindly** (corrected after the independent review). The first version of this note said a
  staff member could edit or delete the recovery copy; that was wrong: `d0c_audit` revokes UPDATE and DELETE on `job_audit_log` from the API roles, so a
  genuine `schedule_imported` row cannot be altered afterwards. The real risk is the opposite direction: INSERT is still allowed to a writer, so a writer can
  insert a FORGED `schedule_imported` row (any `job_id` of their company, any `metadata.recovery`). Anything that restores from `metadata.recovery` must
  therefore verify the row (it was written by the RPC: `user_id` is the importer and the row sits in the same transaction/time as the delete, `deleted`
  counts equal the recovery sizes, every recovered `id` is absent from the live tables, `job_id`/`company_id` inside the rows match the job) and show it to
  an approver before writing. Not closable inside this migration (the audit table belongs to D0c); a restore tool is not built yet.
* R2 **Deleting from job_tasks cascades or nulls other tables.** Replace runs `DELETE FROM job_tasks`; tables added later that reference `job_tasks(id)` (A2b `labour_entries.task_id` is `ON DELETE SET NULL`, future B/C tables) will lose or null their link. Re-check when those land.
* R3 **Concurrency.** The advisory lock serialises only code that takes the same lock; UI row saves go straight to PostgREST. The window this note used to
  describe for replace (an edit or insert between the stale check, the recovery copy and the DELETE) is now closed: replace takes `FOR UPDATE` row locks on the
  job's phases, tasks and links BEFORE the stale check, and the recovery copy is taken from `DELETE ... RETURNING`, so it is exactly the set of deleted rows.
  Proven with two real sessions by `supabase/tests/a2a_import/concurrency.sh` (CONCURRENCY OK) and two mutants of it (locks removed, tasks lock removed: MUTANT CAUGHT).
  Still open: append and merge take no row locks (they rely on the stale check, which a concurrent uncommitted edit can pass; the later UPDATE/INSERT then
  simply lands after it), and a row INSERTED by the UI after the locks are taken is deleted by replace and appears in the recovery copy but was never previewed.
* R4 **Temp tables.** The RPC creates `ON COMMIT DROP` temp tables with fixed names in `pg_temp`. They are dropped (if present) before use and always referenced as `pg_temp.x`; another role cannot read them. If the function is ever called with `statement_timeout` shorter than the job it will roll back cleanly.
* R5 **uid reuse.** The counter is `max(msp_uid) + 1` over the job (the spec's rule); replace keeps the old floor, but a UI delete of the newest row followed by an import can reuse its uid. A persistent counter would need a column or table.
* R6 **Other leaf's guards.** The `a2a_schema` leaf adds parent same-job/cycle/depth triggers. The RPC pre-checks the whole final graph and detaches changed parents before attaching, so it should never trip them, but the two migrations were tested separately; run the combined suite at integration.
* R7 **Resources/assignments** in the payload are ignored with a warning (A2b not built); the RPC must be revisited then.
* R8 **Heavy but legitimate use.** A writer can import a 2000-task file repeatedly (about 1.2 s each); there is no rate limit.
* R9 **service_role** keeps EXECUTE (Supabase default); it has no `auth.uid()` so the RPC answers `job not found`.
* R10 **Permission overrides** (if the live `user_has_perm` ever honours per-user overrides) are not honoured by the company-scoped check, which reads role permissions only (same as `d0d_actor_has_atom`).

## Review findings (independent attack review) and what covers them

Each was proven by the reviewer in a throwaway Postgres; each now has a test written first (it failed on the previous migration) and mutants.
Test labels are the `NOTICE: PASS <label>` prefixes; the family is the directory under `supabase/tests/`.

| ID | Finding | Fix | Covering tests (family: label prefix) | Mutants |
|---|---|---|---|---|
| H1 HIGH | Cross-company planting: the Phase A policies on job_phases / job_tasks / job_task_links check only `company_id`, so a writer of C2 could insert rows with the job_id of a C1 job; import and export trust rows by job_id (leak through merge, planted uid 100000000 blocks append/replace, planted `updated_at` 2099 fails the stale check forever) | (1) a2a_schema: BEFORE INSERT OR UPDATE OF job_id, company_id trigger `job_schedule_company_guard` on the three tables, SQLSTATE A2C01, SECURITY DEFINER so it works under any RLS on `jobs`; (2) import: refuses a schedule that already holds rows of another company ('schedule contains rows of another company', A2C01) and scopes every stored-row predicate to the job's company; (3) export: same scoping | a2a_schema: `h1:` (through the real policies as authenticated writers: all three tables, update path, nonexistent job, RLS hiding jobs); a2a_import: `h1:` (API path blocked; foreign phase/task/link planted as owner with triggers off: append, replace, merge refused, nothing written, clean-up then works); a2a_export: `h1:` | a2a_schema `h1:`, a2a_import `h1:`, a2a_export `h1:` |
| M2 MED | Cycle check re-scanned every stored link: a one-task append on a 10k-task chain took 10.4 s (Supabase timeout 8 s) | Stored links were already checked one by one by `job_task_links_no_cycle`, so a cycle must pass through an edge that is NEW in the file. No new edges: no scan. Otherwise only the part reachable from the new edges' predecessors is loaded and peeled with a worklist (stored links are loaded only for merge) | a2a_import: `m2:` (9000-task stored chain: one-task append < 2 s, measured 0.2 s; 3000-chain: cycle through stored links rejected before any write, short back edge rejected, acyclic link onto the chain tail accepted, own file with only stored links changes nothing) | a2a_import `m2:` |
| M3 MED | A writer could UPDATE msp_uid to 2147483647, blocking every import ('uid space exhausted') and overflowing the export's `max + rn` | CHECK `msp_uid > 0 AND msp_uid <= 100000000` as named NOT VALID constraints (idempotent; the old unnamed check is dropped); export and import ignore stored uids above the cap and refuse ('uid space exhausted') instead of crossing it | a2a_schema: `m3:`; a2a_export: `m3:`; a2a_import: `m3:` | each family `m3:` |
| L4 LOW | A merge that changed a published task's phase made it client-visible without approve or audit (task published inside an unpublished phase, phase_uid dropped) | The merge UPDATE sets `client_visible = false` when `phase_id` changes; the existing visibility guard writes the audit row | a2a_import: `l4:` (moved into an unpublished phase, moved out of any phase, the exact finding, unchanged phase stays published, audit rows, re-merge is a no-op) | a2a_import `l4:` |
| L5 LOW | Recovery copy kept ids and names only; no lock between copy and delete; a replaced locked baseline was logged like a first lock | Recovery = `to_jsonb(row)` of exactly the rows deleted (`DELETE ... RETURNING`, bounded by the 10k cap); row locks first (see R3); replace over a locked baseline is audited as `baseline_reset` (the name `lock_job_baseline` uses for every re-lock), a first lock stays `baseline_locked` | a2a_import: `l5:`, `replace: recovery`, `replace: first import locked ...`; two sessions: `concurrency.sh` | a2a_import `l5:`; lock mutants in concurrency.sh |
| L6 LOW | The name cleaner let through U+061C, U+3164, U+115F, U+1160, U+180E, U+FFA0, U+FFF9..FFFB and the tag range U+E0000..E007F | Added to the stripped class (also U+206A..206F, the rest of the invisible formatting block) | a2a_import: `l6:` (each stripped, neighbours and real text kept: accented, CJK, Hangul, Arabic, Cyrillic, emoji) | a2a_import `l6:` / `cleaner class` |
| L7 | This file: R1 was wrong, R3 window now closed | see R1 and R3 above | | |

### Unresolved or by decision (nothing above is deferred except these)

* **Composite FK alternative for H1** (`(job_id, company_id) REFERENCES jobs(id, company_id)`) was not chosen: it needs a unique constraint on `jobs` and rewrites three
  live tables' constraints; the trigger is additive. Cost if wrong: none for correctness; the trigger costs one `jobs` primary-key lookup per written row.
* **The company scoping added to the import's stored-row predicates is defence in depth** and cannot be tested on its own while the schedule-level refusal and the trigger
  exist (a row of another company can never reach those predicates). The refusal itself has a mutant per table; the scoping has none (it would be an equivalent mutant).
* **L4 covers `phase_id` only.** The visibility predicate X22 (`job_task_client_visible`) depends on the task's phase, not on its parent, so a parent change alone
  cannot make a task visible and a merge that only re-parents a published task leaves it published. If the client ever sees hierarchy, revisit.
* **Merge cost on a very deep stored chain** is about 0.13 to 0.3 ms per level between a new edge and the end of the chain it points at (3000 levels: 0.4 s; 9000 levels: about 3 s), both
  for the reachability walk and, only when a new edge's task is itself reachable, for the peel. A one-task append or an own-file merge with no new link costs nothing.
* **The recovery copy is large** (full rows; up to 10000 tasks is several MB in one audit row). Acceptable for an event this rare and approver-only; an archive table
  would be the next step together with the restore tool of R1.
* **The msp_uid range constraints are NOT VALID** (existing rows are not checked, so the migration cannot fail on prod). Pre-check queries are in the migration headers.
* R2, R4, R5 to R10 above are unchanged.
