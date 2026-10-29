-- Rollback for 202610271300_a2a_import.sql. Idempotent. Drops only the RPC and its helpers; no table or column is touched.
-- Audit rows already written by the RPC (schedule_imported, baseline_locked) stay: they are history. Rows the RPC created stay too.
DROP FUNCTION IF EXISTS import_job_schedule(uuid, text, jsonb, text);
DROP FUNCTION IF EXISTS import_sched_warn(jsonb, text, text, integer);
DROP FUNCTION IF EXISTS import_sched_has_atom(uuid, text);
DROP FUNCTION IF EXISTS import_sched_bool(jsonb, text, text);
DROP FUNCTION IF EXISTS import_sched_date(jsonb, text, text);
DROP FUNCTION IF EXISTS import_sched_int(jsonb, text, text, bigint, bigint, boolean);
DROP FUNCTION IF EXISTS import_sched_str(jsonb, text, text, integer, boolean);
DROP FUNCTION IF EXISTS import_sched_clean(text);
