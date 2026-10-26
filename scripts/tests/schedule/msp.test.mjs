// Tests for the MS Project XML codec (schedule-msp.js). Run: node --test scripts/tests/schedule/msp.test.mjs
// The codec is loaded in a vm context that holds nothing but a Date that throws (it must be pure). MSP_SRC lets the mutation
// check (msp-mutate.mjs) point at a mutated copy. Real-file expectations come from scripts/tests/schedule/mspdi/README.txt
// (ProjectLibre output, checked by script 2026-10-21); file 07 is synthetic and proves parser shape only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "..");
const SRC = process.env.MSP_SRC ?? join(root, "schedule-msp.js");
const NoDate = function () { throw new Error("Date used inside the codec"); };
for (const k of ["now", "UTC", "parse"]) NoDate[k] = () => { throw new Error("Date." + k + " used inside the codec"); };
const ctx = { Date: NoDate };
vm.createContext(ctx);
const C = vm.runInContext(`(function(){\n${readFileSync(SRC, "utf8")}\nreturn MspCodec;\n})()`, ctx);   // trusted: this repo's own file
const plain = (o) => JSON.parse(JSON.stringify(o));
const fx = (f) => readFileSync(join(here, "mspdi", f), "utf8");
const parseFx = (f) => plain(C.parse(fx(f)));
const NS = "http://schemas.microsoft.com/project";
const byUid = (p, uid) => p.tasks.find((t) => t.uid === uid);
const links = (t) => t.links.map((l) => l.predUid + l.type + l.lagDays).join(",");
const codes = (p) => p.warnings.map((w) => w.code);
const rejects = (xml, code) => assert.throws(() => C.parse(xml), (e) => e.name === "MspError" && e.code === code, "expected rejection " + code);
// a minimal valid project around some <Task> bodies
const task = (uid, name, extra = "") => `<Task><UID>${uid}</UID><Name>${name}</Name><OutlineLevel>1</OutlineLevel><Summary>0</Summary><Milestone>0</Milestone>` +
  `<Start>2026-03-02T08:00:00</Start><Finish>2026-03-03T17:00:00</Finish><Duration>PT16H0M0S</Duration><PercentComplete>0</PercentComplete>${extra}</Task>`;
const project = (tasks, head = "") => `<?xml version="1.0" encoding="UTF-8"?><Project xmlns="${NS}">${head}<Tasks>${tasks}</Tasks></Project>`;

// ---------- real ProjectLibre files ----------
test("every fixture file parses", () => {
  const files = readdirSync(join(here, "mspdi")).filter((f) => f.endsWith(".xml")).sort();
  assert.equal(files.length, 7);
  for (const f of files) assert.ok(parseFx(f).tasks.length > 0, f);
});
test("01: mixed link types, lags, percent complete and one outline summary", () => {
  const p = parseFx("01-simple-fs.xml");
  assert.equal(p.tasks.length, 14);
  assert.equal(byUid(p, 1).isSummary, true);
  assert.equal(byUid(p, 1).percent, 15);
  assert.deepEqual([2, 3, 4].map((u) => byUid(p, u).percent), [100, 60, 10]);
  const all = p.tasks.flatMap((t) => t.links.map((l) => l.type)).sort();
  assert.deepEqual(all, ["FF", "FS", "FS", "FS", "FS", "FS", "FS", "FS", "FS", "SF", "SS", "SS"]);   // 8 FS, 2 SS, 1 FF, 1 SF
  assert.equal(links(byUid(p, 3)), "2SS0");
  assert.equal(links(byUid(p, 7)), "6SS0");
  assert.equal(links(byUid(p, 10)), "9FF0");
  assert.equal(links(byUid(p, 14)), "13SF1");                                  // 2400 tenths of a minute = 4 h = half a day, rounded away from zero
  const pl = plain(C.toPayload(C.parse(fx("01-simple-fs.xml"))));
  assert.equal(pl.phases.length, 1);
  assert.equal(pl.tasks.length, 13);
  assert.ok(pl.tasks.every((t) => t.phase_uid === 1 && t.parent_uid === null));
  assert.ok(codes(p).includes("constraint-ignored"));
  assert.ok(!codes(p).includes("finish-recomputed"), "mid-day starts that run into the next day are valid, not stale");
});
test("02: all four link types, lag and lead", () => {
  const p = parseFx("02-link-types.xml");
  assert.equal(p.tasks.length, 11);
  assert.equal(links(byUid(p, 4)), "3FS2");                                    // +2 days
  assert.equal(links(byUid(p, 9)), "8FF-1");                                   // lead of one day
  assert.equal(links(byUid(p, 11)), "10SF2");
  assert.equal(links(byUid(p, 3)), "2SS0");
  assert.equal(p.tasks.flatMap((t) => t.links).length, 9);
});
test("03: two summaries and a milestone, with a cross-group link", () => {
  const p = parseFx("03-milestones-summary.xml");
  assert.deepEqual(p.tasks.filter((t) => t.isSummary).map((t) => t.uid), [1, 5]);
  const m = byUid(p, 9);
  assert.equal(m.isMilestone, true);
  assert.equal(m.level, 2);
  assert.equal(links(m), "4FS0,8FS0");
  assert.equal(links(byUid(p, 6)), "2SS0");
  assert.equal(plain(C.toPayload(C.parse(fx("03-milestones-summary.xml")))).phases.length, 2);
});
test("04: four outline levels come from OutlineLevel; the stray WBS is not trusted", () => {
  const p = parseFx("04-hierarchy-deep.xml");
  assert.deepEqual(p.tasks.map((t) => t.level), [1, 2, 3, 4, 4, 3, 4, 4, 2, 3, 4, 4]);
  assert.equal(p.tasks.filter((t) => t.isSummary).length, 6);
  const a2 = p.tasks.find((t) => t.name === "Task A2");
  assert.equal(a2.parentUid, p.tasks.find((t) => t.name === "WP1").uid);       // the file says <WBS>1.1</WBS> for this row; its real place is 1.1.1.2
  const pl = plain(C.toPayload(C.parse(fx("04-hierarchy-deep.xml"))));
  assert.equal(pl.phases.length, 1);
  assert.equal(pl.tasks.length, 11);
  const t = (n) => pl.tasks.find((x) => x.name === n);
  assert.equal(t("Phase A").parent_uid, null);                                 // directly under the phase
  assert.equal(t("Task A1").parent_uid, t("WP1").uid);
  assert.ok(pl.tasks.every((x) => x.phase_uid === pl.phases[0].uid));
  assert.equal(pl.tasks.filter((x) => x.is_summary).length, 5);
});
test("05: resources, assignments (placeholders skipped), baselines", () => {
  const p = parseFx("05-resources-baseline.xml");
  assert.deepEqual(p.resources.map((r) => r.name), ["Technician 1", "Technician 2", "Bearing"]);   // UID 0 "Unassigned" skipped
  assert.equal(p.assignments.length, 4);                                       // the two placeholder (-65535) assignments are skipped
  assert.deepEqual(p.assignments.filter((a) => a.taskUid === 2).map((a) => [a.resourceUid, a.units]), [[1, 1], [2, 0.5]]);
  assert.equal(p.assignments.find((a) => a.resourceUid === 3).workHours, 40);
  for (const u of [1, 2]) { const t = byUid(p, u); assert.equal(t.baselineStart, t.start); assert.equal(t.baselineEnd, t.end); }
  for (const u of [3, 4, 5]) { const t = byUid(p, u); assert.ok(t.start > t.baselineStart && t.end > t.baselineEnd, "uid " + u + " is later than its baseline"); }
  assert.ok(codes(p).includes("resource-rates-dropped"));
  assert.ok(p.tasks.every((t) => t.level === 1 && !t.isSummary));              // flat: no phases
  assert.equal(plain(C.toPayload(C.parse(fx("05-resources-baseline.xml")))).phases.length, 0);
});
test("06: Mon-Fri calendar with an exception; the stale finish is recomputed once", () => {
  const p = parseFx("06-calendar-monfri.xml");
  assert.equal(p.project.calendar, "working-days");
  const test2 = byUid(p, 2);
  assert.deepEqual([test2.start, test2.end], ["2026-10-27", "2026-10-30"]);    // stored 10-28 is a non-working day; 16 h from Tue = Tue + Fri
  assert.deepEqual([byUid(p, 3).start, byUid(p, 3).end], ["2026-10-30", "2026-11-02"]);   // 2 working days = 4 calendar days (Fri to Mon)
  assert.deepEqual([byUid(p, 7).start, byUid(p, 7).end], ["2026-11-09", "2026-11-10"]);   // 12 h
  assert.deepEqual([byUid(p, 8).start, byUid(p, 8).end], ["2026-11-10", "2026-11-10"]);   // 1 h
  assert.equal(p.warnings.find((w) => w.code === "finish-recomputed").count, 1);
  assert.ok(codes(p).includes("calendar-working-days"));
});
test("07 (synthetic): a material resource keeps its name, loses its quantity, and warns", () => {
  const p = parseFx("07-synthetic-material.xml");
  const mat = p.resources.find((r) => r.name === "Bearing set");
  assert.equal(mat.materialLike, true);
  assert.equal(mat.materialLabel, "set");
  const a = p.assignments.find((x) => x.resourceUid === mat.uid);
  assert.deepEqual([a.units, a.workHours], [null, null]);
  assert.deepEqual(p.assignments.filter((x) => x.resourceUid !== mat.uid).map((x) => x.units), [1, 1]);   // the work resource is untouched
  assert.ok(codes(p).includes("material-resource") && codes(p).includes("material-quantity-dropped"));
});

// ---------- hostile and malformed input ----------
test("rejected: DOCTYPE, ENTITY, binary or non-XML, wrong root, no namespace, broken tags, no tasks, size and count caps", () => {
  rejects(`<?xml version="1.0"?><!DOCTYPE Project [<!ENTITY x "y">]><Project xmlns="${NS}"><Tasks>${task(1, "A")}</Tasks></Project>`, "doctype");
  rejects(`<Project xmlns="${NS}"><!ENTITY a "b"><Tasks>${task(1, "A")}</Tasks></Project>`, "doctype");
  rejects("¬í\u0000\u0005sr\u0000", "not-xml");                       // a native .pod (Java serialization)
  rejects("", "not-xml");
  rejects(`<?xml version="1.0"?><Other xmlns="${NS}"/>`, "bad-root");
  rejects(`<?xml version="1.0"?><Project><Tasks>${task(1, "A")}</Tasks></Project>`, "bad-namespace");
  rejects(`<?xml version="1.0"?><Project xmlns="urn:other"><Tasks>${task(1, "A")}</Tasks></Project>`, "bad-namespace");
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}"><Tasks><Task></Tasks></Project>`, "bad-xml");
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}"><Tasks></Tasks>`, "bad-xml");
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}"><Tasks><Task></Tasks></Task></Project>`, "bad-xml");   // closings swapped: balanced, but not nested
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}"></Project><Project xmlns="${NS}"></Project>`, "bad-xml");
  rejects(project(""), "no-tasks");
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}"/>`, "no-tasks");
  rejects(project(Array.from({ length: 2001 }, (_, i) => task(i + 1, "T" + i)).join("")), "too-many-tasks");
  rejects("<?xml version=\"1.0\"?><Project xmlns=\"" + NS + "\">" + "x".repeat(5000001) + "</Project>", "too-large");
  rejects(`<?xml version="1.0"?><Project xmlns="${NS}">` + "<a>".repeat(70) + "</Project>", "bad-xml");
  const manyLinks = task(1, "A") + `<Task><UID>2</UID><Name>B</Name><OutlineLevel>1</OutlineLevel>${"<PredecessorLink><PredecessorUID>1</PredecessorUID><Type>1</Type></PredecessorLink>".repeat(5001)}</Task>`;
  rejects(project(manyLinks), "too-many-links");
});
test("names stay inert text: entities decoded, markup is not markup, control characters stripped, length capped", () => {
  const p = C.parse(project(task(1, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &#65;&#x42;") + task(2, "<![CDATA[<b>bold</b>]]>") + task(3, "a\u0001b\u0007c") + task(4, "x".repeat(400))));
  assert.equal(p.tasks[0].name, "<script>alert(1)</script> & AB");
  assert.equal(p.tasks[1].name, "<b>bold</b>");
  assert.equal(p.tasks[2].name, "abc");
  assert.equal(p.tasks[3].name.length, 255);
  assert.equal(C.parse(project(task(1, "a&unknown;b"))).tasks[0].name, "a&unknown;b");   // only the five predefined entities and numeric references decode
});
test("bad rows: UID 0, IsNull, duplicates, invalid dates, end before start, links to nowhere, self links, lag clamps", () => {
  const p = plain(C.parse(project(
    task(0, "Project summary") + task(1, "ok") + task(1, "duplicate") + task(2, "nulled", "<IsNull>1</IsNull>") +
    `<Task><UID>3</UID><Name>bad date</Name><OutlineLevel>1</OutlineLevel><Start>2026-02-30T08:00:00</Start><Finish>2026-03-03T17:00:00</Finish></Task>` +
    `<Task><UID>4</UID><Name>backwards</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-05T08:00:00</Start><Finish>2026-03-03T17:00:00</Finish></Task>` +
    `<Task><UID>5</UID><Name>year</Name><OutlineLevel>1</OutlineLevel><Start>1999-03-05T08:00:00</Start><Finish>2026-03-06T17:00:00</Finish></Task>` +
    task(6, "links", `<PredecessorLink><PredecessorUID>1</PredecessorUID><Type>1</Type><LinkLag>${480 * 10 * 1000}</LinkLag></PredecessorLink>` +
      `<PredecessorLink><PredecessorUID>1</PredecessorUID><Type>3</Type><LinkLag>${-480 * 10 * 99}</LinkLag></PredecessorLink>` +
      `<PredecessorLink><PredecessorUID>1</PredecessorUID><Type>9</Type></PredecessorLink><PredecessorLink><Type>1</Type></PredecessorLink>`))));
  assert.deepEqual(p.tasks.map((t) => t.uid), [1, 3, 4, 5, 6]);               // 0, the duplicate 1 and the IsNull row are gone
  assert.deepEqual([3, 4, 5].map((u) => [byUid(p, u).start, byUid(p, u).end]), [[null, null], [null, null], [null, null]]);
  assert.deepEqual(byUid(p, 6).links.map((l) => l.type + l.lagDays), ["FS365", "SS-30", "FS0"]);
  assert.ok(["row-skipped", "duplicate-uid", "dates-invalid", "lag-clamped", "link-type", "link-dropped"].every((c) => codes(p).includes(c)));
  const payload = plain(C.toPayload(C.parse(project(task(1, "A", `<PredecessorLink><PredecessorUID>1</PredecessorUID></PredecessorLink><PredecessorLink><PredecessorUID>99</PredecessorUID></PredecessorLink>`)))));
  assert.deepEqual(payload.tasks[0].links, []);                                // self link and a link to a missing task are dropped
});
test("outline: levels that jump, and rows nested deeper than six levels", () => {
  const row = (uid, level, sum = 0) => `<Task><UID>${uid}</UID><Name>L${uid}</Name><OutlineLevel>${level}</OutlineLevel><Summary>${sum}</Summary><Start>2026-03-02T08:00:00</Start><Finish>2026-03-02T17:00:00</Finish><Duration>PT8H0M0S</Duration></Task>`;
  const p = plain(C.parse(project(row(1, 1, 1) + row(2, 3) + row(3, 2) + row(4, 1))));
  assert.deepEqual(p.tasks.map((t) => t.parentUid), [null, 1, 1, null]);       // a jump from level 1 to 3 attaches to the nearest shallower row
  const deep = plain(C.parse(project([1, 2, 3, 4, 5, 6, 7, 8].map((l) => row(l, l, l < 8 ? 1 : 0)).join(""))));
  assert.equal(deep.tasks[5].parentUid, 5);                                    // depth 6 (the phase counts as level 1) is the deepest allowed
  assert.equal(deep.tasks[6].parentUid, 5);                                    // levels 7 and 8 attach to the level-5 row so they land on depth 6
  assert.equal(deep.tasks[7].parentUid, 5);
  assert.ok(codes(deep).includes("depth-flattened"));
  assert.equal(byUid(plain(C.parse(project(row(1, 1, 1)))), 1).isSummary, false);   // "Summary=1" with no children is a plain task
});
test("milestones: the flag, or a zero duration on a leaf", () => {
  const p = plain(C.parse(project(
    `<Task><UID>1</UID><Name>flag</Name><OutlineLevel>1</OutlineLevel><Milestone>1</Milestone><Start>2026-03-02T08:00:00</Start><Finish>2026-03-02T08:00:00</Finish><Duration>PT0H0M0S</Duration></Task>` +
    `<Task><UID>2</UID><Name>zero</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-04T08:00:00</Start><Finish>2026-03-05T08:00:00</Finish><Duration>PT0H0M0S</Duration></Task>` + task(3, "normal"))));
  assert.deepEqual(p.tasks.map((t) => t.isMilestone), [true, true, false]);
  assert.equal(byUid(p, 2).end, byUid(p, 2).start);                            // a milestone ends the day it starts
});
test("calendar: a 7-day calendar keeps the file's dates; working-day files recompute only a finish on a non-working day", () => {
  const cal = (days, ex = "") => `<CalendarUID>1</CalendarUID><MinutesPerDay>480</MinutesPerDay><Calendars><Calendar><UID>1</UID><Name>c</Name><IsBaseCalendar>1</IsBaseCalendar><WeekDays>` +
    days.map((w, i) => `<WeekDay><DayType>${i + 1}</DayType><DayWorking>${w}</DayWorking></WeekDay>`).join("") + `</WeekDays>${ex}</Calendar></Calendars>`;
  const sat = `<Task><UID>1</UID><Name>weekend finish</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-06T08:00:00</Start><Finish>2026-03-07T17:00:00</Finish><Duration>PT16H0M0S</Duration></Task>`;
  // Fri 03-06 + 16 h on a Mon-Fri calendar ends Mon 03-09; the stored Saturday finish is stale
  const wk = plain(C.parse(project(sat, cal([0, 1, 1, 1, 1, 1, 0]))));
  assert.equal(wk.tasks[0].end, "2026-03-09");
  const seven = plain(C.parse(project(sat, cal([1, 1, 1, 1, 1, 1, 1]))));
  assert.equal(seven.tasks[0].end, "2026-03-07");
  assert.equal(seven.project.calendar, "seven-day");
  assert.ok(!codes(seven).includes("calendar-working-days") && !codes(seven).includes("finish-recomputed"));
  assert.equal(plain(C.parse(project(sat))).tasks[0].end, "2026-03-07");       // no calendar at all: dates are authoritative
  // a stored finish on a WORKING day is kept even when the calendar would say otherwise (Mon + 8 h would end Mon; the file says Wed)
  const kept = `<Task><UID>1</UID><Name>kept</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-02T08:00:00</Start><Finish>2026-03-04T17:00:00</Finish><Duration>PT8H0M0S</Duration></Task>`;
  assert.equal(plain(C.parse(project(kept, cal([0, 1, 1, 1, 1, 1, 0])))).tasks[0].end, "2026-03-04");
});

test("calendar recompute follows the time of day: 16 h from Thursday 13:00 ends Monday, not Friday", () => {
  const cal = `<CalendarUID>1</CalendarUID><MinutesPerDay>480</MinutesPerDay><Calendars><Calendar><UID>1</UID><Name>c</Name><IsBaseCalendar>1</IsBaseCalendar><WeekDays>` +
    [0, 1, 1, 1, 1, 1, 0].map((w, i) => `<WeekDay><DayType>${i + 1}</DayType><DayWorking>${w}</DayWorking>${w ? "<WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes>" : ""}</WeekDay>`).join("") + `</WeekDays></Calendar></Calendars>`;
  const t = `<Task><UID>1</UID><Name>t</Name><OutlineLevel>1</OutlineLevel><Start>2026-03-05T13:00:00</Start><Finish>2026-03-07T17:00:00</Finish><Duration>PT16H0M0S</Duration></Task>`;
  assert.equal(plain(C.parse(project(t, cal))).tasks[0].end, "2026-03-09");      // Thu 4 h + Fri 8 h + Mon 4 h
});
test("percent complete is clamped, a material-like work value is not trusted, and a link to a phase is dropped", () => {
  const p = plain(C.parse(project(task(1, "over", "<PercentComplete>150</PercentComplete>").replace("<PercentComplete>0</PercentComplete>", "") + task(2, "under").replace("<PercentComplete>0</PercentComplete>", "<PercentComplete>-5</PercentComplete>"))));
  assert.deepEqual(p.tasks.map((t) => t.percent), [100, 0]);
  const m = plain(C.parse(project(task(1, "t"), `<Resources><Resource><UID>1</UID><Name>Bearing</Name><Type>1</Type></Resource></Resources>`).replace("</Tasks>", `</Tasks><Assignments><Assignment><TaskUID>1</TaskUID><ResourceUID>1</ResourceUID><Units>1</Units><Work>PT24000000H0M0S</Work></Assignment></Assignments>`)));
  assert.equal(m.resources[0].materialLike, true);
  assert.deepEqual([m.assignments[0].units, m.assignments[0].workHours], [null, null]);
  const row = (uid, level, sum, extra = "") => `<Task><UID>${uid}</UID><Name>n${uid}</Name><OutlineLevel>${level}</OutlineLevel><Summary>${sum}</Summary><Start>2026-03-02T08:00:00</Start><Finish>2026-03-02T17:00:00</Finish><Duration>PT8H0M0S</Duration>${extra}</Task>`;
  const pl = plain(C.toPayload(C.parse(project(row(1, 1, 1) + row(2, 2, 0) + row(3, 1, 1) + row(4, 2, 0, `<PredecessorLink><PredecessorUID>1</PredecessorUID><Type>1</Type></PredecessorLink><PredecessorLink><PredecessorUID>2</PredecessorUID><Type>1</Type></PredecessorLink>`)))));
  assert.deepEqual(pl.tasks.find((t) => t.uid === 4).links.map((l) => l.pred_uid), [2]);   // the link to phase 1 is dropped, the link to a task stays
  assert.ok(pl.warnings.some((w) => w.code === "link-dropped"));
});

// ---------- build, and the round trip ----------
const model = () => ({
  project: { id: "4f5b1c1e-0000-4000-8000-000000000001", name: "WO-0142", title: "WO-0142 Motor repair" },
  phases: [{ uid: 10, name: "Teardown" }, { uid: 11, name: "Reassembly" }],
  tasks: [
    { uid: 20, name: "Inspect <motor> & \"log\"", phase_uid: 10, parent_uid: null, start_date: "2026-03-02", end_date: "2026-03-04", progress: 100, is_milestone: false, is_critical: true, baseline_start: "2026-03-02", baseline_end: "2026-03-03", links: [] },
    { uid: 21, name: "Remove bearings", phase_uid: 10, parent_uid: null, start_date: "2026-03-05", end_date: "2026-03-10", progress: 40, is_milestone: false, links: [{ pred_uid: 20, link_type: "FS", lag_days: 1 }] },
    { uid: 22, name: "Bearing A", phase_uid: 10, parent_uid: 21, start_date: "2026-03-05", end_date: "2026-03-07", progress: 50, is_milestone: false, links: [{ pred_uid: 20, link_type: "SS", lag_days: 0 }] },
    { uid: 23, name: "Bearing B", phase_uid: 10, parent_uid: 21, start_date: "2026-03-08", end_date: "2026-03-10", progress: 25, is_milestone: false, links: [{ pred_uid: 22, link_type: "FF", lag_days: -1 }, { pred_uid: 20, link_type: "SF", lag_days: 3 }] },
    { uid: 24, name: "Fit new bearings", phase_uid: 11, parent_uid: null, start_date: "2026-03-11", end_date: "2026-03-13", progress: 0, is_milestone: false, links: [{ pred_uid: 21, link_type: "FS", lag_days: 0 }] },
    { uid: 25, name: "Delivery", phase_uid: null, parent_uid: null, start_date: "2026-03-16", end_date: "2026-03-16", progress: 0, is_milestone: true, links: [{ pred_uid: 24, link_type: "FS", lag_days: 0 }] },
  ],
});
test("round trip: build, parse, toPayload gives back every mapped field", () => {
  const m = model(), xml = C.build(m, { notice: "Property of Q2 Machines. Confidential." });
  const parsed = C.parse(xml), pl = plain(C.toPayload(parsed));
  assert.deepEqual(pl.phases.map((p) => [p.uid, p.name]), [[10, "Teardown"], [11, "Reassembly"]]);
  assert.equal(pl.tasks.length, m.tasks.length);
  for (const t of m.tasks) {
    const g = pl.tasks.find((x) => x.uid === t.uid);
    assert.ok(g, "task " + t.uid);
    assert.equal(g.name, t.name);
    assert.equal(g.phase_uid, t.phase_uid);
    assert.equal(g.parent_uid, t.parent_uid);
    if (t.uid !== 21) { assert.equal(g.start_date, t.start_date); assert.equal(g.end_date, t.end_date); assert.equal(g.progress, t.progress); }
    assert.equal(g.is_milestone, !!t.is_milestone);
    assert.deepEqual(g.links.map((l) => [l.pred_uid, l.link_type, l.lag_days]), t.links.map((l) => [l.pred_uid, l.link_type, l.lag_days]));
    assert.equal(g.baseline_start, t.baseline_start || null);
    assert.equal(g.baseline_end, t.baseline_end || null);
  }
  assert.equal(pl.tasks.find((x) => x.uid === 21).is_summary, true);           // Remove bearings has children, so it is a summary row
  assert.equal(pl.tasks.find((x) => x.uid === 21).start_date, "2026-03-05");   // a summary's span is derived from its children on export
  assert.equal(pl.tasks.find((x) => x.uid === 21).end_date, "2026-03-10");
  assert.equal(parsed.project.calendar, "seven-day");
  assert.deepEqual(plain(codes(parsed)), []);                                  // our own file produces no warnings
  assert.equal(parsed.project.minutesPerDay, 480);
  assert.equal(parsed.project.uid, m.project.id);                              // the identity an import uses to tell "from this job" from a foreign file
  assert.equal(parsed.project.manager, null);
  assert.equal(C.parse(C.build(m, { manager: "meridian-readonly-export" })).project.manager, "meridian-readonly-export");
  assert.equal(parseFx("01-simple-fs.xml").project.uid, null);                 // ProjectLibre files carry no Meridian identity
});
test("round trip does not depend on input order", () => {
  const a = model(), b = model();
  b.tasks.reverse(); b.phases.reverse();
  const pa = plain(C.toPayload(C.parse(C.build(a)))), pb = plain(C.toPayload(C.parse(C.build(b))));
  const norm = (p) => p.tasks.map((t) => ({ ...t, sort_order: 0 })).sort((x, y) => x.uid - y.uid);
  assert.deepEqual(norm(pb), norm(pa));
});
test("build: format details the other tools rely on", () => {
  const xml = C.build(model(), { notice: "Property of Q2 Machines. Confidential." });
  assert.ok(xml.startsWith('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'));
  assert.ok(xml.includes(`<Project xmlns="${NS}">`));
  assert.ok(xml.includes("<MinutesPerDay>480</MinutesPerDay>") && xml.includes("<MinutesPerWeek>3360</MinutesPerWeek>") && xml.includes("<DaysPerMonth>30</DaysPerMonth>"));
  assert.equal((xml.match(/<DayWorking>1<\/DayWorking>/g) || []).length, 7);   // a 7-day working calendar
  assert.ok(xml.includes("<Duration>PT24H0M0S</Duration>"));                   // Inspect: 03-02..03-04 = 3 days = 24 h
  assert.ok(xml.includes("<Duration>PT0H0M0S</Duration>"));                    // the milestone
  assert.ok(xml.includes("<LinkLag>4800</LinkLag>") && xml.includes("<LinkLag>-4800</LinkLag>"));   // +1 day and -1 day, tenths of a minute at 480 min/day
  assert.ok(xml.includes("<ConstraintType>4</ConstraintType>"));               // Start No Earlier Than pins every dated leaf
  assert.ok(xml.includes("<Subject>Property of Q2 Machines. Confidential.</Subject>") && xml.includes("<Notes>Property of Q2 Machines. Confidential.</Notes>"));
  assert.ok(xml.includes("Inspect &lt;motor&gt; &amp; &quot;log&quot;"));      // names are escaped
  const rows = xml.split("<Task>").slice(1);
  assert.equal(rows.length, 8);                                                // 2 phases + 6 tasks
  assert.equal(rows.map((r) => /<OutlineLevel>(\d+)/.exec(r)[1]).join(""), "12233121");   // Teardown, Inspect, Remove bearings, Bearing A, Bearing B, Reassembly, Fit, Delivery
});
test("build refuses bad models", () => {
  const bad = (mut, code = "bad-model") => { const m = model(); mut(m); assert.throws(() => C.build(m), (e) => e.name === "MspError" && e.code === code); };
  bad((m) => { m.tasks[0].uid = 21; });                                        // duplicate UID
  bad((m) => { m.tasks[5].uid = 10; });                                        // a task that shares a phase's UID
  bad((m) => { m.tasks[0].uid = 0; });
  bad((m) => { m.tasks[0].uid = 1.5; });
  bad((m) => { m.tasks[0].phase_uid = 999; });                                 // phase does not exist
  bad((m) => { m.tasks[2].parent_uid = 999; });
  bad((m) => { m.tasks[1].links[0].link_type = "XX"; });
});
test("build: control characters are removed and a link to an unknown UID is skipped", () => {
  const m = model(); m.tasks[0].name = "a\u0001b"; m.tasks[1].links.push({ pred_uid: 999, link_type: "FS", lag_days: 0 });
  const p = plain(C.toPayload(C.parse(C.build(m))));
  assert.equal(p.tasks.find((t) => t.uid === 20).name, "ab");
  assert.equal(p.tasks.find((t) => t.uid === 21).links.length, 1);
});

// ---------- purity ----------
test("the codec exports a frozen API and never touches Date", () => {
  assert.ok(Object.isFrozen(C));
  assert.deepEqual(Object.keys(C).sort(), ["LIMITS", "MspError", "NS", "build", "parse", "parseDay", "toPayload", "ymdOf"]);
  assert.equal(C.parseDay("2026-02-30"), null);
  assert.equal(C.parseDay("2100-12-31") - C.parseDay("2000-01-01"), 36889);
  assert.equal(C.ymdOf(C.parseDay("2026-03-02") + 1), "2026-03-03");
});
