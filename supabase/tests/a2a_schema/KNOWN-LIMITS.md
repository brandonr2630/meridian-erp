# Known limits of the schedule (A2a) database guards

These are things the independent reviews found that we **decided not to fix**. Each one says what it is, who could trigger it, why it is accepted
and how it would be fixed later. None of them lets a person read or change another company's data. Most of them only hurt the person who does
them, or need direct database access (a DBA or a service script), which ordinary users of the ERP do not have.

"Guards" below means the database triggers that refuse bad schedule changes (a link between a task and its own ancestor or descendant, a link
loop, moving a task under one of its own descendants, a unique number moving to another job).

## The four Lows from review round 4 (L1 to L4)

### L1. The guards can be bypassed inside a REPEATABLE READ or SERIALIZABLE transaction
- **What it is.** The link guard and the re-parent guard take a lock on the job and then look at the rows. At the default isolation level (READ
  COMMITTED) they see everything committed before they look. In a REPEATABLE READ or SERIALIZABLE transaction the database shows a transaction a
  frozen picture taken at its first query, so two such transactions can each pass the guard and together commit a shape the guard would have
  refused (for example two links that together make a loop).
- **Who could trigger it.** Only someone who can open a transaction and set its isolation level: a DBA, or a service script using a direct database
  connection. PostgREST (the Supabase API the ERP uses) cannot set the isolation level, so ordinary users and the browser app cannot.
- **Why accepted.** Not reachable from the application; the damage is a bad schedule shape in one job, which `job_schedule_status` already survives
  (it stops instead of raising), and a DBA can already do worse.
- **How it would be fixed later.** Make the guard raise an error when `current_setting('transaction_isolation') <> 'read committed'`, so a
  stricter transaction is refused instead of silently weakened.

### L2. A specially built hierarchy plus links makes the guard about 8 times slower
- **What it is.** The guard has to work out ancestors and descendants. For one deliberately awkward shape (deep hierarchy with many links across
  it) the check measured 6.07 s for 300 links against 0.72 s for an ordinary shape. A 5000-link import of that shape took about 90 s, and holds the
  per-job lock the whole time, so other changes to that one job wait.
- **Who could trigger it.** Only a person who can write that job's tasks and links (the job's own writers). Other jobs and other companies are not
  blocked, because the lock is per job.
- **Why accepted.** The cost falls on the job of the person doing it; there is no way to slow anyone else, and a normal schedule is nowhere near
  this shape.
- **How it would be fixed later.** Keep a precomputed ancestor table (or a depth/path column) maintained by the re-parent guard so the link guard
  does one lookup instead of a walk; or cap the number of links one import may add.

### L3. The import's cycle pre-check can mistake a client-supplied task id for one of its own internal ids
- **What it is.** Before writing, the import builds internal node ids for its cycle check as `md5(id || 'N')::uuid`. If a client-supplied task id
  happens to equal one of those derived ids, the pre-check treats two different nodes as the same one and refuses the import with 23514 (a "false
  refusal"). It can never miss a real cycle; it can only refuse something that was fine.
- **Who could trigger it.** Someone who deliberately crafts task ids of that exact derived form (finding such an id means inverting md5). It affects
  only imports into that person's own job.
- **Why accepted.** Practically unreachable by accident and harmless when forced: the import is refused, nothing is written.
- **How it would be fixed later.** Key the check on the pair `(uuid, boolean)` instead of a single derived uuid, so no id can collide.

### L4. Changing a task's primary key skips the hierarchy and link guards
- **What it is.** The guards fire on changes to `parent_task_id`, links, and similar columns. Changing a task's own `id` (its primary key) is not
  one of the watched changes, so a rename of the key does not re-run them.
- **Who could trigger it.** Only raw SQL by a DBA or service script. PostgREST does not offer a way to update a primary key through the normal
  API path used by the app, and the ERP never does it.
- **Why accepted.** Not reachable from the application; a DBA can already change data directly.
- **How it would be fixed later.** Add a BEFORE UPDATE OF id trigger that simply refuses the change (a task's id should never change).

## Earlier accepted limits

- **uuid-existence oracle (23503 versus A2C01).** A writer who tries to link to an id learns from the error code whether that id exists as a task
  somewhere (foreign-key error) or not (our own message). It reveals existence of a random uuid only, never any content. Fix later: make both
  paths raise the same code.
- **A phase can move jobs while tasks still reference it.** Moving a phase to another job does not by itself drag its tasks along; the company and
  job guards keep the rows consistent per table, but the tasks keep pointing at the old phase until someone fixes them. Only the job's writers can do
  it, and they own both jobs' data. Fix later: refuse a phase job change while tasks reference it.
- **Audit forgery R1 and R3.** A writer who can insert into the audit table directly could add a believable-looking audit line, and the
  export/import audit rows are written by the same functions the caller invokes. The audit log is a convenience trail, not evidence for disputes.
  Fix later: write audit rows only through a definer function and remove the direct insert path.
- **40P01 deadlock entry points.** Two writers changing the same job's links and tasks in opposite orders can deadlock; the database aborts one of
  them with error 40P01 and the app can simply retry. Nothing is corrupted. Fix later: take the job lock first in every write path.
- **Import two-step re-parent loses the planted-link exemption.** If an import has to move a task in two steps (first detach, then re-attach), a
  link that a DBA had planted between a task and its ancestor loses the exemption it had for the single-step move, so the second step can be refused.
  The import is refused whole and nothing is written. Fix later: carry the exemption across both steps.
- **Guard cost is 2 to 4 times higher on link and re-parent writes.** Each link or re-parent write now does extra checking. Measured and judged
  acceptable for the sizes the ERP handles (hundreds of tasks). See `GATES-r3-guard.md` and `bench-guard-cost.sh` for the numbers.
- **The UI shows a generic error for A2L01 and A2L03.** The database refuses with a specific code and message, but the page currently shows a
  generic "could not save" for these two codes. Nothing is lost; the user just does not see the reason. Fix later: map A2L01/A2L03 to friendly text
  in the UI.
- **Ancestor links already planted by a DBA stay valid.** The new guard stops people creating a link between a task and its own ancestor or
  descendant, but such links that already exist (planted directly in the database or from before the guard) are left in place, and the status
  function copes with them. Fix later: a one-off clean-up query run by the owner, then a validated constraint.
