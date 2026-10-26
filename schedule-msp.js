// schedule-msp.js — MS Project XML (MSPDI) codec for the Meridian schedule (Phase A2a).
// ONE pure, DOM-free implementation shared by the ERP schedule window and (copied and verified, O3) the client portal.
// No DOM, no fetch, no Date, no globals other than the one it defines: it runs in a browser <script>, and in Node via vm.
//   MspCodec.parse(xmlText)      -> { project, calendar, tasks, resources, assignments, warnings }   (throws MspError on rejection)
//   MspCodec.toPayload(parsed)   -> { phases, tasks, resources, assignments, warnings }              (Meridian-shaped, UID-based)
//   MspCodec.build(model, opts)  -> MSPDI XML string                                                  (caller supplies stable UIDs)
// The server RE-VALIDATES everything the browser parses (import_job_schedule); the parser's limits below only protect the
// browser. Rules come from docs/specs/project-portal/phase-a2-projectlibre.md ("Fixture findings") and the ProjectLibre
// fixtures in scripts/tests/schedule/mspdi/: durations are working HOURS, hierarchy comes from OutlineLevel only (WBS is
// unreliable), link type codes are 0=FF 1=FS 2=SF 3=SS, lag is in tenths of a minute, placeholder resources are skipped.
const MspCodec = (function () {
  'use strict';
  const NS = 'http://schemas.microsoft.com/project';
  const LIMITS = Object.freeze({ chars: 5000000, tasks: 2000, links: 5000, elements: 400000, depth: 64, nameLen: 255, outlineDepth: 6 });
  const LINK_CODE = Object.freeze({ FF: 0, FS: 1, SF: 2, SS: 3 });
  const CODE_LINK = Object.freeze({ 0: 'FF', 1: 'FS', 2: 'SF', 3: 'SS' });
  const PLACEHOLDER_RESOURCE = -65535;
  const DEFAULT_TIMES = Object.freeze([[480, 720], [780, 1020]]);   // 08:00-12:00 and 13:00-17:00 when a working day lists no times

  class MspError extends Error {
    constructor(code, message) { super(message || code); this.name = 'MspError'; this.code = code; }
  }

  // ---------------------------------------------------------------- dates (integer UTC day numbers, no Date)
  function dayNum(y, m, d) {                                     // Hinnant days_from_civil
    y -= m <= 2 ? 1 : 0;
    const era = Math.floor(y / 400), yoe = y - era * 400, doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
    return era * 146097 + yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy - 719468;
  }
  function ymdOf(n) {                                            // Hinnant civil_from_days
    const z = n + 719468, era = Math.floor(z / 146097), doe = z - era * 146097;
    const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100)), mp = Math.floor((5 * doy + 2) / 153);
    const d = doy - Math.floor((153 * mp + 2) / 5) + 1, mo = mp < 10 ? mp + 3 : mp - 9, y = yoe + era * 400 + (mo <= 2 ? 1 : 0);
    return String(y).padStart(4, '0') + '-' + String(mo).padStart(2, '0') + '-' + String(d).padStart(2, '0');
  }
  // 'YYYY-MM-DD[T...]' -> day number, or null when not a real calendar date in 2000..2100
  function parseDay(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s == null ? '' : s).trim());
    if (!m) return null;
    const y = +m[1], mo = +m[2], d = +m[3];
    if (y < 2000 || y > 2100 || mo < 1 || mo > 12 || d < 1) return null;
    const n = dayNum(y, mo, d);
    return ymdOf(n) === m[1] + '-' + m[2] + '-' + m[3] ? n : null;   // rejects 02-30 and the like
  }
  const weekdayType = n => (((n + 4) % 7) + 7) % 7 + 1;          // MSPDI DayType: 1 = Sunday .. 7 = Saturday

  // ---------------------------------------------------------------- strict, tiny XML reader
  // Rejects DOCTYPE/ENTITY outright (no entity expansion, no external entities), supports the five predefined entities and
  // numeric character references, comments, CDATA and processing instructions. Namespace prefixes are dropped (local names).
  function decodeText(s) {
    if (s.indexOf('&') < 0) return s;
    return s.replace(/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|amp|lt|gt|quot|apos);/g, (all, e) => {
      if (e[0] === '#') {
        const cp = e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        return cp > 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) ? String.fromCodePoint(cp) : '';
      }
      return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[e];
    });
  }
  function readXml(src) {
    if (typeof src !== 'string') throw new MspError('not-xml', 'The file is not text.');
    if (src.length > LIMITS.chars) throw new MspError('too-large', 'The file is larger than 5 MB.');
    if (src.charCodeAt(0) === 0xFEFF) src = src.slice(1);
    if (!/^\s*<\?xml[\s?]/.test(src) && !/^\s*<[A-Za-z]/.test(src)) throw new MspError('not-xml', 'The file is not XML (it must start with <?xml). Re-save it as MS Project XML.');
    if (/<!DOCTYPE|<!ENTITY/i.test(src)) throw new MspError('doctype', 'The file declares a DOCTYPE or ENTITY, which is not allowed.');
    const root = { n: '#doc', a: {}, t: '', c: [] }, stack = [root];
    let i = 0, elements = 0;
    const len = src.length;
    while (i < len) {
      const lt = src.indexOf('<', i);
      const top = stack[stack.length - 1];
      if (lt < 0) { top.t += decodeText(src.slice(i)); break; }
      if (lt > i) top.t += decodeText(src.slice(i, lt));
      if (src.startsWith('<!--', lt)) {
        const e = src.indexOf('-->', lt + 4); if (e < 0) throw new MspError('bad-xml', 'Unterminated comment.');
        i = e + 3;
      } else if (src.startsWith('<![CDATA[', lt)) {
        const e = src.indexOf(']]>', lt + 9); if (e < 0) throw new MspError('bad-xml', 'Unterminated CDATA.');
        top.t += src.slice(lt + 9, e); i = e + 3;
      } else if (src.startsWith('<?', lt)) {
        const e = src.indexOf('?>', lt + 2); if (e < 0) throw new MspError('bad-xml', 'Unterminated processing instruction.');
        i = e + 2;
      } else if (src[lt + 1] === '/') {
        const e = src.indexOf('>', lt); if (e < 0) throw new MspError('bad-xml', 'Unterminated tag.');
        const name = src.slice(lt + 2, e).trim().replace(/^[^:]*:/, '');
        if (stack.length < 2 || top.n !== name) throw new MspError('bad-xml', 'Mismatched closing tag </' + name + '>.');
        stack.pop(); i = e + 1;
      } else if (src[lt + 1] === '!') {
        throw new MspError('bad-xml', 'Unsupported markup declaration.');
      } else {
        const m = /^<([A-Za-z_][\w.:-]*)((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>/.exec(src.slice(lt, lt + 4096));
        if (!m) throw new MspError('bad-xml', 'Malformed tag near character ' + lt + '.');
        if (++elements > LIMITS.elements) throw new MspError('too-large', 'The file has too many elements.');
        const attrs = {};
        m[2].replace(/([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g, (all, k, v1, v2) => { attrs[k] = decodeText(v1 !== undefined ? v1 : v2); return ''; });
        const node = { n: m[1].replace(/^[^:]*:/, ''), a: attrs, t: '', c: [] };
        top.c.push(node);
        if (!m[3]) { if (stack.length >= LIMITS.depth) throw new MspError('bad-xml', 'The file is nested too deeply.'); stack.push(node); }
        i = lt + m[0].length;
      }
    }
    if (stack.length !== 1) throw new MspError('bad-xml', 'The file ends before all tags are closed.');
    const top = root.c.filter(x => x.n !== '#text');
    if (top.length !== 1) throw new MspError('bad-xml', 'The file must have exactly one root element.');
    return top[0];
  }
  const kid = (node, name) => { for (const c of node.c) if (c.n === name) return c; return null; };
  const kids = (node, name) => node.c.filter(c => c.n === name);
  const txt = (node, name) => { const k = node && kid(node, name); return k ? k.t.trim() : null; };
  const num = (node, name) => { const s = txt(node, name); if (s == null || s === '') return null; const v = Number(s); return Number.isFinite(v) ? v : null; };
  const clean = (s, max) => String(s == null ? '' : s).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').replace(/\s+/g, ' ').trim().slice(0, max == null ? LIMITS.nameLen : max);

  function clock(s) {                                            // 'HH:MM:SS' or '...THH:MM:SS' -> minutes after midnight, or null
    const m = /(?:^|T)(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(String(s == null ? '' : s).trim());
    return m && +m[1] <= 24 && +m[2] < 60 ? +m[1] * 60 + +m[2] : null;
  }
  // ISO 8601 duration as written by MSPDI: PT8H0M0S (also tolerates days). Returns working HOURS, or null.
  function parseHours(s) {
    const m = /^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$/.exec(String(s == null ? '' : s).trim());
    if (!m || (m[1] == null && m[2] == null && m[3] == null && m[4] == null)) return null;
    return (+(m[1] || 0)) * 24 + (+(m[2] || 0)) + (+(m[3] || 0)) / 60 + (+(m[4] || 0)) / 3600;
  }

  // ---------------------------------------------------------------- calendars
  function readCalendars(proj) {
    const out = new Map(), root = kid(proj, 'Calendars');
    if (!root) return out;
    for (const c of kids(root, 'Calendar')) {
      const uid = num(c, 'UID'); if (uid == null) continue;
      const days = {}, ex = [];
      const wd = kid(c, 'WeekDays');
      if (wd) for (const w of kids(wd, 'WeekDay')) {
        const t = num(w, 'DayType'), working = num(w, 'DayWorking');
        if (t >= 1 && t <= 7 && working != null) {
          const times = [], wt = kid(w, 'WorkingTimes');
          if (wt) for (const x of kids(wt, 'WorkingTime')) {
            const a = clock(txt(x, 'FromTime')), b = clock(txt(x, 'ToTime'));
            if (a != null && b != null) times.push([a, b <= a ? b + 1440 : b]);           // a ToTime of 00:00:00 means midnight
          }
          days[t] = { w: working === 1, t: times.length ? times.sort((p, q) => p[0] - q[0]) : DEFAULT_TIMES };
        }
      }
      const exs = kid(c, 'Exceptions');
      if (exs) for (const e of kids(exs, 'Exception')) {
        const tp = kid(e, 'TimePeriod'); if (!tp) continue;
        const from = parseDay(txt(tp, 'FromDate')), to = parseDay(txt(tp, 'ToDate'));
        if (from == null || to == null || to < from || to - from > 3660) continue;
        ex.push({ from, to, working: num(e, 'DayWorking') === 1 });
      }
      out.set(uid, { uid, base: num(c, 'BaseCalendarUID'), days, ex });
    }
    return out;
  }
  function resolveCalendar(cals, uid) {                          // weekday flags fall back along BaseCalendarUID; exceptions accumulate
    const chain = [];
    for (let u = uid, hops = 0; u != null && cals.has(u) && hops < 8; hops++) { const c = cals.get(u); chain.push(c); u = c.base; }
    if (!chain.length) return null;
    const days = {}, ex = [];
    for (let d = 1; d <= 7; d++) { const hit = chain.find(c => c.days[d] !== undefined); days[d] = hit ? hit.days[d] : { w: true, t: DEFAULT_TIMES }; }
    for (const c of chain) ex.push(...c.ex);
    return { days, ex, allDays: Object.values(days).every(d => d.w) && ex.every(e => e.working) };
  }
  const isWorkingDay = (cal, n) => {
    for (let k = cal.ex.length - 1; k >= 0; k--) { const e = cal.ex[k]; if (n >= e.from && n <= e.to) return e.working; }
    return cal.days[weekdayType(n)].w;
  };
  const timesOf = (cal, n) => {                                   // working intervals of a day, in minutes after midnight
    for (let k = cal.ex.length - 1; k >= 0; k--) { const e = cal.ex[k]; if (n >= e.from && n <= e.to) return e.working ? DEFAULT_TIMES : []; }
    const d = cal.days[weekdayType(n)]; return d.w ? d.t : [];
  };
  // Day on which a task of `hours` working hours that starts on day `start` at minute `startMin` ends, consuming the calendar's working
  // time interval by interval (so a task that starts at 13:00 and needs 8 h ends the next working day at 13:00). Null if none within ~11 years.
  function finishFromCalendar(cal, start, startMin, hours) {
    let remaining = Math.max(0, hours * 60);
    for (let n = start, guard = 0; guard < 4000; n++, guard++) {
      for (const [a, b] of timesOf(cal, n)) {
        const from = n === start ? Math.max(a, startMin) : a;
        if (from >= b) continue;
        if (remaining <= b - from + 1e-9) return n;
        remaining -= b - from;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- parse
  function parse(xml) {
    const proj = readXml(xml);
    if (proj.n !== 'Project') throw new MspError('bad-root', 'This is not an MS Project XML file (the root element is ' + clean(proj.n, 40) + ').');
    if (proj.a.xmlns !== NS) throw new MspError('bad-namespace', 'This file is missing the MS Project namespace.');
    const warnings = [], counts = new Map();
    const warn = (code, message, n) => { const k = counts.get(code); if (k) k.count += (n || 1); else { const w = { code, message, count: n || 1 }; counts.set(code, w); warnings.push(w); } };

    const minutesPerDay = Math.min(1440, Math.max(60, num(proj, 'MinutesPerDay') || 480));
    const cals = readCalendars(proj), calUid = num(proj, 'CalendarUID');
    const cal = calUid != null ? resolveCalendar(cals, calUid) : null;
    const useCal = !!cal && !cal.allDays;                        // a 7-day calendar keeps "the file's dates are authoritative"
    const project = { uid: clean(txt(proj, 'UID') || '', 64) || null, manager: clean(txt(proj, 'Manager') || '', 80) || null,   // Project/UID = jobs.id when Meridian wrote the file
      name: clean(txt(proj, 'Name') || txt(proj, 'Title') || ''), title: clean(txt(proj, 'Title') || ''), minutesPerDay,
      calendar: cal ? (cal.allDays ? 'seven-day' : 'working-days') : 'none', saveVersion: num(proj, 'SaveVersion') };

    // ---- tasks (document order is the outline order)
    const tasksNode = kid(proj, 'Tasks'), rows = [], seen = new Set(), subject = txt(proj, 'Subject');
    let linkCount = 0;
    if (!tasksNode) throw new MspError('no-tasks', 'The file has no tasks.');
    for (const tn of kids(tasksNode, 'Task')) {
      const uid = num(tn, 'UID');
      if (uid == null || !Number.isInteger(uid) || uid <= 0 || num(tn, 'IsNull') === 1) { if (uid !== 0) warn('row-skipped', 'Empty or invalid task rows were skipped.'); continue; }
      if (seen.has(uid)) { warn('duplicate-uid', 'Tasks with a repeated UID were skipped.'); continue; }
      seen.add(uid);
      if (rows.length >= LIMITS.tasks) throw new MspError('too-many-tasks', 'The file has more than ' + LIMITS.tasks + ' tasks.');
      const links = [];
      for (const pl of kids(tn, 'PredecessorLink')) {
        if (++linkCount > LIMITS.links) throw new MspError('too-many-links', 'The file has more than ' + LIMITS.links + ' links.');
        const pu = num(pl, 'PredecessorUID'), code = num(pl, 'Type');
        let type = CODE_LINK[code == null ? 1 : code];
        if (!type) { type = 'FS'; warn('link-type', 'Links with an unknown type were read as Finish-to-Start.'); }
        const lagMin = (num(pl, 'LinkLag') || 0) / 10, fmt = num(pl, 'LagFormat');   // LinkLag is tenths of a minute whatever the display format
        let lagDays = Math.sign(lagMin) * Math.round(Math.abs(lagMin) / minutesPerDay);
        if ((fmt === 19 || fmt === 20) && lagMin !== 0) { lagDays = 0; warn('lag-format', 'Links with a percentage lag were read with no lag.'); }
        if (lagDays < -30 || lagDays > 365) { lagDays = Math.max(-30, Math.min(365, lagDays)); warn('lag-clamped', 'Link lags outside -30..365 days were clamped.'); }
        if (pu == null || !Number.isInteger(pu)) { warn('link-dropped', 'Links to a missing task were dropped.'); continue; }
        links.push({ predUid: pu, type, lagDays });
      }
      let baseStart = null, baseEnd = null;
      for (const b of kids(tn, 'Baseline')) if (num(b, 'Number') === 0) { baseStart = parseDay(txt(b, 'Start')); baseEnd = parseDay(txt(b, 'Finish')); }
      const ct = num(tn, 'ConstraintType');
      const start = parseDay(txt(tn, 'Start')), finish = parseDay(txt(tn, 'Finish'));
      if (ct != null && ct !== 0 && !(ct === 4 && parseDay(txt(tn, 'ConstraintDate')) === start)) warn('constraint-ignored', 'Scheduling constraints other than the Meridian date pin were ignored.');
      const note = txt(tn, 'Notes');
      if (note && note !== subject) warn('notes-dropped', 'Task notes were not imported.');   // a note equal to the project subject is our own ownership notice
      rows.push({ uid, name: clean(txt(tn, 'Name')), level: Math.max(1, Math.floor(num(tn, 'OutlineLevel') || 1)), summaryFlag: num(tn, 'Summary') === 1,
        milestoneFlag: num(tn, 'Milestone') === 1, start, startText: txt(tn, 'Start'), finish, hours: parseHours(txt(tn, 'Duration')),
        percent: Math.max(0, Math.min(100, Math.round(num(tn, 'PercentComplete') || 0))), baselineStart: baseStart, baselineEnd: baseEnd, links, parentUid: null });
    }
    if (!rows.length) throw new MspError('no-tasks', 'The file has no tasks.');

    // ---- outline -> parent (OutlineLevel only; WBS is not trusted). Depth beyond the cap is attached to the capped ancestor.
    const stack = [];
    for (const r of rows) {
      while (stack.length && stack[stack.length - 1].level >= r.level) stack.pop();
      r.parentUid = stack.length ? stack[stack.length - 1].uid : null;
      stack.push(r);
    }
    const byUid = new Map(rows.map(r => [r.uid, r]));
    const depthOf = r => { let d = 1; for (let p = r.parentUid; p != null; p = byUid.get(p).parentUid) d++; return d; };
    for (const r of rows) {
      if (r.parentUid != null && depthOf(r) > LIMITS.outlineDepth) {
        let p = r.parentUid; while (p != null && depthOf(byUid.get(p)) >= LIMITS.outlineDepth) p = byUid.get(p).parentUid;
        r.parentUid = p; warn('depth-flattened', 'Rows nested deeper than ' + LIMITS.outlineDepth + ' levels were moved up.');
      }
    }
    const hk = new Set(rows.filter(r => r.parentUid != null).map(r => r.parentUid));
    let recomputed = 0;
    const tasks = rows.map(r => {
      const isSummary = hk.has(r.uid);
      const isMilestone = !isSummary && (r.milestoneFlag || r.hours === 0);
      let s = r.start, e = r.finish;
      if (!isSummary && s != null && e != null && e < s) { warn('dates-invalid', 'Tasks whose finish is before their start were imported without dates.'); s = null; e = null; }
      if (isMilestone && s != null) e = s;
      // A stored finish on a NON-working day (ProjectLibre leaves it stale across a calendar exception) is recomputed from the calendar;
      // a finish on a working day is kept: the file's dates stay authoritative.
      if (useCal && !isSummary && !isMilestone && s != null && e != null && r.hours != null && r.hours > 0 && !isWorkingDay(cal, e)) {
        const f = finishFromCalendar(cal, s, clock(r.startText) == null ? 480 : clock(r.startText), r.hours);
        if (f != null && f !== e) { e = f; recomputed++; }
      }
      if (!isSummary && (s == null) !== (e == null)) { s = e = null; }
      return { uid: r.uid, name: r.name, level: r.level, parentUid: r.parentUid, isSummary, isMilestone, start: s == null ? null : ymdOf(s), end: e == null ? null : ymdOf(e),
        percent: r.percent, baselineStart: r.baselineStart == null ? null : ymdOf(r.baselineStart), baselineEnd: r.baselineEnd == null ? null : ymdOf(r.baselineEnd),
        durationHours: r.hours, links: r.links };
    });
    if (recomputed) warn('finish-recomputed', 'Finish dates were recomputed from the file\'s working calendar (the stored finish was stale or inconsistent).', recomputed);
    if (useCal) warn('calendar-working-days', 'The file uses a working-day calendar; Meridian schedules in calendar days, so task spans may look longer here than in the file.');

    // ---- resources and assignments (placeholders skipped; materials are not trusted)
    const resources = [], resByUid = new Map(), rn = kid(proj, 'Resources');
    if (rn) for (const x of kids(rn, 'Resource')) {
      const uid = num(x, 'UID');
      if (uid == null || uid === 0 || uid === PLACEHOLDER_RESOURCE || num(x, 'IsNull') === 1) continue;
      const type = num(x, 'Type'), label = txt(x, 'MaterialLabel');
      const r = { uid, name: clean(txt(x, 'Name')), kind: type === 0 ? 'material' : type === 2 ? 'cost' : 'work', materialLike: type === 0 || !!label, materialLabel: label ? clean(label, 40) : null };
      if (num(x, 'StandardRate') || num(x, 'OvertimeRate') || num(x, 'CostPerUse')) warn('resource-rates-dropped', 'Resource rates were not imported.');
      resources.push(r); resByUid.set(uid, r);
    }
    const assignments = [], an = kid(proj, 'Assignments');
    if (an) for (const x of kids(an, 'Assignment')) {
      const tu = num(x, 'TaskUID'), ru = num(x, 'ResourceUID');
      if (tu == null || ru == null || ru === PLACEHOLDER_RESOURCE || ru === 0 || !byUid.has(tu)) continue;
      const res = resByUid.get(ru); if (!res) continue;
      const work = parseHours(txt(x, 'Work'));
      if (work != null && work > 100000) res.materialLike = true;   // ProjectLibre writes an absurd work value for material-like rows
      assignments.push({ taskUid: tu, resourceUid: ru, units: num(x, 'Units'), workHours: work });
    }
    for (const r of resources) if (r.materialLike) warn('material-resource', 'Material resources are not imported as quantities; they were kept by name only.');
    for (const a of assignments) { const r = resByUid.get(a.resourceUid); if (r.materialLike) { a.units = null; a.workHours = null; } }
    if (assignments.some(a => a.units === null)) warn('material-quantity-dropped', 'Quantities on material-like resources were not trusted and were dropped.');

    return { project, tasks, resources, assignments, warnings };
  }

  // ---------------------------------------------------------------- parsed -> Meridian-shaped payload
  // Level-1 summary rows become phases (job_phases); every other row is a task (job_tasks), nested through parent_uid.
  function toPayload(parsed) {
    const warnings = parsed.warnings.map(w => ({ ...w })), warn = (code, message) => { const w = warnings.find(x => x.code === code); if (w) w.count++; else warnings.push({ code, message, count: 1 }); };
    const phaseUids = new Set(parsed.tasks.filter(t => t.level === 1 && t.isSummary).map(t => t.uid));
    const byUid = new Map(parsed.tasks.map(t => [t.uid, t]));
    const phaseOf = t => { let r = t; while (r.parentUid != null) r = byUid.get(r.parentUid); return phaseUids.has(r.uid) ? r.uid : null; };
    const phases = parsed.tasks.filter(t => phaseUids.has(t.uid)).map((t, i) => ({ uid: t.uid, name: t.name, sort_order: (i + 1) * 10 }));
    let order = 0;
    const tasks = parsed.tasks.filter(t => !phaseUids.has(t.uid)).map(t => {
      const links = [];
      for (const l of t.links) {
        if (l.predUid === t.uid || !byUid.has(l.predUid) || phaseUids.has(l.predUid)) { warn('link-dropped', 'Links to a missing task or to a phase were dropped.'); continue; }
        links.push({ pred_uid: l.predUid, link_type: l.type, lag_days: l.lagDays });
      }
      return { uid: t.uid, name: t.name, phase_uid: phaseOf(t), parent_uid: t.parentUid != null && !phaseUids.has(t.parentUid) ? t.parentUid : null,
        start_date: t.start, end_date: t.end, progress: t.percent, is_milestone: t.isMilestone, is_summary: t.isSummary,
        baseline_start: t.baselineStart, baseline_end: t.baselineEnd, sort_order: (++order) * 10, links };
    });
    return { project: parsed.project, phases, tasks, resources: parsed.resources, assignments: parsed.assignments, warnings };
  }

  // ---------------------------------------------------------------- build
  const esc = s => String(s == null ? '' : s).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  // model = { project: { id, name, title }, phases: [{ uid, name }], tasks: [{ uid, name, phase_uid, parent_uid, start_date, end_date, progress,
  //           is_milestone, is_critical, baseline_start, baseline_end, links: [{ pred_uid, link_type, lag_days }] }] }
  // Rows are written in outline order (each phase with its tasks depth-first, then unphased tasks). UIDs must already exist and be unique.
  function build(model, opts) {
    opts = opts || {};
    const phases = model.phases || [], tasks = model.tasks || [], all = new Set();
    for (const r of phases.concat(tasks)) {
      if (!Number.isInteger(r.uid) || r.uid <= 0 || all.has(r.uid)) throw new MspError('bad-model', 'Every phase and task needs a unique positive UID.');
      all.add(r.uid);
    }
    const kidsOf = new Map(), rootsOf = new Map(), loose = [];
    for (const t of tasks) {
      if (t.parent_uid != null) { if (!kidsOf.has(t.parent_uid)) kidsOf.set(t.parent_uid, []); kidsOf.get(t.parent_uid).push(t); }
      else if (t.phase_uid != null) { if (!rootsOf.has(t.phase_uid)) rootsOf.set(t.phase_uid, []); rootsOf.get(t.phase_uid).push(t); }
      else loose.push(t);
    }
    const rowsOut = [];                                          // { kind, row, level }
    const walk = (t, level) => { rowsOut.push({ kind: 'task', row: t, level }); for (const c of kidsOf.get(t.uid) || []) walk(c, level + 1); };
    for (const p of phases) { rowsOut.push({ kind: 'phase', row: p, level: 1 }); for (const t of rootsOf.get(p.uid) || []) walk(t, 2); }
    for (const t of loose) walk(t, 1);
    if (rowsOut.filter(r => r.kind === 'task').length !== tasks.length) throw new MspError('bad-model', 'Some tasks refer to a missing phase or parent.');
    // outline numbers and derived summary spans
    const counters = [], numbers = [];
    for (const r of rowsOut) { counters.length = r.level; counters[r.level - 1] = (counters[r.level - 1] || 0) + 1; for (let k = r.level; k < counters.length; k++) counters[k] = 0; numbers.push(counters.slice(0, r.level).join('.')); }
    const span = new Map();
    const spanOf = (uid, ownChildren) => {
      let lo = null, hi = null;
      for (const c of ownChildren) {
        let a = c.start_date ? parseDay(c.start_date) : null, b = c.end_date ? parseDay(c.end_date) : null;
        if ((kidsOf.get(c.uid) || []).length) { const s = span.get(c.uid) || spanOf(c.uid, kidsOf.get(c.uid)); if (s) { a = s.lo; b = s.hi; } }
        if (a != null && (lo == null || a < lo)) lo = a; if (b != null && (hi == null || b > hi)) hi = b;
      }
      const r = lo == null ? null : { lo, hi }; span.set(uid, r); return r;
    };
    for (const p of phases) spanOf(p.uid, rootsOf.get(p.uid) || []);
    let projStart = null, projEnd = null;
    for (const t of tasks) { const a = parseDay(t.start_date), b = parseDay(t.end_date); if (a != null && (projStart == null || a < projStart)) projStart = a; if (b != null && (projEnd == null || b > projEnd)) projEnd = b; }
    const dt = (n, time) => ymdOf(n) + 'T' + time;
    const out = [];
    const L = s => out.push(s);
    L('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
    L('<Project xmlns="' + NS + '">');
    L('<SaveVersion>12</SaveVersion>');
    if (model.project && model.project.id) L('<UID>' + esc(model.project.id) + '</UID>');
    L('<Name>' + esc((model.project && model.project.name) || 'Schedule') + '</Name>');
    L('<Title>' + esc((model.project && (model.project.title || model.project.name)) || 'Schedule') + '</Title>');
    if (opts.notice) L('<Subject>' + esc(opts.notice) + '</Subject>');
    if (opts.manager) L('<Manager>' + esc(opts.manager) + '</Manager>');
    L('<ScheduleFromStart>1</ScheduleFromStart>');
    if (projStart != null) L('<StartDate>' + dt(projStart, '08:00:00') + '</StartDate>');
    if (projEnd != null) L('<FinishDate>' + dt(projEnd, '17:00:00') + '</FinishDate>');
    L('<CalendarUID>1</CalendarUID><MinutesPerDay>480</MinutesPerDay><MinutesPerWeek>3360</MinutesPerWeek><DaysPerMonth>30</DaysPerMonth>');
    L('<DurationFormat>7</DurationFormat>');
    L('<Calendars><Calendar><UID>1</UID><Name>Meridian 7-day week</Name><IsBaseCalendar>1</IsBaseCalendar><WeekDays>');
    for (let d = 1; d <= 7; d++) L('<WeekDay><DayType>' + d + '</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>');
    L('</WeekDays></Calendar></Calendars>');
    L('<Tasks>');
    rowsOut.forEach((r, idx) => {
      const row = r.row, isPhase = r.kind === 'phase', hasKids = isPhase || (kidsOf.get(row.uid) || []).length > 0;
      const sp = hasKids ? span.get(row.uid) : null;
      const s = hasKids ? (sp ? sp.lo : null) : parseDay(row.start_date), e = hasKids ? (sp ? sp.hi : null) : parseDay(row.end_date);
      const ms = !hasKids && !!row.is_milestone, dated = s != null && e != null;
      L('<Task><UID>' + row.uid + '</UID><ID>' + (idx + 1) + '</ID><Name>' + esc(row.name) + '</Name><Type>0</Type><IsNull>0</IsNull>');
      L('<WBS>' + numbers[idx] + '</WBS><OutlineNumber>' + numbers[idx] + '</OutlineNumber><OutlineLevel>' + r.level + '</OutlineLevel>');
      if (dated) {
        L('<Start>' + dt(s, '08:00:00') + '</Start><Finish>' + dt(ms ? s : e, ms ? '08:00:00' : '17:00:00') + '</Finish>');
        L('<Duration>PT' + (ms ? 0 : (e - s + 1) * 8) + 'H0M0S</Duration><DurationFormat>7</DurationFormat>');
      }
      L('<Milestone>' + (ms ? 1 : 0) + '</Milestone><Summary>' + (hasKids ? 1 : 0) + '</Summary>');
      if (!isPhase) L('<Critical>' + (row.is_critical ? 1 : 0) + '</Critical>');
      const pct = isPhase || hasKids ? 0 : Math.max(0, Math.min(100, Math.round(Number(row.progress) || 0)));
      L('<PercentComplete>' + pct + '</PercentComplete><PercentWorkComplete>' + pct + '</PercentWorkComplete>');
      if (dated && !hasKids) L('<ConstraintType>4</ConstraintType><ConstraintDate>' + dt(s, '08:00:00') + '</ConstraintDate>');   // Start No Earlier Than: keeps ProjectLibre from pulling tasks earlier
      if (!isPhase) for (const l of row.links || []) {
        const code = LINK_CODE[l.link_type == null ? 'FS' : l.link_type];
        if (code === undefined) throw new MspError('bad-model', 'Unknown link type ' + l.link_type + '.');
        if (!all.has(l.pred_uid) || l.pred_uid === row.uid) continue;
        L('<PredecessorLink><PredecessorUID>' + l.pred_uid + '</PredecessorUID><Type>' + code + '</Type><CrossProject>0</CrossProject><LinkLag>' + Math.round((Number(l.lag_days) || 0) * 4800) + '</LinkLag><LagFormat>7</LagFormat></PredecessorLink>');
      }
      if (!isPhase && !hasKids && row.baseline_start && row.baseline_end) L('<Baseline><Number>0</Number><Start>' + row.baseline_start + 'T08:00:00</Start><Finish>' + row.baseline_end + 'T17:00:00</Finish></Baseline>');
      if (opts.notice && idx === 0) L('<Notes>' + esc(opts.notice) + '</Notes>');
      L('</Task>');
    });
    L('</Tasks></Project>');
    return out.join('\n');
  }

  return Object.freeze({ parse, toPayload, build, MspError, NS, LIMITS, parseDay, ymdOf });
})();
if (typeof module !== 'undefined' && module.exports) module.exports = MspCodec;
