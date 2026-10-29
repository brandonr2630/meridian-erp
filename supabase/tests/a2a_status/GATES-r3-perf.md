# GATES r3 perf: job_schedule_status quadratic on a reversed FS chain (behaviour-preserving)

1. Timing: `bash supabase/tests/a2a_status/bench-reversed-chain.sh [migration.sql]` builds a 2000-task reversed FS chain
   (task i has predecessor i+1, so link order is the worst case) on throwaway Postgres 17 and prints the median of 3 timings.
   Baseline recorded below before coding; after must be >= 2x faster (ratio stated). Otherwise abandon with the reason.
2. `bash supabase/tests/d0c_common/run.sh a2a_status` -> ALL A2A_STATUS TESTS PASSED (incl. rollback / re-apply).
3. `bash supabase/tests/phase_a_sql/run-fixture.sh` -> SQL FIXTURE PASSED 55/55 cases.
4. `node supabase/tests/d0c_common/mutate.mjs a2a_status` kills every mutant (equivalents documented).
5. `bash supabase/tests/d0c_common/run.sh phase_a_sql` still 10/381/21 and `bash supabase/tests/a2a_all/run.sh` passes.

## Results
1. Baseline (A2a body at bdf0fce), 2000-task reversed FS chain, 3 runs: 2550 / 2635 / 2584 ms (median ~2584 ms); Phase A body for reference ~1.4-1.5 s.
   After (links relaxed in dependency order): 167 / 205 / 149 ms then 147 / 150 / 145 ms on re-runs (median ~150 ms). Ratio ~17x (>= 2x). Same output row.
2. PASS: ALL A2A_STATUS TESTS PASSED (130 checks AFTER, 13 after rollback, re-apply ok).
3. PASS: SQL FIXTURE PASSED 55/55 cases.
4. PASS: mutation check passed 26/26 (31 mutants, 5 equivalent documented in mutations.json; 4 new r3 mutants, 2 killable and killed, 2 perf-only equivalents).
5. PASS: phase_a_sql 10/381/21; A2A COMBINED STACK PASSED.

Approach: when there is no summary and the link graph is acyclic the fixpoint is unique, so links are relaxed in topological order
(forward) / reverse (backward); otherwise array order as before so non-settling values are unchanged (tests r3 added).
