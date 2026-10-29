# Gates: r3 uid-space lock (MEDIUM): a writer without approve could block a job's uid space forever

Attack: writer sets `msp_uid = 99999999` on one task (the range CHECK allows it), one uid request (`prepare_schedule_export` or an import)
seeds `job_schedule_uid_counter` at 99999999 and moves it to 100000000. Clearing the planted uid does not help; append, replace and export then
fail with "uid space exhausted" for good.

## Design (root fix + safety net, both)
- (b) ROOT FIX: `job_schedule_msp_uid_guard` BEFORE INSERT OR UPDATE OF msp_uid on job_phases and job_tasks (SQLSTATE A2U01) refuses any
  msp_uid change made by an API role (`current_user` in authenticated, anon, service_role). Only the definer export/import code (running as the
  function owner) assigns uids. Verified the client never writes it: `grep -n msp_uid index.html schedule-msp.js` finds only a comment; the
  UI inserts/patches job_tasks/job_phases without the column; import goes through the definer RPC. An invoker trigger on purpose: inside a
  definer function `current_user` is the owner, so no flag or GUC can be forged by a caller. Name sorts after `*_company_guard`, so the
  cross-company A2C01 tests still see A2C01 first.
- SAFETY NET (a): `sched_next_uids` seeds a NEW counter at the highest stored uid only if that is plausible
  (`<= 4 * rows + 1000`, rows = phases + tasks of the job); otherwise it seeds 0 and the used-number skip (already there) keeps uids unique.
  A value planted by a DBA/migration/legacy data can therefore waste at most 4n+1000 numbers and never lock a job. Not chosen: (c) an approver
  reset (new privileged surface, and moving a counter back risks X26); seeding at 0 always (changes the documented "continue after the
  highest stored uid" numbering).
- X26 untouched: the counter row, once created, still only moves forward; no reset anywhere.

## Gates
1. Attack test reproduces the exact plant and is red on the old code, green on the new.
   - a2a_import 20_after.sql section "r3 uid lock": writer (no approve) plants 99999999 through the API path, then requests uids (append),
     clears it, then approver replaces. Old code: plant succeeds and replace fails "uid space exhausted". New code: plant is `err:A2U01`.
   - Check red: `git show HEAD:supabase/migrations/202610271000_a2a_schema.sql > $TMP/old.sql; bash supabase/tests/d0c_common/run.sh a2a_schema $TMP/old.sql`
     (and the same for a2a_import) must print MUTANT CAUGHT.
2. Writer cannot plant any msp_uid (insert or update, phases and tasks, authenticated/anon) = A2U01; a no-op write of the same value,
   writes that leave msp_uid alone, and postgres (owner) writes are fine. Positive: export, append, merge, replace still assign uids; X26 holds
   after deletes; round-2 gap-fill still works. A DBA-planted 99999999 (owner session) does not exhaust export or import (safety net).
   Tests: a2a_schema section 13, a2a_import "r3 uid lock", a2a_export "r3 uid lock".
3. `bash supabase/tests/d0c_common/run.sh <fam>` for phase_a_sql, a2a_schema, a2a_export, a2a_import, a2a_status (incl. rollback and re-apply);
   `bash supabase/tests/phase_a_sql/run-fixture.sh` 55/55; `bash supabase/tests/a2a_all/run.sh`; `bash supabase/tests/a2a_export/concurrency.sh`.
   The rollback script drops the new trigger functions (a2a_schema 30_rollback checks).
4. New mutants in a2a_schema/a2a_import/a2a_export mutations.json, run serially with the filter and killed; equivalents documented here
   (section "Mutants" below, filled in after the run).

## Mutants (a2a_schema/mutations.json, names start "r3 uid guard" / "r3 net" / "r3 guard function")
18 added, run serially with a name filter: 17 caught, 1 documented equivalent ("anon not blocked": anon has no write privilege on the
schedule tables, so it dies with 42501 before the trigger; the name stays in the list as defence in depth). A first run had a second
survivor ("row count ignores unnumbered rows"); killed by the added test "unnumbered rows count too" (highest 1005, 2 rows -> 1006).
The mutants live in a2a_schema because the logic is in 202610271000; a2a_import / a2a_export migrations did not change (their tests got the
attack and positive cases only; two old expectations that relied on a planted 99999999 seeding the counter now expect 1).
