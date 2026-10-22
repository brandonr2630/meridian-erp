MSPDI FIXTURES FOR THE PHASE A2 CODEC (schedule-msp.js)
=======================================================
Written 2026-10-21. Spec: docs/specs/project-portal/phase-a2-projectlibre.md

Files 01-06 were produced by ProjectLibre (File > Save As > MS Project XML) and
checked by script on 2026-10-21. Do not hand-edit them or re-save them: they are
ground truth for what ProjectLibre actually writes. File 07 is SYNTHETIC (see below).
No file here came from MS Project (the owner has no copy).

MSPDI facts confirmed from these files
--------------------------------------
- Link type codes in <PredecessorLink><Type>: 0 = FF, 1 = FS, 2 = SF, 3 = SS.
- <LinkLag> is in tenths of a minute: 9600 = 2 working days (8 h/day), -4800 = -1 day.
- Durations are working hours (PT8H0M0S = 1 day on the 8-hour calendar), never days.
- Hierarchy comes from <OutlineLevel>; summary rows have <Summary>1</Summary>.
  <WBS> is unreliable (see 04): derive structure from outline level only.
- Milestones: <Milestone>1</Milestone> with zero duration.
- Baseline: <Baseline><Number>0</Number><Start/><Finish/></Baseline> per task.
- Unassigned tasks carry an assignment to the placeholder resource UID -65535.
  Resource UID 0 ("Unassigned") is also written. Both must be skipped.
- Calendar weekdays: DayType 1 = Sunday ... 7 = Saturday; exceptions are
  <TimePeriod><FromDate/><ToDate/></TimePeriod> with DayWorking 0.
- Finish times land at 17:00 for a full day (a lunch break is built into the calendar).

The six ProjectLibre fixtures
-----------------------------
01-simple-fs.xml          Realistic 14-task motor-repair job.
                          UID 1 "Motor Repairs" = summary (level 1); UIDs 2-14 = level 2.
                          Mostly FS links, plus one each of SS (UID 3 after 2), SS (UID 7 after 6),
                          FF (UID 10 after 9), SF (UID 14 after 13, lag 2400 = 4 h = half a day).
                          12 links in total: 8 FS, 2 SS, 1 FF, 1 SF. Only the SF link has a lag.
                          % complete: UID 2 = 100, UID 3 = 60, UID 4 = 10; summary rolls up to 15.
                          NOTE the name says "simple" but it is a mixed-link project.

02-link-types.xml         11 tasks, UID 1 = summary. All four link types present:
                          FF (UID 9 after 8, lead -1 day), FS (6 links, UID 4 has +2 day lag),
                          SF (UID 11 after 10, +2 day lag), SS (UID 3 after 2). 9 links in total.

03-milestones-summary.xml 9 tasks. Two summaries (UIDs 1 and 5) with 3 children each.
                          One milestone: UID 9 "Complete Inspections" (level 2), after UIDs 4 and 8.
                          Includes a cross-group SS link (UID 6 after 2). 7 links.

04-hierarchy-deep.xml     12 tasks, outline levels 1-4. Project > Phase A > WP1 > Task A1, A2;
                          WP2 > Task B1, B2; Phase B > WP3 > Task C1, C2. Six summaries, six leaves.
                          Leaves are one FS chain; no links touch summary rows.
                          QUIRK: UID 5 ("Task A2") has a stray <WBS>1.1</WBS>; all other rows are blank.
                          It does not match the real position (1.1.1.2): never trust WBS.

05-resources-baseline.xml 5 tasks, all level 1: Deliver, Receive, Repair, Test, Reassemble.
                          Resources: Technician 1 (rate 45), Technician 2 (rate 50), Bearing (rate 8000),
                          plus the default "Unassigned" (UID 0). Assignments: UID 1 = Technician 1;
                          UID 2 = Technician 1 AND Technician 2 at 0.5 units; UID 3 = Bearing (40 h);
                          UIDs 4 and 5 = placeholder -65535.
                          Every task has Baseline 0. Plan differs from baseline on UID 3, 4, 5
                          (about 3 days later); UIDs 1 and 2 match.
                          All three resources are <Type>1</Type> (Work): see the material finding.

06-calendar-monfri.xml    8 tasks on the Standard calendar (Mon-Fri, 480 min/day, lunch 12-13).
                          Calendar exception: 2026-10-28 and 2026-10-29 non-working.
                          UID 3 "Disassemble" (2 working days) runs Fri 2026-10-30 to Mon 2026-11-02:
                          2 working days = 4 calendar days (the Meridian mismatch).
                          UID 7 "Test" is 12 h (2026-11-09 08:00 to 2026-11-10 13:00); UID 8 "Deliver"
                          is 1 h (13:00-14:00).
                          QUIRK: UID 2 "Test" (16 h) is stored as finishing 2026-10-28 17:00, a day that is
                          non-working per the exception, while its successor starts 2026-10-30. ProjectLibre's
                          stored finish is stale across an exception: recompute from the calendar and warn.

07-synthetic-material.xml SYNTHETIC. Hand-written from the public MSPDI schema. NOT from any real tool.
                          One Work resource (Technician), one Material resource (Bearing set,
                          <Type>0</Type>, <MaterialLabel>set</MaterialLabel>) and a material assignment whose
                          <Units> is the quantity (2). Proves the parser handles this shape only.
                          It does NOT prove that MS Project writes the same elements.

Known ProjectLibre limitations found while building these (R1 evidence)
-----------------------------------------------------------------------
1. Material resources are exported as Work (<Type>1</Type>) with no MaterialLabel. One save also wrote an
   absurd assignment work value (PT24000000H0M0S, 24 million hours). Importer rule: treat a resource that
   looks like a material (max units 0, absurd work, or Type 0) with caution, warn, and never trust a
   quantity from such a row. Material round trip is UNVERIFIED against a real tool.
2. Save on the Z: drive can fail its final rename: ProjectLibre leaves "<name>_tmp0.xml" (or _tmp1) and no
   real file. The content is complete; renaming the tmp file is enough. Saving to a local folder and
   copying avoids it.
3. The default save is the native .pod (Java serialization, starts ac ed 00 05). Renaming a .pod to .xml
   does not convert it. A real XML file starts with "<?xml". .pod is out of scope for the codec.
4. Stored finish dates can be stale across calendar exceptions (see 06).
5. WBS values can be stray and wrong (see 04).

Expected-value use
------------------
Tests should assert the counts and values above (task counts, outline levels, link types and lags,
resource and assignment rows, baseline dates, calendar exceptions). When a value here changes, the file
changed: investigate before updating this README.
