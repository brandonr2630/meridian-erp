-- Migration: rename JC- prefix to WO-, renumber existing jobs from WO-001
-- Apply in Supabase SQL Editor

-- 1. Update the next_job_no() RPC to emit WO- prefix with 3-digit minimum padding
CREATE OR REPLACE FUNCTION next_job_no()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next bigint;
BEGIN
  v_next := nextval('job_no_seq');
  RETURN 'WO-' || LPAD(v_next::text, 3, '0');
END;
$$;

-- 2. Renumber all existing jobs globally (ordered by created_at, then id for tiebreaking)
--    Result: WO-001, WO-002, WO-003 ...
WITH numbered AS (
  SELECT
    id,
    ROW_NUMBER() OVER (ORDER BY created_at, id) AS rn
  FROM jobs
)
UPDATE jobs
SET job_no = 'WO-' || LPAD(numbered.rn::text, 3, '0')
FROM numbered
WHERE jobs.id = numbered.id;

-- 3. Sync job_audit_log job_no references to match the new numbers
UPDATE job_audit_log jal
SET job_no = j.job_no
FROM jobs j
WHERE jal.job_id = j.id;

-- 4. Advance the sequence past the highest assigned number so the next new job
--    continues from where we left off (no collision with renumbered jobs)
SELECT setval(
  'job_no_seq',
  GREATEST(
    (SELECT COUNT(*) FROM jobs),
    currval('job_no_seq')
  )
);
