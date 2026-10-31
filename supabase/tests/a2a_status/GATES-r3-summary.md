# GATES r3 summary: job_schedule_status quadratic/timeout with links into a summary task (behaviour-preserving)

Attack (independent review, MEDIUM): summary S (uid 1) with 300 leaf kids chained against their direction (t(g) after t(g+1), FS)
plus 300 FS links "pred 1001..1300 -> S". Every pass re-scans all n tasks (with a parent-chain walk) for each link into S, and the
reversed chain needs ~300 passes: 601 tasks / 599 links timed out at 8 s (13.2 s direct).

1. Timing: `bash supabase/tests/a2a_status/bench-summary-links.sh [migration.sql]` builds the reviewer payload directly in SQL
   (also a deep-nesting and a cyclic variant, informational) and prints the median of 3. Baseline recorded BEFORE coding.
   Target: after < 2 s AND >= 5x faster than baseline. If not reachable: report the measured best and why.
2. Regression: `bash supabase/tests/a2a_status/diff-vs-old.sh` loads the pre-change function (git HEAD migration) as
   job_schedule_status_old next to the new one and compares row-for-row on (a) ~25 hand-built summary graphs (FS/SS/FF/SF into and
   out of summaries, nested summaries, reversed chains inside summaries, non-settling hierarchy cycle) and (b) a few hundred seeded
   random graphs (random hierarchy, link types, lags, progress, undated tasks, hierarchy cycles). Must report 0 differences.
   The same hand-built shapes are also in 20_after.sql via gen-cases.mjs with expectations from the JS jcSchedCompute (index.html).
3. `bash supabase/tests/d0c_common/run.sh a2a_status` (incl. rollback + re-apply), `bash supabase/tests/phase_a_sql/run-fixture.sh`
   (55/55), `bash supabase/tests/d0c_common/run.sh phase_a_sql` (381), `bash supabase/tests/a2a_all/run.sh` all pass.
4. `node supabase/tests/d0c_common/mutate.mjs a2a_status` kills every non-equivalent mutant, new ones for the new logic included;
   equivalents documented in mutations.json.

## Results
1. Baseline (pre-change body): reviewer payload 13.3 / 13.4 / 13.3 s; after: 36 / 33 / 35 ms (about 390x, target < 2 s, >= 5x). Informational: 600-deep nesting 0.3-0.45 s -> 22 ms;
   cyclic variant (kid linked to its own summary, passes do not settle) 27 s -> 0.76 s, same output row.
2. diff-vs-old.sh 400: 3280 evaluations (1582 jobs with a summary, all four sweep/pass-loop combinations hit), 0 differences. 20_after.sql: 1242 checks incl.
   JS-expected summary/nested/reversed-chain/FS-SS-FF-SF cases, 360 seeded random cases, "+cyc" variants of every case (forces the pass loop), and 294 cases pinned to the
   pre-change body (pinned-old.json; the same file also passes against the pre-change migration).
3. a2a_status PASS (incl. rollback + re-apply), fixture 55/55, phase_a_sql 381, a2a_all PASS.
4. mutate.mjs a2a_status: 54/54 killable caught, 5 documented equivalents (2 pruning, parent-cycle shortcut, and 2 earlier ones).
