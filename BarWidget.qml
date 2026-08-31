import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget: a shield glyph, plus the time remaining while a block is
// running. The engine lives in Service.qml; this only reads its state and
// hosts the panel.
BarWidget {
  id: root
  moduleName: "shl.deeplok"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("shl.deeplok") : null
  readonly property bool blocking: service ? service.blocking === true : false
  readonly property string label: blocking && service ? service.barLabel : ""

  readonly property string glyph: "󰦝"

  readonly property string tooltip: {
    if (!service || !service.ready) return "Deeplok"
    if (root.blocking)
      return "Deeplok · blocking until " + service.fmtClock(service.block.endsAt)
        + (service.block.lockedUntil > service.nowTick ? " · locked" : "")
    var up = service.upcoming
    if (up) return "Deeplok · next block " + service.fmtDayClock(up.startsAt)
    return "Deeplok · no blocks scheduled"
  }

  // Vertical bar (left/right edge): stacked glyph plus countdown tokens,
  // same shape as omarchy.clock's vertical stack.
  readonly property var verticalLines: {
    if (!root.vertical) return []
    var lines = [root.glyph]
    if (root.label) {
      var parts = String(root.label).split(" ")
      for (var i = 0; i < parts.length; i++) if (parts[i]) lines.push(parts[i])
    }
    return lines
  }

  // ---- Panel shape contract for shell.summon/hide/toggle routing ---------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "shl.deeplok"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : (root.label ? root.glyph + " " + root.label : root.glyph)
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.5
    tooltipText: root.tooltip
    onPressed: root.togglePanel()

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData === root.glyph
            ? Style.font.icon
            : (modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize)
          color: button.foreground
        }
      }
    }
  }
}
