import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model

// Deeplok control panel: live block status, quick sessions (now or at a
// chosen date/time), recurring weekly schedules, and blocklist editing.
// All state changes go through Service.qml; this file is UI only.
//
// Visual language follows the first-party panels (omarchy.power is the
// reference): a hero with a display-size glyph and a big number on the
// right, a progress bar, PanelSectionHeader sections split by
// PanelSeparator, equal-width chip rows, and PanelActionButton row actions.
Panel {
  id: root
  moduleName: "shl.deeplok"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("shl.deeplok") : null
  readonly property bool serviceReady: service && service.ready === true
  readonly property var block: serviceReady ? service.block : null
  readonly property bool blocking: serviceReady && service.blocking
  readonly property bool lockedNow: blocking && block.lockedUntil > nowTick
  readonly property var blocklists: serviceReady ? service.blocklists : []
  readonly property var schedules: serviceReady ? service.schedules : []
  readonly property var sessions: serviceReady ? service.sessions : []
  readonly property double nowTick: serviceReady ? service.nowTick : 0
  readonly property bool installed: serviceReady && service.installed === true
  readonly property bool needsSetup: serviceReady && service.installChecked && !service.installed

  // Guarded so the widget renders before the bar is injected.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.darker(fg, 1.8)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // 0..1 of the current block already elapsed; drives the hero progress bar.
  readonly property real blockFraction: {
    if (!root.blocking) return 0
    var total = root.block.endsAt - root.block.startsAt
    if (!(total > 0)) return 0
    return Math.max(0, Math.min(1, (root.block.endsAt - root.nowTick) / total))
  }

  readonly property string heroStatus: {
    if (!root.serviceReady) return "Starting…"
    if (root.blocking) {
      var s = Model.fmtCount(root.block.domains.length, "site")
        + " · " + Model.fmtCount(root.block.apps.length, "app")
        + " · until " + Model.fmtClock(root.block.endsAt)
      if (root.lockedNow) s += " · 󰌾 locked"
      return s
    }
    var up = root.service.upcoming
    if (up) return "Next · " + up.name + " · " + Model.fmtDayClock(up.startsAt, root.nowTick)
    return "No blocks scheduled"
  }

  // ---- Form state ----------------------------------------------------------
  property var sessionListIds: []
  property int sessionMinutes: 30
  property bool sessionLocked: false
  property bool startLater: false
  property int laterMonth: 1
  property int laterDay: 1
  property int laterHour: 9
  property int laterMinute: 0

  property bool schedFormOpen: false
  property var schedDays: [1, 2, 3, 4, 5]
  property var schedListIds: []
  property bool schedLocked: false
  property int schedStartH: 9
  property int schedStartM: 0
  property int schedEndH: 12
  property int schedEndM: 0

  property string editingListId: ""
  property string flash: ""

  readonly property var durationPresets: [
    { t: "15m", m: 15 }, { t: "30m", m: 30 }, { t: "1h", m: 60 }, { t: "2h", m: 120 }
  ]

  readonly property var dayChoices: [
    { label: "Mon", v: 1 }, { label: "Tue", v: 2 }, { label: "Wed", v: 3 },
    { label: "Thu", v: 4 }, { label: "Fri", v: 5 }, { label: "Sat", v: 6 },
    { label: "Sun", v: 0 }
  ]

  function showFlash(text) {
    root.flash = text
    flashTimer.restart()
  }

  Timer {
    id: flashTimer
    interval: 4000
    onTriggered: root.flash = ""
  }

  function toggledIds(arr, id) {
    var out = []
    var found = false
    for (var i = 0; i < arr.length; i++) {
      if (arr[i] === id) found = true
      else out.push(arr[i])
    }
    if (!found) out.push(id)
    return out
  }

  function resolvedStartMs() {
    if (!root.startLater) return 0
    var now = new Date()
    return new Date(now.getFullYear(), root.laterMonth - 1, root.laterDay,
      root.laterHour, root.laterMinute, 0, 0).getTime()
  }

  readonly property bool laterValid: !startLater || resolvedStartMs() > nowTick

  function startSession() {
    if (!root.serviceReady) return
    if (root.sessionListIds.length === 0) {
      root.showFlash("Pick at least one blocklist")
      return
    }
    var startsAt = root.resolvedStartMs()
    if (root.startLater && startsAt <= Date.now()) {
      root.showFlash("Start time is in the past")
      return
    }
    if (root.service.startSession(root.sessionListIds, root.sessionMinutes, root.sessionLocked, startsAt)) {
      root.startLater = false
      root.showFlash(startsAt > 0 ? "Session scheduled" : "Session started")
    }
  }

  function saveSchedule() {
    if (!root.serviceReady) return
    var name = schedNameField.text.trim()
    if (!name) { root.showFlash("Schedule needs a name"); return }
    if (root.schedDays.length === 0) { root.showFlash("Pick at least one day"); return }
    if (root.schedListIds.length === 0) { root.showFlash("Pick at least one blocklist"); return }
    var ok = root.service.addSchedule({
      name: name,
      blocklistIds: root.schedListIds,
      days: root.schedDays,
      startMin: root.schedStartH * 60 + root.schedStartM,
      endMin: root.schedEndH * 60 + root.schedEndM,
      enabled: true,
      locked: root.schedLocked
    })
    if (!ok) { root.showFlash("Start and end can't be equal"); return }
    root.schedFormOpen = false
    schedNameField.text = ""
  }

  onOpenedChanged: {
    if (!root.opened || !root.serviceReady) return
    // Fresh defaults each open: all lists selected, "later" points at the
    // next full hour.
    if (root.sessionListIds.length === 0 && root.blocklists.length > 0) {
      var ids = []
      for (var i = 0; i < root.blocklists.length; i++) ids.push(root.blocklists[i].id)
      root.sessionListIds = ids
    }
    if (root.schedListIds.length === 0 && root.blocklists.length > 0)
      root.schedListIds = [root.blocklists[0].id]
    var t = new Date(Date.now() + 3600 * 1000)
    root.laterMonth = t.getMonth() + 1
    root.laterDay = t.getDate()
    root.laterHour = t.getHours()
    root.laterMinute = 0
  }

  // ---- Reusable bits -------------------------------------------------------

  component BodyText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  component CaptionText: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  component SectionHeader: PanelSectionHeader {
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  component Chip: Button {
    foreground: root.fg
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    bordered: true
  }

  component ToggleRow: Row {
    property alias checked: sw.checked
    property string label: ""
    signal toggled()
    spacing: Style.space(6)

    ToggleSwitch {
      id: sw
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.fg
      accent: Color.accent
      onToggled: parent.toggled()
    }
    BodyText {
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
    }
  }

  component TimeField: NumberField {
    foreground: root.fg
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    fieldWidth: Style.space(52)
  }

  // Two-line list row with actions pinned right: icon · title/meta · controls.
  component PanelRow: Item {
    property string icon: ""
    property color iconColor: root.dim
    property string title: ""
    property string meta: ""
    default property alias controls: controlsRow.children
    width: parent.width
    implicitHeight: Math.max(Style.space(30), rowLabels.implicitHeight + Style.space(4))

    Text {
      id: rowIcon
      textFormat: Text.PlainText
      visible: icon !== ""
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: parent.icon
      color: parent.iconColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rowLabels
      anchors.left: rowIcon.visible ? rowIcon.right : parent.left
      anchors.leftMargin: rowIcon.visible ? Style.space(10) : 0
      anchors.right: controlsRow.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      BodyText {
        width: parent.width
        text: parent.parent.title
        font.bold: true
      }
      CaptionText {
        width: parent.width
        visible: text !== ""
        text: parent.parent.meta
      }
    }

    Row {
      id: controlsRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && panelScroll.contentHeight > panelScroll.height)
          panelScroll.contentY = Math.max(0, Math.min(
            panelScroll.contentHeight - panelScroll.height,
            panelScroll.contentY - dy * Style.space(24)))
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelScroll.width
          spacing: Style.space(14)

          // ---------- Hero: shield · title/status · countdown ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroCountdown.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.lockedNow ? "󰦝" : (root.blocking ? "󰒃" : "󰒙")
              color: root.blocking ? Color.accent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroCountdown.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.blocking ? "Blocking" : "Deeplok"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.heroStatus.toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            Text {
              id: heroCountdown
              textFormat: Text.PlainText
              visible: root.blocking
              text: root.blocking ? Model.fmtCountdown(root.block.endsAt - root.nowTick) : ""
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ---------- Remaining-time bar (only while blocking) ----------
          Item {
            width: parent.width
            visible: root.blocking
            implicitHeight: Style.space(6)

            Rectangle {
              id: blockTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            }

            Rectangle {
              anchors.left: blockTrack.left
              anchors.verticalCenter: blockTrack.verticalCenter
              height: blockTrack.height
              radius: blockTrack.radius
              color: Color.accent
              width: Math.max(blockTrack.height, blockTrack.width * root.blockFraction)

              Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
            }
          }

          // ---------- Transient feedback ----------
          CaptionText {
            width: parent.width
            visible: root.flash !== ""
            text: "󰀪 " + root.flash
            color: Color.accent
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
          }

          // ---------- Setup card ----------
          Column {
            width: parent.width
            visible: root.needsSetup || (root.serviceReady && root.service.installMessage !== "")
            spacing: Style.space(10)

            PanelSeparator { width: parent.width; foreground: root.fg }

            CaptionText {
              width: parent.width
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: root.serviceReady && root.service.installMessage !== ""
                ? "󰀪 " + root.service.installMessage
                : "Website blocking needs a one-time system setup — a root-owned "
                  + "helper plus a scoped sudo rule, so schedules run unattended. "
                  + "App blocking already works."
            }

            Button {
              width: parent.width
              iconText: "󱊞"
              text: root.serviceReady && root.service.installBusy ? "Installing…" : "Install system helper"
              bordered: true
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.serviceReady && !root.service.installBusy) root.service.installHelper()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Start a block ----------
          Column {
            width: parent.width
            spacing: Style.space(10)

            SectionHeader { text: "START A BLOCK" }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.blocklists

                Chip {
                  required property var modelData
                  text: modelData.name
                  active: root.sessionListIds.indexOf(modelData.id) !== -1
                  tooltipText: Model.fmtCount(modelData.sites.length, "site")
                    + " · " + Model.fmtCount(modelData.apps.length, "app")
                  onClicked: root.sessionListIds = root.toggledIds(root.sessionListIds, modelData.id)
                }
              }
            }

            Row {
              id: durationRow
              width: parent.width
              spacing: Style.space(6)

              readonly property real cellWidth:
                (width - spacing * (root.durationPresets.length + 1) - customField.width - customUnit.implicitWidth)
                / root.durationPresets.length

              Repeater {
                model: root.durationPresets

                Chip {
                  required property var modelData
                  width: durationRow.cellWidth
                  text: modelData.t
                  active: root.sessionMinutes === modelData.m
                  onClicked: root.sessionMinutes = modelData.m
                }
              }

              TimeField {
                id: customField
                anchors.verticalCenter: parent.verticalCenter
                value: root.sessionMinutes
                from: 5
                to: 12 * 60
                stepSize: 5
                fieldWidth: Style.space(64)
                onModified: function(v) { root.sessionMinutes = v }
              }

              CaptionText {
                id: customUnit
                anchors.verticalCenter: parent.verticalCenter
                text: "min"
              }
            }

            Row {
              spacing: Style.space(16)

              ToggleRow {
                label: "Locked 󰌾"
                checked: root.sessionLocked
                onToggled: root.sessionLocked = !root.sessionLocked
              }

              ToggleRow {
                label: "Start later"
                checked: root.startLater
                onToggled: root.startLater = !root.startLater
              }
            }

            Column {
              visible: root.startLater
              width: parent.width
              spacing: Style.space(6)

              Row {
                spacing: Style.space(6)

                TimeField {
                  value: root.laterDay
                  from: 1; to: 31
                  onModified: function(v) { root.laterDay = v }
                }
                CaptionText { anchors.verticalCenter: parent.verticalCenter; text: "/" }
                TimeField {
                  value: root.laterMonth
                  from: 1; to: 12
                  onModified: function(v) { root.laterMonth = v }
                }
                Item { width: Style.space(10); height: 1 }
                TimeField {
                  value: root.laterHour
                  from: 0; to: 23
                  onModified: function(v) { root.laterHour = v }
                }
                CaptionText { anchors.verticalCenter: parent.verticalCenter; text: ":" }
                TimeField {
                  value: root.laterMinute
                  from: 0; to: 59
                  stepSize: 5
                  onModified: function(v) { root.laterMinute = v }
                }
              }

              CaptionText {
                width: parent.width
                color: root.laterValid ? root.dim : Color.urgent
                text: root.laterValid
                  ? "Starts " + Model.fmtDayClock(root.resolvedStartMs(), root.nowTick)
                    + " · day / month · 24h clock"
                  : "󰀪 Start time is in the past"
              }
            }

            Button {
              width: parent.width
              iconText: "󰒃"
              text: root.startLater && root.laterValid
                ? "Schedule for " + Model.fmtDayClock(root.resolvedStartMs(), root.nowTick)
                : "Start blocking now"
              bordered: true
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.startSession()
            }
          }

          // ---------- Sessions (only when some exist) ----------
          Column {
            width: parent.width
            visible: root.sessions.length > 0
            spacing: Style.space(10)

            PanelSeparator { width: parent.width; foreground: root.fg }

            SectionHeader { text: "SESSIONS" }

            Repeater {
              model: root.sessions

              PanelRow {
                required property var modelData
                readonly property bool live: modelData.startsAt <= root.nowTick
                readonly property bool sessionLockedNow: modelData.locked && live

                icon: live ? "󰐊" : "󰅐"
                iconColor: live ? Color.accent : root.dim
                title: live
                  ? Model.fmtCountdown(modelData.endsAt - root.nowTick) + " left"
                  : "Starts " + Model.fmtDayClock(modelData.startsAt, root.nowTick)
                meta: (live ? "Until " + Model.fmtClock(modelData.endsAt)
                            : Model.fmtCountdown(modelData.endsAt - modelData.startsAt) + " long")
                  + (modelData.locked ? " · 󰌾 locked" : "")

                PanelActionButton {
                  iconText: sessionLockedNow ? "󰌾" : "󰅖"
                  enabled: !sessionLockedNow
                  tooltipText: sessionLockedNow
                    ? "Locked until " + Model.fmtClock(modelData.endsAt)
                    : (live ? "End session" : "Cancel session")
                  foreground: root.fg
                  hoverColor: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.service.endSession(modelData.id)
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Schedules ----------
          Column {
            width: parent.width
            spacing: Style.space(10)

            SectionHeader { text: "RECURRING SCHEDULES" }

            CaptionText {
              visible: root.schedules.length === 0 && !root.schedFormOpen
              text: "None yet — block the same hours every week"
            }

            Repeater {
              model: root.schedules

              PanelRow {
                required property var modelData
                icon: "󰃰"
                iconColor: modelData.enabled ? Color.accent : root.faint
                title: modelData.name + (modelData.locked ? " 󰌾" : "")
                meta: Model.daysLabel(modelData.days) + " · "
                  + Model.hhmm(modelData.startMin) + "–" + Model.hhmm(modelData.endMin)

                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: modelData.enabled
                  foreground: root.fg
                  accent: Color.accent
                  onToggled: {
                    if (!root.service.setScheduleEnabled(modelData.id, !modelData.enabled))
                      root.showFlash("Locked — can't disable while running")
                  }
                }

                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Delete schedule"
                  foreground: root.fg
                  hoverColor: Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: {
                    if (!root.service.removeSchedule(modelData.id))
                      root.showFlash("Locked — can't delete while running")
                  }
                }
              }
            }

            Button {
              visible: !root.schedFormOpen
              iconText: "󰐕"
              text: "New schedule"
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.schedFormOpen = true
            }

            // ---------- New-schedule form ----------
            Column {
              visible: root.schedFormOpen
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: schedNameField
                width: parent.width
                placeholderText: "Name — e.g. Deep work"
                foreground: root.fg
                accent: Color.accent
              }

              Row {
                id: dayRow
                width: parent.width
                spacing: Style.space(4)

                readonly property real cellWidth:
                  (width - spacing * (root.dayChoices.length - 1)) / root.dayChoices.length

                Repeater {
                  model: root.dayChoices

                  Chip {
                    required property var modelData
                    width: dayRow.cellWidth
                    text: modelData.label
                    fontSize: Style.font.caption
                    active: root.schedDays.indexOf(modelData.v) !== -1
                    onClicked: root.schedDays = root.toggledIds(root.schedDays, modelData.v)
                  }
                }
              }

              Row {
                spacing: Style.space(6)

                TimeField {
                  value: root.schedStartH
                  from: 0; to: 23
                  onModified: function(v) { root.schedStartH = v }
                }
                CaptionText { anchors.verticalCenter: parent.verticalCenter; text: ":" }
                TimeField {
                  value: root.schedStartM
                  from: 0; to: 59
                  stepSize: 5
                  onModified: function(v) { root.schedStartM = v }
                }
                CaptionText { anchors.verticalCenter: parent.verticalCenter; text: "  –  " }
                TimeField {
                  value: root.schedEndH
                  from: 0; to: 23
                  onModified: function(v) { root.schedEndH = v }
                }
                CaptionText { anchors.verticalCenter: parent.verticalCenter; text: ":" }
                TimeField {
                  value: root.schedEndM
                  from: 0; to: 59
                  stepSize: 5
                  onModified: function(v) { root.schedEndM = v }
                }
              }

              CaptionText {
                width: parent.width
                color: root.faint
                text: "End before start runs overnight — 22:00–06:00"
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: root.blocklists

                  Chip {
                    required property var modelData
                    text: modelData.name
                    active: root.schedListIds.indexOf(modelData.id) !== -1
                    onClicked: root.schedListIds = root.toggledIds(root.schedListIds, modelData.id)
                  }
                }
              }

              ToggleRow {
                label: "Locked 󰌾 — can't be disabled while running"
                checked: root.schedLocked
                onToggled: root.schedLocked = !root.schedLocked
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Button {
                  width: (parent.width - parent.spacing) * 0.62
                  iconText: "󰃰"
                  text: "Save schedule"
                  bordered: true
                  foreground: root.fg
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.saveSchedule()
                }

                Button {
                  width: (parent.width - parent.spacing) * 0.38
                  text: "Cancel"
                  bordered: true
                  foreground: root.dim
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.schedFormOpen = false
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Blocklists ----------
          Column {
            width: parent.width
            spacing: Style.space(10)

            SectionHeader { text: "BLOCKLISTS" }

            Repeater {
              model: root.blocklists

              Column {
                id: listCard
                required property var modelData
                readonly property bool editing: root.editingListId === modelData.id
                readonly property bool listLockedNow: root.serviceReady && root.service.lockedListActive(modelData.id)
                width: panelColumn.width
                spacing: Style.space(6)

                PanelRow {
                  icon: "󰈲"
                  iconColor: listCard.listLockedNow ? Color.accent : root.dim
                  title: listCard.modelData.name + (listCard.listLockedNow ? " 󰌾" : "")
                  meta: Model.fmtCount(listCard.modelData.sites.length, "site")
                    + " · " + Model.fmtCount(listCard.modelData.apps.length, "app")

                  PanelActionButton {
                    iconText: listCard.editing ? "󰅀" : "󰅂"
                    tooltipText: listCard.editing ? "Collapse" : "Edit entries"
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.body
                    onClicked: root.editingListId = listCard.editing ? "" : listCard.modelData.id
                  }

                  PanelActionButton {
                    iconText: "󰅖"
                    tooltipText: "Delete blocklist"
                    foreground: root.fg
                    hoverColor: Color.urgent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.body
                    onClicked: {
                      if (!root.service.removeBlocklist(listCard.modelData.id))
                        root.showFlash("Locked — can't delete while blocking")
                    }
                  }
                }

                Column {
                  visible: listCard.editing
                  width: parent.width
                  spacing: Style.space(6)

                  Flow {
                    width: parent.width
                    spacing: Style.space(4)
                    visible: listCard.modelData.sites.length + listCard.modelData.apps.length > 0

                    Repeater {
                      model: listCard.modelData.sites

                      Chip {
                        required property string modelData
                        text: "󰖟 " + modelData
                        fontSize: Style.font.caption
                        tooltipText: "Click to remove"
                        onClicked: {
                          if (!root.service.removeSite(listCard.modelData.id, modelData))
                            root.showFlash("Locked — can't remove while blocking")
                        }
                      }
                    }

                    Repeater {
                      model: listCard.modelData.apps

                      Chip {
                        required property string modelData
                        text: "󰣆 " + modelData
                        fontSize: Style.font.caption
                        tooltipText: "Click to remove"
                        onClicked: {
                          if (!root.service.removeApp(listCard.modelData.id, modelData))
                            root.showFlash("Locked — can't remove while blocking")
                        }
                      }
                    }
                  }

                  TextField {
                    width: parent.width
                    placeholderText: "󰖟  Add site — youtube.com"
                    foreground: root.fg
                    accent: Color.accent
                    onAccepted: {
                      var err = root.service.addSite(listCard.modelData.id, text)
                      if (err) root.showFlash(err)
                      else text = ""
                    }
                  }

                  TextField {
                    width: parent.width
                    placeholderText: "󰣆  Add app — window class, e.g. steam"
                    foreground: root.fg
                    accent: Color.accent
                    onAccepted: {
                      var err = root.service.addApp(listCard.modelData.id, text)
                      if (err) root.showFlash(err)
                      else text = ""
                    }
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: newListField
                width: parent.width - newListBtn.width - parent.spacing
                placeholderText: "New blocklist name"
                foreground: root.fg
                accent: Color.accent
                onAccepted: newListBtn.clicked()
              }

              Button {
                id: newListBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰐕"
                text: "Add"
                bordered: true
                foreground: root.fg
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  var id = root.service.addBlocklist(newListField.text)
                  if (id) {
                    newListField.text = ""
                    root.editingListId = id
                  }
                }
              }
            }
          }

          // ---------- Footer ----------
          Column {
            width: parent.width
            visible: root.installed
            spacing: Style.space(8)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Button {
              text: "Uninstall system helper"
              tooltipText: "Removes the root helper and sudo rule"
              foreground: root.faint
              accent: Color.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: if (!root.service.installBusy) root.service.uninstallHelper()
            }
          }
        }
      }
    }
  }
}
