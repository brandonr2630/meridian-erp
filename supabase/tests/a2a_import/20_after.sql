-- AFTER the migration: import_job_schedule behaviour. One transaction, rolled back. Every check prints NOTICE 'PASS ...'.
-- Identities (see 10_stub_extra.sql t_u): ops = operations_tech C1 (read/write/approve), viewr, cadm = company_admin C1 (approve), sup = super_admin C1+C2,
-- ops2 = operations_tech C2, wrt = write-only (NO approve) C1, fin = finance C1 (no ops atoms), mix = write+approve in C1 but only viewer in C2,
-- gone = inactive user, clnt = client-shaped login (no erp_users row), anon.
BEGIN;

-- BEGIN GENERATED PAYLOADS (node supabase/tests/a2a_import/gen-payloads.mjs --write; do not edit by hand)
CREATE TEMP TABLE t_payloads (name text PRIMARY KEY, body jsonb NOT NULL, meta jsonb);
GRANT ALL ON t_payloads TO PUBLIC;
INSERT INTO t_payloads VALUES ('f01', $j${"project":{"uid":null,"manager":"B Rampersad","name":"01-simple-fs","title":"01-simple-fs","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Motor Repairs","sort_order":10}],"tasks":[{"uid":2,"name":"Receive Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":100,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"Inspect Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":60,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[{"pred_uid":2,"link_type":"SS","lag_days":0}]},{"uid":4,"name":"Report Findings of Inspection","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-22","progress":10,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[{"pred_uid":3,"link_type":"FS","lag_days":0}]},{"uid":5,"name":"Disassemble Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"Change Bearings","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":7,"name":"Clean Stator","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":6,"link_type":"SS","lag_days":0}]},{"uid":8,"name":"Re-varnish Stator","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-23","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Check Runout on Rotor Shaft","phase_uid":1,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-23","progress":0,"is_milestone":true,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[{"pred_uid":8,"link_type":"FS","lag_days":0}]},{"uid":10,"name":"Reassemble Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-23","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":90,"links":[{"pred_uid":9,"link_type":"FF","lag_days":0}]},{"uid":11,"name":"Test & Certify","phase_uid":1,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-23","progress":0,"is_milestone":true,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":100,"links":[{"pred_uid":10,"link_type":"FS","lag_days":0}]},{"uid":12,"name":"Paint","phase_uid":1,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-26","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":110,"links":[{"pred_uid":11,"link_type":"FS","lag_days":0}]},{"uid":13,"name":"Stage","phase_uid":1,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":120,"links":[{"pred_uid":12,"link_type":"FS","lag_days":0}]},{"uid":14,"name":"Deliver","phase_uid":1,"parent_uid":null,"start_date":"2026-10-27","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":130,"links":[{"pred_uid":13,"link_type":"SF","lag_days":1}]}],"resources":[],"assignments":[],"warnings":[{"code":"constraint-ignored","message":"Scheduling constraints other than the Meridian date pin were ignored.","count":1},{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f02', $j${"project":{"uid":null,"manager":"B Rampersad","name":"02-link-types","title":"02-link-types","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Motor Repairs","sort_order":10}],"tasks":[{"uid":2,"name":"Receive Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"Prepare Documentation","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[{"pred_uid":2,"link_type":"SS","lag_days":0}]},{"uid":4,"name":"Inspect Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-26","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[{"pred_uid":3,"link_type":"FS","lag_days":2}]},{"uid":5,"name":"Report Findings & Quote","phase_uid":1,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"Confirm customer PO","phase_uid":1,"parent_uid":null,"start_date":"2026-10-27","end_date":"2026-10-28","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":7,"name":"Disassemble Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-28","end_date":"2026-10-28","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":6,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Rewind Stator","phase_uid":1,"parent_uid":null,"start_date":"2026-10-28","end_date":"2026-11-02","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Check Runout of Rotor Shaft","phase_uid":1,"parent_uid":null,"start_date":"2026-10-29","end_date":"2026-10-30","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[{"pred_uid":8,"link_type":"FF","lag_days":-1}]},{"uid":10,"name":"assemble motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-30","end_date":"2026-11-02","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":90,"links":[{"pred_uid":9,"link_type":"FS","lag_days":0}]},{"uid":11,"name":"test motor","phase_uid":1,"parent_uid":null,"start_date":"2026-11-02","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":100,"links":[{"pred_uid":10,"link_type":"SF","lag_days":2}]}],"resources":[],"assignments":[],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f03', $j${"project":{"uid":null,"manager":"B Rampersad","name":"03-milestones-summary","title":"03-milestones-summary","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Motor 1 Repair","sort_order":10},{"uid":5,"name":"Motor 2 Repair","sort_order":20}],"tasks":[{"uid":2,"name":"Receive Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"Prepare Documentation","phase_uid":1,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[{"pred_uid":2,"link_type":"FS","lag_days":0}]},{"uid":4,"name":"Inspect Motor","phase_uid":1,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-23","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[{"pred_uid":3,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"Receive Motor","phase_uid":5,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-21","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":2,"link_type":"SS","lag_days":0}]},{"uid":7,"name":"Prepare Documentation","phase_uid":5,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[{"pred_uid":6,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Inspect Motor","phase_uid":5,"parent_uid":null,"start_date":"2026-10-23","end_date":"2026-10-23","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Complete Inspections","phase_uid":5,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-26","progress":0,"is_milestone":true,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0},{"pred_uid":8,"link_type":"FS","lag_days":0}]}],"resources":[],"assignments":[],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f04', $j${"project":{"uid":null,"manager":"BTR","name":"04-hierarchy-deep","title":"04-hierarchy-deep","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Project","sort_order":10}],"tasks":[{"uid":2,"name":"Phase A","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"WP1","phase_uid":1,"parent_uid":2,"start_date":"2026-10-21","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[]},{"uid":4,"name":"Task A1","phase_uid":1,"parent_uid":3,"start_date":"2026-10-21","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[]},{"uid":5,"name":"Task A2","phase_uid":1,"parent_uid":3,"start_date":"2026-10-23","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"WP2","phase_uid":1,"parent_uid":2,"start_date":"2026-10-28","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[]},{"uid":7,"name":"Task B1","phase_uid":1,"parent_uid":6,"start_date":"2026-10-28","end_date":"2026-10-29","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Task B2","phase_uid":1,"parent_uid":6,"start_date":"2026-10-30","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Phase B","phase_uid":1,"parent_uid":null,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[]},{"uid":10,"name":"WP3","phase_uid":1,"parent_uid":9,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":90,"links":[]},{"uid":11,"name":"Task C1","phase_uid":1,"parent_uid":10,"start_date":"2026-11-04","end_date":"2026-11-05","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":100,"links":[{"pred_uid":8,"link_type":"FS","lag_days":0}]},{"uid":12,"name":"Task C2","phase_uid":1,"parent_uid":10,"start_date":"2026-11-06","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":110,"links":[{"pred_uid":11,"link_type":"FS","lag_days":0}]}],"resources":[],"assignments":[],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f05', $j${"project":{"uid":null,"manager":null,"name":"05-resources-baseline","title":"05-resources-baseline","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[],"tasks":[{"uid":1,"name":"Deliver","phase_uid":null,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":"2026-10-21","baseline_end":"2026-10-22","sort_order":10,"links":[]},{"uid":2,"name":"Receive","phase_uid":null,"parent_uid":null,"start_date":"2026-10-22","end_date":"2026-10-23","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":"2026-10-22","baseline_end":"2026-10-23","sort_order":20,"links":[{"pred_uid":1,"link_type":"FS","lag_days":0}]},{"uid":3,"name":"Repair","phase_uid":null,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-30","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":"2026-10-23","baseline_end":"2026-10-28","sort_order":30,"links":[{"pred_uid":2,"link_type":"FS","lag_days":0}]},{"uid":4,"name":"Test","phase_uid":null,"parent_uid":null,"start_date":"2026-11-02","end_date":"2026-11-06","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":"2026-10-28","baseline_end":"2026-11-03","sort_order":40,"links":[{"pred_uid":3,"link_type":"FS","lag_days":0}]},{"uid":5,"name":"Reassemble","phase_uid":null,"parent_uid":null,"start_date":"2026-11-06","end_date":"2026-11-13","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":"2026-11-03","baseline_end":"2026-11-10","sort_order":50,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]}],"resources":[{"uid":1,"name":"Technician 1","kind":"work","materialLike":false,"materialLabel":null},{"uid":2,"name":"Technician 2","kind":"work","materialLike":false,"materialLabel":null},{"uid":3,"name":"Bearing","kind":"work","materialLike":false,"materialLabel":null}],"assignments":[{"taskUid":1,"resourceUid":1,"units":1,"workHours":12},{"taskUid":2,"resourceUid":1,"units":1,"workHours":12},{"taskUid":2,"resourceUid":2,"units":0.5,"workHours":6},{"taskUid":3,"resourceUid":3,"units":1,"workHours":40}],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1},{"code":"resource-rates-dropped","message":"Resource rates were not imported.","count":3}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f06', $j${"project":{"uid":null,"manager":"B Rampersad","name":"06-calendar-monfri","title":"06-calendar-monfri","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[],"tasks":[{"uid":1,"name":"Receive","phase_uid":null,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-26","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":2,"name":"Test","phase_uid":null,"parent_uid":null,"start_date":"2026-10-27","end_date":"2026-10-30","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[{"pred_uid":1,"link_type":"FS","lag_days":0}]},{"uid":3,"name":"Disassemble","phase_uid":null,"parent_uid":null,"start_date":"2026-10-30","end_date":"2026-11-02","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[{"pred_uid":2,"link_type":"FS","lag_days":0}]},{"uid":4,"name":"Repair","phase_uid":null,"parent_uid":null,"start_date":"2026-11-03","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":3,"link_type":"FS","lag_days":0}]},{"uid":5,"name":"Reassemble","phase_uid":null,"parent_uid":null,"start_date":"2026-11-04","end_date":"2026-11-04","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"Paint","phase_uid":null,"parent_uid":null,"start_date":"2026-11-05","end_date":"2026-11-06","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":7,"name":"Test","phase_uid":null,"parent_uid":null,"start_date":"2026-11-09","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":6,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Deliver","phase_uid":null,"parent_uid":null,"start_date":"2026-11-10","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]}],"resources":[],"assignments":[],"warnings":[{"code":"finish-recomputed","message":"Finish dates were recomputed from the file's working calendar (the stored finish was stale or inconsistent).","count":1},{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('f07', $j${"project":{"uid":null,"manager":null,"name":"07-synthetic-material","title":"07-synthetic-material","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Bearing replacement","sort_order":10}],"tasks":[{"uid":2,"name":"Remove old bearings","phase_uid":1,"parent_uid":null,"start_date":"2026-10-26","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"Fit new bearings","phase_uid":1,"parent_uid":null,"start_date":"2026-10-28","end_date":"2026-10-28","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[{"pred_uid":2,"link_type":"FS","lag_days":0}]}],"resources":[{"uid":1,"name":"Technician","kind":"work","materialLike":false,"materialLabel":null},{"uid":2,"name":"Bearing set","kind":"material","materialLike":true,"materialLabel":"set"}],"assignments":[{"taskUid":2,"resourceUid":1,"units":1,"workHours":16},{"taskUid":3,"resourceUid":1,"units":1,"workHours":8},{"taskUid":3,"resourceUid":2,"units":null,"workHours":null}],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1},{"code":"resource-rates-dropped","message":"Resource rates were not imported.","count":2},{"code":"material-resource","message":"Material resources are not imported as quantities; they were kept by name only.","count":1},{"code":"material-quantity-dropped","message":"Quantities on material-like resources were not trusted and were dropped.","count":1}]}$j$::jsonb, NULL);
INSERT INTO t_payloads VALUES ('own04', $j${"project":{"uid":"b1000000-0000-0000-0000-0000000e00f1","manager":"BTR","name":"04-hierarchy-deep","title":"04-hierarchy-deep","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Project","sort_order":10}],"tasks":[{"uid":2,"name":"Phase A","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"WP1","phase_uid":1,"parent_uid":2,"start_date":"2026-10-21","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[]},{"uid":4,"name":"Renamed in ProjectLibre","phase_uid":1,"parent_uid":3,"start_date":"2026-10-21","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[]},{"uid":5,"name":"Task A2","phase_uid":1,"parent_uid":3,"start_date":"2026-10-23","end_date":"2026-10-27","progress":55,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"WP2","phase_uid":1,"parent_uid":2,"start_date":"2026-10-28","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[]},{"uid":7,"name":"Task B1","phase_uid":1,"parent_uid":6,"start_date":"2026-10-28","end_date":"2026-10-29","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Task B2","phase_uid":1,"parent_uid":6,"start_date":"2026-10-30","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Phase B","phase_uid":1,"parent_uid":null,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[]},{"uid":10,"name":"WP3","phase_uid":1,"parent_uid":9,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":90,"links":[]},{"uid":11,"name":"Task C1","phase_uid":1,"parent_uid":10,"start_date":"2026-11-04","end_date":"2026-11-05","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":100,"links":[{"pred_uid":8,"link_type":"FS","lag_days":0}]},{"uid":9999,"name":"Added in ProjectLibre","phase_uid":1,"parent_uid":null,"start_date":"2026-12-01","end_date":"2026-12-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":900,"links":[]}],"resources":[],"assignments":[],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, $j${"job":"b1000000-0000-0000-0000-0000000e00f1","base_tasks":11,"base_phases":1,"expect":{"created":1,"updated":2,"kept":1,"skipped":9}}$j$::jsonb);
INSERT INTO t_payloads VALUES ('ro04', $j${"project":{"uid":"b1000000-0000-0000-0000-0000000e00f1","manager":"meridian-readonly-export","name":"04-hierarchy-deep","title":"04-hierarchy-deep","minutesPerDay":480,"calendar":"working-days","saveVersion":14},"phases":[{"uid":1,"name":"Project","sort_order":10}],"tasks":[{"uid":2,"name":"Phase A","phase_uid":1,"parent_uid":null,"start_date":"2026-10-21","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":10,"links":[]},{"uid":3,"name":"WP1","phase_uid":1,"parent_uid":2,"start_date":"2026-10-21","end_date":"2026-10-27","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":20,"links":[]},{"uid":4,"name":"Renamed in ProjectLibre","phase_uid":1,"parent_uid":3,"start_date":"2026-10-21","end_date":"2026-10-22","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":30,"links":[]},{"uid":5,"name":"Task A2","phase_uid":1,"parent_uid":3,"start_date":"2026-10-23","end_date":"2026-10-27","progress":55,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":40,"links":[{"pred_uid":4,"link_type":"FS","lag_days":0}]},{"uid":6,"name":"WP2","phase_uid":1,"parent_uid":2,"start_date":"2026-10-28","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":50,"links":[]},{"uid":7,"name":"Task B1","phase_uid":1,"parent_uid":6,"start_date":"2026-10-28","end_date":"2026-10-29","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":60,"links":[{"pred_uid":5,"link_type":"FS","lag_days":0}]},{"uid":8,"name":"Task B2","phase_uid":1,"parent_uid":6,"start_date":"2026-10-30","end_date":"2026-11-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":70,"links":[{"pred_uid":7,"link_type":"FS","lag_days":0}]},{"uid":9,"name":"Phase B","phase_uid":1,"parent_uid":null,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":80,"links":[]},{"uid":10,"name":"WP3","phase_uid":1,"parent_uid":9,"start_date":"2026-11-04","end_date":"2026-11-10","progress":0,"is_milestone":false,"is_summary":true,"baseline_start":null,"baseline_end":null,"sort_order":90,"links":[]},{"uid":11,"name":"Task C1","phase_uid":1,"parent_uid":10,"start_date":"2026-11-04","end_date":"2026-11-05","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":100,"links":[{"pred_uid":8,"link_type":"FS","lag_days":0}]},{"uid":9999,"name":"Added in ProjectLibre","phase_uid":1,"parent_uid":null,"start_date":"2026-12-01","end_date":"2026-12-03","progress":0,"is_milestone":false,"is_summary":false,"baseline_start":null,"baseline_end":null,"sort_order":900,"links":[]}],"resources":[],"assignments":[],"warnings":[{"code":"calendar-working-days","message":"The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.","count":1}]}$j$::jsonb, NULL);
-- END GENERATED PAYLOADS

-- ===== 1. structure and exposure =====
DO $$
DECLARE f text;
BEGIN
  PERFORM t_expect('struct: import_job_schedule is SECURITY DEFINER with a pinned search_path',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'import_job_schedule' AND prosecdef
       AND array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%'), '1');
  PERFORM t_expect('struct: owned by the owner of lock_job_baseline (baseline guard owner rule)',
    (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE proname = 'import_job_schedule'),
    (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE proname = 'lock_job_baseline'));
  PERFORM t_expect('struct: returns jsonb', (SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = 'import_job_schedule'), 'jsonb');
  PERFORM t_expect('struct: the RPC is the only new definer function',
    (SELECT string_agg(proname, ',' ORDER BY proname) FROM pg_proc WHERE proname LIKE 'import%' AND prosecdef), 'import_job_schedule');
  PERFORM t_expect('struct: six helpers plus warn are SECURITY INVOKER with pinned search_path',
    (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'import\_sched\_%' AND NOT prosecdef AND array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%'), '7');
  PERFORM t_expect('struct: no dynamic SQL anywhere in the import code',
    (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'import%' AND prosrc ~* '\mexecute\M'), '0');
  PERFORM t_expect('struct: the baseline guard trigger and lock_job_baseline are untouched',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'job_tasks_baseline_guard' AND tgrelid = 'public.job_tasks'::regclass), '1');
  PERFORM t_expect('exposure: anon cannot execute the RPC', has_function_privilege('anon', 'public.import_job_schedule(uuid,text,jsonb,text)', 'EXECUTE')::text, 'false');
  PERFORM t_expect('exposure: authenticated can execute the RPC', has_function_privilege('authenticated', 'public.import_job_schedule(uuid,text,jsonb,text)', 'EXECUTE')::text, 'true');
  PERFORM t_expect('exposure: PUBLIC has no EXECUTE on the RPC',
    (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname = 'import_job_schedule' AND a.grantee = 0), '0');
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p WHERE p.proname LIKE 'import\_sched\_%' LOOP
    PERFORM t_expect('exposure: helper not executable by anon ' || f, has_function_privilege('anon', f, 'EXECUTE')::text, 'false');
    PERFORM t_expect('exposure: helper not executable by authenticated ' || f, has_function_privilege('authenticated', f, 'EXECUTE')::text, 'false');
    PERFORM t_expect('exposure: helper has no PUBLIC EXECUTE ' || f, (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = f::regprocedure AND a.grantee = 0), '0');
  END LOOP;
  PERFORM t_expect('exposure: anon really gets 42501 calling the RPC',
    t_val('anon', NULL, 'SELECT import_job_schedule(''b1000000-0000-0000-0000-000000000001''::uuid, ''append'', ''{}''::jsonb)::text'), 'err:42501');
  PERFORM t_expect('exposure: authenticated really gets 42501 calling a helper',
    t_val('authenticated', t_u('ops'), 'SELECT import_sched_clean(''x'')'), 'err:42501');
  PERFORM t_expect('exposure: authenticated cannot read the working tables or call has_atom',
    t_val('authenticated', t_u('ops'), 'SELECT import_sched_has_atom(''c1000000-0000-0000-0000-000000000001'', ''ops:work-orders:write'')::text'), 'err:42501');
END $$;

-- ===== 2. authorisation matrix =====
DO $$
DECLARE
  ja uuid := t_job(1); jc2 uuid := t_job(2, 2); res text; p jsonb;
BEGIN
  p := t_pl(jsonb_build_array(t_ph(1, 'Phase')), jsonb_build_array(t_tk(2, 'A', 1), t_tk(3, 'B', 1, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(2)))), ja);
  PERFORM t_expect('auth: anon refused', t_val('anon', NULL, format('SELECT import_job_schedule(%L, ''append'', %L::jsonb)::text', ja, p::text)), 'err:42501');
  PERFORM t_expect('auth: client-shaped login (no erp_users row) gets job not found', t_imp('authenticated', t_u('clnt'), ja, 'append', p), 'job not found');
  PERFORM t_expect('auth: inactive user gets job not found', t_imp('authenticated', t_u('gone'), ja, 'append', p), 'job not found');
  PERFORM t_expect('auth: other company approver gets job not found (cross-company job refused)', t_imp('authenticated', t_u('ops2'), ja, 'append', p), 'job not found');
  PERFORM t_expect('auth: other company approver cannot replace either', t_imp('authenticated', t_u('ops2'), ja, 'replace', p, 'because'), 'job not found');
  PERFORM t_expect('auth: viewer refused', t_imp('authenticated', t_u('viewr'), ja, 'append', p), 'permission denied: ops:work-orders:write required');
  PERFORM t_expect('auth: finance role refused', t_imp('authenticated', t_u('fin'), ja, 'append', p), 'permission denied: ops:work-orders:write required');
  PERFORM t_expect('auth: write in company 1 does not carry into a company 2 job (atoms are company scoped)',
    t_imp('authenticated', t_u('mix'), jc2, 'append', t_pl(jsonb_build_array(t_ph(1, 'Phase')), '[]', jc2)), 'permission denied: ops:work-orders:write required');
  PERFORM t_expect('auth: the company 2 approver may import into its own job',
    left(t_imp('authenticated', t_u('ops2'), jc2, 'append', t_pl(jsonb_build_array(t_ph(1, 'Phase')), '[]', jc2)), 3), 'ok:');
  PERFORM t_expect('auth: NULL job', t_msg('authenticated', t_u('ops'), 'SELECT import_job_schedule(NULL, ''append'', ''{}''::jsonb)::text'), 'job not found');
  PERFORM t_expect('auth: unknown job', t_imp('authenticated', t_u('ops'), 'aaaaaaaa-0000-0000-0000-000000000000', 'append', p), 'job not found');
  PERFORM t_expect('auth: NULL mode', t_msg('authenticated', t_u('ops'), format('SELECT import_job_schedule(%L, NULL, %L::jsonb)::text', ja, p::text)), 'invalid import mode');
  PERFORM t_expect('auth: unknown mode', t_imp('authenticated', t_u('ops'), ja, 'upsert', p), 'invalid import mode');
  PERFORM t_expect('auth: upper-case mode is not a mode', t_imp('authenticated', t_u('ops'), ja, 'APPEND', p), 'invalid import mode');
  PERFORM t_expect('auth: nothing was written by any refusal', t_state(ja) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = ja), '0/0/0|0');
  PERFORM t_expect('auth: writer (no approve) can append', left(t_imp('authenticated', t_u('wrt'), ja, 'append', p), 3), 'ok:');
  PERFORM t_expect('auth: the append landed', t_state(ja), '1/2/1');
  PERFORM t_expect('auth: mixed user can import into the company 1 job where they hold the atoms',
    left(t_imp('authenticated', t_u('mix'), t_job(3), 'append', t_pl(jsonb_build_array(t_ph(1, 'Phase')), '[]', NULL)), 3), 'ok:');
END $$;

-- ===== 3. append, merge and the writer limits =====
DO $$
DECLARE
  ja uuid := t_job(10); res text; p jsonb; ps int; sv int; dv int; lv int; vid uuid;
BEGIN
  p := t_pl(jsonb_build_array(t_ph(1, 'Assess')),
            jsonb_build_array(t_tk(2, 'Survey', 1), t_tk(3, 'Design', 1, NULL, '2026-05-06', '2026-05-10', jsonb_build_array(t_lk(2, 'FS', 2))), t_tk(4, 'Loose')), ja);
  res := t_imp('authenticated', t_u('wrt'), ja, 'append', p);
  PERFORM t_expect('append: result counts', t_res(res, 'created') || '/' || t_res(res, 'updated') || '/' || t_res(res, 'kept') || '/' || t_res(res, 'skipped'), '4/0/0/0');
  PERFORM t_expect('append: rows and link', t_state(ja), '1/3/1');
  PERFORM t_expect('append: imported rows are never client visible',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = ja AND client_visible) || (SELECT count(*)::text FROM job_phases WHERE job_id = ja AND client_visible), '00');
  PERFORM t_expect('append: msp_uid from one shared counter: phase 1 then tasks 2..4, none is 0',
    (SELECT string_agg(u::text, ',' ORDER BY u) FROM (SELECT msp_uid u FROM job_phases WHERE job_id = ja UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id = ja) s), '1,2,3,4');
  PERFORM t_expect('append: phase membership kept', (SELECT count(*)::text FROM job_tasks t JOIN job_phases p ON p.id = t.phase_id WHERE t.job_id = ja AND p.name = 'Assess'), '2');
  PERFORM t_expect('append: link type, lag and depends_on mirror',
    (SELECT l.link_type || l.lag_days || (t.depends_on = l.predecessor_id)::text FROM job_task_links l JOIN job_tasks t ON t.id = l.task_id WHERE l.job_id = ja), 'FS2true');
  PERFORM t_expect('append: audit row schedule_imported with metadata',
    (SELECT metadata ->> 'mode' || '|' || (metadata ->> 'file_name') || '|' || (metadata ->> 'created') || '|' || username || '|' || user_id::text
       FROM job_audit_log WHERE job_id = ja AND action_type = 'schedule_imported'), 'append|test.xml|4|writer C1|' || t_u('wrt')::text);
  PERFORM t_expect('append: no baseline_locked row for a file without baselines', (SELECT count(*)::text FROM job_audit_log WHERE job_id = ja AND action_type = 'baseline_locked'), '0');
  PERFORM t_expect('append: the advisory lock on the job key was taken (shared with prepare_schedule_export)',
    (SELECT count(*)::text FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()
       AND mod(hashtext(ja::text)::numeric + 18446744073709551616, 18446744073709551616) = classid::bigint::numeric * 4294967296 + objid::bigint::numeric), '1');
  -- a second append adds again; the counter never reuses a uid
  res := t_imp('authenticated', t_u('wrt'), ja, 'append', t_pl(jsonb_build_array(t_ph(1, 'Assess 2')), jsonb_build_array(t_tk(2, 'Survey 2', 1)), ja));
  PERFORM t_expect('append twice: created 2, existing 4 rows kept', t_res(res, 'created') || '/' || t_res(res, 'kept'), '2/4');
  PERFORM t_expect('append twice: uids continue 5,6 and stay unique',
    (SELECT string_agg(u::text, ',' ORDER BY u) FROM (SELECT msp_uid u FROM job_phases WHERE job_id = ja UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id = ja) s), '1,2,3,4,5,6');

  -- merge: stored uids
  SELECT msp_uid INTO sv FROM job_tasks WHERE job_id = ja AND task_name = 'Survey';
  SELECT msp_uid INTO dv FROM job_tasks WHERE job_id = ja AND task_name = 'Design';
  SELECT msp_uid INTO ps FROM job_phases WHERE job_id = ja AND name = 'Assess';
  -- a Meridian-only row and two published rows (inserted as postgres: the publish exemption applies to migrations/backfills)
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, client_visible) VALUES ('c1000000-0000-0000-0000-000000000001', ja, 99, 'Meridian only', false);
  UPDATE job_tasks SET client_visible = true WHERE job_id = ja AND task_name IN ('Survey', 'Design');
  DELETE FROM job_audit_log WHERE job_id = ja AND action_type = 'visibility_changed';
  p := jsonb_build_object('project_uid', upper(ja::text), 'file_name', 'back.xml', 'based_on', t_based(ja),
    'phases', jsonb_build_array(t_ph(ps, 'Assess', 10)),
    'tasks', jsonb_build_array(t_tk(sv, 'Survey v2', ps), t_tk(dv, 'Design', ps, NULL, '2026-05-07', '2026-05-12', jsonb_build_array(t_lk(sv, 'FS', 2))) || '{"progress":40}',
                               t_tk(500, 'Meridian only', NULL)));
  PERFORM t_expect('merge: writer refused a foreign file (other project uid)',
    t_imp('authenticated', t_u('wrt'), ja, 'merge', p || jsonb_build_object('project_uid', 'b1000000-0000-0000-0000-00000000ffff')),
    'merge requires a file exported from this job (use append, or replace as an approver)');
  PERFORM t_expect('merge: a file with no project uid is foreign', t_imp('authenticated', t_u('wrt'), ja, 'merge', p - 'project_uid'),
    'merge requires a file exported from this job (use append, or replace as an approver)');
  PERFORM t_expect('merge: temporary_uids flag makes it foreign (approver too)', t_imp('authenticated', t_u('ops'), ja, 'merge', p || '{"temporary_uids":true}'),
    'merge requires a file exported from this job (use append, or replace as an approver)');
  PERFORM t_expect('merge: the read-only export marker in project.manager makes it foreign',
    t_imp('authenticated', t_u('ops'), ja, 'merge', (p - 'project_uid') || jsonb_build_object('project', jsonb_build_object('uid', ja::text, 'manager', 'meridian-readonly-export'))),
    'merge requires a file exported from this job (use append, or replace as an approver)');
  PERFORM t_expect('merge: project.uid (the codec field) is accepted in place of project_uid',
    left(t_imp('authenticated', t_u('wrt'), ja, 'merge', (p - 'project_uid') || jsonb_build_object('project', jsonb_build_object('uid', ja::text))), 3), 'ok:');
  -- that merge applied the edits already: restore the starting state so the numbers below are about one clean merge
  UPDATE job_tasks SET task_name = 'Survey', client_visible = true WHERE job_id = ja AND task_name = 'Survey v2';
  UPDATE job_tasks SET task_name = 'Design', progress = 0, start_date = '2026-05-06', end_date = '2026-05-10', client_visible = true, is_critical = true WHERE job_id = ja AND msp_uid = dv;
  DELETE FROM job_tasks WHERE job_id = ja AND msp_uid > 6;
  DELETE FROM job_audit_log WHERE job_id = ja AND action_type = 'visibility_changed';
  p := p || jsonb_build_object('based_on', t_based(ja));
  PERFORM t_expect('merge: project.uid and project_uid that disagree are refused',
    left(t_imp('authenticated', t_u('wrt'), ja, 'merge', p || jsonb_build_object('project', jsonb_build_object('uid', 'b1000000-0000-0000-0000-00000000ffff'))), 15), 'invalid payload');
  res := t_imp('authenticated', t_u('wrt'), ja, 'merge', p);
  PERFORM t_expect('merge: result 1 created, 2 updated, kept = rows not matched, skipped = matched but unchanged',
    t_res(res, 'created') || '/' || t_res(res, 'updated') || '/' || t_res(res, 'kept') || '/' || t_res(res, 'skipped'), '1/2/4/1');
  PERFORM t_expect('merge: the Meridian-only row is kept untouched', (SELECT task_name || (msp_uid IS NULL)::text || client_visible::text FROM job_tasks WHERE job_id = ja AND task_name = 'Meridian only' AND msp_uid IS NULL), 'Meridian onlytruefalse');
  PERFORM t_expect('merge: a same-named row with another uid is NOT matched (only msp_uid matches): two rows now',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = ja AND task_name = 'Meridian only'), '2');
  PERFORM t_expect('merge: rows absent from the file are kept (Loose and the second Assess phase tasks)', (SELECT count(*)::text FROM job_tasks WHERE job_id = ja AND task_name IN ('Loose', 'Survey 2')), '2');
  PERFORM t_expect('merge: edited name arrived and fields updated', (SELECT task_name || '|' || progress || '|' || start_date FROM job_tasks WHERE job_id = ja AND msp_uid = dv), 'Design|40|2026-05-07');
  PERFORM t_expect('merge: is_critical is cleared on an updated row (recomputed by the next UI save)', (SELECT is_critical::text FROM job_tasks WHERE job_id = ja AND msp_uid = dv), 'false');
  PERFORM t_expect('merge: a published task whose name changed is auto-unpublished',
    (SELECT task_name || client_visible::text FROM job_tasks WHERE job_id = ja AND msp_uid = sv), 'Survey v2false');
  PERFORM t_expect('merge: a published task edited in dates/progress only stays published',
    (SELECT client_visible::text FROM job_tasks WHERE job_id = ja AND msp_uid = dv), 'true');
  PERFORM t_expect('merge: the guard wrote one visibility_changed audit row (wording_edited)',
    (SELECT count(*)::text || '|' || min(metadata ->> 'reason') FROM job_audit_log WHERE job_id = ja AND action_type = 'visibility_changed'), '1|wording_edited');
  PERFORM t_expect('merge: new row is unpublished and got the next uid from the counter',
    (SELECT client_visible::text || msp_uid FROM job_tasks WHERE job_id = ja AND msp_uid > 6), 'false7');
  PERFORM t_expect('merge: the unchanged link was not rewritten and the link count is the same', t_state(ja), '2/6/1');
  PERFORM t_expect('merge: audit row says merge with its counts',
    (SELECT metadata ->> 'mode' || '|' || (metadata ->> 'created') || '|' || (metadata ->> 'updated') || '|' || (metadata ->> 'kept') || '|' || (metadata ->> 'skipped')
       FROM job_audit_log WHERE job_id = ja AND action_type = 'schedule_imported' AND metadata ->> 'file_name' = 'back.xml' ORDER BY created_at DESC, id LIMIT 1), 'merge|1|2|4|1');
  -- merge rewrites an existing link's type/lag and never deletes one
  p := jsonb_build_object('project_uid', ja::text, 'based_on', t_based(ja), 'phases', jsonb_build_array(t_ph(ps, 'Assess', 10)),
    'tasks', jsonb_build_array(t_tk(sv, 'Survey v2', ps), t_tk(dv, 'Design', ps, NULL, '2026-05-07', '2026-05-12', jsonb_build_array(t_lk(sv, 'SS', -3))) || '{"progress":40}'));
  res := t_imp('authenticated', t_u('wrt'), ja, 'merge', p);
  PERFORM t_expect('merge: second merge ok', left(res, 3), 'ok:');
  PERFORM t_expect('merge: the link took the new type and lag; depends_on cleared because the first link is not FS',
    (SELECT l.link_type || l.lag_days || (t.depends_on IS NULL)::text FROM job_task_links l JOIN job_tasks t ON t.id = l.task_id WHERE l.job_id = ja), 'SS-3true');
  PERFORM t_expect('merge: matched tasks keep their phase', (SELECT count(*)::text FROM job_tasks WHERE job_id = ja AND msp_uid IN (sv, dv) AND phase_id IS NOT NULL), '2');
  -- limits of the writer
  PERFORM t_expect('writer cannot replace', t_imp('authenticated', t_u('wrt'), ja, 'replace', t_pl('[]', jsonb_build_array(t_tk(1, 'x')), ja), 'reason'), 'permission denied: ops:work-orders:approve required for replace');
  PERFORM t_expect('writer cannot replace (nothing happened)', t_state(ja), '2/6/1');
  -- kind mismatch: a payload PHASE whose uid is a stored TASK uid is added as a new row, with a warning
  vid := (SELECT id FROM job_tasks WHERE job_id = ja AND msp_uid = sv);
  res := t_imp('authenticated', t_u('wrt'), ja, 'merge', jsonb_build_object('project_uid', ja::text, 'based_on', t_based(ja), 'phases', jsonb_build_array(t_ph(sv, 'Became a phase')), 'tasks', '[]'::jsonb));
  PERFORM t_expect('merge: uid kind mismatch creates a row and warns', t_res(res, 'created') || '|' || t_warn(res, 'uid-kind-changed'), '1|1');
  PERFORM t_expect('merge: the task with that uid was not touched', (SELECT task_name FROM job_tasks WHERE id = vid), 'Survey v2');
END $$;

DO $$
DECLARE jc2 uuid := t_job(11, 2); ja uuid := t_job(12); res text; before_name text;
BEGIN
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, msp_uid) VALUES ('c2000000-0000-0000-0000-000000000002', jc2, 1, 'C2 secret', 1);
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, msp_uid) VALUES ('c1000000-0000-0000-0000-000000000001', ja, 1, 'C1 row', 1);
  res := t_imp('authenticated', t_u('ops'), ja, 'merge', jsonb_build_object('project_uid', ja::text, 'based_on', t_based(ja), 'phases', '[]'::jsonb,
    'tasks', jsonb_build_array(t_tk(1, 'Hacked name'))));
  PERFORM t_expect('xco: own row with uid 1 updated', (SELECT task_name FROM job_tasks WHERE job_id = ja), 'Hacked name');
  PERFORM t_expect('xco: other company row with the same uid untouched', (SELECT task_name FROM job_tasks WHERE job_id = jc2), 'C2 secret');
  PERFORM t_expect('xco: importing into the other company job by guessing its id is refused',
    t_imp('authenticated', t_u('ops'), jc2, 'merge', jsonb_build_object('project_uid', jc2::text, 'phases', '[]'::jsonb, 'tasks', jsonb_build_array(t_tk(1, 'pwn')))), 'job not found');
  PERFORM t_expect('xco: other company row still untouched', (SELECT task_name FROM job_tasks WHERE job_id = jc2), 'C2 secret');
END $$;

-- ===== 4. replace =====
DO $$
DECLARE
  jb uuid := t_job(20); res text; p jsonb; oldmax int; r1 text; vid uuid;
BEGIN
  -- the starting schedule is made by an approver with baselines
  p := t_pl(jsonb_build_array(t_ph(1, 'Old phase')),
            jsonb_build_array(t_tk(2, 'Old A', 1) || '{"baseline_start":"2026-05-01","baseline_end":"2026-05-05"}', t_tk(3, 'Old B', 1, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(2))), t_tk(4, 'Old C', NULL, NULL, '2026-05-10', '2026-05-12', jsonb_build_array(t_lk(3, 'FF', 1)))), jb);
  res := t_imp('authenticated', t_u('ops'), jb, 'append', p);
  PERFORM t_expect('replace setup: approver append with a baseline', t_res(res, 'created'), '4');
  UPDATE job_tasks SET client_visible = true WHERE job_id = jb AND task_name = 'Old B';
  PERFORM t_expect('replace setup: state', t_state(jb), '1/3/2');
  SELECT max(m) INTO oldmax FROM (SELECT max(msp_uid) m FROM job_tasks WHERE job_id = jb UNION ALL SELECT max(msp_uid) FROM job_phases WHERE job_id = jb) s;
  p := t_pl(jsonb_build_array(t_ph(1, 'New phase')), jsonb_build_array(t_tk(2, 'New A', 1) || '{"baseline_start":"2026-06-01","baseline_end":"2026-06-05"}', t_tk(3, 'New B', 1)), jb);
  PERFORM t_expect('replace: viewer refused', t_imp('authenticated', t_u('viewr'), jb, 'replace', p, 'x'), 'permission denied: ops:work-orders:write required');
  PERFORM t_expect('replace: writer without approve refused (even with a reason)', t_imp('authenticated', t_u('wrt'), jb, 'replace', p, 'a real reason'), 'permission denied: ops:work-orders:approve required for replace');
  PERFORM t_expect('replace: approver without a reason refused', t_imp('authenticated', t_u('ops'), jb, 'replace', p), 'replace requires a reason');
  PERFORM t_expect('replace: empty reason refused', t_imp('authenticated', t_u('ops'), jb, 'replace', p, ''), 'replace requires a reason');
  PERFORM t_expect('replace: blank reason refused', t_imp('authenticated', t_u('ops'), jb, 'replace', p, '   '), 'replace requires a reason');
  PERFORM t_expect('replace: a reason of only control characters is blank', t_imp('authenticated', t_u('ops'), jb, 'replace', p, chr(1) || chr(10) || chr(9)), 'replace requires a reason');
  PERFORM t_expect('replace: refusals changed nothing', t_state(jb) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = jb AND action_type = 'schedule_imported'), '1/3/2|1');
  PERFORM t_expect('replace: a stale preview is refused too', t_imp('authenticated', t_u('ops'), jb, 'replace', p || '{"based_on":"2020-01-01T00:00:00Z"}', 'why'), 'schedule changed since preview');
  PERFORM t_expect('replace: still nothing changed', t_state(jb), '1/3/2');
  res := t_imp('authenticated', t_u('cadm'), jb, 'replace', p, 'client sent a new programme');
  PERFORM t_expect('replace: company_admin (approver) with a reason succeeds', t_res(res, 'created') || '/' || t_res(res, 'kept'), '3/0');
  PERFORM t_expect('replace: the old schedule is gone, the new one is there', t_state(jb) || '|' || (SELECT string_agg(task_name, ',' ORDER BY msp_uid) FROM job_tasks WHERE job_id = jb), '1/2/0|New A,New B');
  PERFORM t_expect('replace: no old row id survived', (SELECT count(*)::text FROM job_tasks WHERE job_id = jb AND task_name LIKE 'Old%'), '0');
  PERFORM t_expect('replace: new uids continue after the old maximum (never reused)',
    (SELECT min(m)::text FROM (SELECT msp_uid m FROM job_tasks WHERE job_id = jb UNION ALL SELECT msp_uid FROM job_phases WHERE job_id = jb) s), (oldmax + 1)::text);
  PERFORM t_expect('replace: imported rows are unpublished', (SELECT count(*)::text FROM job_tasks WHERE job_id = jb AND client_visible), '0');
  PERFORM t_expect('replace: recovery metadata holds the old ids and names',
    (SELECT jsonb_array_length(metadata -> 'recovery' -> 'phases') || '/' || jsonb_array_length(metadata -> 'recovery' -> 'tasks') || '/' || jsonb_array_length(metadata -> 'recovery' -> 'links')
            || '|' || (metadata -> 'recovery' -> 'phases' -> 0 ->> 1) || '|' || (SELECT string_agg(x ->> 1, ',' ORDER BY x ->> 1) FROM jsonb_array_elements(metadata -> 'recovery' -> 'tasks') x)
       FROM job_audit_log WHERE job_id = jb AND action_type = 'schedule_imported' AND metadata ->> 'mode' = 'replace'), '1/3/2|Old phase|Old A,Old B,Old C');
  PERFORM t_expect('replace: recovery ids are the real old row ids and keep the published flag',
    (SELECT (jsonb_typeof(x -> 0) = 'string' AND (x -> 5)::text = 'true')::text FROM (SELECT t.x FROM job_audit_log a, jsonb_array_elements(a.metadata -> 'recovery' -> 'tasks') t(x) WHERE a.job_id = jb AND a.action_type = 'schedule_imported' AND a.metadata ->> 'mode' = 'replace' AND t.x ->> 1 = 'Old B') s), 'true');
  PERFORM t_expect('replace: audit says what was deleted, the reason and the file',
    (SELECT (metadata -> 'deleted' ->> 'phases') || (metadata -> 'deleted' ->> 'tasks') || (metadata -> 'deleted' ->> 'links') || '|' || (metadata ->> 'reason') || '|' || (metadata ->> 'file_name')
       FROM job_audit_log WHERE job_id = jb AND action_type = 'schedule_imported' AND metadata ->> 'mode' = 'replace'), '132|client sent a new programme|test.xml');
  PERFORM t_expect('replace: an append audit row has no recovery and no deleted counts',
    (SELECT (metadata -> 'recovery' = 'null'::jsonb)::text || (metadata -> 'deleted' = 'null'::jsonb)::text FROM job_audit_log WHERE job_id = jb AND action_type = 'schedule_imported' AND metadata ->> 'mode' = 'append'), 'truetrue');
  PERFORM t_expect('replace: a baseline in the file is written in replace mode (approver)', (SELECT baseline_start::text FROM job_tasks WHERE job_id = jb AND task_name = 'New A'), '2026-06-01');
  PERFORM t_expect('replace: two baseline_locked rows now (first import, replace)', (SELECT count(*)::text FROM job_audit_log WHERE job_id = jb AND action_type = 'baseline_locked'), '2');
END $$;

-- ===== 5. baseline rules =====
DO $$
DECLARE
  jc uuid := t_job(30); jd uuid := t_job(31); res text; p jsonb; bl jsonb := '{"baseline_start":"2026-05-01","baseline_end":"2026-05-05"}';
BEGIN
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'W1') || bl, t_tk(2, 'W2') || bl), jd);
  res := t_imp('authenticated', t_u('wrt'), jd, 'append', p);
  PERFORM t_expect('baseline: a writer file imports but its baselines are dropped with a warning', t_res(res, 'created') || '|' || t_warn(res, 'baseline-ignored'), '2|2');
  PERFORM t_expect('baseline: no baseline column was written for the writer',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = jd AND (baseline_start IS NOT NULL OR baseline_end IS NOT NULL OR baseline_locked_at IS NOT NULL)), '0');
  PERFORM t_expect('baseline: no baseline_locked audit row for the writer', (SELECT count(*)::text FROM job_audit_log WHERE job_id = jd AND action_type = 'baseline_locked'), '0');
  -- approver
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'A1') || bl, t_tk(2, 'A2') || bl, t_tk(3, 'A3') || '{"baseline_start":"2026-05-01"}', t_tk(4, 'A4')), jc);
  res := t_imp('authenticated', t_u('ops'), jc, 'append', p);
  PERFORM t_expect('baseline: approver file writes complete baselines only (partial one ignored with a warning)',
    t_res(res, 'created') || '|' || t_warn(res, 'baseline-incomplete') || '|' || t_warn(res, 'baseline-ignored'), '4|1|none');
  PERFORM t_expect('baseline: two rows carry baseline dates and a lock time',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = jc AND baseline_start = '2026-05-01' AND baseline_end = '2026-05-05' AND baseline_locked_at IS NOT NULL), '2');
  PERFORM t_expect('baseline: the partial and the absent baselines were not written', (SELECT count(*)::text FROM job_tasks WHERE job_id = jc AND baseline_start IS NULL AND baseline_locked_at IS NULL), '2');
  PERFORM t_expect('baseline: audit row baseline_locked records tasks and the import file name',
    (SELECT (metadata ->> 'tasks') || '|' || (metadata ->> 'file_name') || '|' || (metadata ->> 'source') || '|' || username FROM job_audit_log WHERE job_id = jc AND action_type = 'baseline_locked'), '2|test.xml|import|ops C1');
  PERFORM t_expect('baseline: the setting is switched off again after the write', coalesce(current_setting('app.baseline_rpc', true), 'unset'), 'off');
  -- with a locked baseline: append and merge drop baselines; replace may re-lock
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'B1') || bl, t_tk(2, 'B2') || bl), jc);
  res := t_imp('authenticated', t_u('ops'), jc, 'append', p);
  PERFORM t_expect('baseline: append on a job with a locked baseline ignores baselines', t_res(res, 'created') || '|' || t_warn(res, 'baseline-ignored'), '2|2');
  PERFORM t_expect('baseline: still only the two original baseline rows', (SELECT count(*)::text FROM job_tasks WHERE job_id = jc AND baseline_locked_at IS NOT NULL), '2');
  res := t_imp('authenticated', t_u('ops'), jc, 'merge', jsonb_build_object('project_uid', jc::text, 'based_on', t_based(jc), 'phases', '[]'::jsonb,
         'tasks', jsonb_build_array(t_tk((SELECT msp_uid FROM job_tasks WHERE job_id = jc AND task_name = 'A4'), 'A4') || '{"baseline_start":"2026-07-01","baseline_end":"2026-07-09"}')));
  PERFORM t_expect('baseline: merge on a job with a locked baseline ignores baselines', t_warn(res, 'baseline-ignored') || '|' || (SELECT count(*)::text FROM job_tasks WHERE job_id = jc AND baseline_start = '2026-07-01'), '1|0');
  res := t_imp('authenticated', t_u('ops'), jd, 'merge', jsonb_build_object('project_uid', jd::text, 'based_on', t_based(jd), 'phases', '[]'::jsonb,
    'tasks', jsonb_build_array(t_tk((SELECT msp_uid FROM job_tasks WHERE job_id = jd AND task_name = 'W1'), 'W1') || bl)));
  PERFORM t_expect('baseline: a baseline can be written by merge when none is locked yet', t_warn(res, 'baseline-ignored') || '|' || (SELECT count(*)::text FROM job_tasks WHERE job_id = jd AND baseline_locked_at IS NOT NULL), 'none|1');
  -- the guard stays shut for everyone else, before and after
  PERFORM t_expect('baseline: direct UPDATE of baseline columns by authenticated is still blocked after an import',
    t_dml('authenticated', t_u('ops'), format('UPDATE job_tasks SET baseline_start = ''2026-01-01'', baseline_end = ''2026-01-31'' WHERE job_id = %L', jc)), 'err:P0001');
  PERFORM t_expect('baseline: direct UPDATE as the table owner is blocked too (setting is off, not left on)',
    t_dml('postgres', NULL, format('UPDATE job_tasks SET baseline_start = ''2026-01-01'', baseline_end = ''2026-01-31'' WHERE job_id = %L', jc)), 'err:P0001');
  PERFORM t_expect('baseline: direct INSERT with a baseline is still blocked for authenticated',
    t_dml('authenticated', t_u('ops'), format('INSERT INTO job_tasks (company_id, job_id, task_name, baseline_start) VALUES (''c1000000-0000-0000-0000-000000000001'', %L, ''x'', ''2026-01-01'')', jc)), 'err:P0001');
  PERFORM t_expect('baseline: lock_job_baseline still demands a reason to re-baseline', t_msg('authenticated', t_u('ops'), format('SELECT lock_job_baseline(%L)', jc)), 're-baseline requires a reason');
  PERFORM t_expect('baseline: setting app.baseline_rpc=on as authenticated still does not open the guard',
    t_dml('authenticated', t_u('ops'), format('DO $b$ BEGIN PERFORM set_config(''app.baseline_rpc'',''on'',true); UPDATE job_tasks SET baseline_start=''2026-01-01'' WHERE job_id = %L; END $b$', jc)), 'err:P0001');
END $$;

-- the owner rule is load-bearing: the same function owned by a role that does not own lock_job_baseline cannot write a baseline
DO $$
DECLARE jo uuid := t_job(32); p jsonb; bl jsonb := '{"baseline_start":"2026-05-01","baseline_end":"2026-05-05"}'; res text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'imp_other') THEN CREATE ROLE imp_other NOLOGIN BYPASSRLS; END IF;
  GRANT ALL ON ALL TABLES IN SCHEMA public TO imp_other;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO imp_other;
  GRANT USAGE ON SCHEMA public, auth TO imp_other;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO imp_other;
  GRANT EXECUTE ON FUNCTION auth.uid() TO imp_other;
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'O1') || bl), jo);
  DROP TABLE IF EXISTS pg_temp.imp_p, pg_temp.imp_t, pg_temp.imp_l, pg_temp.imp_e, pg_temp.imp_n;   -- working tables of the earlier calls in this transaction belong to the old owner
  ALTER FUNCTION import_job_schedule(uuid, text, jsonb, text) OWNER TO imp_other;
  PERFORM t_expect('owner: a re-owned function cannot write a baseline (guard checks current_user)',
    t_imp('authenticated', t_u('ops'), jo, 'append', p), 'baseline is set only by lock_job_baseline()');
  PERFORM t_expect('owner: nothing was written by the failed call', t_state(jo), '0/0/0');
  ALTER FUNCTION import_job_schedule(uuid, text, jsonb, text) OWNER TO postgres;
  PERFORM t_expect('owner: with the right owner the same call works', left(t_imp('authenticated', t_u('ops'), jo, 'append', p), 3), 'ok:');
  PERFORM t_expect('owner: and the baseline is there', (SELECT count(*)::text FROM job_tasks WHERE job_id = jo AND baseline_locked_at IS NOT NULL), '1');
END $$;

-- ===== 6. stale preview, based_on =====
DO $$
DECLARE je uuid := t_job(40); p jsonb; res text; ms text;
BEGIN
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'S1')), je);
  PERFORM t_expect('stale: an empty job needs no based_on', left(t_imp('authenticated', t_u('ops'), je, 'append', p), 3), 'ok:');
  PERFORM t_expect('stale: a job with a schedule requires based_on',
    t_imp('authenticated', t_u('ops'), je, 'append', p - 'based_on'), 'invalid payload: based_on is required for a job that already has a schedule');
  PERFORM t_expect('stale: a null based_on is the same as none', left(t_imp('authenticated', t_u('ops'), je, 'append', p || '{"based_on":null}'), 15), 'invalid payload');
  PERFORM t_expect('stale: an old based_on is refused', t_imp('authenticated', t_u('ops'), je, 'append', p || '{"based_on":"2020-01-01T00:00:00Z"}'), 'schedule changed since preview');
  PERFORM t_expect('stale: SQLSTATE is serialization_failure so a client can re-preview',
    t_val('authenticated', t_u('ops'), format('SELECT import_job_schedule(%L, ''append'', %L::jsonb)::text', je, (p || '{"based_on":"2020-01-01T00:00:00Z"}')::text)), 'err:40001');
  PERFORM t_expect('stale: a future based_on is refused too', t_imp('authenticated', t_u('ops'), je, 'append', p || '{"based_on":"2999-01-01T00:00:00Z"}'), 'schedule changed since preview');
  PERFORM t_expect('stale: based_on that is not a timestamp is invalid', left(t_imp('authenticated', t_u('ops'), je, 'append', p || '{"based_on":"yesterday-ish"}'), 15), 'invalid payload');
  PERFORM t_expect('stale: refusals wrote nothing', t_state(je), '0/1/0');
  ms := (SELECT to_char(max(u) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') FROM (SELECT max(updated_at) u FROM job_tasks WHERE job_id = je) s);
  PERFORM t_expect('stale: a JavaScript-style millisecond timestamp matches', left(t_imp('authenticated', t_u('ops'), je, 'append', p || jsonb_build_object('based_on', ms)), 3), 'ok:');
  PERFORM t_expect('stale: an empty job refuses a based_on from a time it had rows',
    t_imp('authenticated', t_u('ops'), t_job(41), 'append', p || '{"based_on":"2026-01-01T00:00:00Z"}'), 'schedule changed since preview');
END $$;

-- ===== 7. atomicity: a failure at any point leaves zero writes =====
DO $$
DECLARE jf uuid := t_job(50); jg uuid := t_job(51); p jsonb; res text; before_state text;
BEGIN
  CREATE FUNCTION t_boom() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN IF NEW.lag_days = 77 THEN RAISE EXCEPTION 'boom'; END IF; RETURN NEW; END $f$;
  CREATE TRIGGER t_boom BEFORE INSERT ON job_task_links FOR EACH ROW EXECUTE FUNCTION t_boom();
  p := t_pl(jsonb_build_array(t_ph(1, 'Ph')), jsonb_build_array(t_tk(2, 'F1', 1), t_tk(3, 'F2', 1, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(2, 'FS', 77))), t_tk(4, 'F3')), jf);
  PERFORM t_expect('atomic: a failure after phases and tasks were inserted leaves nothing (append)', t_imp('authenticated', t_u('ops'), jf, 'append', p), 'boom');
  PERFORM t_expect('atomic: zero rows and zero audit rows', t_state(jf) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = jf), '0/0/0|0');
  -- a schedule exists; a replace that dies half way must keep it whole
  p := t_pl(jsonb_build_array(t_ph(1, 'Keep')), jsonb_build_array(t_tk(2, 'K1', 1), t_tk(3, 'K2', 1, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(2)))), jg);
  PERFORM t_expect('atomic setup', left(t_imp('authenticated', t_u('ops'), jg, 'append', p), 3), 'ok:');
  before_state := t_state(jg) || '|' || (SELECT string_agg(id::text, ',' ORDER BY id) FROM job_tasks WHERE job_id = jg) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = jg);
  p := t_pl(jsonb_build_array(t_ph(1, 'New')), jsonb_build_array(t_tk(2, 'N1', 1), t_tk(3, 'N2', 1, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(2, 'FS', 77)))), jg);
  PERFORM t_expect('atomic: a replace that fails after the delete rolls the delete back', t_imp('authenticated', t_u('ops'), jg, 'replace', p, 'why'), 'boom');
  PERFORM t_expect('atomic: the old schedule is intact (same row ids) and no audit row was added',
    t_state(jg) || '|' || (SELECT string_agg(id::text, ',' ORDER BY id) FROM job_tasks WHERE job_id = jg) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = jg), before_state);
  PERFORM t_expect('atomic: old names still there', (SELECT string_agg(task_name, ',' ORDER BY task_name) FROM job_tasks WHERE job_id = jg), 'K1,K2');
  DROP TRIGGER t_boom ON job_task_links;
  DROP FUNCTION t_boom();
END $$;

-- ===== 8. graph rules: cycles, hierarchy depth, parents =====
DO $$
DECLARE jg uuid := t_job(60); jm uuid := t_job(65); jh uuid; p jsonb; res text; ph jsonb := jsonb_build_array(t_ph(1, 'Ph')); i int; tasks jsonb;
BEGIN
  p := t_pl(ph, jsonb_build_array(t_tk(2, 'C1', 1, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(4))),
    t_tk(3, 'C2', 1, NULL, '2026-05-03', '2026-05-04', jsonb_build_array(t_lk(2))), t_tk(4, 'C3', 1, NULL, '2026-05-05', '2026-05-06', jsonb_build_array(t_lk(3)))), jg);
  PERFORM t_expect('graph: a link cycle inside the payload is rejected before any write', t_imp('authenticated', t_u('ops'), jg, 'append', p), 'dependency cycle in the imported schedule');
  PERFORM t_expect('graph: nothing written, no audit row', t_state(jg) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = jg), '0/0/0|0');
  PERFORM t_expect('graph: the same payload without the back link is fine', left(t_imp('authenticated', t_u('ops'), jg, 'append', jsonb_set(p, '{tasks,0,links}', '[]')), 3), 'ok:');
  PERFORM t_expect('graph: a self link is refused', t_imp('authenticated', t_u('ops'), t_job(61), 'append',
    t_pl('[]', jsonb_build_array(t_tk(2, 'S', NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(2)))))), 'invalid payload: a task is linked to itself');
  PERFORM t_expect('graph: a link to a missing uid is refused', t_imp('authenticated', t_u('ops'), t_job(62), 'append',
    t_pl('[]', jsonb_build_array(t_tk(2, 'S', NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(99)))))), 'invalid payload: a link refers to a missing task');
  PERFORM t_expect('graph: a link to a phase uid is refused', t_imp('authenticated', t_u('ops'), t_job(63), 'append',
    t_pl(ph, jsonb_build_array(t_tk(2, 'S', 1, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(1)))))), 'invalid payload: a link refers to a missing task');
  PERFORM t_expect('graph: the same predecessor twice is refused', t_imp('authenticated', t_u('ops'), t_job(64), 'append',
    t_pl('[]', jsonb_build_array(t_tk(2, 'P'), t_tk(3, 'S', NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(2), t_lk(2, 'SS', 1)))))), 'invalid payload: a task has the same predecessor twice');
  -- the cycle needs a STORED link: M2 depends on M1 is stored, the merge file adds M1 depends on M2
  PERFORM t_expect('graph setup: M2 depends on M1', left(t_imp('authenticated', t_u('ops'), jm, 'append',
    t_pl('[]', jsonb_build_array(t_tk(1, 'M1'), t_tk(2, 'M2', NULL, NULL, '2026-05-06', '2026-05-09', jsonb_build_array(t_lk(1)))))), 3), 'ok:');
  p := jsonb_build_object('project_uid', jm::text, 'based_on', t_based(jm), 'phases', '[]'::jsonb,
    'tasks', jsonb_build_array(t_tk(1, 'M1 renamed', NULL, NULL, '2026-05-01', '2026-05-05', jsonb_build_array(t_lk(2))), t_tk(2, 'M2')));
  PERFORM t_expect('graph: merge never deletes, so a new link that reverses a STORED link closes a cycle: rejected before any write',
    t_imp('authenticated', t_u('ops'), jm, 'merge', p), 'dependency cycle in the imported schedule');
  PERFORM t_expect('graph: the rejected merge changed nothing', (SELECT string_agg(task_name, ',' ORDER BY msp_uid) FROM job_tasks WHERE job_id = jm) || '|' || t_state(jm), 'M1,M2|0/2/1');
END $$;

DO $$
DECLARE jh uuid; ph jsonb := jsonb_build_array(t_ph(1, 'Ph')); res text; tasks jsonb; i int; p jsonb;
BEGIN
  -- a phase is level 1, so five nested tasks under a phase are the maximum
  jh := t_job(67);
  tasks := '[]'; FOR i IN 1..5 LOOP tasks := tasks || t_tk(i + 1, 'D' || i, 1, CASE WHEN i = 1 THEN NULL ELSE i END); END LOOP;
  PERFORM t_expect('depth: phase + 5 nested tasks (6 levels) is accepted', left(t_imp('authenticated', t_u('ops'), jh, 'append', t_pl(ph, tasks)), 3), 'ok:');
  PERFORM t_expect('depth: D2..D5 each hang under the previous one',
    (SELECT string_agg(c.task_name || '>' || p.task_name, ',' ORDER BY c.task_name) FROM job_tasks c JOIN job_tasks p ON p.id = c.parent_task_id WHERE c.job_id = jh), 'D2>D1,D3>D2,D4>D3,D5>D4');
  PERFORM t_expect('depth: D1 is a direct child of the phase', (SELECT (phase_id IS NOT NULL AND parent_task_id IS NULL)::text FROM job_tasks WHERE job_id = jh AND task_name = 'D1'), 'true');
  tasks := '[]'; FOR i IN 1..6 LOOP tasks := tasks || t_tk(i + 1, 'E' || i, 1, CASE WHEN i = 1 THEN NULL ELSE i END); END LOOP;
  PERFORM t_expect('depth: phase + 6 nested tasks (7 levels) is rejected', t_imp('authenticated', t_u('ops'), t_job(68), 'append', t_pl(ph, tasks)), 'task hierarchy is deeper than 6 levels');
  tasks := '[]'; FOR i IN 1..6 LOOP tasks := tasks || t_tk(i, 'F' || i, NULL, CASE WHEN i = 1 THEN NULL ELSE i - 1 END); END LOOP;
  PERFORM t_expect('depth: 6 nested tasks without a phase (6 levels) is accepted', left(t_imp('authenticated', t_u('ops'), t_job(69), 'append', t_pl('[]', tasks)), 3), 'ok:');
  tasks := '[]'; FOR i IN 1..7 LOOP tasks := tasks || t_tk(i, 'G' || i, NULL, CASE WHEN i = 1 THEN NULL ELSE i - 1 END); END LOOP;
  PERFORM t_expect('depth: 7 nested tasks without a phase is rejected', t_imp('authenticated', t_u('ops'), t_job(70), 'append', t_pl('[]', tasks)), 'task hierarchy is deeper than 6 levels');
  PERFORM t_expect('depth: rejected files wrote nothing', t_state(t_jid(68)) || t_state(t_jid(70)) || (SELECT count(*)::text FROM job_audit_log WHERE job_id IN (t_jid(68), t_jid(70))), '0/0/00/0/00');
END $$;

-- depth through a stored descendant that is NOT in the file: R2 has a stored child D1, moving R2 deeper must count it
DO $$
DECLARE jh uuid := t_job(71); tasks jsonb; res text; p jsonb; r2 uuid; c3 uuid; d1 uuid;
BEGIN
  PERFORM t_expect('depth setup: R1>C1>C2>C3>C4 and R2>D1 (no phase)', left(t_imp('authenticated', t_u('ops'), jh, 'append', t_pl('[]', jsonb_build_array(
    t_tk(1, 'R1'), t_tk(2, 'C1', NULL, 1), t_tk(3, 'C2', NULL, 2), t_tk(4, 'C3', NULL, 3), t_tk(5, 'C4', NULL, 4), t_tk(6, 'R2'), t_tk(7, 'D1', NULL, 6)))), 3), 'ok:');
  tasks := jsonb_build_array(t_tk(1, 'R1'), t_tk(2, 'C1', NULL, 1), t_tk(3, 'C2', NULL, 2), t_tk(4, 'C3', NULL, 3), t_tk(5, 'C4', NULL, 4), t_tk(6, 'R2', NULL, 5));
  p := jsonb_build_object('project_uid', jh::text, 'based_on', t_based(jh), 'phases', '[]'::jsonb, 'tasks', tasks);
  PERFORM t_expect('depth: R2 under C4 would put the stored D1 at level 7: rejected', t_imp('authenticated', t_u('ops'), jh, 'merge', p), 'task hierarchy is deeper than 6 levels');
  PERFORM t_expect('depth: nothing moved', (SELECT parent_task_id IS NULL FROM job_tasks WHERE job_id = jh AND task_name = 'R2')::text, 'true');
  tasks := jsonb_set(tasks, '{5,parent_uid}', '4');
  p := jsonb_build_object('project_uid', jh::text, 'based_on', t_based(jh), 'phases', '[]'::jsonb, 'tasks', tasks);
  res := t_imp('authenticated', t_u('ops'), jh, 'merge', p);
  PERFORM t_expect('depth: R2 under C3 keeps D1 at level 6: accepted', t_res(res, 'updated') || '|' || t_res(res, 'kept'), '1|1');
  PERFORM t_expect('depth: R2 now hangs under C3, D1 still under R2',
    (SELECT (SELECT task_name FROM job_tasks x WHERE x.id = r.parent_task_id) || '|' || (SELECT (SELECT task_name FROM job_tasks y WHERE y.id = d.parent_task_id) FROM job_tasks d WHERE d.job_id = jh AND d.task_name = 'D1')
       FROM job_tasks r WHERE r.job_id = jh AND r.task_name = 'R2'), 'C3|R2');
END $$;

DO $$
DECLARE ph2 jsonb := jsonb_build_array(t_ph(1, 'P1'), t_ph(7, 'P2'));
BEGIN
  PERFORM t_expect('parent: a parent cycle in the file is rejected', t_imp('authenticated', t_u('ops'), t_job(72), 'append',
    t_pl(jsonb_build_array(t_ph(1, 'P')), jsonb_build_array(t_tk(2, 'A', 1, 3), t_tk(3, 'B', 1, 2)))), 'task hierarchy cycle in the imported schedule');
  PERFORM t_expect('parent: a three-step parent cycle is rejected', t_imp('authenticated', t_u('ops'), t_job(73), 'append',
    t_pl('[]', jsonb_build_array(t_tk(2, 'A', NULL, 4), t_tk(3, 'B', NULL, 2), t_tk(4, 'C', NULL, 3)))), 'task hierarchy cycle in the imported schedule');
  PERFORM t_expect('parent: a task cannot be its own parent', t_imp('authenticated', t_u('ops'), t_job(74), 'append', t_pl('[]', jsonb_build_array(t_tk(2, 'A', NULL, 2)))),
    'invalid payload: a task has a missing or self parent');
  PERFORM t_expect('parent: a parent that is not in the file is refused', t_imp('authenticated', t_u('ops'), t_job(75), 'append', t_pl('[]', jsonb_build_array(t_tk(2, 'A', NULL, 9)))),
    'invalid payload: a task has a missing or self parent');
  PERFORM t_expect('parent: a task and its parent must be in the same phase', t_imp('authenticated', t_u('ops'), t_job(76), 'append',
    t_pl(ph2, jsonb_build_array(t_tk(2, 'A', 1), t_tk(3, 'B', 7, 2)))), 'invalid payload: a task and its parent are in different phases');
  PERFORM t_expect('parent: a task in a phase cannot hang under a phase-less parent', t_imp('authenticated', t_u('ops'), t_job(77), 'append',
    t_pl(ph2, jsonb_build_array(t_tk(2, 'A'), t_tk(3, 'B', 7, 2)))), 'invalid payload: a task and its parent are in different phases');
  PERFORM t_expect('parent: a task refers to a missing phase', t_imp('authenticated', t_u('ops'), t_job(78), 'append', t_pl(ph2, jsonb_build_array(t_tk(2, 'A', 5)))),
    'invalid payload: a task refers to a missing phase');
  PERFORM t_expect('uid: a phase and a task may not share a uid', t_imp('authenticated', t_u('ops'), t_job(79), 'append', t_pl(ph2, jsonb_build_array(t_tk(7, 'A')))),
    'invalid payload: a uid is used by both a phase and a task');
  PERFORM t_expect('uid: duplicate task uids are refused', t_imp('authenticated', t_u('ops'), t_job(90), 'append', t_pl('[]', jsonb_build_array(t_tk(2, 'A'), t_tk(2, 'B')))),
    'invalid payload: a uid is used twice');
  PERFORM t_expect('uid: duplicate phase uids are refused', t_imp('authenticated', t_u('ops'), t_job(91), 'append', t_pl(jsonb_build_array(t_ph(1, 'A'), t_ph(1, 'B')), '[]')),
    'invalid payload: a uid is used twice');
  PERFORM t_expect('graph and uid refusals wrote nothing at all',
    (SELECT (count(*) FILTER (WHERE true))::text FROM job_tasks WHERE job_id IN (SELECT t_jid(n) FROM generate_series(72, 79) n UNION ALL SELECT t_jid(90) UNION ALL SELECT t_jid(91))), '0');
END $$;


-- ===== 9. wrong JSON types and out-of-range values for every field =====
DO $$
DECLARE
  j uuid := t_job(80); base jsonb; c record; res text; n int := 0; long256 text := to_jsonb(repeat('a', 256))::text; long121 text := to_jsonb(repeat('a', 121))::text;
BEGIN
  base := t_pl(jsonb_build_array(t_ph(1, 'P')), jsonb_build_array(t_tk(2, 'A', 1), t_tk(3, 'B', 1, 2, '2026-05-01', '2026-05-05', jsonb_build_array(t_lk(2)))), j);
  FOR c IN SELECT * FROM (VALUES
    ('{phases,0,uid}', '"1"'), ('{phases,0,uid}', '1.5'), ('{phases,0,uid}', 'null'), ('{phases,0,uid}', 'true'), ('{phases,0,uid}', '[]'), ('{phases,0,uid}', '{}'),
    ('{phases,0,uid}', '0'), ('{phases,0,uid}', '-1'), ('{phases,0,uid}', '100000001'), ('{phases,0,uid}', '1e400'),
    ('{phases,0,name}', '5'), ('{phases,0,name}', 'true'), ('{phases,0,name}', 'null'), ('{phases,0,name}', '[]'), ('{phases,0,name}', '{}'), ('{phases,0,name}', long256),
    ('{phases,0,sort_order}', '"x"'), ('{phases,0,sort_order}', '-1'), ('{phases,0,sort_order}', '1.5'), ('{phases,0,sort_order}', '100000001'), ('{phases,0}', '5'), ('{phases,0}', '[]'),
    ('{tasks,0,uid}', '"2"'), ('{tasks,0,uid}', '2.5'), ('{tasks,0,uid}', 'null'), ('{tasks,0,uid}', 'true'), ('{tasks,0,uid}', '[]'), ('{tasks,0,uid}', '{}'),
    ('{tasks,0,uid}', '0'), ('{tasks,0,uid}', '-7'), ('{tasks,0,uid}', '100000001'), ('{tasks,0,uid}', '3'), ('{tasks,0,uid}', '1'),
    ('{tasks,0,name}', '5'), ('{tasks,0,name}', 'true'), ('{tasks,0,name}', 'null'), ('{tasks,0,name}', '[]'), ('{tasks,0,name}', '{}'), ('{tasks,0,name}', long256),
    ('{tasks,0,phase_uid}', '"1"'), ('{tasks,0,phase_uid}', '99'), ('{tasks,0,phase_uid}', '1.5'), ('{tasks,0,phase_uid}', 'true'), ('{tasks,0,phase_uid}', '0'), ('{tasks,0,phase_uid}', '-1'),
    ('{tasks,1,parent_uid}', '"x"'), ('{tasks,1,parent_uid}', '99'), ('{tasks,1,parent_uid}', '3'), ('{tasks,1,parent_uid}', 'true'), ('{tasks,1,parent_uid}', '0'), ('{tasks,1,parent_uid}', '1'),
    ('{tasks,0,start_date}', '20260501'), ('{tasks,0,start_date}', '"2026-02-30"'), ('{tasks,0,start_date}', '"2026-5-1"'), ('{tasks,0,start_date}', '"1999-12-31"'),
    ('{tasks,0,start_date}', '"2101-01-01"'), ('{tasks,0,start_date}', 'true'), ('{tasks,0,start_date}', '" 2026-05-01"'), ('{tasks,0,start_date}', '"2026-05-01T08:00:00"'),
    ('{tasks,0,start_date}', '"2026-13-01"'), ('{tasks,0,start_date}', '""'), ('{tasks,0,start_date}', '[]'), ('{tasks,0,start_date}', '"2026-05-06"'),
    ('{tasks,0,end_date}', '"2026-04-30"'), ('{tasks,0,end_date}', '5'), ('{tasks,0,end_date}', '"x"'), ('{tasks,0,end_date}', '"2026-00-10"'), ('{tasks,0,end_date}', '{}'),
    ('{tasks,0,progress}', '"5"'), ('{tasks,0,progress}', '101'), ('{tasks,0,progress}', '-1'), ('{tasks,0,progress}', '50.5'), ('{tasks,0,progress}', 'true'), ('{tasks,0,progress}', '[]'), ('{tasks,0,progress}', '{}'),
    ('{tasks,0,is_milestone}', '"true"'), ('{tasks,0,is_milestone}', '1'), ('{tasks,0,is_milestone}', '[]'), ('{tasks,0,is_milestone}', 'true'),
    ('{tasks,0,is_summary}', '"x"'), ('{tasks,0,is_summary}', '0'),
    ('{tasks,0,assignee}', '5'), ('{tasks,0,assignee}', '[]'), ('{tasks,0,assignee}', 'true'), ('{tasks,0,assignee}', long121),
    ('{tasks,0,baseline_start}', '5'), ('{tasks,0,baseline_start}', '"bad"'), ('{tasks,0,baseline_start}', 'true'), ('{tasks,0,baseline_end}', '5'), ('{tasks,0,baseline_end}', '"2026-02-30"'), ('{tasks,0,baseline_end}', '[]'),
    ('{tasks,0,sort_order}', '"x"'), ('{tasks,0,sort_order}', '-1'), ('{tasks,0,sort_order}', '1.5'), ('{tasks,0,sort_order}', '100000001'),
    ('{tasks,0,links}', '{}'), ('{tasks,0,links}', '"x"'), ('{tasks,0,links}', '5'), ('{tasks,0,links}', 'true'), ('{tasks,0}', '5'), ('{tasks,0}', '"x"'), ('{tasks,0}', '[]'), ('{tasks,0}', 'null'),
    ('{tasks,1,links,0}', '5'), ('{tasks,1,links,0}', '"x"'), ('{tasks,1,links,0}', '[]'), ('{tasks,1,links,0}', 'null'),
    ('{tasks,1,links,0,pred_uid}', '"2"'), ('{tasks,1,links,0,pred_uid}', '999'), ('{tasks,1,links,0,pred_uid}', '3'), ('{tasks,1,links,0,pred_uid}', 'null'), ('{tasks,1,links,0,pred_uid}', '0'),
    ('{tasks,1,links,0,pred_uid}', '1.5'), ('{tasks,1,links,0,pred_uid}', 'true'), ('{tasks,1,links,0,pred_uid}', '1'), ('{tasks,1,links,0,pred_uid}', '100000001'),
    ('{tasks,1,links,0,link_type}', '"XX"'), ('{tasks,1,links,0,link_type}', '"fs"'), ('{tasks,1,links,0,link_type}', '5'), ('{tasks,1,links,0,link_type}', '"FSS"'), ('{tasks,1,links,0,link_type}', 'true'), ('{tasks,1,links,0,link_type}', '""'),
    ('{tasks,1,links,0,lag_days}', '366'), ('{tasks,1,links,0,lag_days}', '-31'), ('{tasks,1,links,0,lag_days}', '"1"'), ('{tasks,1,links,0,lag_days}', '1.5'), ('{tasks,1,links,0,lag_days}', 'true'), ('{tasks,1,links,0,lag_days}', '1e9'),
    ('{format}', '"xml"'), ('{format}', '5'), ('{format}', 'null'), ('{version}', '2'), ('{version}', '"1"'), ('{version}', 'true'), ('{version}', 'null'),
    ('{file_name}', '5'), ('{file_name}', 'true'), ('{file_name}', to_jsonb(repeat('f', 256))::text), ('{based_on}', '5'), ('{based_on}', '"garbage"'), ('{based_on}', 'true'), ('{based_on}', '[]'),
    ('{project}', '[]'), ('{project}', '"x"'), ('{project}', '5'), ('{project,uid}', '5'), ('{project,manager}', '5'), ('{project_uid}', '5'), ('{project_uid}', 'true'), ('{project_uid}', to_jsonb(repeat('u', 65))::text),
    ('{temporary_uids}', '"yes"'), ('{temporary_uids}', '1'), ('{temporary_uids}', '[]'),
    ('{phases}', '{}'), ('{phases}', '"x"'), ('{phases}', '5'), ('{tasks}', '{}'), ('{tasks}', '"x"'), ('{tasks}', '5'), ('{tasks}', 'true'),
    ('{links}', '[{"a":1}]'), ('{links}', '{}'), ('{links}', '"x"'), ('{links}', '5'), ('{links}', 'true'), ('{warnings}', '{}'), ('{warnings}', '"x"'), ('{warnings}', '5')
  ) AS v(path, val) LOOP
    res := t_imp('authenticated', t_u('ops'), j, 'append', jsonb_set(CASE WHEN c.path = '{project,uid}' OR c.path = '{project,manager}' THEN base || '{"project":{}}' ELSE base END, c.path::text[], c.val::jsonb));
    PERFORM t_expect('type: ' || c.path || ' = ' || left(c.val, 20), left(res, 15), 'invalid payload');
    n := n + 1;
  END LOOP;
  PERFORM t_expect('type: the milestone flag with different start and end is refused', left(t_imp('authenticated', t_u('ops'), j, 'append', jsonb_set(base, '{tasks,0,is_milestone}', 'true')), 15), 'invalid payload');
  PERFORM t_expect('type: baseline_end before baseline_start is refused', left(t_imp('authenticated', t_u('ops'), j, 'append',
    jsonb_set(jsonb_set(base, '{tasks,0,baseline_start}', '"2026-05-05"'), '{tasks,0,baseline_end}', '"2026-05-01"')), 15), 'invalid payload');
  PERFORM t_expect('type: the payload itself must be an object (array)', t_imp('authenticated', t_u('ops'), j, 'append', '[]'::jsonb), 'invalid payload: a JSON object is required');
  PERFORM t_expect('type: the payload itself must be an object (string)', t_imp('authenticated', t_u('ops'), j, 'append', '"x"'::jsonb), 'invalid payload: a JSON object is required');
  PERFORM t_expect('type: the payload itself must be an object (json null)', t_imp('authenticated', t_u('ops'), j, 'append', 'null'::jsonb), 'invalid payload: a JSON object is required');
  PERFORM t_expect('type: the payload itself must be an object (SQL NULL)',
    t_msg('authenticated', t_u('ops'), format('SELECT import_job_schedule(%L, ''append'', NULL)::text', j)), 'invalid payload: a JSON object is required');
  PERFORM t_expect('type: an empty object has no rows', t_imp('authenticated', t_u('ops'), j, 'append', '{}'::jsonb), 'invalid payload: it has no rows');
  PERFORM t_expect('type: empty arrays have no rows', t_imp('authenticated', t_u('ops'), j, 'append', '{"phases":[],"tasks":[]}'::jsonb), 'invalid payload: it has no rows');
  PERFORM t_expect('type: at least 150 wrong-type cases ran', (n >= 150)::text, 'true');
  PERFORM t_expect('type: every refused file wrote nothing (rows, links, audit)', t_state(j) || '|' || (SELECT count(*)::text FROM job_audit_log WHERE job_id = j), '0/0/0|0');
END $$;

-- ===== 10. boundary values are accepted =====
DO $$
DECLARE j uuid := t_job(81); p jsonb; res text;
BEGIN
  p := jsonb_build_object('format', 'mspdi', 'version', 1.0, 'file_name', repeat('f', 255), 'phases', jsonb_build_array(t_ph(100000000, repeat('p', 80), 0)),
    'tasks', jsonb_build_array(
      t_tk(1, repeat('n', 255), 100000000, NULL, '2000-01-01', '2100-12-31') || jsonb_build_object('progress', 100, 'assignee', repeat('a', 120), 'sort_order', 100000000),
      t_tk(2, 'ms', NULL, NULL, '2026-05-05', '2026-05-05', jsonb_build_array(t_lk(1, 'SS', -30))) || '{"is_milestone":true,"progress":0}',
      t_tk(3, 'x', NULL, NULL, NULL, NULL, jsonb_build_array(t_lk(1, 'FF', 365), t_lk(2, 'SF', 0))),
      t_tk(4, 'y', NULL, NULL, '2026-05-05', '2026-05-05', jsonb_build_array(t_lk(3)))));
  res := t_imp('authenticated', t_u('ops'), j, 'append', p);
  PERFORM t_expect('bounds: every limit value is accepted', t_res(res, 'created'), '5');
  PERFORM t_expect('bounds: stored values', (SELECT max(char_length(task_name))::text || '|' || max(char_length(assignee)) || '|' || min(start_date) || '|' || max(end_date) || '|' || max(progress) FROM job_tasks WHERE job_id = j), '255|120|2000-01-01|2100-12-31|100');
  PERFORM t_expect('bounds: lag and type extremes stored', (SELECT string_agg(link_type || lag_days, ',' ORDER BY link_type, lag_days) FROM job_task_links WHERE job_id = j), 'FF365,FS0,SF0,SS-30');
  PERFORM t_expect('bounds: the milestone and the undated task', (SELECT string_agg(task_name || is_milestone::text || coalesce(start_date::text, '-'), ',' ORDER BY msp_uid) FROM job_tasks WHERE job_id = j AND task_name IN ('ms', 'x')), 'mstrue2026-05-05,xfalse-');
  PERFORM t_expect('bounds: the file name of 255 characters is kept in the audit', (SELECT char_length(metadata ->> 'file_name')::text FROM job_audit_log WHERE job_id = j), '255');
END $$;

-- ===== 11. hostile strings stay inert text =====
DO $$
DECLARE j uuid := t_job(82); p jsonb; res text; inj text := $q$'); DROP TABLE job_tasks; --$q$;
BEGIN
  PERFORM t_expect('clean: control, bidi and zero-width characters are removed', import_sched_clean('a' || chr(1) || 'b' || chr(7) || chr(127) || chr(8232) || chr(8238) || chr(8203) || chr(133) || 'c'), 'abc');
  PERFORM t_expect('clean: line breaks and tabs become one space', import_sched_clean('l1' || chr(10) || chr(9) || chr(13) || 'l2'), 'l1 l2');
  PERFORM t_expect('clean: runs of spaces collapse and the ends are trimmed', import_sched_clean('  x   y  '), 'x y');
  PERFORM t_expect('clean: ordinary unicode survives', import_sched_clean('Café – Ünïcödé 工程'), 'Café – Ünïcödé 工程');
  p := jsonb_build_object('file_name', 'x' || chr(1) || '.xml' || chr(10), 'based_on', NULL,
    'phases', jsonb_build_array(t_ph(1, 'p' || repeat('x', 90))),
    'tasks', jsonb_build_array(
      t_tk(2, 'a' || chr(1) || 'b' || chr(7) || chr(127) || chr(8232) || chr(8238) || chr(8203) || 'c', 1),
      t_tk(3, 'line1' || chr(10) || chr(9) || 'line2', 1), t_tk(4, '  x   y  ', 1), t_tk(5, '<script>alert(1)</script>', 1), t_tk(6, inj, 1),
      t_tk(7, 'Café – Ünïcödé 工程', 1), t_tk(8, chr(1), 1), t_tk(9, 'with assignee', 1) || jsonb_build_object('assignee', 'A.' || chr(10) || 'Ramdhan' || chr(7))));
  res := t_imp('authenticated', t_u('ops'), j, 'append', p);
  PERFORM t_expect('inert: imported', t_res(res, 'created'), '9');
  PERFORM t_expect('inert: names after cleaning', (SELECT string_agg(task_name, '|' ORDER BY msp_uid) FROM job_tasks WHERE job_id = j),
    'abc|line1 line2|x y|<script>alert(1)</script>|' || inj || '|Café – Ünïcödé 工程|(unnamed)|with assignee');
  PERFORM t_expect('inert: assignee cleaned', (SELECT assignee FROM job_tasks WHERE job_id = j AND task_name = 'with assignee'), 'A. Ramdhan');
  PERFORM t_expect('inert: the SQL text did nothing: the table and all rows are still there', (to_regclass('public.job_tasks') IS NOT NULL)::text || t_state(j), 'true1/8/0');
  PERFORM t_expect('inert: the phase name is cut to 80 characters', (SELECT char_length(name)::text FROM job_phases WHERE job_id = j), '80');
  PERFORM t_expect('inert: truncation and the defaulted empty name are reported', t_warn(res, 'name-truncated') || '|' || t_warn(res, 'name-defaulted'), '1|1');
  PERFORM t_expect('inert: the audit file name is cleaned', (SELECT metadata ->> 'file_name' FROM job_audit_log WHERE job_id = j), 'x.xml');
  -- the reason and its length
  res := t_imp('authenticated', t_u('ops'), t_job(83), 'replace', t_pl('[]', jsonb_build_array(t_tk(1, 'r'))), 'because' || chr(7) || repeat('r', 600));
  PERFORM t_expect('inert: the replace reason is cleaned and cut to 500', (SELECT char_length(metadata ->> 'reason')::text || left(metadata ->> 'reason', 9) FROM job_audit_log WHERE job_id = t_jid(83)), '500becauserr');
  PERFORM t_expect('inert: a reason with SQL text is stored as text', left(t_imp('authenticated', t_u('ops'), t_job(84), 'replace', t_pl('[]', jsonb_build_array(t_tk(1, 'r'))), inj), 3), 'ok:');
  PERFORM t_expect('inert: ... verbatim', (SELECT metadata ->> 'reason' FROM job_audit_log WHERE job_id = t_jid(84)), inj);
  PERFORM t_expect('inert: a 256-character name is refused, not cut', left(t_imp('authenticated', t_u('ops'), t_job(85), 'append', t_pl('[]', jsonb_build_array(t_tk(1, repeat('z', 256))))), 15), 'invalid payload');
END $$;

-- ===== 12. size caps and warnings =====
DO $$
DECLARE j uuid; p jsonb; res text; t0 timestamptz; big jsonb;
BEGIN
  PERFORM t_expect('caps: 2001 tasks are refused', t_imp('authenticated', t_u('ops'), t_job(86), 'append',
    t_pl('[]', (SELECT jsonb_agg(t_tk(i, 'T' || i)) FROM generate_series(1, 2001) i))), 'invalid payload: more than 2000 tasks');
  PERFORM t_expect('caps: 501 phases are refused', t_imp('authenticated', t_u('ops'), t_job(87), 'append',
    t_pl((SELECT jsonb_agg(t_ph(i, 'P' || i)) FROM generate_series(1, 501) i), '[]')), 'invalid payload: more than 500 phases');
  PERFORM t_expect('caps: more than 5000 links are refused', t_imp('authenticated', t_u('ops'), t_job(88), 'append',
    t_pl('[]', (SELECT jsonb_agg(t_tk(i, 'T' || i, NULL, NULL, '2026-05-01', '2026-05-02',
        (SELECT coalesce(jsonb_agg(t_lk(i - d)), '[]') FROM generate_series(1, 3) d WHERE i - d >= 1))) FROM generate_series(1, 2000) i))), 'invalid payload: more than 5000 links');
  PERFORM t_expect('caps: a payload over 6 MB is refused', t_imp('authenticated', t_u('ops'), t_job(89), 'append',
    t_pl('[]', jsonb_build_array(t_tk(1, 'x'))) || jsonb_build_object('junk', repeat('x', 7000000))), 'invalid payload: too large');
  PERFORM t_expect('caps: the refusals wrote nothing', (SELECT count(*)::text FROM job_tasks WHERE job_id IN (t_jid(86), t_jid(87), t_jid(88), t_jid(89))), '0');
  -- exactly 2000 tasks as one 2000-long dependency chain (also the worst case for the cycle check)
  j := t_job(92);
  t0 := clock_timestamp();
  res := t_imp('authenticated', t_u('ops'), j, 'append',
    t_pl('[]', (SELECT jsonb_agg(t_tk(i, 'T' || i, NULL, NULL, '2026-05-01', '2026-05-02', CASE WHEN i = 1 THEN '[]'::jsonb ELSE jsonb_build_array(t_lk(i - 1)) END)) FROM generate_series(1, 2000) i)));
  PERFORM t_expect('caps: a 2000-task, 1999-link chain is accepted', t_res(res, 'created') || '|' || t_state(j), '2000|0/2000/1999');
  RAISE NOTICE 'timing: 2000-task chain import took % ms', round(extract(epoch FROM clock_timestamp() - t0) * 1000);
  PERFORM t_expect('caps: ... in reasonable time (< 60 s)', (clock_timestamp() - t0 < interval '60 seconds')::text, 'true');
  -- the same chain closed into a ring is rejected (long peel)
  PERFORM t_expect('caps: closing that chain into a ring is rejected', t_imp('authenticated', t_u('ops'), t_job(93), 'append',
    t_pl('[]', (SELECT jsonb_agg(t_tk(i, 'T' || i, NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(CASE WHEN i = 1 THEN 2000 ELSE i - 1 END)))) FROM generate_series(1, 2000) i))),
    'dependency cycle in the imported schedule');
  -- warnings: the codec's own warnings pass through; hostile ones are dropped or cleaned; resources are not imported yet
  p := t_pl('[]', jsonb_build_array(t_tk(1, 'W'))) || jsonb_build_object('warnings', jsonb_build_array(
    jsonb_build_object('code', 'calendar-working-days', 'message', 'cal', 'count', 3), jsonb_build_object('code', 'bad code!', 'message', 'y', 'count', 2),
    jsonb_build_object('code', 'ok', 'message', chr(1) || 'clean' || chr(10), 'count', 'x'), jsonb_build_object('code', 'calendar-working-days', 'count', 2),
    5, jsonb_build_object('code', 'huge', 'count', 99999999999)),
    'resources', jsonb_build_array(jsonb_build_object('uid', 1), jsonb_build_object('uid', 2)));
  res := t_imp('authenticated', t_u('ops'), t_job(94), 'append', p);
  PERFORM t_expect('warn: counts of the same code add up, bad counts become 1, hostile codes are dropped',
    t_warn(res, 'calendar-working-days') || '|' || t_warn(res, 'ok') || '|' || t_warn(res, 'bad code!') || '|' || t_warn(res, 'huge') || '|' || t_warn(res, 'resources-ignored'), '5|1|none|1|2');
  PERFORM t_expect('warn: the message of a file warning is cleaned',
    (SELECT w ->> 'message' FROM jsonb_array_elements((substr(res, 4)::jsonb) -> 'warnings') w WHERE w ->> 'code' = 'ok'), 'clean');
  PERFORM t_expect('warn: a warning code longer than 64 characters is refused', left(t_imp('authenticated', t_u('ops'), t_job(96), 'append', t_pl('[]', jsonb_build_array(t_tk(1, 'W'))) || jsonb_build_object('warnings', jsonb_build_array(jsonb_build_object('code', repeat('c', 65))))), 15), 'invalid payload');
  PERFORM t_expect('warn: the warnings are in the audit metadata too', (SELECT jsonb_array_length(metadata -> 'warnings')::text FROM job_audit_log WHERE job_id = t_jid(94)), '4');
END $$;

-- ===== 13. depends_on keeps mirroring the first FS predecessor =====
DO $$
DECLARE j uuid := t_job(95); res text;
BEGIN
  res := t_imp('authenticated', t_u('ops'), j, 'append', t_pl('[]', jsonb_build_array(t_tk(1, 'P1'), t_tk(2, 'P2'),
    t_tk(3, 'S-fs-first', NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(1, 'FS', 1), t_lk(2, 'SS', 0))),
    t_tk(4, 'S-ss-first', NULL, NULL, '2026-05-01', '2026-05-02', jsonb_build_array(t_lk(1, 'SS', 0), t_lk(2, 'FS', 0))),
    t_tk(5, 'S-none'))));
  PERFORM t_expect('depends_on: first FS link mirrored, non-FS first link leaves it empty',
    (SELECT string_agg(s.task_name || '=' || coalesce(p.task_name, '-'), ',' ORDER BY s.task_name) FROM job_tasks s LEFT JOIN job_tasks p ON p.id = s.depends_on WHERE s.job_id = j AND s.task_name LIKE 'S-%'),
    'S-fs-first=P1,S-none=-,S-ss-first=-');
  PERFORM t_expect('depends_on: all links stored with their types and lags', (SELECT string_agg(link_type || lag_days, ',' ORDER BY link_type, lag_days) FROM job_task_links WHERE job_id = j), 'FS0,FS1,SS0,SS0');
END $$;

-- ===== 14. G3: the REAL payloads (schedule-msp.js toPayload output for the seven ProjectLibre fixtures) =====
DO $$
DECLARE
  r record; j uuid; res text; bd jsonb; np int; nt int; nl int; nb int; k int := 0; exp_t text; got_t text; exp_h text; got_h text; exp_l text; got_l text;
BEGIN
  FOR r IN SELECT p.name, p.body AS pbody FROM t_payloads p WHERE p.name ~ '^f0[0-9]$' ORDER BY p.name LOOP
    k := k + 1; j := t_job(100 + k);
    bd := r.pbody || jsonb_build_object('file_name', r.name || '.xml');            -- the wrapper adds file_name; toPayload does not emit it
    np := jsonb_array_length(bd -> 'phases'); nt := jsonb_array_length(bd -> 'tasks');
    nl := (SELECT coalesce(sum(jsonb_array_length(e -> 'links')), 0) FROM jsonb_array_elements(bd -> 'tasks') e);
    nb := (SELECT count(*) FROM jsonb_array_elements(bd -> 'tasks') e WHERE e ->> 'baseline_start' IS NOT NULL AND e ->> 'baseline_end' IS NOT NULL);
    res := t_imp('authenticated', t_u('ops'), j, 'append', bd);
    PERFORM t_expect('real ' || r.name || ': accepted unchanged, created = phases + tasks', t_res(res, 'created'), (np + nt)::text);
    PERFORM t_expect('real ' || r.name || ': row and link counts match the payload', t_state(j), np || '/' || nt || '/' || nl);
    SELECT string_agg(coalesce(e ->> 'name', '') || '|' || coalesce(e ->> 'start_date', '-') || '|' || coalesce(e ->> 'end_date', '-') || '|' || (e ->> 'progress') || '|' || (e ->> 'is_milestone'), ',' ORDER BY i)
      INTO exp_t FROM jsonb_array_elements(bd -> 'tasks') WITH ORDINALITY x(e, i);
    SELECT string_agg(task_name || '|' || coalesce(start_date::text, '-') || '|' || coalesce(end_date::text, '-') || '|' || progress || '|' || is_milestone::text, ',' ORDER BY msp_uid)
      INTO got_t FROM job_tasks WHERE job_id = j;
    PERFORM t_expect('real ' || r.name || ': name, dates, progress and milestone of every task', got_t, exp_t);
    SELECT string_agg(((e.i + np) || '>' || (pe.i + np)), ',' ORDER BY e.i) INTO exp_h
      FROM (SELECT (x ->> 'uid')::int uid, (x ->> 'parent_uid')::int puid, i FROM jsonb_array_elements(bd -> 'tasks') WITH ORDINALITY a(x, i)) e
      JOIN (SELECT (x ->> 'uid')::int uid, i FROM jsonb_array_elements(bd -> 'tasks') WITH ORDINALITY a(x, i)) pe ON pe.uid = e.puid;
    SELECT string_agg(c.msp_uid || '>' || p.msp_uid, ',' ORDER BY c.msp_uid) INTO got_h FROM job_tasks c JOIN job_tasks p ON p.id = c.parent_task_id WHERE c.job_id = j;
    PERFORM t_expect('real ' || r.name || ': hierarchy through parent_task_id equals the payload parents', coalesce(got_h, '-'), coalesce(exp_h, '-'));
    PERFORM t_expect('real ' || r.name || ': phase membership',
      (SELECT count(*)::text FROM job_tasks WHERE job_id = j AND phase_id IS NOT NULL), (SELECT count(*)::text FROM jsonb_array_elements(bd -> 'tasks') e WHERE e ->> 'phase_uid' IS NOT NULL));
    SELECT string_agg(l, ',' ORDER BY l) INTO exp_l FROM (SELECT (le ->> 'link_type') || (le ->> 'lag_days') l FROM jsonb_array_elements(bd -> 'tasks') e, jsonb_array_elements(e -> 'links') le) s;
    SELECT string_agg(link_type || lag_days, ',' ORDER BY link_type || lag_days) INTO got_l FROM job_task_links WHERE job_id = j;
    PERFORM t_expect('real ' || r.name || ': link types and lags', coalesce(got_l, '-'), coalesce(exp_l, '-'));
    PERFORM t_expect('real ' || r.name || ': baselines written for exactly the complete ones (approver)',
      (SELECT count(*)::text FROM job_tasks WHERE job_id = j AND baseline_locked_at IS NOT NULL), nb::text);
    PERFORM t_expect('real ' || r.name || ': every file warning arrives with the same count',
      coalesce((SELECT bool_and(t_warn(res, w ->> 'code') = (w ->> 'count'))::text FROM jsonb_array_elements(bd -> 'warnings') w), 'true'), 'true');
    PERFORM t_expect('real ' || r.name || ': nothing is published, uids are 1..n', (SELECT count(*) FILTER (WHERE client_visible)::text || (SELECT max(msp_uid) FROM job_tasks WHERE job_id = j)::text FROM job_tasks WHERE job_id = j), '0' || (np + nt)::text);
    PERFORM t_expect('real ' || r.name || ': the same file imports for a writer too (baselines dropped)',
      left(t_imp('authenticated', t_u('wrt'), t_job(120 + k), 'append', bd), 3) || (SELECT count(*)::text FROM job_tasks WHERE job_id = t_jid(120 + k) AND baseline_locked_at IS NOT NULL), 'ok:0');
  END LOOP;
  PERFORM t_expect('real: all seven fixtures were exercised', k::text, '7');
END $$;

-- the merge round trip on a real file: append fixture 04, then merge the same file as exported by this job with three edits
DO $$
DECLARE
  m jsonb; own jsonb; ro jsonb; j uuid; res text; ex jsonb;
BEGIN
  SELECT meta, body INTO m, own FROM t_payloads WHERE name = 'own04';
  SELECT body INTO ro FROM t_payloads WHERE name = 'ro04';
  j := (m ->> 'job')::uuid;
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (j, 'c1000000-0000-0000-0000-000000000001', 'IMP-OWN', 'Open');
  res := t_imp('authenticated', t_u('wrt'), j, 'append', (SELECT body FROM t_payloads WHERE name = 'f04') || '{"file_name":"orig.xml"}');
  PERFORM t_expect('roundtrip: the original file imports', left(res, 3), 'ok:');
  PERFORM t_expect('roundtrip: a foreign file (no project uid) cannot merge', left(t_imp('authenticated', t_u('wrt'), j, 'merge', (SELECT body FROM t_payloads WHERE name = 'f04') || jsonb_build_object('based_on', t_based(j))), 21), 'merge requires a file');
  PERFORM t_expect('roundtrip: a read-only-export file (temporary uids) cannot merge', left(t_imp('authenticated', t_u('ops'), j, 'merge', ro || jsonb_build_object('based_on', t_based(j))), 21), 'merge requires a file');
  res := t_imp('authenticated', t_u('wrt'), j, 'merge', own || jsonb_build_object('based_on', t_based(j), 'file_name', 'edited.xml'));
  ex := m -> 'expect';
  PERFORM t_expect('roundtrip: only the edits arrive: created/updated/kept/skipped as designed',
    t_res(res, 'created') || '/' || t_res(res, 'updated') || '/' || t_res(res, 'kept') || '/' || t_res(res, 'skipped'),
    (ex ->> 'created') || '/' || (ex ->> 'updated') || '/' || (ex ->> 'kept') || '/' || (ex ->> 'skipped'));
  PERFORM t_expect('roundtrip: the renamed task and the new progress arrived',
    (SELECT count(*)::text FROM job_tasks WHERE job_id = j AND ((task_name = 'Renamed in ProjectLibre') OR (task_name = 'Added in ProjectLibre') OR progress = 55)), '3');
  PERFORM t_expect('roundtrip: the row left out of the file is kept', (SELECT count(*)::text FROM job_tasks WHERE job_id = j), ((m ->> 'base_tasks')::int + 1)::text);
  PERFORM t_expect('roundtrip: the added row got the next uid', (SELECT msp_uid::text FROM job_tasks WHERE job_id = j AND task_name = 'Added in ProjectLibre'), ((m ->> 'base_phases')::int + (m ->> 'base_tasks')::int + 1)::text);
  PERFORM t_expect('roundtrip: the same edited file again changes nothing (idempotent)',
    (SELECT t_res(r, 'created') || '/' || t_res(r, 'updated') FROM (SELECT t_imp('authenticated', t_u('wrt'), j, 'merge', own || jsonb_build_object('based_on', t_based(j))) r) s), '1/0');
END $$;

-- ===== 15. gaps found by the mutation run =====
DO $$
DECLARE jq uuid := t_job(130); ja uuid := t_job(131); res text; p jsonb; sv int;
BEGIN
  PERFORM t_expect('gap: a phase uid of 0 is refused', left(t_imp('authenticated', t_u('ops'), jq, 'append', t_pl(jsonb_build_array(t_ph(0, 'P')), jsonb_build_array(t_tk(2, 'A')))), 15), 'invalid payload');
  PERFORM t_expect('gap: an end date after 2100 is refused', left(t_imp('authenticated', t_u('ops'), jq, 'append', t_pl('[]', jsonb_build_array(jsonb_set(t_tk(2, 'A'), '{end_date}', '"2101-01-01"')))), 15), 'invalid payload');
  PERFORM t_expect('gap: an end date after 2100 is refused (no start)', left(t_imp('authenticated', t_u('ops'), jq, 'append', t_pl('[]', jsonb_build_array(t_tk(2, 'A', NULL, NULL, NULL, '2101-01-01')))), 15), 'invalid payload');
  res := t_imp('authenticated', t_u('ops'), jq, 'append', t_pl(jsonb_build_array(t_ph(1, chr(1))), '[]'));
  PERFORM t_expect('gap: a phase with an empty name is called (unnamed) and reported', t_warn(res, 'name-defaulted') || '|' || (SELECT name FROM job_phases WHERE job_id = jq), '1|(unnamed)');
  -- merge: a matched task whose file row has no dates keeps its stored dates
  PERFORM t_expect('gap setup', left(t_imp('authenticated', t_u('ops'), ja, 'append', t_pl('[]', jsonb_build_array(t_tk(1, 'Dated', NULL, NULL, '2026-05-01', '2026-05-09')))), 3), 'ok:');
  res := t_imp('authenticated', t_u('ops'), ja, 'merge', jsonb_build_object('project_uid', ja::text, 'based_on', t_based(ja), 'phases', '[]'::jsonb,
    'tasks', jsonb_build_array(t_tk(1, 'Dated renamed', NULL, NULL, NULL, NULL))));
  PERFORM t_expect('gap: merge with no dates in the file keeps the stored dates', (SELECT task_name || '|' || start_date || '|' || end_date FROM job_tasks WHERE job_id = ja), 'Dated renamed|2026-05-01|2026-05-09');
  res := t_imp('authenticated', t_u('ops'), ja, 'merge', jsonb_build_object('project_uid', ja::text, 'based_on', t_based(ja), 'phases', '[]'::jsonb,
    'tasks', jsonb_build_array(t_tk(1, 'Dated renamed', NULL, NULL, '2027-01-01', NULL))));
  PERFORM t_expect('gap: merge with one date only keeps both stored dates', left(res, 3) || (SELECT start_date || '|' || end_date FROM job_tasks WHERE job_id = ja), 'ok:2026-05-01|2026-05-09');
END $$;

-- an atom present but not true does not count (role permissions are compared strictly)
DO $$
DECLARE jr uuid := t_job(132);
BEGIN
  INSERT INTO erp_roles (id, name, permissions) VALUES ('a0000000-0000-0000-0000-000000000030', 'imp_false_atoms',
    '{"ops:work-orders:read": true, "ops:work-orders:write": false, "ops:work-orders:approve": "yes"}');
  INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES ('e0000000-0000-0000-0000-000000000030', '30303030-3030-3030-3030-303030303030', 'false atoms', true);
  INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES ('e0000000-0000-0000-0000-000000000030', 'c1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000030');
  PERFORM t_expect('atoms: write=false is not write', t_imp('authenticated', '30303030-3030-3030-3030-303030303030', jr, 'append', t_pl('[]', jsonb_build_array(t_tk(1, 'x')))),
    'permission denied: ops:work-orders:write required');
END $$;

ROLLBACK;
