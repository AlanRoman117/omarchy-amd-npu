import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// NPU dictation: bar icon plus a popup card in the style of Omarchy's own
// panels (power, network, bluetooth). The card shows whether Voxtype
// dictation runs on the NPU Whisper server, lets you switch it on or off, and
// runs a live test. Recording/transcribing state stays with Omarchy's
// built-in Dictation indicator.
Panel {
  id: root
  moduleName: "alanroman117.npu-dictation"
  ipcTarget: "alanroman117.npu-dictation"
  // Own the IPC target so it can also carry refresh().
  manageIpc: false

  // Bar icon state: "ready" (service active and answering), "stopped", or
  // "absent" (not set up, widget hidden).
  property string status: "absent"
  // Popup details, from `npu-dictation status --json`.
  property var info: ({})
  property bool switching: false
  property bool testing: false
  property string testResult: ""
  property string actionError: ""

  readonly property string cli: Qt.resolvedUrl("bin/npu-dictation").toString().replace("file://", "")
  readonly property bool onNpu: info.backend === "remote" && info.service === "active"
  readonly property string probe: "systemctl --user cat flm-asr.service >/dev/null 2>&1 || { echo absent; exit; }; " +
    "if systemctl --user is-active --quiet flm-asr.service && " +
    "[ \"$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:52625/)\" != 000 ]; " +
    "then echo ready; else echo stopped; fi"

  // The bar API handed to third-party plugins has run() but not shellQuote(),
  // so quote locally.
  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function refresh() {
    if (!probeProc.running) probeProc.running = true
    if (opened && !infoProc.running) infoProc.running = true
  }

  // Refresh every copy of the widget (one per monitor), as BarWidget.broadcast does.
  function refreshAll() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i].refresh === "function") items[i].refresh()
    }
  }

  function setNpu(on) {
    if (switching) return
    switching = true
    actionError = ""
    testResult = ""
    switchProc.command = [cli, on ? "enable" : "disable"]
    switchProc.running = true
  }

  function runTest() {
    if (testing) return
    testing = true
    testResult = ""
    testProc.running = true
  }

  function openFullStatus() {
    if (!bar) return
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation " + quote(cli) + " status")
  }

  function statusCaption() {
    if (switching) return onNpu ? "SWITCHING OFF..." : "STARTING ON THE NPU..."
    if (status === "ready" && info.backend === "remote") return "READY - WHISPER ON THE NPU"
    if (status === "ready") return "SERVER UP - VOXTYPE ON LOCAL MODEL"
    return "STOPPED"
  }

  function backendText() {
    if (info.backend === "remote") return "NPU"
    if (info.backend === "-" || info.backend === undefined) return "not set up"
    return "local model"
  }

  IpcHandler {
    target: "alanroman117.npu-dictation"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
  }

  onOpenedChanged: {
    if (opened) {
      testResult = ""
      actionError = ""
      refresh()
    }
  }

  visible: status !== "absent"
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
    id: switchProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: switchErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.switching = false
      if (exitCode !== 0) {
        var lines = String(switchErr.text || "").trim().split("\n")
        root.actionError = (lines[lines.length - 1] || "Failed").replace(/\u001b\[[0-9;]*m/g, "").replace(/^Error:\s*/, "")
      }
      root.refreshAll()
    }
  }

  Process {
    id: testProc
    command: [root.cli, "ping"]
    stdout: StdioCollector {
      id: testOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.testing = false
      var parts = String(testOut.text || "").trim().split(" ")
      root.testResult = parts[0] === "ok"
        ? "Transcription OK in " + parseFloat(parts[1]).toFixed(2) + " s"
        : "Test failed" + (parts[1] ? " (HTTP " + parts[1] + ")" : "")
    }
  }

  // Bar icon: poll at the configured interval. Popup details: every 5 s while open.
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
    text: "\udb81\ude1a"
    dimmed: root.status === "stopped"
    tooltipText: root.opened ? "" : (root.status === "ready" ? "NPU dictation ready" : "NPU Whisper server stopped")
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
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
              text: "NPU Dictation"
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

        // ---------- On/off ----------
        Item {
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
              text: root.actionError !== ""
                ? root.actionError
                : (root.onNpu ? "Voxtype sends audio to the NPU" : "Off: Voxtype uses its local model, NPU free")
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
            busy: root.switching
            foreground: root.bar.foreground
            onToggled: root.setNpu(!root.onNpu)
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Details ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "DETAILS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          InfoPair { label: "Model"; value: (root.info.modelName || "whisper-v3:turbo") + (root.info.model === false ? " (not downloaded)" : "") }
          InfoPair { label: "NPU firmware"; value: root.info.firmware || "-" }
          InfoPair { label: "Server"; value: root.info.server ? "up on 127.0.0.1:52625" : "not running" }
          InfoPair { label: "Voxtype"; value: root.backendText() }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Actions ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: actionRow.cellWidth
              iconText: root.testing ? "\uf021" : "\uf04b"
              iconSpinning: root.testing
              text: root.testing ? "Testing..." : "Test NPU"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.runTest()
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
            visible: root.testResult !== ""
            textFormat: Text.PlainText
            text: root.testResult
            color: root.testResult.indexOf("OK") >= 0 ? root.bar.foreground : Color.urgent
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
