"use strict"

const { test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../lib/Model.js")

// ---- Domain normalization -------------------------------------------------

test("normalizeDomain strips scheme, path, port, www and case", () => {
  assert.equal(Model.normalizeDomain("https://www.YouTube.com/watch?v=x"), "youtube.com")
  assert.equal(Model.normalizeDomain("http://x.com:8080/home"), "x.com")
  assert.equal(Model.normalizeDomain("  reddit.com  "), "reddit.com")
  assert.equal(Model.normalizeDomain("*.instagram.com"), "instagram.com")
  assert.equal(Model.normalizeDomain("news.ycombinator.com"), "news.ycombinator.com")
  assert.equal(Model.normalizeDomain("user@mail.example.org"), "mail.example.org")
})

test("normalizeDomain rejects garbage", () => {
  assert.equal(Model.normalizeDomain(""), "")
  assert.equal(Model.normalizeDomain("not a domain"), "")
  assert.equal(Model.normalizeDomain("localhost"), "")
  assert.equal(Model.normalizeDomain("0.0.0.0 evil.com"), "")
  assert.equal(Model.normalizeDomain("-bad.com"), "")
})

test("hostsDomains expands www variants, dedupes and sorts", () => {
  assert.deepEqual(
    Model.hostsDomains(["youtube.com", "www.youtube.com", "x.com"]),
    ["www.x.com", "www.youtube.com", "x.com", "youtube.com"])
  assert.deepEqual(Model.hostsDomains([]), [])
})

// ---- App matching ---------------------------------------------------------

test("appMatches: exact and substring (min 3 chars)", () => {
  assert.equal(Model.appMatches("Google-chrome", ["chrome"]), true)
  assert.equal(Model.appMatches("steam", ["steam"]), true)
  assert.equal(Model.appMatches("steam_app_1245620", ["steam"]), true)
  assert.equal(Model.appMatches("steam", ["st"]), false)
  assert.equal(Model.appMatches("st", ["st"]), true)
  assert.equal(Model.appMatches("firefox", ["chrome", "discord"]), false)
  assert.equal(Model.appMatches("", ["chrome"]), false)
})

// ---- Time formatting ------------------------------------------------------

test("hhmm and fmtCountdown", () => {
  assert.equal(Model.hhmm(570), "09:30")
  assert.equal(Model.hhmm(0), "00:00")
  assert.equal(Model.fmtCountdown(-5), "0m")
  assert.equal(Model.fmtCountdown(45 * 1000), "45s")
  assert.equal(Model.fmtCountdown(12 * 60 * 1000), "12m")
  assert.equal(Model.fmtCountdown(90 * 60 * 1000), "1h 30m")
  assert.equal(Model.fmtCountdown(2 * 3600 * 1000), "2h")
})

test("daysLabel common shapes", () => {
  assert.equal(Model.daysLabel([0, 1, 2, 3, 4, 5, 6]), "Every day")
  assert.equal(Model.daysLabel([1, 2, 3, 4, 5]), "Mon–Fri")
  assert.equal(Model.daysLabel([0, 6]), "Weekends")
  assert.equal(Model.daysLabel([5, 1, 3]), "Mon, Wed, Fri")
  assert.equal(Model.daysLabel([]), "Never")
})

// ---- Schedule evaluation --------------------------------------------------

// Mon 2026-08-31 is a Monday.
function at(h, m, dayOffset) {
  return new Date(2026, 7, 31 + (dayOffset || 0), h, m, 0, 0)
}

const workHours = {
  id: "s1", name: "Work", blocklistIds: ["b1"], days: [1, 2, 3, 4, 5],
  startMin: 9 * 60, endMin: 12 * 60, enabled: true, locked: false
}

test("scheduleActiveAt: simple daytime range", () => {
  assert.equal(Model.scheduleActiveAt(workHours, at(8, 59)), false)
  assert.equal(Model.scheduleActiveAt(workHours, at(9, 0)), true)
  assert.equal(Model.scheduleActiveAt(workHours, at(11, 59)), true)
  assert.equal(Model.scheduleActiveAt(workHours, at(12, 0)), false)
  // Saturday (offset +5) is not in days.
  assert.equal(Model.scheduleActiveAt(workHours, at(10, 0, 5)), false)
  // Disabled schedule never fires.
  assert.equal(Model.scheduleActiveAt(Object.assign({}, workHours, { enabled: false }), at(10, 0)), false)
})

test("scheduleActiveAt: overnight range crosses midnight", () => {
  const night = Object.assign({}, workHours, { days: [1], startMin: 22 * 60, endMin: 6 * 60 })
  assert.equal(Model.scheduleActiveAt(night, at(23, 0)), true)       // Mon 23:00
  assert.equal(Model.scheduleActiveAt(night, at(3, 0, 1)), true)     // Tue 03:00 (tail)
  assert.equal(Model.scheduleActiveAt(night, at(6, 0, 1)), false)    // Tue 06:00 ended
  assert.equal(Model.scheduleActiveAt(night, at(23, 0, 1)), false)   // Tue night not scheduled
  assert.equal(Model.scheduleActiveAt(night, at(3, 0)), false)       // Mon 03:00 (Sun not scheduled)
})

test("scheduleEndMs points at the closing edge of the live window", () => {
  assert.equal(Model.scheduleEndMs(workHours, at(10, 0)), at(12, 0).getTime())
  const night = Object.assign({}, workHours, { days: [1], startMin: 22 * 60, endMin: 6 * 60 })
  assert.equal(Model.scheduleEndMs(night, at(23, 0)), at(6, 0, 1).getTime())
  assert.equal(Model.scheduleEndMs(night, at(3, 0, 1)), at(6, 0, 1).getTime())
})

test("scheduleNextStartMs finds the next occurrence", () => {
  // Monday 13:00 → next window is Tuesday 09:00.
  assert.equal(Model.scheduleNextStartMs(workHours, at(13, 0).getTime()), at(9, 0, 1).getTime())
  // Monday 08:00 → today 09:00.
  assert.equal(Model.scheduleNextStartMs(workHours, at(8, 0).getTime()), at(9, 0).getTime())
  // Friday 13:00 → Monday 09:00.
  assert.equal(Model.scheduleNextStartMs(workHours, at(13, 0, 4).getTime()), at(9, 0, 7).getTime())
  assert.equal(Model.scheduleNextStartMs(Object.assign({}, workHours, { enabled: false }), at(8, 0).getTime()), 0)
})

// ---- activeBlock ----------------------------------------------------------

function fixtureState() {
  return Model.sanitizeState({
    blocklists: [
      { id: "b1", name: "Social", sites: ["youtube.com", "x.com"], apps: ["discord"] },
      { id: "b2", name: "Games", sites: [], apps: ["steam"] }
    ],
    schedules: [workHours],
    sessions: []
  })
}

test("activeBlock unions domains and apps from active items", () => {
  const s = fixtureState()
  s.sessions.push({
    id: "x1", blocklistIds: ["b2"], startsAt: at(9, 0).getTime(),
    endsAt: at(14, 0).getTime(), locked: true
  })
  const block = Model.activeBlock(s, at(10, 0).getTime())
  assert.equal(block.active, true)
  assert.equal(block.count, 2)
  assert.deepEqual(block.domains, ["x.com", "youtube.com"])
  assert.deepEqual(block.apps, ["discord", "steam"])
  // Blocking ends when the last item ends; lock covers only the session.
  assert.equal(block.endsAt, at(14, 0).getTime())
  assert.equal(block.lockedUntil, at(14, 0).getTime())
  assert.deepEqual(block.lockedListIds, ["b2"])
  assert.deepEqual(block.lockedDomains, [])
})

test("activeBlock is inert outside all windows", () => {
  const block = Model.activeBlock(fixtureState(), at(13, 0).getTime())
  assert.equal(block.active, false)
  assert.deepEqual(block.domains, [])
  assert.equal(block.endsAt, 0)
  assert.equal(block.lockedUntil, 0)
})

test("activeBlock ignores dangling blocklist ids", () => {
  const s = fixtureState()
  s.schedules[0].blocklistIds = ["gone"]
  const block = Model.activeBlock(s, at(10, 0).getTime())
  assert.equal(block.active, true)
  assert.deepEqual(block.domains, [])
})

test("expireSessions drops only finished sessions", () => {
  const now = at(10, 0).getTime()
  const sessions = [
    { id: "a", blocklistIds: [], startsAt: now - 7200000, endsAt: now - 3600000, locked: false },
    { id: "b", blocklistIds: [], startsAt: now - 60000, endsAt: now + 60000, locked: false }
  ]
  const kept = Model.expireSessions(sessions, now)
  assert.equal(kept.length, 1)
  assert.equal(kept[0].id, "b")
  assert.equal(Model.expireSessions(kept, now), null)
})

test("upcomingBlock picks the earliest future start", () => {
  const s = fixtureState()
  const now = at(13, 0).getTime()
  s.sessions.push({ id: "f", blocklistIds: ["b1"], startsAt: at(15, 0).getTime(), endsAt: at(16, 0).getTime(), locked: false })
  const up = Model.upcomingBlock(s, now)
  assert.equal(up.startsAt, at(15, 0).getTime())     // before Tue 09:00
  s.sessions = []
  assert.equal(Model.upcomingBlock(s, now).startsAt, at(9, 0, 1).getTime())
})

test("applySignature changes only when hosts content or lock horizon change", () => {
  const s = fixtureState()
  const a = Model.applySignature(Model.activeBlock(s, at(10, 0).getTime()))
  const b = Model.applySignature(Model.activeBlock(s, at(10, 30).getTime()))
  assert.equal(a, b)
  const off = Model.applySignature(Model.activeBlock(s, at(13, 0).getTime()))
  assert.notEqual(a, off)
})

test("applyPayload emits the helper contract", () => {
  const s = fixtureState()
  s.sessions.push({ id: "x1", blocklistIds: ["b1"], startsAt: at(9, 30).getTime(), endsAt: at(11, 0).getTime(), locked: true })
  const p = JSON.parse(Model.applyPayload(Model.activeBlock(s, at(10, 0).getTime())))
  assert.deepEqual(p.domains, ["www.x.com", "www.youtube.com", "x.com", "youtube.com"])
  assert.deepEqual(p.lockedDomains, p.domains)
  assert.equal(p.lockedUntil, Math.floor(at(11, 0).getTime() / 1000))
})

test("sanitizeState survives junk", () => {
  assert.deepEqual(Model.sanitizeState(null), Model.newState())
  assert.deepEqual(Model.sanitizeState([1, 2]), Model.newState())
  const s = Model.sanitizeState({
    blocklists: [{ id: "b", sites: ["a.com", 5, ""], apps: "no" }, { name: "no id" }],
    schedules: [{ id: "s", days: [1, 9, -2, 1], startMin: "540", endMin: 5000 }],
    sessions: [{ id: "x", startsAt: 10, endsAt: 5 }]
  })
  assert.deepEqual(s.blocklists, [{ id: "b", name: "Blocklist", sites: ["a.com"], apps: [] }])
  assert.equal(s.schedules[0].endMin, 24 * 60 - 1)
  assert.deepEqual(s.schedules[0].days, [1])
  assert.equal(s.schedules[0].enabled, true)
  assert.deepEqual(s.sessions, [])
})
