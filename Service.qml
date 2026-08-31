import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "lib/Model.js" as Model

// Deeplok engine: evaluates sessions and recurring schedules against the
// clock, keeps /etc/hosts in sync through the root helper, and closes
// windows of blocked apps.
//
// State is a single JSON file
//   ~/.config/omarchy/deeplok/state.json
// shaped as { blocklists: [], schedules: [], sessions: [], seeded: bool }.
// All logic that can be pure lives in lib/Model.js (tested with node
// --test); this file owns timers, disk I/O and process spawning.
//
// Privileged side: /usr/local/lib/deeplok/deeplok-helper (root-owned,
// installed once via `pkexec bin/deeplok-setup`). The engine only ever
// calls it as `sudo -n deeplok-helper apply|clear|status` — the exact
// invocations the sudoers drop-in allows.
Item {
  id: root

  // Injected by omarchy-shell (the generic service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string user: Quickshell.env("USER")
  readonly property string dataDir: home + "/.config/omarchy/deeplok"
  readonly property string statePath: dataDir + "/state.json"
  readonly property string helperPath: "/usr/local/lib/deeplok/deeplok-helper"
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.startsWith("file://")) u = u.slice(7)
    return u.replace(/\/$/, "")
  }

  property bool ready: false
  property bool startupPhase: true

  // ---- System helper status ----------------------------------------------
  // installed === false shows the setup card in the panel; the engine never
  // calls sudo while it is false.
  property bool installed: false
  property bool installChecked: false
  property bool installBusy: false
  property string installMessage: ""

  // ---- User state (always replaced, never mutated in place) --------------
  property var blocklists: []
  property var schedules: []
  property var sessions: []

  // ---- Live block state ---------------------------------------------------
  // Recomputed by reconcile(); the bar widget and panel bind to this.
  property var block: ({ active: false, count: 0, domains: [], apps: [],
    lockedDomains: [], lockedListIds: [], endsAt: 0, lockedUntil: 0, labels: [] })
  property double nowTick: Date.now()

  readonly property bool blocking: block && block.active === true
  readonly property string barLabel: blocking ? Model.fmtCountdown(block.endsAt - nowTick) : ""
  readonly property var upcoming: Model.upcomingBlock(stateObj(), nowTick)

  function stateObj() {
    return { blocklists: root.blocklists, schedules: root.schedules, sessions: root.sessions }
  }

  function fmtCountdown(ms) { return Model.fmtCountdown(ms) }
  function fmtClock(ms) { return Model.fmtClock(ms) }
  function fmtDayClock(ms) { return Model.fmtDayClock(ms, root.nowTick) }
  function daysLabel(days) { return Model.daysLabel(days) }
  function hhmm(minutes) { return Model.hhmm(minutes) }

  // ---- Reconcile loop -----------------------------------------------------

  property string appliedSig: "__unknown__"
  property string pendingSig: ""
  property string pendingPayload: ""
  property bool applyDirty: false

  function reconcile() {
    if (!root.ready) return
    var now = Date.now()
    root.nowTick = now
    var kept = Model.expireSessions(root.sessions, now)
    if (kept) {
      root.sessions = kept
      root.persist()
    }
    var b = Model.activeBlock(root.stateObj(), now)
    root.block = b
    if (root.installed) root.maybeApply(b)
    root.enforceApps()
  }

  function maybeApply(b) {
    var sig = Model.applySignature(b)
    if (sig === root.appliedSig) return
    if (applyProc.running) {
      root.applyDirty = true
      return
    }
    root.pendingSig = sig
    root.pendingPayload = Model.applyPayload(b)
    applyProc.running = true
  }

  // ---- App enforcement -----------------------------------------------------
  // Closing the toplevel is a polite close request (the app may prompt to
  // save); notifications are throttled per app so a stubborn relaunch loop
  // doesn't spam.
  property var notifiedAt: ({})

  function enforceApps() {
    if (!root.blocking || root.block.apps.length === 0) return
    var values = ToplevelManager.toplevels.values
    var now = Date.now()
    for (var i = 0; i < values.length; i++) {
      var tl = values[i]
      if (!tl || !tl.appId) continue
      if (!Model.appMatches(tl.appId, root.block.apps)) continue
      tl.close()
      var key = String(tl.appId).toLowerCase()
      if (!root.notifiedAt[key] || now - root.notifiedAt[key] > 30000) {
        var na = Object.assign({}, root.notifiedAt)
        na[key] = now
        root.notifiedAt = na
        Quickshell.execDetached(["notify-send", "-a", "Deeplok", "Deeplok",
          tl.appId + " is blocked until " + Model.fmtClock(root.block.endsAt)])
      }
    }
  }

  // ---- Mutations (called from the panel) -----------------------------------

  function persist() {
    if (root.startupPhase) return
    stateAdapter.blocklists = root.blocklists
    stateAdapter.schedules = root.schedules
    stateAdapter.sessions = root.sessions
    saveTimer.restart()
  }

  // startsAtMs <= 0 means "now".
  function startSession(listIds, minutes, locked, startsAtMs) {
    if (!listIds || listIds.length === 0 || !(minutes > 0)) return false
    var start = startsAtMs && startsAtMs > Date.now() ? startsAtMs : Date.now()
    root.sessions = root.sessions.concat([{
      id: Model.uid(),
      blocklistIds: listIds.slice(),
      startsAt: start,
      endsAt: start + minutes * 60000,
      locked: locked === true
    }])
    root.persist()
    root.reconcile()
    return true
  }

  // Returns false when the session is locked and running.
  function endSession(id) {
    var now = Date.now()
    var out = []
    var refused = false
    for (var i = 0; i < root.sessions.length; i++) {
      var s = root.sessions[i]
      if (s.id !== id) {
        out.push(s)
        continue
      }
      if (s.locked && Model.sessionActiveAt(s, now)) {
        refused = true
        out.push(s)
      }
    }
    if (refused) return false
    root.sessions = out
    root.persist()
    root.reconcile()
    return true
  }

  function lockedListActive(listId) {
    return root.blocking && root.block.lockedListIds.indexOf(listId) !== -1
  }

  function scheduleLockedActive(id) {
    for (var i = 0; i < root.schedules.length; i++) {
      var sch = root.schedules[i]
      if (sch.id === id)
        return sch.locked && Model.scheduleActiveAt(sch, new Date())
    }
    return false
  }

  function addBlocklist(name) {
    var trimmed = String(name || "").trim()
    if (!trimmed) return ""
    var list = { id: Model.uid(), name: trimmed, sites: [], apps: [] }
    root.blocklists = root.blocklists.concat([list])
    root.persist()
    return list.id
  }

  function removeBlocklist(id) {
    if (root.lockedListActive(id)) return false
    var lists = []
    for (var i = 0; i < root.blocklists.length; i++)
      if (root.blocklists[i].id !== id) lists.push(root.blocklists[i])
    root.blocklists = lists
    // Drop dangling references so schedules don't silently block nothing.
    root.schedules = root.schedules.map(function(sch) {
      if (sch.blocklistIds.indexOf(id) === -1) return sch
      return Object.assign({}, sch, { blocklistIds: sch.blocklistIds.filter(function(x) { return x !== id }) })
    })
    root.sessions = root.sessions.map(function(s) {
      if (s.blocklistIds.indexOf(id) === -1) return s
      return Object.assign({}, s, { blocklistIds: s.blocklistIds.filter(function(x) { return x !== id }) })
    })
    root.persist()
    root.reconcile()
    return true
  }

  function patchList(id, patch) {
    root.blocklists = root.blocklists.map(function(l) {
      return l.id === id ? Object.assign({}, l, patch) : l
    })
    root.persist()
    root.reconcile()
  }

  // Returns "" on success, else a short error for the panel to show.
  function addSite(listId, text) {
    var domain = Model.normalizeDomain(text)
    if (!domain) return "Not a valid domain"
    for (var i = 0; i < root.blocklists.length; i++) {
      var l = root.blocklists[i]
      if (l.id !== listId) continue
      if (l.sites.indexOf(domain) !== -1) return "Already in the list"
      root.patchList(listId, { sites: l.sites.concat([domain]) })
      return ""
    }
    return "List not found"
  }

  // Removing entries from a locked-active list would weaken a locked block.
  function removeSite(listId, domain) {
    if (root.lockedListActive(listId)) return false
    for (var i = 0; i < root.blocklists.length; i++) {
      var l = root.blocklists[i]
      if (l.id !== listId) continue
      root.patchList(listId, { sites: l.sites.filter(function(s) { return s !== domain }) })
      return true
    }
    return false
  }

  function addApp(listId, text) {
    var app = Model.normalizeApp(text)
    if (!app) return "Empty app id"
    for (var i = 0; i < root.blocklists.length; i++) {
      var l = root.blocklists[i]
      if (l.id !== listId) continue
      if (l.apps.indexOf(app) !== -1) return "Already in the list"
      root.patchList(listId, { apps: l.apps.concat([app]) })
      return ""
    }
    return "List not found"
  }

  function removeApp(listId, app) {
    if (root.lockedListActive(listId)) return false
    for (var i = 0; i < root.blocklists.length; i++) {
      var l = root.blocklists[i]
      if (l.id !== listId) continue
      root.patchList(listId, { apps: l.apps.filter(function(a) { return a !== app }) })
      return true
    }
    return false
  }

  function addSchedule(sch) {
    if (!sch || !sch.name || !sch.days || sch.days.length === 0) return false
    if (!sch.blocklistIds || sch.blocklistIds.length === 0) return false
    if (sch.startMin === sch.endMin) return false
    root.schedules = root.schedules.concat([{
      id: Model.uid(),
      name: String(sch.name),
      blocklistIds: sch.blocklistIds.slice(),
      days: sch.days.slice(),
      startMin: sch.startMin,
      endMin: sch.endMin,
      enabled: sch.enabled !== false,
      locked: sch.locked === true
    }])
    root.persist()
    root.reconcile()
    return true
  }

  // Disabling a locked schedule mid-window is refused; enabling always works.
  function setScheduleEnabled(id, on) {
    if (!on && root.scheduleLockedActive(id)) return false
    root.schedules = root.schedules.map(function(sch) {
      return sch.id === id ? Object.assign({}, sch, { enabled: on === true }) : sch
    })
    root.persist()
    root.reconcile()
    return true
  }

  function removeSchedule(id) {
    if (root.scheduleLockedActive(id)) return false
    root.schedules = root.schedules.filter(function(sch) { return sch.id !== id })
    root.persist()
    root.reconcile()
    return true
  }

  // ---- System helper install / uninstall -----------------------------------

  function installHelper() {
    if (root.installBusy) return
    root.installBusy = true
    root.installMessage = ""
    installProc.running = true
  }

  function uninstallHelper() {
    if (root.installBusy) return
    root.installBusy = true
    root.installMessage = ""
    uninstallProc.running = true
  }

  function recheckHelper() {
    statusProc.running = true
  }

  // ---- Persistence ---------------------------------------------------------

  // Fires both for the initial auto-load and for ensureDirProc's reload of
  // the seeded "{}" file, so it must be idempotent. A reload resets adapter
  // properties to whatever the file holds; the first-run seed is therefore
  // applied here (post-reload) and immediately persisted, never earlier —
  // otherwise the "{}" reload would wipe it before the debounced save fires.
  function onStateLoaded() {
    var clean = Model.sanitizeState({
      blocklists: stateAdapter.blocklists,
      schedules: stateAdapter.schedules,
      sessions: stateAdapter.sessions
    })
    var needSave = false
    if (stateAdapter.seeded !== true) {
      clean = Model.defaultState()
      stateAdapter.seeded = true
      needSave = true
    }
    root.blocklists = clean.blocklists
    root.schedules = clean.schedules
    root.sessions = clean.sessions
    if (!root.ready) {
      root.ready = true
      root.startupPhase = false
      statusProc.running = true
    }
    if (needSave) root.persist()
    root.reconcile()
  }

  // Expected once on the very first run: the FileView auto-loads before
  // ensureDirProc has seeded the file. ensureDirProc's reload lands in
  // onStateLoaded, which does the real first-run setup.
  function onStateLoadFailed() {
    console.warn("shl.deeplok: state not loadable yet, waiting for seed")
  }

  FileView {
    id: stateFile
    path: root.statePath
    printErrors: true
    atomicWrites: true
    onLoaded: root.onStateLoaded()
    onLoadFailed: root.onStateLoadFailed()

    JsonAdapter {
      id: stateAdapter
      property var blocklists: []
      property var schedules: []
      property var sessions: []
      property bool seeded: false
    }
  }

  Process {
    id: ensureDirProc
    environment: ({ "HOME": root.home })
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.config/omarchy/deeplok\"; f=\"$HOME/.config/omarchy/deeplok/state.json\"; [[ -f \"$f\" ]] || printf '{}\\n' > \"$f\""]
    onExited: stateFile.reload()
  }

  Timer {
    id: saveTimer
    interval: 1000
    repeat: false
    onTriggered: stateFile.writeAdapter()
  }

  // ---- Processes -----------------------------------------------------------

  // Exit 10 = helper binary missing (never installed); any other non-zero
  // means the helper exists but sudo refused — a broken install worth
  // surfacing rather than silently ignoring.
  Process {
    id: statusProc
    command: ["bash", "-c",
      "[[ -x \"$1\" ]] || exit 10; sudo -n \"$1\" status", "bash", root.helperPath]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.installChecked = true
      if (code === 0) {
        root.installed = true
        root.installMessage = ""
        root.appliedSig = "__unknown__"
        root.reconcile()
      } else if (code === 10) {
        root.installed = false
      } else {
        root.installed = false
        root.installMessage = "Helper present but sudo rule broken — reinstall"
        console.warn("shl.deeplok: helper status failed with code", code)
      }
    }
  }

  // printf|sudo through argv keeps the JSON payload out of shell quoting.
  Process {
    id: applyProc
    command: ["bash", "-c",
      "printf %s \"$1\" | sudo -n \"$2\" apply", "bash", root.pendingPayload, root.helperPath]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        root.appliedSig = root.pendingSig
      } else {
        console.warn("shl.deeplok: apply failed:", applyErr.text.trim())
        // sudo -n failing means the NOPASSWD rule is gone; stop hammering.
        if (applyErr.text.indexOf("password") !== -1 || code === 1) {
          root.installed = false
          root.installMessage = "Lost permission to apply blocks — run setup again"
        }
      }
      if (root.applyDirty) {
        root.applyDirty = false
        root.reconcile()
      }
    }
  }

  Process {
    id: installProc
    command: ["pkexec", root.pluginDir + "/bin/deeplok-setup", "install", root.pluginDir, root.user]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: installErr; waitForEnd: true }
    onExited: function(code) {
      root.installBusy = false
      if (code === 0) {
        root.installMessage = ""
      } else if (code === 126 || code === 127) {
        root.installMessage = "Authentication cancelled"
      } else {
        root.installMessage = "Install failed: " + installErr.text.trim().slice(0, 120)
      }
      statusProc.running = true
    }
  }

  Process {
    id: uninstallProc
    command: ["pkexec", root.helperPath.replace("deeplok-helper", "deeplok-setup"), "uninstall"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: uninstallErr; waitForEnd: true }
    onExited: function(code) {
      root.installBusy = false
      if (code === 3)
        root.installMessage = "Locked session running — uninstall refused"
      else if (code !== 0 && code !== 126 && code !== 127)
        root.installMessage = "Uninstall failed: " + uninstallErr.text.trim().slice(0, 120)
      statusProc.running = true
    }
  }

  // ---- Timers --------------------------------------------------------------

  // The scheduler heartbeat. 5s keeps schedule edges within a few seconds
  // of the wall clock without meaningful cost.
  Timer {
    interval: 5000
    repeat: true
    running: root.ready
    onTriggered: root.reconcile()
  }

  // Smooth countdowns while a block is running or one is pending soon.
  Timer {
    interval: 1000
    repeat: true
    running: root.ready && root.blocking
    onTriggered: root.nowTick = Date.now()
  }

  // Blocked apps are enforced event-driven (new windows) plus a slow sweep.
  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.enforceApps() }
  }

  Component.onCompleted: ensureDirProc.running = true
}
