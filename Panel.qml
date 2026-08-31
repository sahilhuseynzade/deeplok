import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model

// Deeplok control panel: live block status, quick sessions (now or at a
// chosen date/time), recurring weekly schedules, and blocklist editing.
// All state changes go through Service.qml; this file is UI only.
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
  readonly property var blocklists: serviceReady ? service.blocklists : []
  readonly property var schedules: serviceReady ? service.schedules : []
  readonly property var sessions: serviceReady ? service.sessions : []
  readonly property double nowTick: serviceReady ? service.nowTick : 0
  readonly property bool installed: serviceReady && service.installed === true
  readonly property bool needsSetup: serviceReady && service.installChecked && !service.installed

  // Guarded so the widget renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(root.contentForeground, 1.4)

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

  readonly property var dayChoices: [
    { label: "M", v: 1 }, { label: "T", v: 2 }, { label: "W", v: 3 },
    { label: "T", v: 4 }, { label: "F", v: 5 }, { label: "S", v: 6 },
    { label: "S", v: 0 }
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
    var t = new Date(Date.now() + 3600 * 1000)
    root.laterMonth = t.getMonth() + 1
    root.laterDay = t.getDate()
    root.laterHour = t.getHours()
    root.laterMinute = 0
  }

  // ---- Reusable bits -------------------------------------------------------

  component SectionLabel: Text {
    property string label: ""
    text: label
    textFormat: Text.PlainText
    color: root.dimForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.2
  }

  component BodyText: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  component ListChips: Flow {
    id: chips
    property var selected: []
    signal toggled(string id)
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.blocklists

      Button {
        required property var modelData
        text: modelData.name
        selected: chips.selected.indexOf(modelData.id) !== -1
        bordered: true
        foreground: root.contentForeground
        accent: Color.accent
        fontFamily: root.contentFontFamily
        fontSize: Style.font.bodySmall
        onClicked: chips.toggled(modelData.id)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

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
          spacing: Style.space(10)

          // ============================================================ Hero
          Column {
            width: parent.width
            spacing: Style.space(2)

            SectionLabel { label: "DEEPLOK" }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: {
                if (!root.serviceReady) return "Starting…"
                if (root.blocking)
                  return "Blocking · " + Model.fmtCountdown(root.block.endsAt - root.nowTick) + " left"
                return "No active block"
              }
              color: root.blocking ? Color.accent : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }

            BodyText {
              width: parent.width
              visible: root.serviceReady
              color: root.dimForeground
              text: {
                if (!root.serviceReady) return ""
                if (root.blocking) {
                  var s = "Until " + Model.fmtClock(root.block.endsAt)
                    + " · " + root.block.domains.length + " sites · "
                    + root.block.apps.length + " apps"
                  if (root.block.lockedUntil > root.nowTick)
                    s += " · 󰌾 locked until " + Model.fmtClock(root.block.lockedUntil)
                  return s
                }
                var up = root.service.upcoming
                return up ? "Next block: " + up.name + " · " + Model.fmtDayClock(up.startsAt, root.nowTick)
                          : "Nothing scheduled"
              }
            }
          }

          // Transient feedback line (errors, confirmations).
          BodyText {
            width: parent.width
            visible: root.flash !== ""
            text: root.flash
            color: Color.accent
            wrapMode: Text.WordWrap
          }

          // ==================================================== Setup card
          Column {
            width: parent.width
            visible: root.needsSetup || (root.serviceReady && root.service.installMessage !== "")
            spacing: Style.space(6)

            PanelSeparator { width: parent.width; foreground: root.contentForeground }

            BodyText {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.serviceReady && root.service.installMessage !== ""
                ? root.service.installMessage
                : "Website blocking needs a one-time system setup (root helper + a "
                  + "sudo rule so schedules run unattended). App blocking already works."
            }

            Button {
              text: root.serviceReady && root.service.installBusy ? "Installing…" : "Install system helper"
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: if (root.serviceReady && !root.service.installBusy) root.service.installHelper()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground }

          // ====================================================== Sessions
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionLabel { label: "SESSIONS" }

            // Active and upcoming one-off sessions.
            Repeater {
              model: root.sessions

              Item {
                required property var modelData
                readonly property bool live: modelData.startsAt <= root.nowTick
                readonly property bool lockedNow: modelData.locked && live
                width: panelColumn.width
                height: Style.space(24)

                BodyText {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.right: endBtn.left
                  anchors.rightMargin: Style.space(6)
                  text: (live
                    ? "Running · " + Model.fmtCountdown(modelData.endsAt - root.nowTick) + " left"
                    : "Starts " + Model.fmtDayClock(modelData.startsAt, root.nowTick)
                      + " · " + Model.fmtCountdown(modelData.endsAt - modelData.startsAt))
                    + (modelData.locked ? " · 󰌾" : "")
                }

                Button {
                  id: endBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: lockedNow ? "󰌾" : (live ? "End" : "Cancel")
                  tooltipText: lockedNow ? "Locked until " + Model.fmtClock(modelData.endsAt) : ""
                  foreground: lockedNow ? root.dimForeground : root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  onClicked: {
                    if (lockedNow) { root.showFlash("Locked — runs until " + Model.fmtClock(modelData.endsAt)); return }
                    root.service.endSession(modelData.id)
                  }
                }
              }
            }

            ListChips {
              selected: root.sessionListIds
              onToggled: function(id) { root.sessionListIds = root.toggledIds(root.sessionListIds, id) }
            }

            Row {
              spacing: Style.space(4)

              Repeater {
                model: [{ t: "15m", m: 15 }, { t: "30m", m: 30 }, { t: "1h", m: 60 }, { t: "2h", m: 120 }]

                Button {
                  required property var modelData
                  text: modelData.t
                  selected: root.sessionMinutes === modelData.m
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.sessionMinutes = modelData.m
                }
              }

              NumberField {
                label: ""
                value: root.sessionMinutes
                from: 5
                to: 12 * 60
                stepSize: 5
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onModified: function(v) { root.sessionMinutes = v }
              }

              BodyText {
                anchors.verticalCenter: parent.verticalCenter
                text: "min"
                color: root.dimForeground
              }
            }

            Row {
              spacing: Style.space(10)

              Row {
                spacing: Style.space(4)
                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.sessionLocked
                  foreground: root.contentForeground
                  accent: Color.accent
                  onToggled: root.sessionLocked = !root.sessionLocked
                }
                BodyText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Locked 󰌾"
                }
              }

              Row {
                spacing: Style.space(4)
                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.startLater
                  foreground: root.contentForeground
                  accent: Color.accent
                  onToggled: root.startLater = !root.startLater
                }
                BodyText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Start later"
                }
              }
            }

            Row {
              visible: root.startLater
              spacing: Style.space(6)

              NumberField {
                label: "Month"
                value: root.laterMonth
                from: 1; to: 12
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onModified: function(v) { root.laterMonth = v }
              }
              NumberField {
                label: "Day"
                value: root.laterDay
                from: 1; to: 31
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onModified: function(v) { root.laterDay = v }
              }
              NumberField {
                label: "Hour"
                value: root.laterHour
                from: 0; to: 23
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onModified: function(v) { root.laterHour = v }
              }
              NumberField {
                label: "Min"
                value: root.laterMinute
                from: 0; to: 59
                stepSize: 5
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onModified: function(v) { root.laterMinute = v }
              }
            }

            Button {
              text: root.startLater ? "Schedule session" : "Start blocking now"
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.startSession()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground }

          // ==================================================== Schedules
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionLabel { label: "RECURRING SCHEDULES" }

            BodyText {
              visible: root.schedules.length === 0
              text: "No schedules yet"
              color: root.dimForeground
            }

            Repeater {
              model: root.schedules

              Item {
                required property var modelData
                readonly property bool lockedNow: root.serviceReady && root.service.scheduleLockedActive(modelData.id)
                width: panelColumn.width
                height: Style.space(26)

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.right: schedControls.left
                  anchors.rightMargin: Style.space(6)
                  spacing: 0

                  BodyText {
                    width: parent.width
                    text: modelData.name + (modelData.locked ? " 󰌾" : "")
                  }
                  BodyText {
                    width: parent.width
                    color: root.dimForeground
                    font.pixelSize: Style.font.caption
                    text: Model.daysLabel(modelData.days) + " · "
                      + Model.hhmm(modelData.startMin) + "–" + Model.hhmm(modelData.endMin)
                  }
                }

                Row {
                  id: schedControls
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  ToggleSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: modelData.enabled
                    foreground: root.contentForeground
                    accent: Color.accent
                    onToggled: {
                      if (!root.service.setScheduleEnabled(modelData.id, !modelData.enabled))
                        root.showFlash("Locked — can't disable while running")
                    }
                  }

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰅖"
                    tooltipText: "Delete schedule"
                    foreground: root.dimForeground
                    accent: Color.accent
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.caption
                    onClicked: {
                      if (!root.service.removeSchedule(modelData.id))
                        root.showFlash("Locked — can't delete while running")
                    }
                  }
                }
              }
            }

            Button {
              text: root.schedFormOpen ? "Cancel" : "New schedule"
              bordered: true
              foreground: root.contentForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.schedFormOpen = !root.schedFormOpen
            }

            Column {
              visible: root.schedFormOpen
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: schedNameField
                width: parent.width
                placeholderText: "Name (e.g. Deep work)"
                foreground: root.contentForeground
                accent: Color.accent
              }

              Row {
                spacing: Style.space(4)

                Repeater {
                  model: root.dayChoices

                  Button {
                    required property var modelData
                    text: modelData.label
                    selected: root.schedDays.indexOf(modelData.v) !== -1
                    bordered: true
                    foreground: root.contentForeground
                    accent: Color.accent
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.caption
                    onClicked: root.schedDays = root.toggledIds(root.schedDays, modelData.v)
                  }
                }
              }

              Row {
                spacing: Style.space(6)

                NumberField {
                  label: "From"
                  value: root.schedStartH
                  from: 0; to: 23
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onModified: function(v) { root.schedStartH = v }
                }
                NumberField {
                  label: ""
                  value: root.schedStartM
                  from: 0; to: 59
                  stepSize: 5
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onModified: function(v) { root.schedStartM = v }
                }
                NumberField {
                  label: "To"
                  value: root.schedEndH
                  from: 0; to: 23
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onModified: function(v) { root.schedEndH = v }
                }
                NumberField {
                  label: ""
                  value: root.schedEndM
                  from: 0; to: 59
                  stepSize: 5
                  foreground: root.contentForeground
                  accent: Color.accent
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onModified: function(v) { root.schedEndM = v }
                }
              }

              BodyText {
                color: root.dimForeground
                font.pixelSize: Style.font.caption
                text: "End before start = overnight (e.g. 22:00–06:00)"
              }

              ListChips {
                selected: root.schedListIds
                onToggled: function(id) { root.schedListIds = root.toggledIds(root.schedListIds, id) }
              }

              Row {
                spacing: Style.space(4)
                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.schedLocked
                  foreground: root.contentForeground
                  accent: Color.accent
                  onToggled: root.schedLocked = !root.schedLocked
                }
                BodyText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Locked 󰌾 (can't be disabled while running)"
                }
              }

              Button {
                text: "Save schedule"
                bordered: true
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.saveSchedule()
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.contentForeground }

          // ==================================================== Blocklists
          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionLabel { label: "BLOCKLISTS" }

            Repeater {
              model: root.blocklists

              Column {
                id: listCard
                required property var modelData
                readonly property bool editing: root.editingListId === modelData.id
                readonly property bool lockedNow: root.serviceReady && root.service.lockedListActive(modelData.id)
                width: panelColumn.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  height: Style.space(24)

                  BodyText {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: listControls.left
                    anchors.rightMargin: Style.space(6)
                    text: modelData.name + (listCard.lockedNow ? " 󰌾" : "")
                      + "  ·  " + modelData.sites.length + " sites, " + modelData.apps.length + " apps"
                  }

                  Row {
                    id: listControls
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Button {
                      text: listCard.editing ? "Done" : "Edit"
                      foreground: root.contentForeground
                      accent: Color.accent
                      fontFamily: root.contentFontFamily
                      fontSize: Style.font.caption
                      onClicked: root.editingListId = listCard.editing ? "" : listCard.modelData.id
                    }

                    Button {
                      text: "󰅖"
                      tooltipText: "Delete blocklist"
                      foreground: root.dimForeground
                      accent: Color.accent
                      fontFamily: root.contentFontFamily
                      fontSize: Style.font.caption
                      onClicked: {
                        if (!root.service.removeBlocklist(listCard.modelData.id))
                          root.showFlash("Locked — can't delete while blocking")
                      }
                    }
                  }
                }

                Column {
                  visible: listCard.editing
                  width: parent.width
                  spacing: Style.space(4)

                  BodyText {
                    color: root.dimForeground
                    font.pixelSize: Style.font.caption
                    text: "Click an entry to remove it"
                    visible: listCard.modelData.sites.length + listCard.modelData.apps.length > 0
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: listCard.modelData.sites

                      Button {
                        required property string modelData
                        text: "󰖟 " + modelData
                        foreground: root.contentForeground
                        accent: Color.accent
                        fontFamily: root.contentFontFamily
                        fontSize: Style.font.caption
                        onClicked: {
                          if (!root.service.removeSite(listCard.modelData.id, modelData))
                            root.showFlash("Locked — can't remove while blocking")
                        }
                      }
                    }

                    Repeater {
                      model: listCard.modelData.apps

                      Button {
                        required property string modelData
                        text: "󰣆 " + modelData
                        foreground: root.contentForeground
                        accent: Color.accent
                        fontFamily: root.contentFontFamily
                        fontSize: Style.font.caption
                        onClicked: {
                          if (!root.service.removeApp(listCard.modelData.id, modelData))
                            root.showFlash("Locked — can't remove while blocking")
                        }
                      }
                    }
                  }

                  TextField {
                    width: parent.width
                    placeholderText: "Add site (e.g. youtube.com)"
                    foreground: root.contentForeground
                    accent: Color.accent
                    onAccepted: {
                      var err = root.service.addSite(listCard.modelData.id, text)
                      if (err) root.showFlash(err)
                      else text = ""
                    }
                  }

                  TextField {
                    width: parent.width
                    placeholderText: "Add app (window class, e.g. steam)"
                    foreground: root.contentForeground
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
              spacing: Style.space(4)

              TextField {
                id: newListField
                width: parent.width - newListBtn.width - Style.space(4)
                placeholderText: "New blocklist name"
                foreground: root.contentForeground
                accent: Color.accent
                onAccepted: newListBtn.clicked()
              }

              Button {
                id: newListBtn
                anchors.verticalCenter: parent.verticalCenter
                text: "Add"
                bordered: true
                foreground: root.contentForeground
                accent: Color.accent
                fontFamily: root.contentFontFamily
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

          // ==================================================== Footer
          Column {
            width: parent.width
            visible: root.installed
            spacing: Style.space(4)

            PanelSeparator { width: parent.width; foreground: root.contentForeground }

            Button {
              text: "Uninstall system helper"
              tooltipText: "Removes the root helper and sudo rule"
              foreground: root.dimForeground
              accent: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              onClicked: if (!root.service.installBusy) root.service.uninstallHelper()
            }
          }
        }
      }
    }
  }
}
