// Pure JS core for Deeplok: state shape, schedule/session evaluation,
// domain normalization, and formatting. No Qt imports so everything here
// runs under `node --test` as well as inside the QML JS engine.

function pad2(n) {
  n = Math.floor(n)
  return n < 10 ? "0" + n : String(n)
}

// Collision-resistant enough for ids scoped to one user's state file.
function uid() {
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8)
}

var DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// ---- State shape ----------------------------------------------------------
//
// blocklists: [{ id, name, sites: ["youtube.com"], apps: ["steam"] }]
// schedules:  [{ id, name, blocklistIds, days: [1..5], startMin, endMin,
//                enabled, locked }]        (days use JS getDay(): 0 = Sunday)
// sessions:   [{ id, blocklistIds, startsAt, endsAt, locked }]  (epoch ms)

function newState() {
  return { blocklists: [], schedules: [], sessions: [] }
}

// First-run seed: one ready-made list so "block now" works immediately.
function defaultState() {
  return {
    blocklists: [{
      id: uid(),
      name: "Distractions",
      sites: ["youtube.com", "x.com", "twitter.com", "instagram.com",
        "reddit.com", "facebook.com", "tiktok.com"],
      apps: []
    }],
    schedules: [],
    sessions: []
  }
}

function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }

function cleanStrings(arr) {
  if (!Array.isArray(arr)) return []
  var out = []
  for (var i = 0; i < arr.length; i++)
    if (typeof arr[i] === "string" && arr[i] !== "") out.push(arr[i])
  return out
}

// Accepts whatever was on disk and returns a state that every function in
// this module can safely consume. Unknown fields are dropped, wrong types
// coerced to empty defaults.
function sanitizeState(raw) {
  var s = newState()
  // QML's JsonAdapter hands over QVariant-wrapped lists on which
  // Array.isArray reports false, silently discarding every entry. A JSON
  // round-trip flattens them into plain JS structures first; it is a no-op
  // for data that is already plain.
  if (raw !== null && typeof raw === "object") {
    try { raw = JSON.parse(JSON.stringify(raw)) } catch (e) { raw = null }
  }
  if (!isObj(raw)) return s
  if (Array.isArray(raw.blocklists)) {
    for (var i = 0; i < raw.blocklists.length; i++) {
      var b = raw.blocklists[i]
      if (!isObj(b) || typeof b.id !== "string" || !b.id) continue
      s.blocklists.push({
        id: b.id,
        name: typeof b.name === "string" && b.name ? b.name : "Blocklist",
        sites: cleanStrings(b.sites),
        apps: cleanStrings(b.apps)
      })
    }
  }
  if (Array.isArray(raw.schedules)) {
    for (var j = 0; j < raw.schedules.length; j++) {
      var c = raw.schedules[j]
      if (!isObj(c) || typeof c.id !== "string" || !c.id) continue
      var days = []
      if (Array.isArray(c.days))
        for (var d = 0; d < c.days.length; d++) {
          var v = Number(c.days[d])
          if (v >= 0 && v <= 6 && days.indexOf(v) === -1) days.push(v)
        }
      s.schedules.push({
        id: c.id,
        name: typeof c.name === "string" && c.name ? c.name : "Schedule",
        blocklistIds: cleanStrings(c.blocklistIds),
        days: days,
        startMin: clampMin(c.startMin),
        endMin: clampMin(c.endMin),
        enabled: c.enabled !== false,
        locked: c.locked === true
      })
    }
  }
  if (Array.isArray(raw.sessions)) {
    for (var k = 0; k < raw.sessions.length; k++) {
      var x = raw.sessions[k]
      if (!isObj(x) || typeof x.id !== "string" || !x.id) continue
      var st = Number(x.startsAt), en = Number(x.endsAt)
      if (!(st > 0) || !(en > st)) continue
      s.sessions.push({
        id: x.id,
        blocklistIds: cleanStrings(x.blocklistIds),
        startsAt: st,
        endsAt: en,
        locked: x.locked === true
      })
    }
  }
  return s
}

function clampMin(v) {
  v = Math.floor(Number(v))
  if (!(v >= 0)) return 0
  return Math.min(v, 24 * 60 - 1)
}

// ---- Domains and apps -----------------------------------------------------

// "https://www.YouTube.com/watch?v=x" -> "youtube.com". Returns "" for
// anything that doesn't normalize to a plausible hostname.
function normalizeDomain(input) {
  var s = String(input || "").trim().toLowerCase()
  s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, "")   // scheme
  s = s.replace(/^\*\./, "")                     // wildcard prefix
  s = s.split("/")[0].split("?")[0].split("#")[0]
  s = s.split("@").pop()                         // userinfo
  s = s.split(":")[0]                            // port
  s = s.replace(/\.+$/, "")
  if (s.indexOf("www.") === 0) s = s.slice(4)
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(s)) return ""
  return s
}

function normalizeApp(input) {
  return String(input || "").trim().toLowerCase()
}

// Expands the user-entered domain list into the exact hostnames written to
// /etc/hosts: each domain plus its www. variant, deduplicated and sorted.
function hostsDomains(domains) {
  var seen = {}
  for (var i = 0; i < domains.length; i++) {
    var d = domains[i]
    if (!d) continue
    seen[d] = true
    if (d.indexOf("www.") !== 0) seen["www." + d] = true
  }
  return Object.keys(seen).sort()
}

// An app entry matches a compositor appId either exactly or as a substring
// (min 3 chars, so "chrome" catches "google-chrome" without "st" catching
// "steam").
function appMatches(appId, apps) {
  var id = String(appId || "").toLowerCase()
  if (!id) return false
  for (var i = 0; i < apps.length; i++) {
    var a = apps[i]
    if (!a) continue
    if (id === a) return true
    if (a.length >= 3 && id.indexOf(a) !== -1) return true
  }
  return false
}

// ---- Time helpers ---------------------------------------------------------

function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes()
}

function hhmm(minutes) {
  minutes = clampMin(minutes)
  return pad2(minutes / 60) + ":" + pad2(minutes % 60)
}

function fmtClock(ms) {
  var d = new Date(ms)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "Tue 14:30" — used for future session starts and "next block" hints.
function fmtDayClock(ms, nowMs) {
  var d = new Date(ms)
  var now = new Date(nowMs === undefined ? Date.now() : nowMs)
  var sameDay = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  if (sameDay) return fmtClock(ms)
  return DAY_SHORT[d.getDay()] + " " + fmtClock(ms)
}

function fmtCountdown(remainMs) {
  if (!(remainMs > 0)) return "0m"
  var totalSec = Math.ceil(remainMs / 1000)
  if (totalSec < 60) return totalSec + "s"
  var totalMin = Math.ceil(totalSec / 60)
  if (totalMin < 60) return totalMin + "m"
  var h = Math.floor(totalMin / 60)
  var m = totalMin % 60
  return m === 0 ? h + "h" : h + "h " + m + "m"
}

// "1 site" / "3 sites"
function fmtCount(n, noun) {
  return n + " " + noun + (n === 1 ? "" : "s")
}

// "Every day" / "Mon–Fri" / "Mon, Wed, Fri"
function daysLabel(days) {
  if (!days || days.length === 0) return "Never"
  if (days.length === 7) return "Every day"
  var weekdays = [1, 2, 3, 4, 5]
  var isWeekdays = days.length === 5
  for (var i = 0; i < weekdays.length && isWeekdays; i++)
    if (days.indexOf(weekdays[i]) === -1) isWeekdays = false
  if (isWeekdays) return "Mon–Fri"
  if (days.length === 2 && days.indexOf(0) !== -1 && days.indexOf(6) !== -1) return "Weekends"
  // Sort into Mon-first display order.
  var order = [1, 2, 3, 4, 5, 6, 0]
  var out = []
  for (var j = 0; j < order.length; j++)
    if (days.indexOf(order[j]) !== -1) out.push(DAY_SHORT[order[j]])
  return out.join(", ")
}

// ---- Schedule evaluation --------------------------------------------------

// Whether a recurring schedule is active at `date`. Ranges where
// endMin < startMin cross midnight: 22:00–06:00 on Monday is active Monday
// night and into Tuesday morning.
function scheduleActiveAt(sch, date) {
  if (!sch.enabled) return false
  if (!sch.days || sch.days.length === 0) return false
  var m = minutesOfDay(date)
  var day = date.getDay()
  var prev = (day + 6) % 7
  if (sch.startMin === sch.endMin) return false
  if (sch.startMin < sch.endMin)
    return sch.days.indexOf(day) !== -1 && m >= sch.startMin && m < sch.endMin
  // Overnight range.
  if (sch.days.indexOf(day) !== -1 && m >= sch.startMin) return true
  return sch.days.indexOf(prev) !== -1 && m < sch.endMin
}

// Epoch ms at which the currently-active window of `sch` ends. Only valid
// while scheduleActiveAt is true.
function scheduleEndMs(sch, date) {
  var end = new Date(date.getFullYear(), date.getMonth(), date.getDate(),
    Math.floor(sch.endMin / 60), sch.endMin % 60, 0, 0)
  if (sch.startMin < sch.endMin) return end.getTime()
  // Overnight: before endMin we are in the tail of yesterday's window
  // (today's end applies); past startMin the window ends tomorrow.
  if (minutesOfDay(date) < sch.endMin) return end.getTime()
  return end.getTime() + 24 * 3600 * 1000
}

// Next epoch ms at which `sch` starts, looking up to 8 days out. Returns 0
// when the schedule can never fire (disabled / no days).
function scheduleNextStartMs(sch, nowMs) {
  if (!sch.enabled || !sch.days || sch.days.length === 0) return 0
  var now = new Date(nowMs)
  for (var i = 0; i < 8; i++) {
    var day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i,
      Math.floor(sch.startMin / 60), sch.startMin % 60, 0, 0)
    if (sch.days.indexOf(day.getDay()) === -1) continue
    if (day.getTime() > nowMs) return day.getTime()
  }
  return 0
}

function sessionActiveAt(session, nowMs) {
  return session.startsAt <= nowMs && nowMs < session.endsAt
}

// ---- The engine's core question: what should be blocked right now? --------
//
// Returns:
//   { active, domains, apps, endsAt, lockedUntil, lockedDomains,
//     lockedListIds, labels, count }
//
// domains are normalized user entries (not yet www-expanded); endsAt is when
// blocking ends entirely (max across active items); lockedUntil covers only
// locked items.
function activeBlock(state, nowMs) {
  var now = new Date(nowMs)
  var items = []   // { name, startsAt, endsAt, locked, blocklistIds }
  var i
  for (i = 0; i < state.sessions.length; i++) {
    var ses = state.sessions[i]
    if (!sessionActiveAt(ses, nowMs)) continue
    items.push({ name: "Session", startsAt: ses.startsAt, endsAt: ses.endsAt, locked: ses.locked, blocklistIds: ses.blocklistIds })
  }
  for (i = 0; i < state.schedules.length; i++) {
    var sch = state.schedules[i]
    if (!scheduleActiveAt(sch, now)) continue
    var end = scheduleEndMs(sch, now)
    var lenMin = ((sch.endMin - sch.startMin) % (24 * 60) + 24 * 60) % (24 * 60)
    items.push({ name: sch.name, startsAt: end - lenMin * 60000, endsAt: end, locked: sch.locked, blocklistIds: sch.blocklistIds })
  }

  var byId = {}
  for (i = 0; i < state.blocklists.length; i++) byId[state.blocklists[i].id] = state.blocklists[i]

  var domains = {}, apps = {}, lockedDomains = {}, lockedListIds = {}
  var startsAt = 0, endsAt = 0, lockedUntil = 0
  var labels = []
  for (i = 0; i < items.length; i++) {
    var it = items[i]
    if (it.endsAt > endsAt) endsAt = it.endsAt
    if (startsAt === 0 || it.startsAt < startsAt) startsAt = it.startsAt
    if (it.locked && it.endsAt > lockedUntil) lockedUntil = it.endsAt
    labels.push(it.name)
    for (var l = 0; l < it.blocklistIds.length; l++) {
      var list = byId[it.blocklistIds[l]]
      if (!list) continue
      if (it.locked) lockedListIds[list.id] = true
      for (var d = 0; d < list.sites.length; d++) {
        var dom = normalizeDomain(list.sites[d])
        if (!dom) continue
        domains[dom] = true
        if (it.locked) lockedDomains[dom] = true
      }
      for (var a = 0; a < list.apps.length; a++) {
        var app = normalizeApp(list.apps[a])
        if (app) apps[app] = true
      }
    }
  }
  return {
    active: items.length > 0,
    count: items.length,
    domains: Object.keys(domains).sort(),
    apps: Object.keys(apps).sort(),
    lockedDomains: Object.keys(lockedDomains).sort(),
    lockedListIds: Object.keys(lockedListIds),
    startsAt: startsAt,
    endsAt: endsAt,
    lockedUntil: lockedUntil,
    labels: labels
  }
}

// Earliest upcoming block (future session or next schedule window) within
// the next 8 days, or null.
function upcomingBlock(state, nowMs) {
  var best = null
  var i
  for (i = 0; i < state.sessions.length; i++) {
    var ses = state.sessions[i]
    if (ses.startsAt > nowMs && (!best || ses.startsAt < best.startsAt))
      best = { name: "Session", startsAt: ses.startsAt }
  }
  for (i = 0; i < state.schedules.length; i++) {
    var next = scheduleNextStartMs(state.schedules[i], nowMs)
    if (next > 0 && (!best || next < best.startsAt))
      best = { name: state.schedules[i].name, startsAt: next }
  }
  return best
}

// Drops sessions whose end has passed. Returns a new array, or null when
// nothing changed (so callers can skip a persist).
function expireSessions(sessions, nowMs) {
  var kept = []
  for (var i = 0; i < sessions.length; i++)
    if (sessions[i].endsAt > nowMs) kept.push(sessions[i])
  return kept.length === sessions.length ? null : kept
}

// Change-detection signature for the engine: hosts content plus the lock
// horizon. When this string is unchanged, no helper call is needed.
function applySignature(block) {
  return hostsDomains(block.domains).join(",")
    + "|" + hostsDomains(block.lockedDomains).join(",")
    + "|" + Math.floor((block.lockedUntil || 0) / 1000)
}

// The JSON payload piped to the root helper.
function applyPayload(block) {
  return JSON.stringify({
    domains: hostsDomains(block.domains),
    lockedDomains: hostsDomains(block.lockedDomains),
    lockedUntil: Math.floor((block.lockedUntil || 0) / 1000)
  })
}

if (typeof module !== "undefined" && module && module.exports) {
  module.exports = {
    pad2: pad2,
    uid: uid,
    DAY_SHORT: DAY_SHORT,
    newState: newState,
    defaultState: defaultState,
    sanitizeState: sanitizeState,
    normalizeDomain: normalizeDomain,
    normalizeApp: normalizeApp,
    hostsDomains: hostsDomains,
    appMatches: appMatches,
    minutesOfDay: minutesOfDay,
    hhmm: hhmm,
    fmtClock: fmtClock,
    fmtDayClock: fmtDayClock,
    fmtCountdown: fmtCountdown,
    fmtCount: fmtCount,
    daysLabel: daysLabel,
    scheduleActiveAt: scheduleActiveAt,
    scheduleEndMs: scheduleEndMs,
    scheduleNextStartMs: scheduleNextStartMs,
    sessionActiveAt: sessionActiveAt,
    activeBlock: activeBlock,
    upcomingBlock: upcomingBlock,
    expireSessions: expireSessions,
    applySignature: applySignature,
    applyPayload: applyPayload
  }
}
