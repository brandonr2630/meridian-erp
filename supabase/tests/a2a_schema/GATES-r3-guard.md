# Gates: r3 cross-job phase_id / depends_on guard (LOW)

Fix: `job_schedule_company_guard` (job_tasks branch) rejects a `phase_id` / `depends_on` that points at a row of ANOTHER job or company
(SQLSTATE A2C01). A reference to a row that does not exist yet is left to the FK. `parent_task_id` is already covered by
`job_tasks_parent_guard` (A2H01/A2H06), so it is not duplicated.

1. New tests in 20_after.sql (section 11b) reproduce the attacks and are red on the old migration, green on the new.
   Check: `git show HEAD:supabase/migrations/202610271000_a2a_schema.sql > $TMP/old.sql; bash supabase/tests/d0c_common/run.sh a2a_schema $TMP/old.sql`
   must print MUTANT CAUGHT (exit 0); positive tests (same-job refs, phase delete, unphasing, unrelated updates) are in the same section.
2. `bash supabase/tests/d0c_common/run.sh a2a_schema` passes (before / apply / re-apply / after / rollback / after rollback).
3. `node supabase/tests/d0c_common/mutate.mjs a2a_schema` kills every mutant, including the new ones in mutations.json.
4. `bash supabase/tests/d0c_common/run.sh a2a_import`, `a2a_export`, `a2a_status`, `phase_a_sql` and `bash supabase/tests/a2a_all/run.sh` still pass.
5. Files stay LF; no stray d0c-* containers remain.
