import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The dictation countdown: a card in the style of Omarchy's OSD, placed just
// above Voxtype's waveform (or below it when there's no room above) so the two
// never overlap and nobody has to move either one.
//
// Voxtype puts its waveform at y = clamp(H * top_margin, margin, H - height -
// margin), centred, for bottom-center and top-center (measured with
// `hyprctl layers -j`: 0.78 on a 1000 px high screen gives y 780). In a corner,
// or when its overlay is off, the card takes Omarchy's usual OSD spot.
Item {
  id: root

  property var targetScreen: null
  property bool showing: false
  property bool transcribing: false
  property int remaining: 0
  property int limit: 60
  property bool warn: false
  property string label: ""
  // The microphone being recorded, shown under the timer.
  property string mic: ""
  readonly property bool showMic: mic !== "" && !transcribing

  // Voxtype's [osd] settings (defaults as in voxtype 1.1).
  property bool voxEnabled: true
  property string voxPosition: "bottom-center"
  property real voxTopMargin: 0.85
  property int voxHeight: 48
  property int voxMargin: 24

  readonly property int pad: Style.space(16)
  readonly property int gap: Style.space(16)
  readonly property int barWidth: Style.space(142)
  readonly property int clearance: Style.space(8)
  readonly property bool voxCentred: voxEnabled && voxPosition.indexOf("left") < 0 && voxPosition.indexOf("right") < 0

  function cardY(screenHeight, cardHeight) {
    if (!voxCentred) return screenHeight - Style.space(67) - cardHeight
    var waveTop = Math.max(voxMargin, Math.min(screenHeight - voxHeight - voxMargin, screenHeight * voxTopMargin))
    var above = waveTop - clearance - cardHeight
    return above >= Style.space(40) ? above : waveTop + voxHeight + clearance
  }

  TextMetrics {
    id: labelMetrics
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
    text: root.label
  }

  TextMetrics {
    id: iconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    text: "\udb80\udf6c"
  }

  PanelWindow {
    id: win
    screen: root.targetScreen
    visible: root.showing
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "amd-npu-countdown"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Visual only: an empty input region keeps clicks going to the desktop.
    mask: Region {}

    BorderSurface {
      id: card
      // Widens for a long mic name, up to a cap; beyond that the name elides.
      readonly property real innerWidth: Math.max(content.implicitWidth,
        root.showMic ? Math.min(micText.implicitWidth, Style.space(360)) : 0)
      width: card.borderLeft + root.pad + innerWidth + root.pad + card.borderRight
      height: card.borderTop + root.pad + Style.font.displayLarge
        + (root.showMic ? Style.space(4) + micText.implicitHeight : 0) + root.pad + card.borderBottom
      x: Math.round((win.width - width) / 2)
      y: Math.round(root.cardY(win.height, height))
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Row {
        id: content
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        height: Style.font.displayLarge
        spacing: root.transcribing ? Math.round(root.gap * 2 / 3) : root.gap

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: iconMetrics.text
          font: iconMetrics.font
          color: Color.popups.text
        }

        Rectangle {
          visible: !root.transcribing
          width: root.barWidth
          height: Math.max(Style.space(6), Style.spacing.sm)
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Color.popups.text, 0.45)

          Rectangle {
            height: parent.height
            width: parent.width * (root.limit > 0 ? Math.max(0, Math.min(1, root.remaining / root.limit)) : 0)
            color: root.warn ? Color.urgent : Color.accent

            Behavior on width {
              enabled: root.showing
              NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: Math.ceil(labelMetrics.advanceWidth)
          anchors.verticalCenter: parent.verticalCenter
          text: root.label
          font: labelMetrics.font
          color: root.warn ? Color.urgent : Color.popups.text
        }
      }

      Text {
        id: micText
        visible: root.showMic
        textFormat: Text.PlainText
        x: content.x
        y: content.y + content.height + Style.space(4)
        width: card.innerWidth
        elide: Text.ElideRight
        text: root.mic
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: root.mic.indexOf("(muted)") >= 0 ? Color.urgent : Util.alpha(Color.popups.text, 0.7)
      }
    }
  }
}
