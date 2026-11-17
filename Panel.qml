import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget: the bamboo mark, plus progress and time left while a print runs.
// The panel shows the details; the same panel holds the printer settings.
Panel {
  id: root
  moduleName: "tripex.bambubar"
  ipcTarget: "tripex.bambubar"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool showProgress: boolSetting("showProgress", true) && !(bar && bar.vertical)
  property bool editing: false
  readonly property bool showForm: editing || (printer.configLoaded && !printer.configured && !printer.isDemo)
  readonly property bool failedState: printer.status === "denied" || (printer.connected && printer.gcodeState === "FAILED")

  readonly property string barLabel: {
    if (!showProgress || !printer.connected) return ""
    switch (printer.gcodeState) {
    case "RUNNING": return strings.t("bar.progress").arg(printer.percent).arg(remainingText(printer.remainingMin))
    case "PAUSE": return strings.t("bar.paused")
    case "FINISH": return strings.t("bar.done")
    case "FAILED": return strings.t("bar.failed")
    default: return ""
    }
  }

  readonly property color barIconColor: {
    if (failedState) return urgent
    if (!printer.connected) return Qt.darker(barForeground, 1.55)
    return barForeground
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || String(value) === "true"
  }

  function remainingText(minutes) {
    var m = Math.max(0, Math.round(minutes))
    if (m >= 60) return strings.t("time.hoursMinutes").arg(Math.floor(m / 60)).arg(m % 60)
    return strings.t("time.minutes").arg(m)
  }

  function stateText() {
    switch (printer.gcodeState) {
    case "RUNNING": return strings.t("state.printing")
    case "PREPARE": return strings.t("state.preparing")
    case "PAUSE": return strings.t("state.paused")
    case "FINISH": return strings.t("state.finished")
    case "FAILED": return strings.t("state.failed")
    case "IDLE": return strings.t("state.idle")
    case "": return "–"
    default: return printer.gcodeState
    }
  }

  function connectionText() {
    switch (printer.status) {
    case "notConfigured": return strings.t("conn.notConfigured")
    case "connecting": return strings.t("conn.connecting")
    case "connected": return printer.isDemo ? strings.t("conn.demo") : strings.t("conn.connected")
    case "denied": return strings.t("conn.denied")
    case "disconnected": return strings.t("conn.disconnected")
    case "failed": return strings.t("conn.failed").arg(printer.statusDetail)
    default: return strings.t("conn.starting")
    }
  }

  function degrees(value) {
    return Commons.I18n.formatNumber(Math.round(value))
  }

  function totalText() {
    var t = Math.max(0, Math.floor(printer.totalPrintSeconds))
    return strings.t("time.hoursMinutes").arg(Math.floor(t / 3600)).arg(Math.floor(t % 3600 / 60))
  }

  // AMS units report a 1-5 level where 5 is driest; show it so higher means
  // more humid, or the real percentage where the hardware has it.
  function amsValue(unit) {
    if (unit.percent !== null && unit.percent !== undefined) return Commons.I18n.formatNumber(unit.percent) + "%"
    var level = Number(unit.level) || 0
    return strings.t("ams.level").arg(level === 0 ? 0 : 6 - level)
  }

  function summary() {
    if (!printer.connected) return connectionText()
    if (printer.gcodeState === "RUNNING") return stateText() + " " + barLabelFor()
    return stateText()
  }

  function barLabelFor() {
    return strings.t("bar.progress").arg(printer.percent).arg(remainingText(printer.remainingMin))
  }

  function startEditing() {
    if (printer.isDemo) return
    editing = true
    hostField.text = printer.host
    serialField.text = printer.serial
    codeField.text = ""
    printer.saveError = ""
    Qt.callLater(function() { hostField.forceActiveFocus() })
  }

  function stopEditing() {
    editing = false
    codeField.text = ""
    printer.saveError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function save() {
    if (printer.saving) return
    printer.configure(hostField.text.trim(), serialField.text.trim(), codeField.text.trim())
  }

  function leaveField() {
    if (printer.configured) stopEditing()
    else root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    Qt.callLater(function() {
      if (root.showForm) hostField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  } else if (editing && printer.configured) {
    stopEditing()
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  PrinterBridge {
    id: printer
    demo: root.boolSetting("demo", false)
    onSaved: root.stopEditing()
    onConfigReceived: if (!root.editing) {
      hostField.text = host
      serialField.text = serial
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { printer.refresh(); return "ok" }
    function status(): string { return root.summary() }
  }

  TextMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: root.barLabel
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: root.barLabel
    slotSize: Style.bar.iconSlot + (root.barLabel !== "" ? Math.ceil(labelMetrics.advanceWidth) + Style.space(8) : 0)
    tooltipText: root.opened ? "" : "BambuBar · " + root.summary()
    iconComponent: Component {
      BambooIcon {
        iconSize: 16
        color: root.barIconColor
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) printer.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostField.activeFocus || serialField.activeFocus || codeField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") printer.refresh()
        else if (t === "s" || t === "S") root.startEditing()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: root.showForm ? strings.t("form.title") : root.stateText()
          meta: root.showForm ? "BambuBar" : root.connectionText()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            BambooIcon {
              iconSize: Style.font.display
              color: root.failedState ? root.urgent : root.foreground
            }
          }

          trailingControl: Component {
            RowLayout {
              spacing: Style.space(8)
              visible: !root.showForm

              PanelActionButton {
                iconText: String.fromCodePoint(0xF0450) // md-refresh
                tooltipText: strings.t("action.refresh")
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                opacity: printer.connected ? 1.0 : 0.5
                Layout.alignment: Qt.AlignVCenter
                onClicked: printer.refresh()
              }

              PanelActionButton {
                visible: !printer.isDemo
                iconText: String.fromCodePoint(0xF0493) // md-cog
                tooltipText: strings.t("action.settings")
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.startEditing()
              }
            }
          }
        }

        // ---- status ------------------------------------------------------

        Column {
          visible: !root.showForm
          width: parent.width
          spacing: Style.space(10)

          Caption {
            visible: printer.job !== ""
            width: parent.width
            text: printer.job
            color: root.foreground
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Column {
            visible: printer.printing
            width: parent.width
            spacing: Style.space(6)

            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: height / 2
              color: Util.alpha(root.foreground, 0.15)

              Rectangle {
                width: parent.width * Math.max(0, Math.min(1, printer.percent / 100))
                height: parent.height
                radius: parent.radius
                color: Commons.Color.accent
                Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
              }
            }

            RowLayout {
              width: parent.width
              Caption { text: Commons.I18n.formatNumber(printer.percent) + "%" }
              Item { Layout.fillWidth: true }
              Caption {
                visible: printer.totalLayers > 0
                text: strings.t("print.layer").arg(printer.currentLayer).arg(printer.totalLayers)
              }
              Item { Layout.fillWidth: true }
              Caption { text: strings.t("print.left").arg(root.remainingText(printer.remainingMin)) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            Caption {
              text: strings.t("temp.nozzle").arg(root.degrees(printer.nozzle)).arg(root.degrees(printer.nozzleTarget))
            }
            Item { Layout.fillWidth: true }
            Caption {
              text: strings.t("temp.bed").arg(root.degrees(printer.bed)).arg(root.degrees(printer.bedTarget))
            }
          }

          PanelSeparator {
            visible: printer.ams.length > 0
            foreground: root.foreground
          }

          Repeater {
            model: printer.ams

            RowLayout {
              required property var modelData
              width: parent.width
              Caption { text: strings.t("ams.humidity").arg((parseInt(modelData.id, 10) || 0) + 1) }
              Item { Layout.fillWidth: true }
              Caption { text: root.amsValue(modelData) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            Caption { text: strings.t("total.label") }
            Item { Layout.fillWidth: true }
            Caption { text: root.totalText() }
          }

          Caption {
            width: parent.width
            text: strings.t("total.hint")
            color: root.dim
            wrapMode: Text.WordWrap
          }

          Caption {
            width: parent.width
            text: strings.t("hint.keys")
            color: root.dim
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        // ---- settings ----------------------------------------------------

        Column {
          visible: root.showForm
          width: parent.width
          spacing: Style.space(8)

          Caption {
            width: parent.width
            text: strings.t("form.intro")
            color: root.dim
            wrapMode: Text.WordWrap
          }

          FieldLabel { text: strings.t("form.host") }
          TextField {
            id: hostField
            width: parent.width
            foreground: root.foreground
            placeholderText: "192.168.1.50"
            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
            KeyNavigation.tab: serialField
            onAccepted: serialField.forceActiveFocus()
            Keys.onEscapePressed: root.leaveField()
          }

          FieldLabel { text: strings.t("form.serial") }
          TextField {
            id: serialField
            width: parent.width
            foreground: root.foreground
            placeholderText: "01P00A000000000"
            inputMethodHints: Qt.ImhNoPredictiveText
            KeyNavigation.tab: codeField
            KeyNavigation.backtab: hostField
            onAccepted: codeField.forceActiveFocus()
            Keys.onEscapePressed: root.leaveField()
          }

          FieldLabel { text: strings.t("form.code") }
          TextField {
            id: codeField
            width: parent.width
            foreground: root.foreground
            password: true
            placeholderText: printer.hasCode ? strings.t("form.codeKeep") : ""
            KeyNavigation.tab: hostField
            KeyNavigation.backtab: serialField
            onAccepted: root.save()
            Keys.onEscapePressed: root.leaveField()
          }

          Caption {
            visible: printer.saveError !== "" || printer.saveWarning !== ""
            width: parent.width
            text: printer.saveError !== "" ? strings.t("error." + printer.saveError) : strings.t("warning." + printer.saveWarning)
            color: root.urgent
            wrapMode: Text.WordWrap
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Caption {
              Layout.fillWidth: true
              text: strings.t("form.keyring")
              color: root.dim
              wrapMode: Text.WordWrap
            }

            Button {
              visible: printer.configured
              text: strings.t("form.cancel")
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.stopEditing()
            }

            Button {
              text: printer.saving ? strings.t("form.saving") : strings.t("form.save")
              active: true
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              opacity: printer.saving ? 0.5 : 1.0
              onClicked: root.save()
            }
          }
        }
      }
    }
  }

  // Everything the panel prints comes from the network or the user, so text
  // is always plain.
  component Caption: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component FieldLabel: Caption {
    color: root.dim
    font.bold: true
  }
}
