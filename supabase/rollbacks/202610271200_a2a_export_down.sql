-- Rollback of 202610271200_a2a_export.sql. Idempotent. Assigned msp_uid values stay (they belong to the schema migration);
-- job_audit_log rows with action_type 'schedule_exported' stay (append-only). Phase D objects that call
-- schedule_export_core() must be rolled back first (the DROP fails on purpose, without CASCADE, while a dependent exists).
DROP FUNCTION IF EXISTS prepare_schedule_export(uuid, text);
DROP FUNCTION IF EXISTS schedule_export_core(uuid, text);
