# Phase A — Addendum A2: ProjectLibre / MS Project compatibility and the schedule window

*Status: draft for owner review · 2026-10-21 (N1-N11 resolutions and A2a/A2b/A2c split proposed 2026-10-26, pending approval) · additive to the Phase A migration `phase_a_schedule_v2` that is **live on prod** (Session 66). Depends on `00-overview.md` (decisions D1-D5, X1-X23 apply unchanged) and `phase-a-schedule-v2.md`. All SQL here is **desk-checked only**: nothing has been executed against any database, and the ProjectLibre fixtures now exist (PR #172) but the codec has not been built against them (see Risks, R1).*

**What this addendum owns:** the MS Project XML (MSPDI) import/export contract, the extra link types and per-link lag editing the format needs, stable identifiers for lossless round trips, the atomic import RPC, and the dedicated full-screen schedule window. It changes Phase A objects (`job_task_links`, `job_tasks`, `job_phases`, the shared progress/status rule) only additively and says exactly which Phase A rules it amends (section "Amendments to Phase A and the X-rules").

## Owner decisions (2026-10-21)

The owner answered the open questions O1-O8 on 2026-10-21. **Four answers widen the scope of A2** (O1, O2, O5, O6). Text elsewhere in this addendum marked *Superseded* still describes the pre-decision design and is rewritten at the next revision; until then **this section wins**. Nothing here changes the database: Phase A is live, A2 remains a draft, and all SQL stays desk-checked.

| # | Decision | Change vs the draft default |
|---|---|---|
| O1 | **Real task hierarchy now.** Imported outlines keep their depth; no flattening. | Changed. Needs the X1 amendment: summary tasks (rows with children) carry weight 0. |
| O2 | **Resources are built into A2**, not deferred to a Phase R. As the Work Order's job-card sections (labour, equipment, materials, consumables, sub-contractors) are filled during execution, the matching resource fields on the schedule are **auto-populated**. | Changed. |
| O3 | Copy-and-verify codec for the portal. | Default stands. |
| O4 | Codec in its own `schedule-msp.js`; window code inline in `index.html`. | Default stands. |
| O5 | **Undo/redo is built** in the schedule window. | Changed. |
| O6 | **Clients see baseline dates (ghost bars)**, in the portal and in the downloaded file, for transparency. Access is conditional on the client accepting a **release / user agreement** that restricts use of the information in legal proceedings. **Ownership of the schedule and its data stays with Q2 Machines.** | Changed. Phase D's `portal_schedule` already returns baseline columns, so the portal side is consistent; this reverses A2's "no baseline in client files". The agreement gate is new (see the Phase D amendment). |
| O7 | Imported tasks get `weight = NULL`. | Default stands. |
| O8 | Add notes to the B and C specs now (`task_id` link); build later. | Default stands. |

### What this changes

1. **Hierarchy (O1).** The two-level phase/task model (X1) becomes a tree. Compute (`jcSchedCompute`), the SQL `job_schedule_status`, the Gantt layout, the task table and the codec all change. FS-only flat jobs must still produce identical results, so the 45-case shared fixture must pass unmodified and gains hierarchy cases.
2. **Resources (O2).** MSPDI `Resource` and `Assignment` elements enter the codec and the field-mapping table; the Out of scope entry on resources is withdrawn. Planned resources are entered on the schedule; actuals flow in from the job card.
3. **Undo/redo (O5).** Edits in the window are undoable and redoable. Today each edit is an immediate database write, so undo means writing the inverse (see N7).
4. **Client disclosure (O6).** The client file includes Baseline 0 for client-visible tasks. The release agreement is a hard gate in Phase D: no schedule data reaches a client until they have accepted the current agreement version.
5. **Scale.** O1, O2 and O5 together are much larger than the draft. Recommendation (not a decision): split into **A2a** (link types, hierarchy, codec, window), **A2b** (resources and job-card auto-fill) and **A2c** (undo/redo), so each can be tested and applied on its own.

### Resolutions of N1-N11 (proposed 2026-10-26; **pending owner approval**)

These are recommendations, written so the engine can start once the owner approves them. Where a resolution contradicts text further down this addendum, **this section wins** until the next revision.

- **N1. Hierarchy model.** **Keep `job_phases` as level 1 and add `job_tasks.parent_task_id`** (nullable self-FK, same-job check, cycle guard, depth cap 6 counting the phase as level 1). A phase maps to MSPDI outline level 1; tasks nest below it. A **summary** is a task that has children (derived, never stored). Links may target summaries, but progress, weighting and critical-path maths use leaf rows only; summary dates are the min start and max end of descendants, and summary % is the weighted average of descendant leaves (X1 amendment). Reason: folding phases into the tree would rewrite live Phase A tables, the publish toggles and the X22 predicate.
- **N2. Existing data.** Every new column is nullable with no backfill, so existing rows stay valid as direct children of their phase and results are unchanged. Gate: the 45-case shared fixture passes unmodified, and gains hierarchy cases.
- **N3. Resource model.** **Two new tables:** `job_resources` (kind: person, equipment or subcontractor; nullable FK to `employees` or `config_equipment`; `msp_uid`) and `job_task_assignments` (task, resource, planned units). **Materials, consumables, hardware and tooling are not schedule resources**: they stay on the job card (see the material finding below). No rate or cost is stored in A2; rates stay internal and never reach the portal (X10, Phase D `rate`/`cost` guard). Only people and equipment have time-based actuals (see N4); a subcontractor entry holds a name and a cost, so a subcontractor resource has planned units but **no actuals in A2**.
- **N4. Job-card to schedule mapping.** **A nullable `task_id` (FK to `job_tasks`, `ON DELETE SET NULL`) on `labour_entries` and `equipment_entries`** (the only entries that feed resource actuals), chosen from a dropdown on the job card (the same anchor as O8 and X28). Entries with no task roll up to the job and show as "Unassigned actuals"; nothing is matched by name or category. *Checked 2026-10-26 against `migrations/job_cards_schema.sql` and `jcSaveJobData` in `index.html`; three facts shape this:* (1) **There are seven entry tables**, not five: `labour_entries`, `equipment_entries`, `material_entries`, `consumable_entries`, `hardware_entries`, `tooling_entries`, `subcontractor_entries`. Only labour (`hours`, `technician`, `entry_date`) and equipment (`setup_hours`, `run_hours`, `machine_name`, `asset_no`) carry time, so only those two feed resource actuals; the others carry quantity and cost and are not schedule resources. (2) **The job-card save deletes every entry row for the job and re-inserts them with new ids** (`sbDeleteWhere` on all seven tables, then `sbPost`). Entry ids are therefore not stable, so `task_id` must be a field of the job-card row model (for example `taskId`) written back on every save and re-read on load; it cannot be set by a separate update that the next save would erase. Adding it is a change to `jcSaveJobData`, `jcOpenJob` and the entry row editors, not just a migration. (3) `labour_entries.tasks` and `equipment_entries.tasks` already exist as `jsonb` lists of **catalogue task names** from `config_tasks` (what the technician did). That is a different concept from a schedule task; do not reuse or overload it. Technician and machine are free text (`technician`, `machine_name`, `asset_no`), not FKs, so N6-style matching to `employees` and `config_equipment` is by exact name and unmatched names show as unlinked.
- **N5. Auto-fill semantics.** Auto-fill produces **actuals only**, from `labour_entries.hours` and `equipment_entries.setup_hours + run_hours` grouped by `task_id` and resource; planned units stay as entered and task progress is never changed by it (X30). Actuals are computed from the entries, not stored on the schedule, so a job-card edit (including the delete-and-reinsert save) simply changes the figure. Rate and amount columns are never read. A manual override, if allowed at all, sits beside the computed value and is flagged.
- **N6. Resource round trip.** Match an imported resource on `msp_uid` (files exported from this job), then on exact name against `employees` and `config_equipment`. An unmatched resource becomes a **schedule-only resource** (no FK) with a preview warning. Import never creates employees or equipment. Skip resource UID 0 and the placeholder UID -65535 (confirmed in the fixtures).
- **N7. Undo/redo scope.** Per tab and per session, in memory, depth 50. Each edit records its inverse and replays it through the existing write path. The stack is cleared on import, on baseline lock and on a stale-`updated_at` conflict. Publishing, baseline locking and import are **not undoable** (they are audited, and import is atomic). Auto-filled values are not edits and are not on the stack.
- **N8. Release agreement.** The spec fixes the mechanism only; the wording is for the owner's lawyer. Mechanism: a versioned `agreement_versions` record and a per-client-user acceptance record; **every client user must accept** (an approver's acceptance does not cover colleagues); a new version requires re-acceptance; a client who has not accepted sees the schedule locked, with no schedule data (X29). Whether a restriction on use in legal proceedings is enforceable in the owner's jurisdiction is for the lawyer.
- **N9. Notice in the exported file.** Yes. Write an ownership and confidentiality notice into the project notes and the first task's note, and write an audit row for every client export with the agreement version.
- **N10. Resource names to clients.** No. Client files carry no assignee or resource names, per X10 and the draft default.
- **N11. Effort and order.** Split confirmed as below. The ProjectLibre fixtures now exist (PR #172), so the A2a precondition is met.

### Proposed split

| Part | Scope | Depends on | Gate |
|---|---|---|---|
| **A2a** | `link_type` (FS/SS/FF/SF), `msp_uid`, `parent_task_id` and hierarchy; compute changes in `jcSchedCompute` and `job_schedule_status`; `schedule-msp.js`; `prepare_schedule_export` and `import_job_schedule`; the `#/schedule/<job_id>` window with import and export. | Fixtures (done). | 45-case fixture unmodified plus new link-type and hierarchy cases; codec tests on fixtures 01-07; migration on throwaway Postgres; manual ProjectLibre interop. |
| **A2b** | `job_resources`, `job_task_assignments`, `task_id` on labour and equipment entries (and the `jcSaveJobData` / `jcOpenJob` / row-editor changes it needs), actuals roll-up, MSPDI Resource and Assignment mapping. | A2a (UIDs, window). | Throwaway-Postgres suite; fixture 05 round trip; a test proving no rate or resource name reaches a client file. |
| **A2c** | Undo/redo in the schedule window. | A2a. Independent of A2b. | UI tests: inverse replay, stack clearing, non-undoable actions. |

The client baseline and the agreement gate (O6, N8-N10) land in Phase D; A2a only needs the export notice (N9). Each part is applied to prod on its own, one step at a time, with simulated-identity verification.

### Fixture findings that change the codec (2026-10-21, PR #172)

The ProjectLibre fixtures under `scripts/tests/schedule/mspdi/` (the README there lists expected values) settle part of risk R1. Rules the codec must follow:

- Link type codes: 0 = FF, 1 = FS, 2 = SF, 3 = SS (matches the mapping table). `LinkLag` is in tenths of a minute (9600 = 2 working days at 8 h/day).
- Durations are working **hours** (`PT8H0M0S` = 1 day on the 8-hour calendar), never days. Convert with the file's calendar.
- Hierarchy comes from `OutlineLevel` only; `Summary=1` marks summaries. **Never trust `WBS`** (fixture 04 has a stray value).
- Skip resource UID 0 and the placeholder resource UID -65535 (written for unassigned tasks).
- **Material resources are not exported correctly by ProjectLibre** (written as Work, and a junk work value of 24 million hours was seen). Warn on a resource that looks like a material and never trust a quantity from such a row. The material round trip is **unverified** against a real tool (fixture 07 is synthetic).
- **Stored finish dates can be stale across calendar exceptions** (fixture 06). This conflicts with "Start and Finish are authoritative" in "Calendar and duration mapping": for a file whose calendar is not a 7-day week, recompute the finish from the file's calendar and warn. Files on the 7-day calendar keep the rule as written.
- ProjectLibre's default save is the native `.pod` (Java serialization); a renamed `.pod` is not XML. Reject any file that does not start with `<?xml`.

### Rules to add to the cross-phase list when this is accepted

- **X1 amendment:** summary tasks (rows with children) are excluded from weighting, like milestones.
- **X29 (proposed): client schedule disclosure requires an accepted agreement.** Every portal schedule read and every client export checks that the caller has accepted the current agreement version; each acceptance and each export is audited.
- **X30 (proposed): job-card actuals are the source for resource actuals** on the schedule; the schedule never writes back to job-card entries.

---

## Goal and scope

Make the per-job schedule interoperable with ProjectLibre and MS Project, and give it room to grow into a project-scheduling tool. Four outcomes:

1. **Export** a job's schedule as an MS Project XML file (`.xml`, the MSPDI schema) that ProjectLibre and MS Project open, for staff (everything the staff user can see) and, through Phase D, for clients (client-visible rows only).
2. **Import** an MSPDI file into a job: parse in the browser, show a dry-run preview (counts, warnings, per-row actions), then commit through one atomic server function. Modes: **append**, **merge** (match by stored UID, only for files that came from this job) and **replace** (approver only, reason required).
3. **Round-trip fidelity** for the fields Meridian models: names, outline (phase to task), dates, % complete, milestones, predecessors with link type and lag, the single `assignee` as a resource name, and baseline dates. Everything Meridian does not model is dropped with a visible warning, never silently.
4. **A dedicated schedule window**: a full-screen route `#/schedule/<job_id>` opened from the Work Order's Schedule card, laid out like a project-planning tool (toolbar, task table left, Gantt right, details pane below). The existing card stays as a summary with an **Open schedule** button.

The task stays the single anchor for later work (resources, QC hold points, documents): this addendum keeps `job_tasks.id` as the one stable identity and adds no parallel task model.

## Out of scope

- **Resources and utilisation** (a `resources` entity, assignments with units, cost rates, over-allocation, leveling). A2 only round-trips the free-text `assignee` as a resource *name*. Planned as its own phase ("Phase R"); it should reuse `employees` and `config_equipment` rather than invent people and plant again. **Superseded 2026-10-21 (O2): resources are now in scope; see Owner decisions.**
- **Working calendars** (working days, holidays, shift hours). Meridian schedules in calendar days. A2 exports a 7-day calendar so durations line up (see "Calendar and duration mapping"); real calendars are a later phase.
- **Scheduling constraints** (Must Start On, Finish No Later Than, deadlines) and **manual vs auto-scheduling**. Import ignores them with a warning; export uses the one constraint in "Date pinning".
- **Arbitrary outline depth.** Meridian has two levels, phase then task. Deeper MSPDI levels are flattened on import with a warning (decision O1). Real sub-tasks need an amendment to X1 (summary tasks must carry weight 0) and are deferred. **Superseded 2026-10-21 (O1): real hierarchy is now in scope; see Owner decisions.**
- **`.mpp`, `.pod` and any binary format.** MSPDI XML only. `.pod` is ProjectLibre's native container and `.mpp` is Microsoft's binary format; both are poor targets for a browser app.
- **Task notes, custom fields, cost, work (hours) and overtime, multiple baselines (only Baseline 0), cross-project links, subprojects.**
- **Drag-to-edit on the Gantt bars.** Still read-only (as Phase A); editing stays in the table and details pane. A follow-up can add it.
- **Real-time multi-user editing.** A2 adds conflict detection (stale `updated_at`), not live merging.
- **Copying ProjectLibre source.** Its licence (CPAL) allows reimplementing behaviour; this is a clean-room build against the public MSPDI schema.

## Data model

All changes are additive and reversible. Migration file `supabase/migrations/<timestamp>_a2_projectlibre.sql` (timestamp is a placeholder; order after the Phase A migration; independent of B and C, but C's and D's use of the schedule functions must be re-checked, see "Amendments"). No new table is created, so no reserved table name changes.

Design decisions embedded in the SQL below:

- **`job_task_links.link_type`** carries FS, SS, FF, SF (the four MSPDI types). `lag_days` already exists (range -30 to 365) and is reused. Default `'FS'` keeps every existing row valid.
- **`msp_uid`** is a positive integer stored on `job_phases` and `job_tasks`. MSPDI has **one** UID space for the whole Tasks list (summary tasks and leaf tasks together), so a UID must be unique across both tables **within a job**. Meridian rows get a UID the first time they are exported by a writer (`prepare_schedule_export`); it never changes afterwards. UID 0 is reserved by MSPDI for the project summary task and is never assigned.
- **The project identity in the file** is `jobs.id` (written as the Project `<UID>`), so an import can tell "this file was exported from this job" (merge allowed) from "foreign file" (append or replace only). A merge never matches a UID from a foreign file, because UID 7 in another project means nothing here.
- **Import is one transaction in a SECURITY DEFINER RPC**, `import_job_schedule`, owned by the same role as `lock_job_baseline` (required: the baseline guard only lets baseline columns change when `current_user` is that owner and `app.baseline_rpc = 'on'`). The browser parses and previews; the server **re-validates every field** and never trusts the parsed payload.
- **No column for scheduling constraints, notes or calendars** (out of scope). Export uses Start No Earlier Than as a pin; import ignores that pin when it equals the task's own start date.

```sql
-- ===== up =====
ALTER TABLE job_task_links
  ADD COLUMN link_type text NOT NULL DEFAULT 'FS'
    CHECK (link_type IN ('FS', 'SS', 'FF', 'SF'));

ALTER TABLE job_phases
  ADD COLUMN msp_uid integer CHECK (msp_uid IS NULL OR msp_uid > 0);
ALTER TABLE job_tasks
  ADD COLUMN msp_uid integer CHECK (msp_uid IS NULL OR msp_uid > 0);
CREATE UNIQUE INDEX job_phases_msp_uid_uq ON job_phases (job_id, msp_uid) WHERE msp_uid IS NOT NULL;
CREATE UNIQUE INDEX job_tasks_msp_uid_uq  ON job_tasks  (job_id, msp_uid) WHERE msp_uid IS NOT NULL;
-- Cross-table uniqueness (a phase and a task of one job never share a UID) is enforced inside
-- prepare_schedule_export / import_job_schedule under pg_advisory_xact_lock(hashtext(job_id::text)); the two partial
-- indexes above stop duplicates within each table even if a caller bypasses the RPCs.

-- Hierarchy needs nothing new: phase = MSPDI outline level 1 summary task, task = level 2 (phase_id may be NULL = "Unphased").

-- Stable-UID assignment + export audit. SECURITY DEFINER because it writes job_audit_log; authorization re-checked inside.
-- p_kind: 'staff' (needs ops:work-orders:read on the job's company) or 'client' (called only by Phase D's definer
-- path; refused to authenticated callers, see RLS and permissions). Rows with msp_uid IS NULL get max(uid)+1 in
-- (sort_order, id) order, phases first, ONLY when the caller also holds ops:work-orders:write (a read-only caller
-- exports with temporary UIDs, see "Round-trip identity"). Returns the number of UIDs newly assigned.
CREATE OR REPLACE FUNCTION prepare_schedule_export(p_job_id uuid, p_kind text DEFAULT 'staff')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- pseudo-code: membership + permission check; advisory lock; assign UIDs if writer;
  -- INSERT job_audit_log (action_type 'schedule_exported', metadata {kind, tasks, phases, assigned}); RETURN assigned
END $$;
REVOKE ALL ON FUNCTION prepare_schedule_export(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION prepare_schedule_export(uuid, text) TO authenticated;

-- Atomic import. SECURITY DEFINER, same owner as lock_job_baseline. See "Import RPC contract" for the payload and rules.
CREATE OR REPLACE FUNCTION import_job_schedule(p_job_id uuid, p_mode text, p_payload jsonb, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- pseudo-code in "Import RPC contract"
END $$;
REVOKE ALL ON FUNCTION import_job_schedule(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION import_job_schedule(uuid, text, jsonb, text) TO authenticated;

-- ===== down (note) =====
-- DROP FUNCTION import_job_schedule(uuid,text,jsonb,text); DROP FUNCTION prepare_schedule_export(uuid,text);
-- DROP INDEX job_tasks_msp_uid_uq, job_phases_msp_uid_uq; ALTER TABLE job_tasks DROP COLUMN msp_uid;
-- ALTER TABLE job_phases DROP COLUMN msp_uid; ALTER TABLE job_task_links DROP COLUMN link_type;
-- (dropping link_type loses SS/FF/SF information: take a copy of job_task_links first if any non-FS link exists.)
```

### Link-type semantics (amends the Phase A compute rule)

Meridian counts days inclusively: duration = `end - start + 1`. With predecessor P (start `Ps`, end `Pe`), successor S (start `Ss`, end `Se`) and `lag` in days (negative = lead), the earliest dates the successor may take are:

```
FS: Ss >= Pe + 1 + lag
SS: Ss >= Ps + lag
FF: Se >= Pe + lag          (so Ss >= Pe + lag - dur(S) + 1)
SF: Se >= Ps + lag          (so Ss >= Ps + lag - dur(S) + 1)
```

The forward pass takes the maximum over all predecessors; the backward pass (latest dates, slack, critical path) uses the mirrored inequalities. `jcSchedCompute` (JS) and `job_schedule_status` (SQL) must implement exactly this, and the shared fixture (`scripts/tests/schedule/fixture.json`) gains cases for each type, for negative lag, for mixed types into one successor and for a cycle through a non-FS link. `job_tasks.depends_on` keeps mirroring the first **FS** predecessor only (NULL if the first predecessor is not FS), so the portfolio Gantt arrows stay valid; they simply omit non-FS links.

### Calendar and duration mapping

Meridian has no working calendar; MSPDI durations are working time. The mapping that keeps dates stable:

- **Export** writes one base calendar (`Meridian 7-day week`) in which all seven days are working, 8 working hours per day, and sets the project's `MinutesPerDay` 480, `MinutesPerWeek` 3360, `DaysPerMonth` 30. A task of N calendar days is then exactly `N x 8h` of duration, so ProjectLibre shows the same dates. Lag is exported as `lag_days x 4800` (tenths of a minute: 480 min x 10 per day).
- **Import** treats the file's **Start and Finish dates as authoritative** and derives `start_date`/`end_date` from them (date part only; time-of-day is dropped). It does **not** recompute dates from `Duration`. Link lag is converted with the file's own `MinutesPerDay` (minutes of lag divided by that, rounded to a whole day); if the file's calendar is not a 7-day week the import warns that lag was converted at working-day length and may differ from the file's calendar dates.
- Meridian's own duration-in-days stays `end - start + 1`.

### Date pinning (preventing silent re-scheduling in ProjectLibre)

An auto-scheduled task with predecessors is moved by ProjectLibre/MS Project to the earliest legal date, which would pull a deliberately later Meridian task forward on open. Export therefore writes **Start No Earlier Than = the task's `start_date`** (ConstraintType 4) on every dated, non-summary task. A predecessor that finishes later still pushes the task later, like real life; nothing is pulled earlier than the planned date. On import, a Start No Earlier Than constraint whose date equals the task's start is **ignored silently** (it is our own pin); any other constraint type or date is ignored with a counted warning.

### MSPDI field mapping

Meridian to MSPDI on export; the reverse on import. "Drop" means not exported or not imported, with a warning on import.

| Meridian | MSPDI element | Notes |
|---|---|---|
| `jobs.id` | `Project/UID` | identity check for merge |
| `jobs.job_no` + `jobs.description` (first 80 chars) | `Project/Name`, `Project/Title` | |
| min task start | `Project/StartDate` | |
| phase (`job_phases`) | `Task` with `Summary=1`, `OutlineLevel=1` | dates = min/max of its tasks, % = weighted average, milestones excluded (X1) |
| task (`job_tasks`) | `Task` with `Summary=0`, `OutlineLevel=2` (1 when unphased) | |
| `msp_uid` | `Task/UID` | `ID` = row order; `WBS` and `OutlineNumber` generated (`1`, `1.1`, `1.2`, `2`...) |
| `task_name` / phase `name` | `Task/Name` | XML-escaped, control characters stripped, max 255 |
| `start_date`, `end_date` | `Start` at 08:00, `Finish` at 17:00 | date part only on import |
| duration | `Duration` as `PT{8 x days}H0M0S` | milestone `PT0H0M0S` |
| `progress` | `PercentComplete`, `PercentWorkComplete` | integer 0-100 |
| `is_milestone` | `Milestone=1` | `Start = Finish` |
| `is_critical` | `Critical` | informational on export; ignored on import (recomputed) |
| `assignee` | `Resource` (`Type=1`, `Name`) + `Assignment` (`Units=1`) | one resource per distinct name; on import several assigned resources are joined with ", " (max 120 chars) |
| `job_task_links` | `PredecessorLink` (`PredecessorUID`, `Type`, `LinkLag`, `LagFormat=7`) | `Type`: FF=0, FS=1, SF=2, SS=3 |
| `baseline_start`, `baseline_end` | `Baseline` (`Number=0`, `Start`, `Finish`) | exported only if locked; see "Baseline on import" |
| `weight`, `client_visible`, `sort_order`, ids | drop | `sort_order` follows file order on import; `weight` stays NULL on imported rows |
| file-only: Notes, Cost, Work, Priority, Deadline, calendars, other constraints, resource rates | drop with warning | counted per category |

Rules the codec follows (all asserted in the test plan):

- **Namespace** `http://schemas.microsoft.com/project`; `SaveVersion` 12 (Project 2007 level). Files that fail to parse, or whose root is not `Project`, are rejected.
- **UID 0** (the project summary task MS Project writes) and any `IsNull=1` task are skipped. MS Project emits a `PredecessorLink` per predecessor inside the successor's `Task`.
- **Security of parsing:** reject any file containing a DOCTYPE or ENTITY declaration (no external entities, no entity expansion); cap size (5 MB) and counts (2000 tasks, 5000 links); parse with `DOMParser`; read text through `textContent` only; never `innerHTML` (the escape rule in `00-overview.md` section 3 applies to every imported string).
- **Dates:** only `YYYY-MM-DD` after parsing; year range 2000-2100; `end >= start` else the row is skipped with a warning.
- **Names:** trimmed, empty names skipped, control characters removed, 255 character cap, surfaced to the user only via `textContent`.

### Round-trip identity

Exports from a writer carry stored UIDs, and `Project/UID` = `jobs.id`. A read-only user (no `ops:work-orders:write`) can still export, but `prepare_schedule_export` cannot assign UIDs for them, so their file uses **temporary** UIDs offset by 1 000 000 and a `Project/Manager` marker `meridian-readonly-export`. Import treats a temporary-UID file as foreign (append/replace only). Stable UIDs are therefore only ever created by a writer.

### Import RPC contract

Browser parse output (the payload) is plain JSON; the server re-validates all of it.

```json
{
  "format": "mspdi", "version": 1,
  "project_uid": "<uuid or null>", "file_name": "...", "temporary_uids": false,
  "phases": [ { "uid": 1, "name": "Assess", "sort": 0 } ],
  "tasks":  [ { "uid": 2, "phase_uid": 1, "name": "Survey", "start": "2026-11-02", "end": "2026-11-06",
                "progress": 40, "milestone": false, "assignee": "A. Ramdhan",
                "baseline_start": "2026-11-02", "baseline_end": "2026-11-06", "sort": 0 } ],
  "links":  [ { "task_uid": 3, "pred_uid": 2, "type": "FS", "lag_days": 0 } ],
  "warnings": [ { "code": "constraint_ignored", "count": 4 } ]
}
```

Server rules (pseudo-code):

```
require membership of the job's company (my_company_ids()) and ops:work-orders:write
mode in ('append','merge','replace'); replace and any baseline write also require ops:work-orders:approve
replace requires a non-empty p_reason (same rule as re-baseline)
merge requires payload.project_uid = p_job_id and not temporary_uids, else raise (the UI downgrades to append)
validate size/count caps; every date/number/length/enum; uid uniqueness inside the payload; link endpoints exist; no cycle
  (the cycle trigger still runs per link; the RPC pre-checks the whole graph so a bad file fails before any write)
pg_advisory_xact_lock(hashtext(p_job_id::text)); stale check: payload carries the job's max(updated_at) it was previewed
  against; if rows changed since, raise 'schedule changed since preview' (client re-previews)
append:  insert phases (new msp_uid from the counter) and tasks and links; existing rows untouched
merge:   rows with matching msp_uid are UPDATED (name, dates, progress, milestone, assignee; phase move allowed);
         file rows with no match are INSERTED; Meridian rows absent from the file are KEPT (never deleted in merge)
replace: DELETE all job_tasks / job_phases / job_task_links for the job, then insert; the old schedule is first copied
         into job_audit_log.metadata (count + a compact JSON of ids and names) so it can be recovered by hand
inserted rows: client_visible = false always; an update to a visible row that changes wording auto-unpublishes through
  job_visibility_guard (the RPC is not exempt: session_user is the API role)
baseline: only if approve held AND payload has baselines for >= 1 task AND (mode is not merge OR no baseline is locked
  yet); sets app.baseline_rpc = 'on' around the baseline write, then 'off'; otherwise baseline fields are ignored with a warning
progress/dates of 'done' tasks are taken as given (no recompute); is_critical is cleared and recomputed by the next UI save
INSERT job_audit_log (action_type 'schedule_imported', metadata {mode, file_name, created, updated, kept, skipped, warnings, reason})
return jsonb {created, updated, kept, skipped, warnings:[...]}
```

### Baseline on import

A baseline is a signed-off planning record (Phase A locks it behind `ops:work-orders:approve` and a reason). Importing one is therefore treated as a baseline lock: allowed only for an approver, only when the job has no locked baseline yet (or in replace mode), and recorded in the audit log as `baseline_locked` with the import's file name. A non-approver's file still imports; its baseline elements are dropped with a warning.

## RLS and permissions

No new table, so no new policies. Existing Phase A policies and D0c/D0d hardening remain the authorization for direct table access.

| Action | Gate | Where enforced |
|---|---|---|
| Open the schedule window, export (staff) | `ops:work-orders:read` + company membership | `prepare_schedule_export`; RLS on the reads |
| Import: append, merge | `ops:work-orders:write` | `import_job_schedule` (re-checked server-side) |
| Import: replace, or write a baseline | `ops:work-orders:approve` (+ reason for replace) | `import_job_schedule` |
| Edit link type and lag | `ops:work-orders:write` | existing `job_task_links` write policy |
| Client download | Phase D `portal_*` path only | `prepare_schedule_export(..., 'client')` refused to `authenticated`; Phase D's definer calls it |

- No new permission atoms are introduced (X11: nothing to seed). The existing atoms already separate prepare (write) from approve.
- Both new functions follow X13: fixed `search_path`, `REVOKE ALL ... FROM PUBLIC, anon`, authorization inside, and the Q-D definer sweep is re-run after the migration. `import_job_schedule` must be owned by the role that owns `lock_job_baseline` (see Data model) and the owner check in the baseline guard must be re-verified on the throwaway Postgres.
- `import_job_schedule` is the only new definer path that writes tasks; because it deletes in replace mode, it is also the highest-risk function in A2 and gets the independent attack review that D0d received.
- Imported text never reaches the DOM except through `textContent`; the server still length-limits and strips control characters because the browser parse is untrusted input.

## Staff UI (ERP)

### Entry point

The Work Order's "Schedule & Tasks" card keeps its KPI strip and baseline caption and gains an **Open schedule** button (opens `#/schedule/<job_id>` in a **new browser tab**, so it can sit on a second monitor). The inline table and Gantt in the card stay for now (the card remains the quick view); the window is the full tool. If the card and window disagree on a field, the database wins and both reload on save.

### Route and delivery

- **Route:** `#/schedule/<job_id>`, restored by `_restoreViewFromHash()` (the hash router from PR #137). It is a new full-screen view (`view-schedule`) without a sidebar entry; the sidebar and topbar are hidden in the window (the company switcher is replaced by the job header).
- **Single login across tabs.** The new tab reads the session from `localStorage` like any reload. Before building, verify that two tabs refreshing the access token at the same moment cannot invalidate each other's refresh token (`tryRestoreSession()` and the refresh path), and add a cross-tab guard (BroadcastChannel or `storage` event) if they can (risk R3).
- **Code layout.** The repo's convention is one inline `index.html`. A2 proposes one additional flat file loaded only on this route and cache-busted with a version query string: `schedule-msp.js` (pure MSPDI codec: parse, build, validate; no DOM or Supabase). `jcSchedCompute` and the Gantt layout/draw functions stay where they are in `index.html` and are **reused, not copied**; the window calls them. This keeps one implementation of the progress/status rule (X1/X20). Open question O4 covers whether to keep everything inline instead.
- The existing test harness extracts blocks from `index.html`; the new codec lives in its own file and is tested directly with `node --test`, plus a mutation run as for the Gantt and KPI blocks.

### Layout (wireframe level)

```
+------------------------------------------------------------------------------------------------+
| Job QM-0042  Belt Conveyor...   [status pill]  Forecast 14 Mar (+3 d)   [Saved]      [Close]    |
+------------------------------------------------------------------------------------------------+
| [+Task][+Milestone][+Phase] [Indent][Outdent] [Link][Unlink] [Baseline] [Import][Export]        |
| [Zoom day|week|month] [Critical path] [Baseline bars]                                           |
+------------------------------------+-----------------------------------------------------------+
| Task table (ID, Name, Start, End,  | Gantt (custom renderer from Phase A: phase headers, ghost |
| Days, %, Predecessors, Assignee,   | baseline bars, milestones, today line, dependency arrows  |
| Publish)                           | per link type, critical path colour)                      |
| scroll-synced rows                 | scroll-synced rows                                        |
+------------------------------------+-----------------------------------------------------------+
| Details pane (selected row): General | Predecessors (task, type FS/SS/FF/SF, lag) | History       |
+------------------------------------------------------------------------------------------------+
```

- **Table:** the Phase A task table promoted to the window, with a **Days** column (`end - start + 1`), predecessors shown MS-Project-style (`3FS+2d`), and indent/outdent (moves a task into or out of the phase above it; there are only two levels). Keyboard: arrows to move, Enter to edit, Tab to next cell. Undo/redo is not promised in v1 (open question O5). **Superseded 2026-10-21 (O1, O5): the tree has arbitrary depth, and undo/redo is built; see Owner decisions.**
- **Details pane:** the predecessor editor with type and lag per link (the new capability), the assignee, weight (staff only, as Phase A), and the publish toggle with the existing guard behaviour.
- **Gantt:** same renderer as Phase A, extended to draw an arrow per link and to start/end it at the correct bar edge for each link type; zoom, today line, ghost bars and critical colouring unchanged.
- **Import dialog:** file picker, parse, then a preview table (counts to create / update / keep / skip, list of warnings with counts, and per-row actions for the first 50 rows), mode selector (Append / Merge / Replace) with merge disabled and explained for foreign files, a reason box for Replace, and a final **Apply** button. Nothing is written before Apply. On a stale-schedule error the dialog re-previews.
- **Export menu:** **MS Project XML (ProjectLibre / MS Project)**. File name `<job_no> schedule <YYYY-MM-DD>.xml`. A one-line note states that dates are pinned (Start No Earlier Than) and the calendar is a 7-day week.
- **Concurrency:** each row save sends the row's `updated_at` as a filter (`PATCH ... WHERE id AND updated_at = old`); zero rows updated means someone else saved first, and the window shows a "changed by someone else, reload this row" notice instead of overwriting.
- **Unsaved guard:** the window warns on close if a save is in flight or failed.
- **Read-only mode:** users without `ops:work-orders:write` see the same window with editing disabled and Import hidden (Export remains).

## Client-facing surface

None from A2 itself: the schedule window and import are staff-only. A2 does define the **client download contract** that Phase D implements:

- The portal's schedule page offers **Download schedule (MS Project / ProjectLibre)**, produced from `portal_schedule` rows only, using the same pure codec (`schedule-msp.js`).
- Included: client-visible phases and tasks (per X22: `task.client_visible AND (task.phase_id IS NULL OR phase.client_visible)`), names, dates, progress, milestones, and links whose **both** ends are client-visible.
- Excluded: `assignee`/resource names (X10: clients see first name plus role only; resources are therefore omitted), `weight`, `is_critical`, internal-only rows and any link touching one, baseline dates (unless Phase D decides clients see the baseline; recommended default: no), and anything not in the `portal_schedule` whitelist. **Superseded 2026-10-21 (O6): baseline dates are now included for the client; see Owner decisions.**
- Every client download is audited through `prepare_schedule_export(..., 'client')` (called by Phase D's definer, not by the browser) and rate-limited by Phase D.
- The codec is the same file in both apps. Because the portal is a separate flat-file app (D3), the file is copied into the portal directory by the deploy workflow and a check script (`scripts/verify-msp-sync.mjs`) fails if the two copies differ. If copy-and-check proves awkward, the fallback is a Supabase edge function `schedule-export` that builds the XML server-side from `portal_schedule` (open question O3).

## Migration and rollout

1. **Prerequisite (owner): create fixture files. Done 2026-10-21 (PR #172, `scripts/tests/schedule/mspdi/`, six ProjectLibre files plus one synthetic; none from MS Project).** Original text: In ProjectLibre, build 3-4 small sample projects covering: a simple FS chain; mixed link types with lag and lead; milestones and a summary task; resources and a baseline; a Mon-Fri calendar project; and save each as MS Project XML. Also save one from MS Project if available. These are the ground truth for the codec (risk R1) and are committed under `scripts/tests/schedule/mspdi/`.
2. **Spec review** of this addendum and the amended rules (owner go-ahead).
3. **Engine first, no UI, no database:** extend `jcSchedCompute` and `job_schedule_status` for link types, extend `fixture.json`, prove JS and SQL agree (the 45 existing cases still pass unchanged). Gate: shared fixture green; mutation run catches the new branches.
4. **Codec:** `schedule-msp.js` with unit tests against the owner's fixture files; export-then-parse-then-compare round-trip tests; opening a generated file in ProjectLibre by hand (and MS Project if available) is a manual gate.
5. **Migration** (`link_type`, `msp_uid`, the two RPCs) on the throwaway Postgres suite, then to prod one step at a time with simulated-identity verification in a rolled-back transaction (the method that worked for D0 and Phase A). Order: after Phase A (already live). Phase B and C are unaffected by the columns; C's snapshot function calls `job_schedule_status`, so the replacement version must keep its signature and return shape (Amendments).
6. **Window UI**, then **import dialog**, then **export menu**, each behind the existing permission gates and each independently shippable. The card gets its **Open schedule** button last.
7. **Phase D hand-off:** Phase D's `portal_schedule` exposes the whitelist and calls the shared codec; A2 does not touch the portal app.
8. **Rollback:** feature-by-feature (the UI is additive; hide the button). The migration's `down` is in the Data model block; dropping `link_type` is lossy if non-FS links exist.

## Test plan

- **Engine (JS and SQL, shared fixture).** New cases: each link type alone; negative lag; mixed types into one successor taking the maximum; SS/FF links on the critical path; SF with a duration longer than the lag; a cycle through a non-FS link rejected by the trigger; unchanged results for every existing FS-only case (regression guard on the 45-case fixture). SQL results compared to JS to the same rounding as X20.
- **Codec (node tests):**
  - Real-file tests from the owner's ProjectLibre/MS Project fixtures: parse and assert tasks, outline, dates, % complete, milestones, predecessor types and lags, baselines, assignments.
  - Round trip: build from a Meridian-shaped object, parse it back, compare equal for every mapped field; repeat with the tasks in a different order.
  - Hostile input: DOCTYPE/ENTITY rejected; 6 MB file rejected; 2001 tasks rejected; huge strings truncated; control characters stripped; script text in names stays inert text; invalid dates, negative durations, a link to a missing UID, a self-link, UID 0, `IsNull` rows, duplicate UIDs, missing namespace, `lag` overflow, a non-Project root.
  - Calendar cases: a Mon-Fri project imported with warnings, a 7-day project imported without; lag conversion at `MinutesPerDay` 480 and 600.
- **Import RPC (throwaway Postgres, simulated identities as for Phase A):** writer can append and merge; writer cannot replace or write a baseline; approver can; replace without reason refused; foreign file cannot merge; temporary-UID file cannot merge; merge keeps Meridian-only rows; replace writes the recovery metadata; imported rows are `client_visible = false`; a merge that edits a published task's name auto-unpublishes with the audit row; stale preview refused; cross-company job refused; `anon` and a client-like login refused; atomic: a bad row in the payload leaves zero writes; a cycle in the payload is rejected before any write; mutation checks as for D0c.
- **`prepare_schedule_export`:** assigns UIDs once and only for writers, UID 0 never used, phases and tasks never share a UID in a job, concurrent calls do not double-assign (advisory lock), an audit row is written for staff and client kinds, `authenticated` cannot call kind `'client'`.
- **UI (static render tests as for KPI/Gantt, then live):** route restore and refresh; new-tab open; dirty guard; read-only mode hides editing and Import; link arrows for all four types; stale-row save notice; an import preview with a hostile name renders as text.
- **Interop (manual, owner):** export a real job, open in ProjectLibre: same dates, same links and lags, no task pulled earlier, milestones as diamonds, resources shown; edit in ProjectLibre, save as XML, merge back into Meridian: only the edits arrive. Repeat in MS Project if available.
- Run `node scripts/verify-spec.mjs phase-a2-projectlibre.md`, `verify-roadmap.mjs` and `verify-guards.mjs` before merging this spec.

## Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Partly mitigated (fixtures merged, see "Fixture findings"). The MSPDI details here come from the public schema and general knowledge, checked against ProjectLibre files only; nothing is verified against MS Project, and material resources are unverified.** ProjectLibre may write or require things differently (UID 0 summary, `LagFormat`, duration formats, `PercentComplete` rounding, whether it honours Start No Earlier Than on open). | Step 1 of rollout: owner supplies fixture files before any codec work; the mapping table is corrected from real files; the interop test is a manual gate. |
| R2 | Date drift on round trip (calendar differences; ProjectLibre auto-scheduling moves tasks). | 7-day export calendar, Start No Earlier Than pin, dates authoritative on import, the preview shows date changes before Apply. |
| R3 | Two tabs refreshing the Supabase token at once may sign one out. | Verify in `tryRestoreSession()` before building; add a cross-tab lock if needed. |
| R4 | `import_job_schedule` (definer, deletes in replace mode) is a new write path that bypasses the UI. | Server re-validation, atomicity, advisory lock, stale check, audit with recovery metadata, independent attack review, mutation tests, replace limited to approvers with a reason. |
| R5 | Changing the compute rule (link types) touches the shared progress/status function that C and D depend on. | Signature and return shape unchanged; FS-only behaviour identical (the existing fixture must pass unmodified); D reads stored snapshots, not the function. |
| R6 | Imported files can be hostile (XML bombs, huge files, script in names). | DOCTYPE rejection, size/count caps, textContent-only rendering, server-side length and control-character limits. |
| R7 | Two levels only: files with deeper outlines lose structure on import. | Visible warning with counts; the flattening rule is deterministic (O1); sub-task support is a deferred amendment to X1. |
| R8 | New front-end file breaks the single-file convention and the extract-block test harness. | The new file is pure and tested directly; `index.html` blocks keep their tests; O4 allows staying inline. |
| R9 | Client downloads leak internal data through the shared codec. | The codec takes only the whitelisted `portal_schedule` shape; a test feeds it a row with internal fields and asserts none appear; D audit and rate limit. |
| R10 | Replace mode is destructive and the task tables have no archive. | Recovery metadata in the audit log, approver + reason, and the preview shows counts to delete before Apply. |

## Open questions

Resolved 2026-10-21: see "Owner decisions" above (O1, O2, O5, O6 changed; O3, O4, O7, O8 keep their defaults). The original questions stay below for the record.

Recommended defaults apply unless you object.

- **O1: **[Resolved 2026-10-21: real task hierarchy now.]** Outline depth on import.** Level 1 summary = phase, level 2 = task; deeper levels are flattened into their level-2 ancestor's phase as tasks, and their WBS prefix is kept in the task name (`1.2.3 Weld`). **Default: flatten with warning.** Alternative: add task hierarchy now (needs an X1 amendment, summary tasks weight 0).
- **O2: **[Resolved 2026-10-21: resources built into A2, auto-filled from job-card sections.]** Resources.** A2 round-trips `assignee` only. **Default: defer resources to Phase R**, which will reuse `employees` and `config_equipment`, and which should key assignments on `job_tasks.id`.
- **O3: Codec sharing with the portal.** Copy-and-verify script vs an edge function. **Default: copy-and-verify**, because the portal reads only `portal_*` functions and a client-side build avoids a new trust boundary.
- **O4: File layout.** New `schedule-msp.js` vs staying fully inline in `index.html`. **Default: codec in its own file, window code inline** until it exceeds a manageable size.
- **O5: **[Resolved 2026-10-21: undo/redo is built.]** Undo/redo in the window.** **Default: not in v1**; row-level conflict notices instead.
- **O6: **[Resolved 2026-10-21: yes, clients see baseline, behind a release agreement.]** Does the client see baseline dates (ghost bars) in the downloaded file?** **Default: no.** Phase D decides for the portal page; A2's contract follows.
- **O7: Weighted progress on import.** Imported tasks get `weight = NULL` (duration weighting). **Default: yes**; round-tripping weights through an MSPDI extended attribute is not worth the complexity.
- **O8: Tie-in with Phases B and C.** Phase B (not yet built) could add a nullable `task_id` to ITP items and hold points so a QC check belongs to a schedule task; Phase C updates could reference a task. **Default: raise as a note in the B and C specs now, build later.**

## Acceptance criteria

1. The migration applies cleanly on a throwaway Postgres and on prod; `down` runs; all existing Phase A tests (45-case shared fixture, 381 SQL asserts, UI tests) pass **unmodified**.
2. `jcSchedCompute` and `job_schedule_status` agree on every fixture case including the new link-type cases; FS-only results are identical to before.
3. A Meridian export opens in ProjectLibre showing the same dates, hierarchy, milestones, predecessors with link type and lag, and assignee names; no task moves earlier than its Meridian start. (Manual, owner-verified; MS Project too if available.)
4. A file saved from ProjectLibre merges back into the same job so that only edited fields change, Meridian-only tasks are kept, and the preview matches what was written.
5. A foreign file can be appended or (by an approver, with a reason) replace the schedule; merge is refused for it; the import is atomic and fully audited; the replace recovery metadata is present.
6. Hostile-file tests all pass (DOCTYPE, size, counts, injection text, invalid dates and links) and nothing imported reaches the DOM except as text.
7. A user without `ops:work-orders:write` cannot import or edit links; a writer cannot replace or lock a baseline; a client-like login and `anon` cannot call either new function.
8. The schedule window opens in a new tab at `#/schedule/<job_id>`, survives refresh and Back/Forward, warns on unsaved changes, and shows a conflict notice instead of overwriting a row saved by someone else.
9. The client download contract is implemented in Phase D with the whitelist, audit and rate limit, and a test proves no internal field appears in the file.
10. The Q-D definer sweep and the Supabase advisors show no new issue beyond the two intended definer functions.

## Amendments to Phase A and the X-rules

Proposed additions for the owner to approve with this addendum (the existing text is not rewritten; Phase A is live):

| # | Amendment | Owner |
|---|---|---|
| X24 | **Link types.** `job_task_links.link_type` (FS/SS/FF/SF) and `lag_days` define dependencies; the precedence rules in "Link-type semantics" are the only definition. `jcSchedCompute` and `job_schedule_status` implement them identically (the X1/X20 fixture requirement extends to them). `depends_on` mirrors the first FS predecessor only. | A2 defines; C, D read stored results |
| X25 | **Schedule interchange.** MSPDI is the only interchange format; the codec is the single implementation (`schedule-msp.js`); client exports contain only the `portal_schedule` whitelist (X22). | A2 defines; D calls |
| X26 | **UID space.** `msp_uid` is unique across `job_phases` and `job_tasks` within one job, assigned only by `prepare_schedule_export`/`import_job_schedule` under an advisory lock, never reused, UID 0 reserved. | A2 |
| X27 | **Schedule imports and exports are audited** (`schedule_imported`, `schedule_exported`) and imports never publish: imported rows are `client_visible = false` and the X5/X19 guard stays in force. | A2 |
| X28 | **Task identity for later phases.** `job_tasks.id` is the anchor for resources, quality checks and documents; later phases reference it by FK and do not model a second task. | A2; B, C, Phase R follow |

Files to update when this addendum is accepted: add a row for A2 to the phase table in `99-roadmap.md` (after Phase A, before B or in parallel), list `import_job_schedule` and `prepare_schedule_export` under shared functions, add X24-X28 to section 8 of `00-overview.md`, and note in `phase-d-client-portal.md` that `portal_schedule` must feed the shared codec and call `prepare_schedule_export(..., 'client')`.
