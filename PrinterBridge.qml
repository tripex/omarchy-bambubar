import QtQuick
import Quickshell.Io

// Runs bin/bambubar-bridge and mirrors what it reports. The bridge owns the
// MQTT connection and the stored settings; this side only displays them and
// forwards the settings form.
Item {
  id: root

  property bool demo: false

  readonly property string bridgePath: decodeURIComponent(
    Qt.resolvedUrl("bin/bambubar-bridge").toString().replace(/^file:\/\//, ""))

  // Settings as stored by the bridge. The access code itself never comes back.
  property string host: ""
  property string serial: ""
  property bool hasCode: false
  property bool configLoaded: false
  property bool isDemo: false

  // starting | notConfigured | connecting | connected | denied | disconnected | failed
  property string status: "starting"
  property string statusDetail: ""

  property string gcodeState: ""
  property int percent: 0
  property int remainingMin: 0
  property real nozzle: 0
  property real nozzleTarget: 0
  property real bed: 0
  property real bedTarget: 0
  property string job: ""
  property int currentLayer: 0
  property int totalLayers: 0
  property var ams: []
  property real totalPrintSeconds: 0

  property bool saving: false
  // Error key from the last save (invalid-host, invalid-serial, invalid-code,
  // code-missing, demo, bridge), or "" when it went through.
  property string saveError: ""
  property string saveWarning: ""
  signal saved()
  // Every config event, so the settings form can follow a restarted bridge
  // (demo mode on or off) and not only the first one.
  signal configReceived()

  readonly property bool configured: host !== "" && serial !== "" && hasCode
  readonly property bool connected: status === "connected"
  readonly property bool printing: gcodeState === "RUNNING" || gcodeState === "PAUSE" || gcodeState === "PREPARE"

  property bool restarting: false

  function configure(newHost, newSerial, accessCode) {
    saveError = ""
    saveWarning = ""
    if (!send({ op: "configure", host: newHost, serial: newSerial, accessCode: accessCode })) {
      saveError = "bridge"
      return
    }
    saving = true
  }

  function refresh() {
    send({ op: "refresh" })
  }

  function send(command) {
    if (!bridge.running || restarting) return false
    bridge.write(JSON.stringify(command) + "\n")
    return true
  }

  function num(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  function handle(line) {
    var ev
    try {
      ev = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!ev || typeof ev !== "object") return

    if (ev.ev === "config") {
      host = String(ev.host || "")
      serial = String(ev.serial || "")
      hasCode = ev.hasCode === true
      isDemo = ev.demo === true
      configLoaded = true
      configReceived()
    } else if (ev.ev === "status") {
      status = String(ev.status || "")
      statusDetail = String(ev.detail || "")
    } else if (ev.ev === "state") {
      gcodeState = String(ev.gcodeState || "")
      percent = num(ev.percent, 0)
      remainingMin = num(ev.remainingMin, 0)
      nozzle = num(ev.nozzle, 0)
      nozzleTarget = num(ev.nozzleTarget, 0)
      bed = num(ev.bed, 0)
      bedTarget = num(ev.bedTarget, 0)
      job = String(ev.job || "")
      currentLayer = num(ev.layer, 0)
      totalLayers = num(ev.totalLayers, 0)
      ams = Array.isArray(ev.ams) ? ev.ams : []
      totalPrintSeconds = num(ev.totalPrintSeconds, 0)
    } else if (ev.ev === "saved") {
      saving = false
      saveError = ev.ok === true ? "" : String(ev.error || "bridge")
      saveWarning = String(ev.warning || "")
      if (ev.ok === true) saved()
    }
  }

  onDemoChanged: {
    if (!bridge.running) return
    restarting = true
    bridge.signal(15)
  }

  Process {
    id: bridge
    command: root.demo ? [root.bridgePath, "--demo"] : [root.bridgePath]
    running: true
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.handle(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("bambubar-bridge: " + line) }
    }

    onExited: function(exitCode) {
      root.saving = false
      if (root.restarting) {
        root.restarting = false
        root.status = "starting"
        root.statusDetail = ""
        root.configLoaded = false
        bridge.running = true
        return
      }
      root.status = "failed"
      root.statusDetail = "bambubar-bridge exited (" + exitCode + ")"
      restartTimer.restart()
    }
  }

  // A crashed bridge comes back on its own, like the printer connection does.
  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: bridge.running = true
  }
}
