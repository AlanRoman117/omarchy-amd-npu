import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Shows whether the NPU Whisper server behind Voxtype dictation is up.
// Recording/transcribing state is already covered by Omarchy's built-in
// Dictation indicator, so this widget only reports the NPU backend.
BarWidget {
  id: root
  moduleName: "alanroman117.npu-dictation"

  // "ready" (service active and answering), "stopped", or "absent" (not set up)
  property string status: "absent"

  readonly property string cli: Qt.resolvedUrl("bin/npu-dictation").toString().replace("file://", "")
  readonly property string probe: "systemctl --user cat flm-asr.service >/dev/null 2>&1 || { echo absent; exit; }; " +
    "if systemctl --user is-active --quiet flm-asr.service && " +
    "[ \"$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:52625/)\" != 000 ]; " +
    "then echo ready; else echo stopped; fi"

  function refresh() {
    if (!probeProc.running) probeProc.running = true
  }

  // The bar API handed to third-party plugins has run() but not shellQuote(),
  // so quote locally.
  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function activate() {
    if (!root.bar) return
    if (status === "stopped") {
      root.bar.run("systemctl --user start flm-asr.service")
      restartCheck.restart()
    } else {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + quote(cli) + " status")
    }
  }

  visible: status !== "absent"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "alanroman117.npu-dictation"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

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

  Timer {
    interval: Math.max(5, root.setting("refreshIntervalSec", 15)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Re-check a few seconds after a click-to-start, once the server is listening.
  Timer {
    id: restartCheck
    interval: 4000
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb81\ude1a"
    dimmed: root.status === "stopped"
    tooltipText: root.status === "ready"
      ? "NPU dictation ready (Whisper on the NPU)"
      : "NPU Whisper server stopped - click to start"
    onPressed: root.activate()
  }
}
