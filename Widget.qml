import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// AMD NPU: bar icon plus a popup card in the style of Omarchy's own panels
// (power, network, bluetooth). The card covers Voxtype dictation on the NPU
// (Whisper) and small local LLMs: load one next to Whisper or give it the
// NPU alone, see what's loaded, test it, unload it. While you dictate, a
// countdown shows above Voxtype's waveform (CountdownOverlay.qml). Before setup,
// the card walks you through it, since Omarchy plugins can't install anything.
Panel {
  id: root
  moduleName: "alanroman117.amd-npu"
  ipcTarget: "alanroman117.amd-npu"
  // Own the IPC target so it can also carry refresh().
  manageIpc: false

  // Bar icon state: "ready" (service active and answering), "stopped", a setup
  // step from `amd-npu setup-state` ("driver", "install", "reboot", "enable"),
  // or "unsupported" (no XDNA2 NPU: widget hidden).
  property string status: "unsupported"
  // Card details, from `amd-npu status --json`.
  property var info: ({})
  // "", "switch", "load", "unload", "share"
  property string busy: ""
  property bool testingNpu: false
  property bool testingLlm: false
  property string npuTest: ""
  property string llmTest: ""
  property string actionError: ""
  property string selectedModel: ""
  property bool loadExclusive: false
  property bool confirming: false

  // Live dictation countdown: Voxtype's state while F9 is held, against its
  // max_duration_secs (read from ~/.config/voxtype/config.toml, default 60).
  property string recState: "idle"
  property int recLimit: 60
  property real recStartMs: 0
  property int recRemaining: 0
  // Voxtype's [osd] settings, so the countdown can sit above its waveform.
  property bool voxOsdEnabled: true
  property string voxOsdPosition: "bottom-center"
  property real voxOsdTopMargin: 0.85
  property int voxOsdHeight: 48
  property int voxOsdMargin: 24
  // Voxtype's [audio] device. "default" (and the pipewire/pulse ALSA plugins)
  // follow the system default input at record time; anything else locks
  // dictation to that ALSA device.
  property string voxDevice: "default"

  // The microphone dictation uses: the system default input, as in Omarchy's
  // audio panel. Only nickname/description/name are read, never `properties`,
  // which can destabilise Quickshell's Pipewire service while Voxtype's capture
  // stream appears.
  readonly property var micSource: Pipewire.defaultAudioSource
  readonly property bool micLocked: ["default", "pipewire", "pulse", ""].indexOf(voxDevice) < 0
  readonly property bool micMuted: !micLocked && !!(micSource && micSource.audio && micSource.audio.muted)
  readonly property string micName: micLocked ? voxDevice : micLabel(micSource)
  // "No sound" warning: while recording, the active mic's level is watched
  // (PwNodePeakMonitor, as in Omarchy's audio panel). If nothing louder than
  // speech-level noise arrives for silenceWarnSec, the countdown's mic line
  // says so; it clears as soon as sound returns. 0 turns it off. Kept in
  // ~/.config/amd-npu/card.json, since plugins can't write their shell settings.
  property int silenceWarnSec: 3
  property bool peakArmed: false
  property real lastSoundMs: 0
  property real micSinceMs: 0
  property bool micSilent: false
  readonly property bool peakWatching: recording && peakArmed && !micLocked && silenceWarnSec > 0 && !!micSource
  readonly property string cardConfigDir: configHome + "/amd-npu"
  onMicSourceChanged: micSinceMs = Date.now()

  // Input list for the picker: a snapshot taken while the card is open, never
  // bound to the live node list (rebuilding from it has crashed Quickshell).
  property var micInputs: []
  readonly property bool recording: recState === "recording"
  readonly property bool recWarn: recording && recRemaining <= 15
  readonly property bool setupMode: ["driver", "install", "reboot", "enable", "foreign"].indexOf(status) >= 0
  // The bar makes one widget per monitor; only the one on the focused monitor
  // (where Voxtype draws its waveform) shows the countdown.
  readonly property var barScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property bool onFocusedMonitor: !Hyprland.focusedMonitor || !barScreen || Hyprland.focusedMonitor.name === barScreen.name
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")

  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/amd-npu").toString().replace("file://", ""))
  readonly property var llm: info.llm || null
  readonly property var downloaded: info.downloaded || []
  readonly property bool exclusive: info.mode === "exclusive"
  readonly property bool onNpu: info.backend === "remote" && info.service === "active" && !exclusive
  // "foreign": another account listens where 127.0.0.1:52625 traffic would go (loopback, 0.0.0.0,
  // ::, ::1 or ::ffff:127.0.0.1; port hex CD91). It would receive the audio and choose the text
  // Voxtype types, so this is checked before anything talks to it.
  readonly property string probe: "systemctl --user cat amd-npu.service >/dev/null 2>&1 || { " + quote(cli) + " setup-state; exit; }; " +
    "awk -v u=\"$(id -u)\" 'FNR > 1 && $4 == \"0A\" && $8 != u && $2 ~ /^(0100007F|00000000|00000000000000000000000000000000|00000000000000000000000001000000|0000000000000000FFFF00000100007F):CD91$/ { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null && { echo foreign; exit; }; " +
    "if systemctl --user is-active --quiet amd-npu.service && " +
    "[ \"$(curl -s --noproxy '*' -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:52625/api/version)\" = 200 ]; " +
    "then echo ready; else echo stopped; fi"

  // The bar API handed to third-party plugins has run() but not shellQuote(),
  // so quote locally.
  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function gb(mb) {
    return (Number(mb || 0) / 1024).toFixed(1) + " GB"
  }

  function refresh() {
    if (!probeProc.running) probeProc.running = true
    if (opened && !setupMode && !infoProc.running) infoProc.running = true
  }

  // Refresh every copy of the widget (one per monitor), as BarWidget.broadcast does.
  function refreshAll() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i].refresh === "function") items[i].refresh()
    }
  }

  function runAction(kind, args) {
    if (busy !== "") return
    busy = kind
    actionError = ""
    npuTest = ""
    llmTest = ""
    actionProc.command = [cli].concat(args)
    actionProc.running = true
  }

  function toggleDictation() {
    if (exclusive && llm) runAction("share", ["load", llm.name, "--share"])
    // Clicking the switch is the consent for enable's Voxtype change; disable puts Voxtype's own values back.
    else runAction("switch", onNpu ? ["disable"] : ["enable", "--yes"])
  }

  function requestLoad() {
    if (selectedModel === "") return
    if (loadExclusive && !confirming) {
      confirming = true
      return
    }
    confirming = false
    runAction("load", loadExclusive ? ["load", selectedModel, "--exclusive", "--yes"] : ["load", selectedModel])
  }

  function testNpu() {
    if (testingNpu) return
    testingNpu = true
    npuTest = ""
    pingProc.running = true
  }

  function testLlm() {
    if (testingLlm) return
    testingLlm = true
    llmTest = ""
    benchProc.running = true
  }

  function openFullStatus() {
    if (!bar) return
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation " + quote(quote(cli)) + " status")
  }

  // A plain floating terminal: the presentation wrapper's logo and "press any key" don't suit a chat.
  function openChat() {
    if (!bar || busy !== "") return
    close()
    bar.run("setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title=" + quote("AMD NPU chat") + " -e " + quote(cli) + " chat")
  }

  // Setup runs in a terminal: it asks for sudo, and install ends with a reboot.
  function openSetup(command) {
    if (!bar) return
    close()
    // The helper runs its arguments through `bash -c` again, so the path is quoted twice.
    bar.run("omarchy-launch-floating-terminal-with-presentation " + quote(quote(cli)) + " " + command)
  }

  function statusCaption() {
    if (status === "foreign") return "PORT TAKEN"
    if (status === "driver") return "DRIVER MISSING"
    if (status === "install") return "NOT SET UP"
    if (status === "reboot") return "RESTART NEEDED"
    if (status === "enable") return "ONE STEP LEFT"
    if (busy === "load") return "LOADING MODEL..."
    if (busy === "unload") return "UNLOADING..."
    if (busy === "share" || busy === "switch") return "SWITCHING..."
    if (status !== "ready") return "STOPPED"
    if (exclusive) return "LLM ONLY"
    if (llm && info.backend === "remote") return "READY + LLM"
    if (info.backend === "remote") return "READY"
    return "LOCAL MODEL"
  }

  function setupText() {
    if (status === "driver") return "This machine has an AMD XDNA2 NPU, but its driver (amdxdna, in Linux 6.14 and later) isn't loaded."
    if (status === "install") return "Run Whisper dictation and small local models on the NPU. Setup installs xrt, xrt-plugin-amdxdna and fastflowlm and raises the locked-memory limit (it asks for your password), then needs a restart."
    if (status === "reboot") return "Installed. Restart the computer to apply the locked-memory limit, then finish setup here."
    if (status === "enable") return "Last step: download Whisper, start the NPU server and point Voxtype at it (it asks before changing Voxtype's settings)."
    if (status === "foreign") return "Another account on this computer is using port 52625. Don't dictate until it's gone: it would receive your audio and choose the text that gets typed. Restarting the NPU server (Details) takes the port back once it's free."
    return ""
  }

  function dictationSubtitle() {
    if (actionError !== "") return actionError
    if (exclusive) return "Off: the LLM has the NPU, dictation uses the CPU"
    if (onNpu && llm) return "On the NPU; waits while the LLM is answering"
    if (onNpu) return "Voxtype sends audio to the NPU"
    return "Off: Voxtype uses its local model, NPU free"
  }

  function backendText() {
    if (info.backend === "remote") return "NPU"
    if (info.backend === "-" || info.backend === undefined) return "not set up"
    return "CPU model"
  }

  function micLabel(node) {
    if (!node) return ""
    var label = String(node.nickname || node.description || node.name || "").trim()
      .replace(/\s+(Input|Mono)$/i, "").replace(/\bMicrophones\b/g, "Microphone")
    // The laptop's own mic is named after its audio chip ("ALC294 Analog"),
    // which doesn't say "built-in". Internal inputs sit on the PCI bus.
    if (String(node.name || "").indexOf("alsa_input.pci-") === 0) return "Built-in mic (" + label + ")"
    return label
  }

  function refreshMicInputs() {
    if (recording || recState === "transcribing") return
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || n.name === "quickshell") continue
      if (n.audio || String(n.type || "").indexOf("Source") >= 0) list.push(n)
    }
    micInputs = list
  }

  // Same as Omarchy's audio panel: Voxtype follows the default at the next recording.
  function setMic(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-input-set-default", String(node.id), String(node.name)])
  }

  function setSilenceWarn(seconds) {
    silenceWarnSec = seconds
    saveCardProc.command = ["sh", "-c", "mkdir -p \"$1\" && printf '%s\\n' \"$2\" > \"$1/card.json\"",
      "sh", cardConfigDir, JSON.stringify({ silenceWarnSec: seconds })]
    saveCardProc.running = true
  }

  function mmss(seconds) {
    var s = Math.max(0, Math.floor(seconds))
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
  }

  // Reads what the card needs from Voxtype's config.toml: the recording limit
  // ([audio] max_duration_secs) and where its waveform sits ([osd]).
  function parseVoxtypeConfig(text) {
    var section = "", values = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\s+#.*$/, "").trim()
      var header = /^\[([^\]]+)\]$/.exec(line)
      if (header) { section = header[1].trim(); continue }
      var pair = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line)
      if (pair) values[section + "." + pair[1]] = pair[2].trim().replace(/^"(.*)"$/, "$1")
    }
    function num(key, fallback) {
      var n = parseFloat(values[key])
      return isNaN(n) ? fallback : n
    }
    recLimit = Math.round(num("audio.max_duration_secs", 60))
    voxOsdEnabled = values["osd.enabled"] !== "false"
    voxOsdPosition = values["osd.position"] || "bottom-center"
    voxOsdTopMargin = num("osd.top_margin", 0.85)
    voxOsdHeight = Math.round(num("osd.height_px", 48))
    voxOsdMargin = Math.round(num("osd.margin_px", 24))
    voxDevice = values["audio.device"] || "default"
  }

  function onVoxtypeState(raw) {
    var data
    try { data = JSON.parse(String(raw)) } catch (e) { return }
    var state = String(data.alt || data["class"] || "idle")
    if (state === recState) return
    recState = state
    if (state === "recording") {
      recStartMs = Date.now()
      micSilent = false
      peakArmTimer.restart()
      recRemaining = -1
      tickCountdown()
    }
  }

  function tickCountdown() {
    var left = Math.max(0, recLimit - Math.floor((Date.now() - recStartMs) / 1000))
    if (left !== recRemaining) recRemaining = left
    var since = Math.max(recStartMs, micSinceMs, lastSoundMs)
    micSilent = peakWatching && Date.now() - since >= silenceWarnSec * 1000
  }

  IpcHandler {
    target: "alanroman117.amd-npu"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function chat(): void { root.openChat() }
  }

  onOpenedChanged: {
    if (opened) {
      npuTest = ""
      llmTest = ""
      actionError = ""
      confirming = false
      refresh()
    }
  }

  onDownloadedChanged: {
    var names = downloaded.map(function(m) { return m.name })
    if (names.indexOf(selectedModel) < 0) selectedModel = names.length > 0 ? names[0] : ""
  }

  visible: status !== "unsupported"
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: probeProc
    command: ["bash", "-c", root.probe]
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line).trim()
        if (value !== "") root.status = value
      }
    }
  }

  Process {
    id: infoProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(String(text || "{}")) } catch (e) { }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.busy = ""
      if (exitCode !== 0) {
        var lines = String(actionErr.text || "").trim().split("\n")
        root.actionError = (lines[lines.length - 1] || "Failed").replace(/\u001b\[[0-9;]*m/g, "").replace(/^Error:\s*/, "")
      }
      root.refreshAll()
    }
  }

  Process {
    id: pingProc
    command: [root.cli, "ping"]
    stdout: StdioCollector {
      id: pingOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.testingNpu = false
      var parts = String(pingOut.text || "").trim().split(" ")
      if (parts[0] === "ok") root.npuTest = "Whisper OK in " + parseFloat(parts[1]).toFixed(2) + " s"
      else if (parts[1] === "no-whisper") root.npuTest = "Whisper is off while the LLM has the NPU"
      else root.npuTest = "Whisper test failed" + (parts[1] ? " (" + parts[1] + ")" : "")
    }
  }

  Process {
    id: benchProc
    command: [root.cli, "bench-llm", "--raw"]
    stdout: StdioCollector {
      id: benchOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.testingLlm = false
      var parts = String(benchOut.text || "").trim().split(" ")
      root.llmTest = parts[0] === "ok"
        ? "Generation " + parseFloat(parts[2]).toFixed(1) + " tok/s (" + parts[3] + " tokens)"
        : "LLM test failed"
    }
  }

  // Voxtype's live state, as Omarchy's own Dictation indicator reads it. The
  // follower dies with the shell (pdeathsig) and is restarted if Voxtype restarts.
  Process {
    id: voxtypeStatus
    command: ["setpriv", "--pdeathsig", "TERM", "voxtype", "status", "--follow", "--format", "json"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.onVoxtypeState(line) }
    }
    onExited: {
      root.onVoxtypeState('{"alt": "idle"}')
      voxtypeRetry.restart()
    }
  }

  Timer {
    id: voxtypeRetry
    interval: 10000
    onTriggered: voxtypeStatus.running = true
  }

  Timer {
    interval: 250
    running: root.recording
    repeat: true
    onTriggered: root.tickCountdown()
  }

  FileView {
    path: root.configHome + "/voxtype/config.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseVoxtypeConfig(text())
    onLoadFailed: root.parseVoxtypeConfig("")
  }

  PwObjectTracker { objects: root.micSource ? [root.micSource] : [] }

  // Starts half a second into a recording, so it doesn't open its stream on
  // the mic at the same moment as Voxtype's.
  Timer {
    id: peakArmTimer
    interval: 500
    onTriggered: root.peakArmed = root.recording
  }

  onRecordingChanged: if (!recording) { peakArmed = false; micSilent = false }

  PwNodePeakMonitor {
    node: root.peakWatching ? root.micSource : null
    enabled: root.peakWatching
    // Speech is well above 0.02; a silent or still-connecting mic stays below.
    onPeakChanged: if (peak > 0.02) root.lastSoundMs = Date.now()
  }

  FileView {
    path: root.cardConfigDir + "/card.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var v = JSON.parse(text()).silenceWarnSec
        if (typeof v === "number" && v >= 0) root.silenceWarnSec = Math.round(v)
      } catch (e) { }
    }
  }

  Process { id: saveCardProc }

  Timer {
    interval: 2000
    running: root.opened && !root.setupMode
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshMicInputs()
  }

  CountdownOverlay {
    targetScreen: root.barScreen
    // Live: if the mic is unplugged mid-recording, PipeWire moves the stream to
    // the new default, and this follows (as Omarchy's own mic indicator does).
    mic: root.micName ? root.micName + (root.micMuted ? " (muted)" : (root.micSilent ? " - no sound" : "")) : "No microphone"
    micAlert: root.micMuted || root.micSilent || !root.micName
    showing: (root.recording || root.recState === "transcribing") && root.onFocusedMonitor
    transcribing: root.recState === "transcribing"
    remaining: Math.max(0, root.recRemaining)
    limit: root.recLimit
    warn: root.recWarn
    label: root.recState === "transcribing" ? "Transcribing..."
      : root.mmss(Math.max(0, root.recRemaining)) + (root.recWarn ? " left - finishing soon" : " left")
    voxEnabled: root.voxOsdEnabled
    voxPosition: root.voxOsdPosition
    voxTopMargin: root.voxOsdTopMargin
    voxHeight: root.voxOsdHeight
    voxMargin: root.voxOsdMargin
  }

  // Bar icon: poll at the configured interval. Card details: every 5 s while open.
  Timer {
    interval: Math.max(5, root.setting("refreshIntervalSec", 15)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.recording ? root.mmss(root.recRemaining) : "\udb81\ude1a"
    slotSize: root.recording && !vertical ? Style.bar.iconSlot * 2.2 : Style.bar.iconSlot
    fontSize: root.recording ? Style.font.caption : Style.bar.iconFont
    active: root.recWarn
    dimmed: root.status !== "ready" && !root.recording
    tooltipText: root.opened || root.recording ? "" : (root.status === "ready"
      ? (root.llm ? "AMD NPU: dictation + " + root.llm.name : "AMD NPU: dictation ready")
      : (root.setupMode ? "AMD NPU: not set up yet" : "AMD NPU server stopped"))
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: chip, title/status, last dictation time ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroValue.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "\udb81\ude1a"
            color: root.bar.foreground
            opacity: root.status === "ready" ? 1 : 0.45
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroValue.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "AMD NPU"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusCaption()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Column {
            id: heroValue
            visible: !root.setupMode
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: root.info.last ? root.info.last.replace("s", " s") : "-"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              text: "LAST DICTATION"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Setup (before amd-npu.service exists) ----------
        Column {
          visible: root.setupMode
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: root.setupText()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Row {
            id: setupRow
            visible: root.status !== "reboot"
            readonly property string primary: root.status === "install" ? "install" : (root.status === "enable" ? "enable" : (root.status === "foreign" ? "status" : "check"))
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: setupRow.cellWidth
              iconText: root.status === "driver" || root.status === "foreign" ? "\uf120" : "\uf019"
              text: root.status === "install" ? "Set up" : (root.status === "enable" ? "Finish setup" : "Details")
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.openSetup(setupRow.primary)
            }

            Button {
              width: setupRow.cellWidth
              iconText: "\uf120"
              text: "Check"
              visible: root.status !== "driver" && root.status !== "foreign"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.openSetup("check")
            }
          }
        }

        // ---------- Dictation on/off ----------
        Item {
          visible: !root.setupMode
          width: parent.width
          implicitHeight: Math.max(toggleLabels.implicitHeight, npuSwitch.implicitHeight)

          Column {
            id: toggleLabels
            anchors.left: parent.left
            anchors.right: npuSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Dictate on the NPU"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: root.dictationSubtitle()
              color: root.actionError !== "" ? Color.urgent : root.bar.foreground
              opacity: root.actionError !== "" ? 1 : 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          ToggleSwitch {
            id: npuSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.onNpu
            busy: root.busy === "switch" || root.busy === "share"
            foreground: root.bar.foreground
            onToggled: root.toggleDictation()
          }
        }

        PanelSeparator { visible: !root.setupMode; foreground: root.bar.foreground }

        // ---------- Local model ----------
        Column {
          visible: !root.setupMode
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "LOCAL MODEL"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // Loaded: details and actions
          Column {
            visible: !!root.llm
            width: parent.width
            spacing: Style.space(8)

            InfoPair { label: "Model"; value: root.llm ? root.llm.name : "" }
            InfoPair { label: "Size"; value: root.llm ? root.llm.params + " " + root.llm.quant : "" }
            InfoPair { label: "Mode"; value: root.exclusive ? "NPU only (dictation on CPU)" : "Shared with Whisper" }
            InfoPair { label: "Memory"; value: root.gb(root.info.npuMb) + " NPU + " + root.gb(root.info.rssMb) }
            InfoPair { label: "API"; value: "127.0.0.1:52625/v1" }

            Row {
              id: llmActions
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - 2 * spacing) / 3

              Button {
                width: llmActions.cellWidth
                iconText: "\uf04b"
                text: root.testingLlm ? "Testing..." : "Test LLM"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.testLlm()
              }

              Button {
                width: llmActions.cellWidth
                iconText: "\uf086"
                text: "Chat"
                tooltipText: "Chat with the model in a terminal"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.openChat()
              }

              Button {
                width: llmActions.cellWidth
                iconText: "\uf00d"
                text: root.busy === "unload" ? "Unloading..." : "Unload"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.runAction("unload", ["unload"])
              }
            }

            Text {
              visible: root.llmTest !== ""
              textFormat: Text.PlainText
              text: root.llmTest
              color: root.bar.foreground
              opacity: 0.8
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // Not loaded, nothing downloaded
          Text {
            visible: !root.llm && root.downloaded.length === 0
            textFormat: Text.PlainText
            text: "No models downloaded yet. In a terminal: amd-npu models, then amd-npu pull qwen3.5:4b"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            wrapMode: Text.WordWrap
          }

          // Not loaded: pick a downloaded model, a mode, then load
          Column {
            visible: !root.llm && root.downloaded.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.downloaded
              Button {
                required property var modelData
                width: parent.width
                leftAlign: true
                text: modelData.name + "   " + modelData.params + ", ~" + modelData.footprint + " GB"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.selectedModel === modelData.name
                onClicked: {
                  root.selectedModel = modelData.name
                  root.confirming = false
                }
              }
            }

            Row {
              id: modeRow
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              Button {
                width: modeRow.cellWidth
                text: "Share with Whisper"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: !root.loadExclusive
                onClicked: { root.loadExclusive = false; root.confirming = false }
              }

              Button {
                width: modeRow.cellWidth
                text: "NPU only"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.loadExclusive
                onClicked: { root.loadExclusive = true; root.confirming = false }
              }
            }

            Text {
              visible: root.confirming
              textFormat: Text.PlainText
              text: "Dictation will use the CPU model (lower accuracy) until you unload " + root.selectedModel + "."
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }

            Row {
              id: loadRow
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              Button {
                visible: root.confirming
                width: loadRow.cellWidth
                text: "Cancel"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.confirming = false
              }

              Button {
                width: root.confirming ? loadRow.cellWidth : loadRow.width
                iconText: "\uf019"
                text: root.busy === "load" ? "Loading..." : (root.confirming ? "Load anyway" : "Load " + root.selectedModel)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.requestLoad()
              }
            }
          }
        }

        PanelSeparator { visible: !root.setupMode; foreground: root.bar.foreground }

        // ---------- Details ----------
        Column {
          visible: !root.setupMode
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "DICTATION"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          InfoPair { label: "Whisper"; value: (root.info.modelName || "whisper-v3:turbo") + (root.info.model === false ? " (not downloaded)" : "") }
          InfoPair { label: "NPU firmware"; value: root.info.firmware || "-" }
          InfoPair { label: "Voxtype uses"; value: root.backendText() }

          Row {
            id: micRow
            width: parent.width
            spacing: Style.space(8)

            InfoLabel { id: micLabelText; text: "Microphone" }
            Item { width: Math.max(0, micRow.width - micLabelText.implicitWidth - micValue.width - micRow.spacing * 2); height: 1 }
            InfoValue {
              id: micValue
              width: Math.min(implicitWidth, micRow.width - micLabelText.implicitWidth - micRow.spacing * 2)
              elide: Text.ElideRight
              text: (root.micName || "none") + (root.micLocked ? " (Voxtype config)" : (root.micMuted ? " (muted)" : ""))
              color: root.micMuted || !root.micName ? Color.urgent : root.bar.foreground
            }
          }

          // Pick the input (changes the system default, like Omarchy's audio panel)
          Column {
            visible: !root.micLocked && root.micInputs.length > 1
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.micInputs
              Button {
                required property var modelData
                width: parent.width
                leftAlign: true
                text: root.micLabel(modelData)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: !!root.micSource && modelData.id === root.micSource.id
                onClicked: root.setMic(modelData)
              }
            }

            InfoLabel {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Sets the system's default input for all apps, as Omarchy's audio panel does."
            }
          }

          // When the countdown says a mic isn't hearing anything
          Row {
            id: silenceRow
            visible: !root.micLocked
            width: parent.width
            spacing: Style.space(6)
            readonly property real labelWidth: silenceLabel.implicitWidth + Style.space(4)
            readonly property real cellWidth: (width - labelWidth - spacing * 4) / 4

            InfoLabel {
              id: silenceLabel
              width: silenceRow.labelWidth
              anchors.verticalCenter: parent.verticalCenter
              text: "Warn on silence"
            }

            Repeater {
              model: [0, 3, 5, 10]
              Button {
                required property var modelData
                width: silenceRow.cellWidth
                text: modelData === 0 ? "Off" : modelData + " s"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.silenceWarnSec === modelData
                onClicked: root.setSilenceWarn(modelData)
              }
            }
          }
        }

        // ---------- Actions ----------
        Column {
          visible: !root.setupMode
          width: parent.width
          spacing: Style.space(8)

          // The plugin was updated but the running proxy/service files are older: enable applies them.
          Button {
            visible: !!root.info.stale
            width: parent.width
            iconText: "\uf019"
            text: "Apply plugin update"
            tooltipText: "Installs the updated proxy and service files (amd-npu enable)"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.openSetup("enable")
          }

          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: actionRow.cellWidth
              iconText: "\uf130"
              text: root.testingNpu ? "Testing..." : "Test dictation"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.testNpu()
            }

            Button {
              width: actionRow.cellWidth
              iconText: "\uf120"
              text: "Full status"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.openFullStatus()
            }
          }

          Text {
            visible: root.npuTest !== ""
            textFormat: Text.PlainText
            text: root.npuTest
            color: root.npuTest.indexOf("OK") >= 0 ? root.bar.foreground : Color.urgent
            opacity: 0.8
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
