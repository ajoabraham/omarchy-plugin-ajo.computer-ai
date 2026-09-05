import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The Computer voice assistant's face: an icon in the status bar with a popup
// that drops down beneath it (like bluetooth/audio).
//
// This file is a VIEW, not the assistant. A bar surface exists per monitor, so
// the shell builds one of these per screen; the turn itself — the pipeline,
// the activity log, the pending grant, the IPC target — lives in Service.qml,
// which the shell loads exactly once (manifest kinds: service + bar-widget).
// Every screen's icon and orb therefore show the same running turn, and the
// panel opened on the big screen is the panel that was hidden on the laptop.
//
// Its centerpiece is an orb of radial bars driven by real audio levels: live
// mic RMS while listening and the reply audio's RMS timeline while speaking.
// While the agent works the bars retract and the gyre takes over — sweeping
// arcs, an elapsed clock, and the newest step the agent took — because a turn
// can run for minutes and a still orb reads as a hang.
//
// Closing the popup (Esc or clicking away) only HIDES it: the turn keeps
// running and keeps speaking, and every bar icon shows that it is still
// working. To stop the current turn, open the popup and press Enter.
//
// Summoned by hotkey via `omarchy-shell ajo.computer-ai summon '{"listen":
// true}'`, which the service routes to the focused screen's copy of this view.
Panel {
  id: root
  moduleName: "ajo.computer-ai"
  // Both IPC handlers are left to the service: the base Panel's would claim
  // (and shadow) the target, and a handler declared here would be registered
  // once per monitor — Quickshell routes a target to exactly one of them and
  // silently drops the rest.
  manageIpc: false

  // The bar allocates a slot the size of the icon button.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The one assistant, shared by every bar surface. Null until the host
  // injects `bar` (it does so just after this component loads).
  readonly property var svc: bar?.shell?.firstPartyServiceFor("ajo.computer-ai") || null

  // --- the service's state, mirrored ---------------------------------------
  //
  // Read-only aliases so the UI below reads the same as it always did, and so
  // a missing service degrades to a quiet idle icon rather than a wall of
  // binding errors.

  readonly property string phase: svc ? svc.phase : "idle"
  readonly property bool busy: svc ? svc.busy : false
  readonly property string transcript: svc ? svc.transcript : ""
  readonly property string response: svc ? svc.response : ""
  readonly property string error: svc ? svc.error : ""
  readonly property string statusLine: svc ? svc.statusLine : "Assistant service unavailable"
  readonly property string agentLabel: svc ? svc.agentLabel : "The assistant"
  readonly property var pendingGrant: svc ? svc.pendingGrant : null
  readonly property var pendingConfirm: svc ? svc.pendingConfirm : null
  readonly property bool typing: svc ? svc.typing : false
  readonly property bool toneEnabled: svc ? svc.toneEnabled : true
  readonly property bool voiceApproval: svc ? svc.voiceApproval : true

  readonly property var voiceOptions: svc ? svc.voiceOptions : []
  readonly property var agentOptions: svc ? svc.agentOptions : []
  readonly property var modelOptions: svc ? svc.modelOptions : []
  readonly property string voice: svc ? svc.voice : ""
  readonly property string agent: svc ? svc.agent : ""
  readonly property string model: svc ? svc.model : ""

  readonly property var lastActivity: svc ? svc.lastActivity : null
  readonly property var statChips: svc ? svc.statChips : []
  readonly property int turnCtx: svc ? svc.turnCtx : 0
  readonly property var activityModel: svc ? svc.activityModel : null
  readonly property int activityCount: activityModel ? activityModel.count : 0

  // Animation phases live in the service too, so every screen draws the same
  // frame of the same orb and the thinking pulse keeps breathing with no
  // panel open at all.
  readonly property real displayLevel: svc ? svc.displayLevel : 0
  readonly property real animPhase: svc ? svc.animPhase : 0
  readonly property real barPhase: svc ? svc.barPhase : 0
  readonly property string idleVariant: svc ? svc.idleVariant : "cocoon"

  readonly property var micWave: svc ? svc.micWave : []
  readonly property bool captureTooQuiet: svc ? svc.captureTooQuiet : false
  readonly property bool showMicWave: svc ? svc.showMicWave : false
  readonly property bool micDebug: svc ? svc.micDebug : false
  readonly property bool playingCapture: svc ? svc.playingCapture : false
  readonly property real playProgress: svc ? svc.playProgress : 0
  readonly property bool awaitingDecision: svc ? svc.awaitingDecision : false
  readonly property real confirmProgress: svc ? svc.confirmProgress : -1

  readonly property var speechLevels: svc ? svc.speechLevels : []
  readonly property int speechIndex: svc ? svc.speechIndex : -1
  readonly property real chunkFracStart: svc ? svc.chunkFracStart : 0
  readonly property real chunkFracEnd: svc ? svc.chunkFracEnd : 1

  // StyledText needs entities escaped, and a reply is arbitrary text.
  function escapeMarkup(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  // Rich text takes a solid colour — "#aarrggbb" is not a colour Qt parses
  // here — so the fade is mixed against the card's own background rather
  // than expressed as transparency.
  function tint(text, alpha) {
    if (text === "") return ""
    var fg = Color.popups.text
    var bg = Color.popups.background
    function channel(f, b) {
      var v = Math.round(255 * (f * alpha + b * (1 - alpha)))
      v = Math.max(0, Math.min(255, v))
      return (v < 16 ? "0" : "") + v.toString(16)
    }
    var hex = "#" + channel(fg.r, bg.r) + channel(fg.g, bg.g) + channel(fg.b, bg.b)
    return "<font color=\"" + hex + "\">" + escapeMarkup(text) + "</font>"
  }

  // The reply, lit by where the voice has got to. Plain text at every other
  // moment — there is nothing to track when nothing is being said.
  readonly property string responseMarkup: {
    if (phase !== "speaking" || response === "") return response
    var len = response.length
    var from = Math.max(0, Math.min(len, Math.round(chunkFracStart * len)))
    var to = Math.max(from, Math.min(len, Math.round(chunkFracEnd * len)))
    return tint(response.slice(0, from), 0.38)
      + tint(response.slice(from, to), 1.0)
      + tint(response.slice(to), 0.62)
  }

  function elapsedLabel() { return svc ? svc.elapsedLabel() : "0:00" }
  function fmtTokens(n) { return svc ? svc.fmtTokens(n) : String(Number(n) || 0) }

  // --- per-view UI state ----------------------------------------------------
  //
  // Which drawers this screen's popup has open is a property of the popup,
  // not of the conversation, so it stays here.

  property bool settingsOpen: false
  // Ctrl+I opens the activity drawer.
  property bool activityOpen: false

  // The orb's rust ramp, shared by the bars, the swarm and the gyre.
  readonly property color rust: Qt.rgba(183 / 255, 65 / 255, 14 / 255, 1)
  readonly property color ember: Qt.rgba(245 / 255, 177 / 255, 66 / 255, 1)
  // Live-mic red for the bar icon while listening.
  readonly property color recRed: Qt.rgba(230 / 255, 56 / 255, 56 / 255, 1)

  // --- popup lifecycle ------------------------------------------------------
  //
  // Overrides the base Panel.open() so showing the popup also refreshes the
  // pickers/grants/mic and takes keyboard focus — but never arms the mic.
  // Clicking a bar icon just shows what's there; the mic is armed only
  // through the service's summon() (the hotkey), and only when idle.
  function open() {
    controller.show()
    if (svc) svc.refreshOnOpen()
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  // The service tracks which views are on screen: animation that only feeds a
  // popup is idle work when none of them is.
  onOpenedChanged: if (svc) svc.recountOpenViews()

  onSvcChanged: {
    if (!svc) return
    svc.registerView(root)
    // `bar` (and so the service) is injected just after this view loads, so
    // pick up whatever is already in flight rather than starting blank.
    if (inputEdit && inputEdit.text !== svc.draft) inputEdit.text = svc.draft
    if (opened) svc.refreshOnOpen()
  }

  Component.onCompleted: if (svc) svc.registerView(root)
  Component.onDestruction: if (svc) svc.unregisterView(root)

  Connections {
    target: root.svc

    // Repaint this screen's canvases in step with the shared phase — only
    // while this popup is actually up.
    function onAnimPhaseChanged() {
      if (!root.opened) return
      swarm.requestPaint()
      if (gyre.visible) gyre.requestPaint()
    }

    // Every tool call kicks the orb, so real progress is visible from across
    // the room without reading a word.
    function onToolPing() { if (root.opened) gyre.ping() }

    // Typing can be started from another screen's panel (or resumed when this
    // one is opened); either way this popup's field takes the caret.
    function onTypingChanged() {
      if (root.opened && root.typing) Qt.callLater(root.focusInput)
    }
  }

  // --- gestures, forwarded to the service -----------------------------------

  function activate() { if (svc) svc.activate() }
  function stopAll() { if (svc) svc.stopAll() }
  function resolveGrant(allowIt) { if (svc) svc.resolveGrant(allowIt) }
  function resolveConfirm(allowIt) { if (svc) svc.resolveConfirm(allowIt) }
  function toggleMicDebug() { if (svc) svc.toggleMicDebug() }
  function playCapture() {
    if (svc) svc.playCapture()
    keyCatcher.forceActiveFocus()
  }
  function submitText(text) {
    if (svc) svc.submitText(text)
    keyCatcher.forceActiveFocus()
  }

  function focusInput() { if (inputEdit) inputEdit.forceActiveFocus() }

  function enterTyping() {
    if (!svc || !svc.canType()) return
    svc.enterTyping()
    Qt.callLater(root.focusInput)
  }

  function cancelTyping() {
    if (svc) svc.cancelTyping()
    keyCatcher.forceActiveFocus()
  }

  // Selection hands keyboard focus back to the panel so Enter speaks again
  // instead of re-opening the dropdown.
  function selectVoice(name) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (svc) svc.selectVoice(name)
  }

  function selectAgent(name) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (svc) svc.selectAgent(name)
  }

  function selectModel(name) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (svc) svc.selectModel(name)
  }

  function toggleTone() {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (svc) svc.toggleTone()
  }

  function toggleVoiceApproval() {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (svc) svc.toggleVoiceApproval()
  }

  // --- bar icon -------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The mark is drawn rather than set in a font. Nothing in the icon sets
    // had the right shape: this assistant is a still point with sound moving
    // out from it, and every candidate glyph rendered that as separate
    // arcs — a wifi fan, a broadcast tower — which reads as transmitting,
    // not listening. So: a core, and around it closed wave rings whose
    // radius rises and falls continuously. One unbroken line each, because
    // a ripple is not a series of marks.
    active: root.phase !== "idle"
    useActiveColor: true

    iconComponent: Component {
      Item {
        Canvas {
          id: mark
          anchors.fill: parent
          // The equalizer takes over for the phases with live audio.
          visible: root.phase !== "listening" && root.phase !== "speaking"

          readonly property color ink: root.busy ? root.rust : root.barForeground
          readonly property real beat: root.animPhase
          onInkChanged: requestPaint()
          onBeatChanged: requestPaint()
          onVisibleChanged: if (visible) requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var size = Math.min(width, height)
            var cx = width / 2
            var cy = height / 2
            // Still at rest, turning while the agent works — the icon moves
            // when there is something to move about, and the phase only
            // advances when a panel is open or a turn is running, so a
            // resting bar costs nothing.
            var t = beat * (root.busy ? 0.9 : 0.35)

            ctx.fillStyle = ink
            ctx.globalAlpha = 1
            ctx.beginPath()
            ctx.arc(cx, cy, size * 0.135, 0, Math.PI * 2)
            ctx.fill()

            ctx.strokeStyle = ink
            ctx.lineJoin = "round"
            // Two rings, unequal lobe counts and opposite drift, so the gap
            // between them breathes instead of staying parallel.
            // Shallow and frequent: at sixteen pixels a deep lobe reads as a
            // flower or a gear, and the thing being drawn is a ripple.
            var rings = [
              { r: 0.29, amp: 0.026, lobes: 9,  dir:  1, alpha: 0.90, w: 0.050 },
              { r: 0.42, amp: 0.026, lobes: 8,  dir: -1, alpha: 0.48, w: 0.040 }
            ]
            for (var k = 0; k < rings.length; k++) {
              var g = rings[k]
              ctx.globalAlpha = g.alpha
              ctx.lineWidth = Math.max(1, size * g.w)
              ctx.beginPath()
              var steps = 72
              for (var i = 0; i <= steps; i++) {
                var th = (i / steps) * Math.PI * 2
                var rr = size * (g.r + g.amp * Math.sin(g.lobes * th + g.dir * t))
                var x = cx + rr * Math.cos(th)
                var y = cy + rr * Math.sin(th)
                if (i === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.closePath()
              ctx.stroke()
            }
            ctx.globalAlpha = 1
          }
        }
      }
    }
    tooltipText: root.busy
      ? (root.agentLabel + " is working — " + root.elapsedLabel())
      : root.phase === "listening" ? "Listening…"
      : root.phase === "speaking"  ? "Speaking…"
      : "Computer — click, or press End, to speak"

    onPressed: function(buttonCode) {
      // Right-click stops the current turn (same as open + Enter); left
      // toggles the popup.
      if (buttonCode === Qt.RightButton) root.stopAll()
      else root.toggle()
    }

    // Something is waiting for an answer. The turn may have started on
    // another screen entirely, and the card may be behind a closed panel, so
    // the icon has to be able to say "you" from across the room.
    Rectangle {
      visible: root.awaitingDecision
      width: Math.max(5, Style.space(6))
      height: width
      radius: width / 2
      color: root.ember
      z: 10
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(4)
      anchors.topMargin: Style.space(5)

      SequentialAnimation on opacity {
        running: root.awaitingDecision
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
      }
    }

    // Thinking: a slow rust breath on the radiobox core. (Listening and
    // speaking use the equalizer below; idle sits still.)
    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.4; duration: 720; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 720; easing.type: Easing.InOutSine }
      onStopped: button.opacity = 1
    }

    // Live equalizer for listening (red, driven by your mic) and speaking
    // (ember, driven by the reply audio) — displayLevel already carries the
    // right signal per phase, plus a per-bar wobble. The bar-sized cousin of
    // the orb's radial bars.
    Row {
      anchors.centerIn: parent
      visible: root.phase === "listening" || root.phase === "speaking"
      spacing: Math.max(1, Style.space(2))

      Repeater {
        model: 4

        Rectangle {
          required property int index
          width: Math.max(2, Style.space(2.5))
          radius: width / 2
          color: root.phase === "listening" ? root.recRed : root.ember
          anchors.verticalCenter: parent.verticalCenter
          readonly property real lvl: 0.32 + 0.68 * root.displayLevel
          height: {
            var w = 0.5 + 0.5 * Math.sin(root.barPhase * (1 + index * 0.45) + index * 1.7)
            return Math.max(2, Style.space(4) + Style.space(11) * lvl * w)
          }
          Behavior on height { NumberAnimation { duration: 60 } }
        }
      }
    }
  }

  // A labelled switch for the settings drawer. Written once because there
  // are two of them now, and a second hand-rolled copy is how two switches
  // start looking subtly different from each other.
  component SettingSwitch: RowLayout {
    id: row

    property string label: ""
    property string detail: ""
    property bool on: false
    signal toggled()

    Layout.fillWidth: true
    spacing: Style.space(10)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0

      Text {
        text: row.label
        color: Qt.alpha(Color.popups.text, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }

      Text {
        visible: text !== ""
        text: row.detail
        color: Qt.alpha(Color.popups.text, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        Layout.fillWidth: true
      }
    }

    Rectangle {
      implicitWidth: Style.space(58)
      implicitHeight: Style.space(24)
      radius: height / 2
      color: row.on ? Qt.alpha(root.ember, 0.22) : Qt.alpha(Color.popups.text, 0.08)
      border.width: Math.max(1, Style.normalBorderWidth)
      border.color: row.on ? Qt.alpha(root.ember, 0.6) : Qt.alpha(Color.popups.text, 0.2)
      Behavior on color { ColorAnimation { duration: 150 } }

      Rectangle {
        width: Style.space(18); height: width; radius: width / 2
        y: (parent.height - height) / 2
        x: row.on ? parent.width - width - Style.space(3) : Style.space(3)
        color: row.on ? root.ember : Qt.alpha(Color.popups.text, 0.5)
        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 150 } }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggled()
      }
    }
  }

  // One approval card, used for both gates below. Long requests scroll
  // inside the card rather than pushing the rest of the panel around, and
  // the height cap is what keeps a wordy reason from taking over the popup.
  component GateCard: Rectangle {
    id: gate

    property string title: ""
    property color accentColor: Color.accent
    property color fillColor: Qt.alpha(Color.accent, 0.10)
    property color edgeColor: Qt.alpha(Color.accent, 0.45)
    property string subject: ""
    property string explanation: ""
    property string footnote: ""
    property string acceptLabel: ""
    property string refuseLabel: ""
    // Shown beside the keys when answering out loud is available, so the
    // card itself teaches the words rather than leaving them in the README.
    property string spokenHint: ""
    // 0..1 of a deadline left, or -1 for a question with no clock.
    property real progress: -1

    signal accepted()
    signal refused()

    Layout.fillWidth: true
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    implicitHeight: Math.min(gateCol.implicitHeight + Style.space(24), Style.space(170))
    radius: Style.cornerRadius
    color: gate.fillColor
    border.color: gate.edgeColor
    border.width: Math.max(1, Style.normalBorderWidth)

    // The clock, along the bottom edge: it retreats as the script's patience
    // runs out, and goes urgent at the end. A card that simply disappeared
    // when the deadline passed looked like a bug; this makes the same moment
    // legible.
    Rectangle {
      visible: gate.progress >= 0
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(2)
      anchors.bottomMargin: Style.space(2)
      width: Math.max(0, (parent.width - Style.space(4)) * Math.max(0, gate.progress))
      height: Math.max(2, Style.space(2))
      radius: height / 2
      color: gate.progress < 0.2 ? Color.urgent : gate.accentColor
      opacity: 0.65
      Behavior on width { NumberAnimation { duration: 200 } }
      Behavior on color { ColorAnimation { duration: 300 } }
    }

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(12)
      contentWidth: width
      contentHeight: gateCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: gateCol
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: gate.title
          color: gate.accentColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
        }

        Text {
          text: gate.subject
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WrapAnywhere
          Layout.fillWidth: true
        }

        Text {
          visible: text !== ""
          text: gate.explanation
          color: Qt.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
          Layout.fillWidth: true
        }

        Text {
          visible: text !== ""
          text: gate.footnote
          color: Qt.alpha(Color.popups.text, 0.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.italic: true
        }

        RowLayout {
          spacing: Style.space(16)

          Text {
            text: gate.acceptLabel
            color: gate.accentColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: gate.accepted()
            }
          }

          Text {
            text: gate.refuseLabel
            color: Qt.alpha(Color.popups.text, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: gate.refused()
            }
          }

          Text {
            visible: text !== ""
            text: gate.spokenHint
            color: Qt.alpha(Color.popups.text, 0.42)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.italic: true
          }
        }
      }
    }
  }

  // --- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    // Full height for the content, capped and scrolled per-section rather
    // than shrunk — the orb keeps its size; grant/activity/settings scroll
    // inside their own slots.
    contentHeight: panel.fittedContentHeight(content.implicitHeight + Style.space(20), Style.space(940))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.close()
      Keys.onReturnPressed: root.activate()
      Keys.onEnterPressed: root.activate()
      Keys.onSpacePressed: root.activate()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_I && (event.modifiers & Qt.ControlModifier)) {
          root.activityOpen = !root.activityOpen
          event.accepted = true
          return
        }
        // Ctrl+M: keep the mic trace up even on turns that worked.
        if (event.key === Qt.Key_M && (event.modifiers & Qt.ControlModifier)) {
          root.toggleMicDebug()
          event.accepted = true
          return
        }
        // '/' opens the text field, when a new turn could start.
        if (event.key === Qt.Key_Slash && !root.typing
            && root.phase !== "listening" && root.phase !== "transcribing"
            && root.phase !== "thinking") {
          root.enterTyping()
          event.accepted = true
          return
        }
        // A blocked action outranks a queued permission: something is
        // waiting on this answer right now.
        if (root.pendingConfirm !== null) {
          if (event.key === Qt.Key_Y) { root.resolveConfirm(true); event.accepted = true }
          else if (event.key === Qt.Key_N) { root.resolveConfirm(false); event.accepted = true }
          return
        }
        if (root.pendingGrant === null) return
        if (event.key === Qt.Key_A) { root.resolveGrant(true); event.accepted = true }
        else if (event.key === Qt.Key_D) { root.resolveGrant(false); event.accepted = true }
      }

      // Fixed column: the orb and status never scroll away. Regions that can
      // outgrow their slot (grant card, settings) scroll independently, and
      // the popup grows with content up to its cap.
      ColumnLayout {
        id: content
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          leftMargin: Style.space(24)
          rightMargin: Style.space(24)
          topMargin: Style.space(16)
        }
        spacing: Style.space(16)

        // The orb: a thin ring with radial bars growing outward from it,
        // a soft halo, and a core that swells with the audio level.
        Item {
          id: orb

          readonly property int barCount: 48
          readonly property real ringRadius: Style.space(88)
          readonly property real maxBar: Style.space(36)
          readonly property real minBar: Style.space(4)
          readonly property real coreRadius: Style.space(56)
          readonly property real level: root.displayLevel

          // Bars share the swarm's heat ramp: rust when quiet, toward
          // ember-gold as the voice level rises.
          readonly property color barColor: Qt.rgba(
            (183 + (245 - 183) * level) / 255,
            (65 + (177 - 65) * level) / 255,
            (14 + (66 - 14) * level) / 255, 1)

          // The bars are the voice — mic level in, speech level out. When
          // there is no voice they idle, and while the agent works they
          // retract entirely and hand the ring to the gyre.
          function barHeight(i) {
            var p = root.phase
            if (p === "listening" || p === "speaking") {
              var wob = 0.4 + 0.6 * Math.abs(Math.sin(i * 2.399 + root.animPhase * (p === "speaking" ? 2.4 : 1.7)))
              return minBar + maxBar * level * wob
            }
            return minBar + maxBar * 0.07 * (1 + Math.sin(i * 0.7 + root.animPhase * 0.5))
          }

          Layout.alignment: Qt.AlignHCenter
          Layout.topMargin: Style.space(4)
          implicitWidth: (ringRadius + maxBar + Style.space(6)) * 2
          implicitHeight: implicitWidth

          // Radial bars. Faded as one group rather than per bar, so the
          // handoff to the gyre is a single clean gesture and the per-bar
          // height animations keep their snap while speaking.
          Item {
            id: bars
            anchors.fill: parent
            opacity: root.busy ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

            Repeater {
              model: orb.barCount

              Item {
                required property int index
                anchors.centerIn: parent
                width: 0
                height: 0
                rotation: index * (360 / orb.barCount)

                Rectangle {
                  readonly property real len: orb.barHeight(parent.index)
                  x: -width / 2
                  y: -(orb.ringRadius + Style.space(4)) - height
                  width: Style.space(4)
                  height: len
                  radius: width / 2
                  color: orb.barColor
                  opacity: 0.3 + 0.7 * ((len - orb.minBar) / orb.maxBar)
                  Behavior on height { NumberAnimation { duration: 70 } }
                }
              }
            }
          }

          // Core: a parametric particle swarm — the same point-cloud math as
          // the omarchyplugins.com hero canvas (RAY/BIRD presets), with my
          // own parameter set, SPARK: a self-portrait as a slow-orbiting
          // plume of light that blooms with the voice level. Each frame
          // places every dot from a closed-form trig expression over its
          // index and time; no state is kept between frames.
          Canvas {
            id: swarm
            anchors.centerIn: parent
            width: (orb.ringRadius - Style.space(3)) * 2
            height: width

            // Three parameter moods, cross-faded by state: COCOON (site
            // preset; calm, tightly wound) for idle, STORM (site preset;
            // scattered, churning) while transcribing/thinking, and SPARK
            // (my RAY retune) for listening and speaking. CX/CY fold in the
            // site's offsetY; ZOOM is rescaled for this canvas.
            readonly property var presets: ({
              cocoon: { AMP: 2.6, WIND: 14.5, VS: 7, VO: 13, QA: 2, QF: 3,
                        SP: 70, TH: 14.2, ORB: 22, YS: 52, PD: 9, PSP: 2,
                        WV: 9, WSP: 2, DOF: 4, RF: 4.2, DPH: 2,
                        DENS: 150, CX: 200, CY: -105, ZOOM: 1.43 },
              storm:  { AMP: 4, WIND: 48, VS: 7, VO: 13, QA: 2, QF: 3,
                        SP: 35, TH: 9, ORB: 40, YS: 35, PD: 2.4, PSP: 4.2,
                        WV: 2.8, WSP: 2, DOF: 4, RF: 19, DPH: -3.4,
                        DENS: 110, CX: 200, CY: 0, ZOOM: 1.26 },
              spark:  { AMP: 8.69, WIND: 38.26, VS: 16.38, VO: 11.75,
                        QA: 1.65, QF: 3.47, SP: 38.62, TH: 9.63,
                        ORB: 47.63, YS: 7.34, PD: 10.77, PSP: 2.73,
                        WV: 7.21, WSP: 3.79, DOF: 5.98, RF: 3.04, DPH: 3.18,
                        DENS: 235, CX: 224, CY: 158, ZOOM: 1.62 },
              // Calm idle moods — variations on cocoon that the idle state
              // slowly morphs between (the service's idleVariants / idleTimer).
              halo:   { AMP: 3.4, WIND: 22, VS: 9, VO: 12, QA: 2, QF: 3,
                        SP: 60, TH: 11, ORB: 34, YS: 40, PD: 7, PSP: 2.4,
                        WV: 6, WSP: 2, DOF: 4, RF: 6, DPH: 1.5,
                        DENS: 170, CX: 200, CY: -40, ZOOM: 1.4 },
              lantern:{ AMP: 2.0, WIND: 11, VS: 6, VO: 13, QA: 2.2, QF: 2.8,
                        SP: 80, TH: 16, ORB: 18, YS: 60, PD: 10, PSP: 1.6,
                        WV: 10, WSP: 1.8, DOF: 3.5, RF: 3.5, DPH: 1.8,
                        DENS: 200, CX: 200, CY: -130, ZOOM: 1.5 },
              drift:  { AMP: 5.2, WIND: 30, VS: 8, VO: 13, QA: 1.8, QF: 3.2,
                        SP: 48, TH: 10, ORB: 26, YS: 30, PD: 6, PSP: 2,
                        WV: 4, WSP: 2.4, DOF: 5, RF: 8, DPH: 2.5,
                        DENS: 160, CX: 200, CY: 10, ZOOM: 1.5 },
              coil:   { AMP: 4.0, WIND: 18, VS: 7, VO: 13, QA: 2, QF: 3.4,
                        SP: 55, TH: 12, ORB: 44, YS: 22, PD: 8, PSP: 2.8,
                        WV: 7, WSP: 2, DOF: 4, RF: 5, DPH: 3,
                        DENS: 180, CX: 210, CY: 60, ZOOM: 1.55 },
              // Waiting on a decision: drawn in, dense and slow, holding
              // still rather than drifting. The one moment the orb should
              // look like it is looking back at you.
              attend: { AMP: 2.2, WIND: 10, VS: 7, VO: 13, QA: 2, QF: 3,
                        SP: 76, TH: 15, ORB: 13, YS: 58, PD: 9, PSP: 1.3,
                        WV: 9, WSP: 1.5, DOF: 4, RF: 3.6, DPH: 1.5,
                        DENS: 215, CX: 200, CY: -122, ZOOM: 1.36 }
            })
            property var cur: null
            readonly property int points: 1200

            function targetPreset() {
              // A card outranks the phase behind it: whatever the agent was
              // doing, the panel is now waiting on a person.
              if (root.awaitingDecision && root.phase !== "listening") return presets.attend
              if (root.phase === "thinking" || root.phase === "transcribing") return presets.storm
              if (root.phase === "idle") return presets[root.idleVariant] || presets.cocoon
              return presets.spark
            }
            // --- the resting orb: water, not particles ------------------
            //
            // Idle used to run the same parametric point-cloud as every
            // other phase, just with calmer constants — and a slow drift of
            // scattered dots reads as "processing at low intensity" rather
            // than "at rest". This is a body of liquid instead: points held
            // in a disc, turned by a slow vortex that spins faster at the
            // centre than the rim, with the surface pushed in and out by
            // layered swells. Nothing here is random per frame — every dot's
            // place comes from its index and the clock — so the motion is
            // continuous and repeats only after a very long time.
            //
            // The five moods are the same idea at different weather: they
            // cross-fade through the same idleVariant timer the presets used.
            readonly property var tides: ({
              cocoon:  { SWELL: 0.055, RIPPLE: 0.030, CHOP: 0.016, SPIN: 0.16,
                         SHEAR: 0.34, BOB: 0.020, BREATH: 0.030, GLINT: 0.55 },
              halo:    { SWELL: 0.075, RIPPLE: 0.024, CHOP: 0.012, SPIN: 0.12,
                         SHEAR: 0.46, BOB: 0.030, BREATH: 0.045, GLINT: 0.75 },
              lantern: { SWELL: 0.038, RIPPLE: 0.018, CHOP: 0.008, SPIN: 0.09,
                         SHEAR: 0.22, BOB: 0.014, BREATH: 0.022, GLINT: 0.40 },
              drift:   { SWELL: 0.090, RIPPLE: 0.042, CHOP: 0.022, SPIN: 0.21,
                         SHEAR: 0.58, BOB: 0.038, BREATH: 0.055, GLINT: 0.62 },
              coil:    { SWELL: 0.062, RIPPLE: 0.048, CHOP: 0.030, SPIN: 0.27,
                         SHEAR: 0.72, BOB: 0.024, BREATH: 0.035, GLINT: 0.85 }
            })
            property var tide: null

            // Golden angle: successive indices land as far apart as they
            // can, which fills the disc evenly and — at this density —
            // draws its own spiral arms. That structure is the point. The
            // motion below turns it rather than scattering it, so the arms
            // wind and unwind instead of dissolving.
            readonly property real goldenAngle: 2.39996322972865332

            function paintTide(ctx, lvl) {
              var tgt = tides[root.idleVariant] || tides.cocoon
              if (!tide) { tide = {}; for (var k in tgt) tide[k] = tgt[k] }
              else { for (var k2 in tgt) tide[k2] = mix(tide[k2], tgt[k2], 0.02) }
              var W = tide

              var t = root.animPhase * 0.11
              var cx = width / 2
              var cy = height / 2
              var maxR = width / 2 - 3
              // The whole body breathes, slower than anything inside it.
              var body = maxR * (0.90 + W.BREATH * Math.sin(t * 0.42))

              var n = points
              var dim = [143, 58, 18]
              var lit = [226, 112, 58]
              var gold = [245, 190, 96]

              for (var i = n; i--; ) {
                // sqrt keeps the density flat instead of piling points into
                // the middle.
                var f = (i + 0.5) / n
                var rr = Math.sqrt(f)
                var a = i * goldenAngle

                // A vortex that shears: the middle turns faster than the rim.
                // Water looks like water because it does not rotate rigidly,
                // and it is the shear that makes the arms curl.
                a += t * (W.SPIN + W.SHEAR * (1 - rr))

                // Three swells at unrelated frequencies and speeds; their sum
                // never repeats on any timescale you will sit and watch.
                var swell = W.SWELL * Math.sin(3 * a + t * 0.9)
                  + W.RIPPLE * Math.sin(5 * a - t * 0.63)
                  + W.CHOP * Math.sin(8 * a + t * 0.37 + rr * 4)
                var r = body * rr * (1 + swell) * (1 + 0.10 * lvl)

                var x = cx + r * Math.cos(a)
                // A slow vertical bob, phase-shifted by depth, so the body
                // rolls instead of sliding.
                var y = cy + r * Math.sin(a)
                  + body * W.BOB * Math.sin(t * 0.6 + rr * 3.1)

                if (r > body * 1.02) continue

                // Light gathers toward the surface, the way it does on water.
                var edge = rr * rr
                var col = heat(dim, lit, Math.min(1, edge * 0.9 + lvl * 0.4))
                var glint = (i % 17 === 0) && edge > 0.55
                if (glint) col = heat(lit, gold, W.GLINT)

                ctx.globalAlpha = (0.16 + 0.5 * edge) * (glint ? 1.6 : 1) + 0.12 * lvl
                ctx.fillStyle = col
                var sz = glint ? 2.1 : (edge > 0.7 ? 1.5 : 1.2)
                ctx.fillRect(x, y, sz, sz)
              }
              ctx.globalAlpha = 1
            }

            function mix(a, b, f) { return a + (b - a) * f }
            function heat(c1, c2, f) {
              return "rgb(" + Math.round(mix(c1[0], c2[0], f)) + ","
                + Math.round(mix(c1[1], c2[1], f)) + ","
                + Math.round(mix(c1[2], c2[2], f)) + ")"
            }

            onPaint: {
              var ctx = getContext("2d")
              // Cross-fade the live parameter set toward the phase's mood.
              var tgt = targetPreset()
              if (!cur) { cur = {}; for (var pk in tgt) cur[pk] = tgt[pk] }
              else { for (var pk2 in tgt) cur[pk2] = mix(cur[pk2], tgt[pk2], 0.055) }
              var V = cur
              // Ember trails: erase a fraction of the last frame toward
              // transparency instead of clearing, so every dot drags a
              // fading streak. destination-out keeps the canvas itself
              // transparent, so this composes over any window background.
              ctx.globalCompositeOperation = "destination-out"
              ctx.globalAlpha = 0.16
              ctx.fillStyle = "#000000"
              ctx.fillRect(0, 0, width, height)
              ctx.globalCompositeOperation = "source-over"
              var lvl = orb.level

              // At rest the orb is water. Every other phase keeps the
              // parametric swarm, which is what makes the resting state read
              // as a different state rather than a slower one.
              if (root.phase === "idle" && !root.awaitingDecision) {
                paintTide(ctx, lvl)
                return
              }

              var busy = root.phase === "thinking" || root.phase === "transcribing"
              var t = root.animPhase * 0.26 * (busy ? 1.9 : 1.0)
              var scale = (Math.min(width, height) / 400) * V.ZOOM
              var ox = (width - 400 * scale) / 2
              var oy = (height - 400 * scale) / 2
              var amp = V.AMP * (0.85 + 0.5 * lvl)
              var orbR = V.ORB * (0.85 + 0.45 * lvl)
              var cx = width / 2
              var cy = height / 2
              var maxR = width / 2 - 2
              var maxR2 = maxR * maxR
              var srcStep = 6000 / points
              // Heat-reactive rust palette: the voice level pushes deep
              // oxidized iron toward bright ember, highlights toward gold.
              var dim = heat([143, 58, 18], [226, 112, 58], lvl)
              var accent = heat([183, 65, 14], [245, 177, 66], lvl)
              for (var i = points; i--; ) {
                var s = i * srcStep
                var y = s / V.DENS
                var k = (amp + Math.cos(s / V.PD - t * V.PSP)) * Math.cos(s / V.WIND)
                var e = y / V.VS - V.VO
                var d = Math.hypot(k, e) + Math.sin(e / V.WV + t / V.WSP) - V.DOF
                var q = V.QA * Math.sin(k * V.QF)
                  - y / V.SP * k * (V.TH + k * Math.sin(Math.cos(e) * V.RF - d * V.DPH + t))
                var a = d - t
                var sx = q + orbR * Math.cos(a) + V.CX
                var sy = q * Math.sin(a) + d * V.YS + V.CY
                var x = ox + sx * scale
                var py = oy + sy * scale
                var dx = x - cx
                var dy = py - cy
                if (dx * dx + dy * dy > maxR2) continue
                ctx.globalAlpha = (i % 13 === 0 ? 0.7 : 0.42) + 0.25 * lvl
                ctx.fillStyle = (i % 5 === 0) ? accent : dim
                var sz = i % 29 === 0 ? 2.2 : 1.4
                ctx.fillRect(x, py, sz, sz)
              }
              ctx.globalAlpha = 1
            }
          }

          // The gyre. While the agent works the ring stops being a mouth
          // and becomes an instrument: three arcs sweep it at unrelated
          // speeds — two one way, one the other — so the figure never
          // visibly repeats and the eye can't mistake it for a freeze.
          // Each tool call fires a sonar ring outward and kicks the arcs
          // forward, so the orb ticks in time with work actually happening.
          Canvas {
            id: gyre
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            opacity: root.busy ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

            // Decaying speed kick, reset by each tool call.
            property real surge: 0
            // In-flight sonar rings, each its own 0→1 progress.
            property var pings: []

            function ping() {
              surge = 1
              var next = pings.slice()
              next.push(0)
              while (next.length > 5) next.shift()
              pings = next
            }

            // Radii are offsets from the ring, spread across the space the
            // bars vacate. The speeds are deliberately incommensurate so the
            // three heads never re-align, and `hot` walks each arc down the
            // rust ramp so depth reads even when they cross.
            readonly property var arcs: [
              { r: 16, sweep: 2.10, w: 3.2, dir:  1, speed: 1.00, alpha: 1.00, hot: 1.00 },
              { r: 30, sweep: 1.30, w: 2.2, dir: -1, speed: 0.62, alpha: 0.85, hot: 0.55 },
              { r:  4, sweep: 3.10, w: 1.6, dir:  1, speed: 1.73, alpha: 0.60, hot: 0.30 }
            ]

            // The orb's heat ramp: deep oxidized iron through to bright ember.
            function heatColor(hot) {
              return Qt.rgba((183 + (245 - 183) * hot) / 255,
                             (65 + (177 - 65) * hot) / 255,
                             (14 + (66 - 14) * hot) / 255, 1)
            }

            // One arc as a comet: segments of falling width and alpha behind
            // a bright head. Canvas can't gradient along an arc, so the tail
            // is drawn as a short run of strokes.
            function comet(ctx, cx, cy, r, head, sweep, w, dir, alpha, hot) {
              var body = heatColor(hot)
              var segs = 44
              for (var i = 0; i < segs; i++) {
                var f = i / segs
                var a0 = head - dir * sweep * f
                var a1 = head - dir * sweep * (f + 1 / segs)
                ctx.beginPath()
                ctx.lineWidth = Math.max(0.6, w * (1 - 0.65 * f))
                ctx.globalAlpha = alpha * Math.pow(1 - f, 1.5)
                ctx.strokeStyle = body
                ctx.arc(cx, cy, r, Math.min(a0, a1), Math.max(a0, a1))
                ctx.stroke()
              }
              // The head runs hotter than its tail, so the leading edge
              // stays legible against the swarm behind it.
              var hx = cx + r * Math.cos(head)
              var hy = cy + r * Math.sin(head)
              ctx.fillStyle = heatColor(Math.min(1, hot + 0.35))
              ctx.globalAlpha = alpha * 0.22
              ctx.beginPath()
              ctx.arc(hx, hy, w * 2.0, 0, Math.PI * 2)
              ctx.fill()
              ctx.globalAlpha = alpha
              ctx.beginPath()
              ctx.arc(hx, hy, w * 0.8, 0, Math.PI * 2)
              ctx.fill()
            }

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var cx = width / 2
              var cy = height / 2
              var base = orb.ringRadius
              surge *= 0.94
              // Blocked on a card, the arcs nearly stop: the agent is not
              // working, it is waiting, and the orb should not claim
              // otherwise.
              var pace = root.awaitingDecision ? 0.18 : 1
              var t = root.animPhase * pace * (1 + 1.6 * surge)

              // Faint dial the arcs ride on, so the ring still reads as a
              // ring in the gaps between comet heads.
              ctx.globalAlpha = 0.10
              ctx.lineWidth = Math.max(1, Style.spaceReal(1))
              ctx.strokeStyle = root.rust
              ctx.beginPath()
              ctx.arc(cx, cy, base + Style.spaceReal(16), 0, Math.PI * 2)
              ctx.stroke()

              for (var i = 0; i < arcs.length; i++) {
                var a = arcs[i]
                comet(ctx, cx, cy, base + Style.spaceReal(a.r), t * a.speed * a.dir,
                      a.sweep, Style.spaceReal(a.w), a.dir, a.alpha, a.hot)
              }

              // Sonar: one expanding ring per tool call, fading as it goes.
              if (pings.length > 0) {
                var live = []
                for (var j = 0; j < pings.length; j++) {
                  var pr = pings[j] + 0.028
                  if (pr >= 1) continue
                  live.push(pr)
                  ctx.globalAlpha = 0.55 * (1 - pr) * (1 - pr)
                  ctx.lineWidth = Math.max(1, Style.spaceReal(2) * (1 - pr))
                  ctx.strokeStyle = root.ember
                  ctx.beginPath()
                  ctx.arc(cx, cy, base * 0.45 + pr * base * 0.72, 0, Math.PI * 2)
                  ctx.stroke()
                }
                pings = live
              }
              ctx.globalAlpha = 1
            }
          }
        }

        // Working caption: which phase, how long it has been going, and the
        // newest thing the agent actually did. The clock is deliberately
        // prominent — "is this still running?" is the question the panel
        // used to leave unanswered.
        ColumnLayout {
          visible: root.busy
          Layout.fillWidth: true
          spacing: Style.space(4)

          RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Style.space(8)

            Text {
              text: root.phase === "transcribing" ? "TRANSCRIBING" : "THINKING"
              color: root.ember
              // Slow breath, so the caption never looks frozen either.
              opacity: 0.6 + 0.4 * (1 + Math.sin(root.animPhase * 0.9)) / 2
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 3
            }

            Text {
              text: root.elapsedLabel()
              color: Qt.alpha(Color.popups.text, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // Context carried by the last call. It ticks up as tool results
            // land, so it is a second heartbeat — and the rest of the
            // numbers stay in the drawer rather than on the face.
            Text {
              visible: root.turnCtx > 0
              text: "· " + root.fmtTokens(root.turnCtx) + " ctx"
              color: Qt.alpha(Color.popups.text, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: text !== ""
            text: root.lastActivity
              ? ((root.lastActivity.label ? root.lastActivity.label + "  " : "")
                 + String(root.lastActivity.detail || "")).trim()
              : ""
            color: Qt.alpha(Color.popups.text, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 1
            Layout.fillWidth: true

            // The one-line summary is a lid on the whole log.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.activityOpen = !root.activityOpen
                keyCatcher.forceActiveFocus()
              }
            }
          }
        }

        // Status line — click it (when idle) to start typing, or press /.
        Text {
          visible: !root.typing
          text: root.statusLine
          color: root.error !== "" && root.phase === "idle"
            ? Color.urgent
            : Qt.alpha(Color.popups.text, statusMouse.containsMouse ? 0.85 : 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Layout.alignment: Qt.AlignHCenter
          Behavior on color { ColorAnimation { duration: 120 } }

          MouseArea {
            id: statusMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.phase !== "listening" && root.phase !== "transcribing"
                     && root.phase !== "thinking"
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.enterTyping()
          }
        }

        // Type-to-ask field: appears in place of the status line, focused.
        // A frosted card with an ember focus-glow; Enter sends, Shift+Enter
        // adds a newline, Esc returns to voice. Submitting runs the same
        // agent pipeline as a spoken turn.
        Rectangle {
          id: inputBox
          visible: root.typing
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          implicitHeight: Math.min(
            Math.max(Style.space(46), inputEdit.implicitHeight + Style.space(20)),
            Style.space(150))
          radius: Style.cornerRadius
          color: Qt.alpha(Color.popups.text, 0.05)
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: inputEdit.activeFocus ? Qt.alpha(root.ember, 0.7)
                                              : Qt.alpha(root.rust, 0.4)
          Behavior on border.color { ColorAnimation { duration: 160 } }
          opacity: root.typing ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(12)
            anchors.topMargin: Style.space(10)
            anchors.bottomMargin: Style.space(10)
            spacing: Style.space(10)

            Text {
              text: "›"
              color: root.ember
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
              Layout.alignment: Qt.AlignTop
            }

            Flickable {
              Layout.fillWidth: true
              Layout.fillHeight: true
              contentWidth: width
              contentHeight: inputEdit.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              // Keep the caret in view as the message grows.
              onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

              TextEdit {
                id: inputEdit
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                selectByMouse: true
                selectionColor: Qt.alpha(root.ember, 0.35)
                cursorDelegate: Rectangle {
                  width: Math.max(1, Style.space(2)); color: root.ember
                  Behavior on opacity { NumberAnimation { duration: 400 } }
                  SequentialAnimation on opacity {
                    running: inputEdit.activeFocus; loops: Animation.Infinite
                    NumberAnimation { to: 0; duration: 480 }
                    NumberAnimation { to: 1; duration: 480 }
                  }
                }

                // The draft belongs to the conversation, not to this screen:
                // a message half-typed on the laptop is still there when the
                // panel is reopened on another monitor. Two-way by hand —
                // binding `text` would break on the first keystroke.
                onTextChanged: {
                  // TextEdit has no maximumLength, and this text becomes an
                  // agent prompt: clamp it here rather than discovering the
                  // size later, in an argv or a log line.
                  var cap = root.svc ? root.svc.maxDraftChars : 8000
                  if (text.length > cap) {
                    text = text.slice(0, cap)
                    cursorPosition = text.length
                    return
                  }
                  if (root.svc && text !== root.svc.draft) root.svc.draft = text
                }

                Connections {
                  target: root.svc
                  function onDraftChanged() {
                    if (inputEdit.text !== root.svc.draft) inputEdit.text = root.svc.draft
                  }
                }

                Keys.onEscapePressed: root.cancelTyping()
                Keys.onReturnPressed: function(e) {
                  if (e.modifiers & Qt.ShiftModifier) { e.accepted = false }
                  else { root.submitText(inputEdit.text); e.accepted = true }
                }
                Keys.onEnterPressed: function(e) {
                  if (e.modifiers & Qt.ShiftModifier) { e.accepted = false }
                  else { root.submitText(inputEdit.text); e.accepted = true }
                }

                Text {
                  anchors.fill: parent
                  visible: inputEdit.text.length === 0
                  text: "Type your message…"
                  color: Qt.alpha(Color.popups.text, 0.32)
                  font: inputEdit.font
                  wrapMode: Text.Wrap
                }
              }
            }

            Text {
              text: "↵ send · esc"
              color: Qt.alpha(Color.popups.text, 0.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignBottom
            }
          }
        }

        // The two gates, one shape. A tinted card with a title, the thing
        // being asked about, why, and two keyed choices — that is both the
        // standing permission grant and the one-shot action confirmation.
        // They differ in wording, colour and consequence, which is what the
        // properties carry; building them twice only made it possible for
        // them to drift apart.
        GateCard {
          visible: root.pendingConfirm !== null
          title: "CONFIRM THIS ACTION"
          accentColor: root.ember
          fillColor: Qt.alpha(root.rust, 0.12)
          edgeColor: Qt.alpha(root.ember, 0.55)
          subject: root.pendingConfirm ? String(root.pendingConfirm.label || "") : ""
          explanation: root.pendingConfirm ? String(root.pendingConfirm.detail || "") : ""
          footnote: "This one time only — it is not remembered."
          acceptLabel: "[Y] Do it"
          refuseLabel: "[N] No"
          spokenHint: root.voiceApproval ? "or say “allow” / “deny”" : ""
          progress: root.confirmProgress
          onAccepted: root.resolveConfirm(true)
          onRefused: root.resolveConfirm(false)
        }

        // The human gate for privilege escalation. Unlike the card above,
        // saying yes here is durable: it writes a rule that applies from the
        // next question until the user removes it.
        GateCard {
          visible: root.pendingGrant !== null
          title: "PERMISSION REQUEST"
          accentColor: Color.accent
          fillColor: Qt.alpha(Color.accent, 0.10)
          edgeColor: Qt.alpha(Color.accent, 0.45)
          subject: root.pendingGrant ? String(root.pendingGrant.rule || "") : ""
          explanation: root.pendingGrant ? String(root.pendingGrant.reason || "") : ""
          acceptLabel: "[A] Allow"
          refuseLabel: "[D] Deny"
          spokenHint: root.voiceApproval ? "or say “allow” / “deny”" : ""
          onAccepted: root.resolveGrant(true)
          onRefused: root.resolveGrant(false)
        }

        // What the microphone actually got — a diagnostic, so it stays out
        // of the way until it is useful: a capture that came back empty
        // raises it on its own, the agent raises it while walking you
        // through mic-calibrate.sh, and Ctrl+M pins it open. On a turn that
        // worked it says nothing the answer does not already say.
        RowLayout {
          visible: root.showMicWave && root.phase !== "listening"
          Layout.fillWidth: true
          spacing: Style.space(10)

          // Levels tell you whether audio arrived and how loud. They cannot
          // tell you whether the recording itself was the problem, so the
          // capture is playable — the same audio the transcriber was given.
          Text {
            text: root.playingCapture ? "◼" : "▶"
            color: playMouse.containsMouse || root.playingCapture
              ? root.ember : Qt.alpha(Color.popups.text, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            Layout.alignment: Qt.AlignVCenter
            Behavior on color { ColorAnimation { duration: 120 } }

            MouseArea {
              id: playMouse
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playCapture()
            }
          }

          Item {
            Layout.fillWidth: true
            implicitHeight: Style.space(26)

          Canvas {
            id: micStrip
            anchors.fill: parent

            readonly property var wave: root.micWave
            readonly property bool quiet: root.captureTooQuiet
            onWaveChanged: requestPaint()
            onQuietChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var n = wave.length
              if (n === 0) return

              var mid = height / 2
              var gap = Math.max(1, Style.spaceReal(1))
              var w = Math.max(1, (width - gap * (n - 1)) / n)
              // Rust when the capture never rose above the speech threshold,
              // ember when it did: the colour is the diagnosis.
              var body = quiet ? root.rust : root.ember

              for (var i = 0; i < n; i++) {
                var lvl = Math.max(0.02, Math.min(1, wave[i]))
                var h = Math.max(1, lvl * (height - 2))
                ctx.globalAlpha = quiet ? 0.45 : (0.35 + 0.5 * lvl)
                ctx.fillStyle = body
                ctx.fillRect(i * (w + gap), mid - h / 2, w, h)
              }

              // The line the endpointer listens for, so a quiet capture
              // shows how far under it fell.
              ctx.globalAlpha = 0.25
              ctx.fillStyle = Color.popups.text
              ctx.fillRect(0, mid - 0.5, width, 1)

              // Playback head, so you can hear which part of the trace is
              // the part that went wrong.
              if (root.playingCapture) {
                ctx.globalAlpha = 0.9
                ctx.fillStyle = root.ember
                ctx.fillRect(Math.min(width - 1, root.playProgress * width), 0, 1.5, height)
              }
              ctx.globalAlpha = 1
            }

            Connections {
              target: root
              function onPlayProgressChanged() {
                if (root.playingCapture) micStrip.requestPaint()
              }
              function onPlayingCaptureChanged() { micStrip.requestPaint() }
            }
          }
          }

          Text {
            visible: root.micDebug
            text: "Ctrl+M"
            color: Qt.alpha(Color.popups.text, 0.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
          }
        }

        Text {
          visible: root.transcript !== ""
          text: "“" + root.transcript + "”"
          color: Qt.alpha(Color.popups.text, 0.65)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.italic: true
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
          Layout.fillWidth: true
        }

        // Teleprompter strip: the response shows three lines at a time and
        // scrolls in sync with the spoken audio (speechIndex walks the same
        // 50ms level timeline that drives the orb), so the line being read
        // is always in view — nothing looks cut off.
        Item {
          id: responseStrip
          visible: root.response !== ""
          Layout.fillWidth: true
          // Exact rendered line height, so the strip never clips a line
          // mid-character.
          readonly property real lineH: responseText.lineCount > 0
            ? responseText.implicitHeight / responseText.lineCount : 1
          implicitHeight: Math.min(responseText.implicitHeight, lineH * 4)
          clip: true

          readonly property real progress: {
            if (root.phase === "speaking") {
              var within = 0
              if (root.speechLevels.length > 1 && root.speechIndex > 0)
                within = Math.min(1, root.speechIndex / (root.speechLevels.length - 1))
              // Map chunk-local progress onto the whole reply.
              return root.chunkFracStart + within * (root.chunkFracEnd - root.chunkFracStart)
            }
            return 1
          }
          readonly property real maxScroll: Math.max(0, responseText.implicitHeight - height)
          // Quantized to whole lines: the strip advances line by line as the
          // reading position moves, teleprompter-style.
          readonly property real scrollTarget: Math.min(maxScroll,
            Math.round(maxScroll * progress / lineH) * lineH)

          // (strip shows up to 4 lines; see implicitHeight above)

          Text {
            id: responseText
            width: parent.width
            y: -parent.scrollTarget
            Behavior on y { NumberAnimation { duration: 300; easing.type: Easing.InOutQuad } }
            // Three weights, not one: what has been said fades back, the
            // sentence being spoken is lit, and what is still coming waits
            // in between. speak.sh already reports which slice of the reply
            // is playing (FRAC), so this costs nothing but the markup.
            text: root.responseMarkup
            textFormat: root.phase === "speaking" ? Text.StyledText : Text.PlainText
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            lineHeight: 1.5
            wrapMode: Text.Wrap
          }
        }

        // Ctrl+I: the turn's full activity, newest at the bottom. One line
        // per step on purpose — a log you scan, not one you read. Height is
        // fixed so streaming lines never make the window jitter.
        Rectangle {
          visible: root.activityOpen
          Layout.fillWidth: true
          implicitHeight: Style.space(230)
          radius: Style.cornerRadius
          color: Qt.alpha(Color.popups.text, 0.04)
          border.color: Qt.alpha(root.rust, 0.35)
          border.width: Math.max(1, Style.normalBorderWidth)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true

              Text {
                text: "ACTIVITY"
                color: root.ember
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 2
              }

              Item { Layout.fillWidth: true }

              Text {
                text: root.activityCount + (root.activityCount === 1 ? " step" : " steps")
                  + " · Ctrl+I to close"
                color: Qt.alpha(Color.popups.text, 0.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            ListView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              model: root.activityModel
              spacing: Style.space(3)
              boundsBehavior: Flickable.StopAtBounds
              // Pin to the newest line, the way a terminal does.
              onCountChanged: Qt.callLater(function() { positionViewAtEnd() })

              delegate: RowLayout {
                id: step
                width: ListView.view ? ListView.view.width : 0
                spacing: Style.space(6)

                // Tools lead, results follow, errors shout.
                readonly property color tint: model.kind === "error" ? Color.urgent
                  : model.kind === "tool" ? root.ember
                  : Qt.alpha(Color.popups.text, 0.45)

                Text {
                  text: model.kind === "tool" ? "▸"
                    : model.kind === "error" ? "✕"
                    : model.kind === "meta" ? "◆"
                    : model.kind === "text" ? "·" : "↳"
                  color: step.tint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: model.label !== ""
                  text: model.label
                  color: step.tint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  text: model.detail
                  color: model.kind === "error" ? Color.urgent
                    : Qt.alpha(Color.popups.text, model.kind === "tool" ? 0.75 : 0.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.italic: model.kind === "text"
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  Layout.fillWidth: true
                }
              }
            }

            Text {
              visible: root.activityCount === 0
              text: root.busy
                ? "Waiting for the first step…"
                : "Nothing yet — the steps of the next answer show up here."
              color: Qt.alpha(Color.popups.text, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Rectangle {
              visible: root.statChips.length > 0
              Layout.fillWidth: true
              implicitHeight: Math.max(1, Style.normalBorderWidth)
              color: Qt.alpha(Color.popups.text, 0.10)
            }

            // Tokens, cost and account usage — the numbers you want once in
            // a while, parked where they cost nothing until you open this.
            Flow {
              visible: root.statChips.length > 0
              Layout.fillWidth: true
              spacing: Style.space(14)

              Repeater {
                model: root.statChips

                Row {
                  required property var modelData
                  spacing: Style.space(5)

                  Text {
                    text: modelData.k
                    color: Qt.alpha(Color.popups.text, 0.35)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: modelData.v
                    color: modelData.warn ? Color.urgent : Qt.alpha(Color.popups.text, 0.75)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
        }

        // Collapsed settings drawer: assistant + voice pickers.
        Text {
          id: settingsHeader
          text: (root.settingsOpen ? "▾" : "▸") + "  Settings"
          color: Qt.alpha(Color.popups.text, settingsMouse.containsMouse ? 0.9 : 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Layout.fillWidth: true

          MouseArea {
            id: settingsMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.settingsOpen = !root.settingsOpen
              keyCatcher.forceActiveFocus()
            }
          }
        }

        // Settings drawer: capped height, scrolls on its own.
        Flickable {
          visible: root.settingsOpen
          Layout.fillWidth: true
          implicitHeight: Math.min(settingsCol.implicitHeight, Style.space(210))
          contentWidth: width
          contentHeight: settingsCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: settingsCol
            width: parent.width
            spacing: Style.space(12)

            // Assistant on the left, that assistant's model on the right.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Dropdown {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                label: "Assistant"
                options: root.agentOptions
                value: root.agent
                onChanged: function(newValue) { root.selectAgent(newValue) }
              }

              Dropdown {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                label: "Model"
                options: root.modelOptions
                value: root.model
                onChanged: function(newValue) { root.selectModel(newValue) }
              }
            }

            Dropdown {
              Layout.fillWidth: true
              label: "Voice"
              options: root.voiceOptions
              value: root.voice
              onChanged: function(newValue) { root.selectVoice(newValue) }
            }

            SettingSwitch {
              label: "Thinking sound"
              detail: "A soft pad while the agent works"
              on: root.toneEnabled
              onToggled: root.toggleTone()
            }

            SettingSwitch {
              label: "Answer cards by voice"
              detail: "Say “allow” or “deny” instead of pressing a key"
              on: root.voiceApproval
              onToggled: root.toggleVoiceApproval()
            }
          }
        }
      }
    }
  }
}
