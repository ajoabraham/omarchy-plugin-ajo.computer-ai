import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Computer voice assistant: a floating window (move it with Super+drag,
// close with Esc or the window button) that runs one conversation turn as a
// pipeline of processes —
// record (ffmpeg) → transcribe (voxtype) → ask (claude/grok) → speak (tts).
// Its centerpiece is an orb of radial bars driven by real audio levels:
// live mic RMS while listening, the reply audio's RMS timeline while
// speaking, and a rotating chase while transcribing/thinking.
// Keys (Enter/Space to speak, Esc to close) only act while the window has
// keyboard focus, like any other window.
// Summoned by hotkey via `omarchy-shell shell summon ajo.computer-ai
// '{"listen": true}'`; payload {"say": "text"} speaks arbitrary text.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string binDir: home + "/.config/omarchy/plugins/ajo.computer-ai/bin"
  readonly property string recFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/computer-question.wav"

  property bool opened: false
  property bool closingFromHost: false
  // idle | listening | transcribing | thinking | speaking
  property string phase: "idle"
  property string transcript: ""
  property string response: ""
  property string error: ""
  property bool expectedStop: false

  property var voiceOptions: []
  property string voice: ""
  property string agent: "claude"
  property bool settingsOpen: false
  // First pending permission request from the agent ({rule, reason} or
  // null). The agent can only queue requests; approval happens here —
  // click Allow/Deny or press A/D — and applies from the next question.
  property var pendingGrant: null
  // "new" for the first question after the panel opens (ask.sh applies its
  // grace window), "follow" for later turns — they resume the same agent
  // conversation, so follow-ups keep their context.
  property string turnMode: "new"

  // --- audio levels driving the orb ---

  // Live mic RMS in dB while listening (~20 samples/s from miclevel.sh).
  property real micDb: -90
  // Voice-activity endpointing: once speech has been heard, ~1.5s of
  // sustained silence ends the recording; 10s of nothing at all gives up.
  // Speech only counts after 3 consecutive loud frames (150ms) so the
  // capture-stream's opening click or a cough can't arm the endpointer,
  // and the first 600ms are ignored entirely as stream warm-up.
  readonly property real speechThresholdDb: -42
  property bool heardSpeech: false
  property real silenceMs: 0
  property int loudStreak: 0
  property real listenedMs: 0
  // Precomputed RMS timeline of the reply audio; stepped by speechTimer.
  property var speechLevels: []
  property int speechIndex: -1

  // Free-running phase for bar wobble / chase / idle drift.
  property real animPhase: 0

  function levelFromDb(db) {
    if (!isFinite(db)) return 0
    return Math.max(0, Math.min(1, (db + 52) / 38))
  }

  readonly property real targetLevel: {
    if (phase === "listening") return levelFromDb(micDb)
    if (phase === "speaking")
      return (speechIndex >= 0 && speechIndex < speechLevels.length)
        ? speechLevels[speechIndex] : 0
    if (phase === "transcribing" || phase === "thinking")
      return 0.22 + 0.14 * (1 + Math.sin(animPhase * 1.4)) / 2
    return 0.06
  }

  property real displayLevel: 0
  Behavior on displayLevel { NumberAnimation { duration: 80 } }
  onTargetLevelChanged: displayLevel = targetLevel

  Timer {
    id: animTimer
    interval: 40
    repeat: true
    running: root.opened
    onTriggered: {
      root.animPhase = (root.animPhase + 0.16) % (Math.PI * 2000)
      if (window.visible) swarm.requestPaint()
    }
  }

  Timer {
    id: speechTimer
    interval: 50
    repeat: true
    onTriggered: {
      if (root.speechIndex + 1 >= root.speechLevels.length) { stop(); return }
      root.speechIndex++
    }
  }

  // Harness adapters discovered from agents/*.sh populate the dropdown;
  // each adapter's --list-models fills the model dropdown beside it.
  property var agentOptions: [{ value: "claude", label: "Claude" }]
  property var modelOptions: []
  property string model: ""

  function agentLabelFor(name) {
    var known = { claude: "Claude", grok: "Grok", chatgpt: "ChatGPT" }
    if (known[name]) return known[name]
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  readonly property string agentLabel: agentLabelFor(agent)

  readonly property string statusLine: {
    if (phase === "listening") return heardSpeech
      ? "Listening… pause when finished (Enter sends now)"
      : "Listening… speak whenever you're ready"
    if (phase === "transcribing") return "Transcribing… Enter cancels"
    if (phase === "thinking") return "Asking " + agentLabel + "… Enter cancels"
    if (phase === "speaking") return "Speaking — Enter interrupts"
    if (error !== "") return error
    if (response !== "") return "Press Enter to ask a follow-up"
    return "Press Enter to speak"
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    closingFromHost = false
    opened = true
    turnMode = "new"
    window.visible = true
    refreshSettings()
    refreshGrants()
    if (payload.say) say(String(payload.say))
    else if (payload.listen !== false) startListening()
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
    opened = false
    expectedStop = true
    if (recProc.running) recProc.running = false
    if (transProc.running) transProc.running = false
    if (askProc.running) askProc.running = false
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    micDb = -90
    phase = "idle"
    transcript = ""
    response = ""
    error = ""
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "ajo.computer-ai")
    else close()
  }

  function startListening() {
    if (recProc.running || transProc.running || askProc.running) return
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    expectedStop = false
    transcript = ""
    response = ""
    error = ""
    micDb = -90
    heardSpeech = false
    silenceMs = 0
    loudStreak = 0
    listenedMs = 0
    phase = "listening"
    recProc.command = [binDir + "/record.sh", recFile, "60"]
    recProc.running = true
  }

  function stopListening() {
    // SIGTERM makes ffmpeg finalize the WAV; the pipeline continues onExited.
    if (recProc.running) recProc.running = false
  }

  function activate() {
    if (phase === "listening") { stopListening(); return }
    if (phase === "transcribing" || phase === "thinking") { cancelTurn(); return }
    if (phase === "speaking") { stopSpeaking(); return }
    startListening()
  }

  // Abort a transcription or agent call in flight and return to idle.
  function cancelTurn() {
    expectedStop = true
    if (transProc.running) transProc.running = false
    if (askProc.running) askProc.running = false
    phase = "idle"
    error = ""
  }

  // Cut the voice off mid-sentence; speakProc.onExited lands us in idle.
  function stopSpeaking() {
    if (speakProc.running) speakProc.running = false
  }

  // Speak arbitrary text (summon payload {"say": "..."}), bypassing the
  // question pipeline — also handy for other scripts that want a voice.
  function say(text) {
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    expectedStop = false
    response = text
    phase = "speaking"
    speakProc.command = [binDir + "/speak.sh", text]
    speakProc.running = true
  }

  property string probedAgent: ""
  // Set by selectAgent: the next settings probe ignores the saved model
  // and selects (and persists) the new assistant's default.
  property bool resetModelOnProbe: false

  function refreshSettings() {
    if (settingsProc.running) return
    probedAgent = agent
    var agentsDir = home + "/.config/omarchy/plugins/ajo.computer-ai/agents"
    settingsProc.command = ["bash", "-c",
      "cd \"$HOME/.local/share/computer/voices\" 2>/dev/null && ls -1 *.onnx 2>/dev/null | sed 's/\\.onnx$//'; " +
      "[ -f \"$HOME/.local/share/computer/kokoro/kokoro-v1.0.onnx\" ] && printf 'kokoro:%s\\n' af_heart af_bella af_sky am_michael am_puck bf_emma bf_isabella bm_george bm_fable; " +
      "for f in \"" + agentsDir + "/\"*.sh; do [ -x \"$f\" ] && printf 'agentopt %s\\n' \"$(basename \"$f\" .sh)\"; done; " +
      "\"" + agentsDir + "/" + agent + ".sh\" --list-models 2>/dev/null | sed 's/^/modelopt /'; " +
      "jq -r '.model_" + agent + " // empty' \"$HOME/.config/omarchy/computer.json\" 2>/dev/null | sed 's/^/curmodel /'; " +
      "jq -r '.voice // empty' \"$HOME/.config/omarchy/computer.json\" 2>/dev/null | sed 's/^/current /'; " +
      "jq -r '.agent // \"claude\"' \"$HOME/.config/omarchy/computer.json\" 2>/dev/null | sed 's/^/agent /'"]
    settingsProc.running = true
  }

  function refreshGrants() {
    if (!grantProbe.running) grantProbe.running = true
  }

  function resolveGrant(allowIt) {
    if (grantAct.running || pendingGrant === null) return
    grantAct.command = [binDir + "/apply-grant.sh", allowIt ? "allow" : "deny"]
    grantAct.running = true
    if (allowIt && phase === "idle" && !speakProc.running) say("Permission granted.")
  }

  Process {
    id: grantProbe
    command: ["bash", "-c", "head -n1 \"$HOME/.local/share/computer/state/pending-grants.jsonl\" 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try {
          var line = String(text || "").trim()
          if (line !== "") parsed = JSON.parse(line)
        } catch (e) {}
        root.pendingGrant = parsed
      }
    }
  }

  Process {
    id: grantAct
    onExited: root.refreshGrants()
  }

  // --- pipeline: record → transcribe → ask → speak ---

  Process {
    id: recProc
    // record.sh streams one RMS line per 50ms of captured audio while it
    // writes the WAV — the same stream feeds the orb and the endpointer.
    stdout: SplitParser {
      onRead: function(line) {
        var m = /RMS_level=(-?(?:[\d.]+|inf))/.exec(String(line))
        if (!m) return
        root.micDb = m[1] === "-inf" ? -90 : parseFloat(m[1])
        if (root.phase !== "listening") return
        root.listenedMs += 50
        if (root.listenedMs < 600) return   // stream warm-up: clicks, pops
        if (root.micDb > root.speechThresholdDb) {
          root.loudStreak += 1
          if (root.loudStreak >= 3) root.heardSpeech = true
          root.silenceMs = 0
          return
        }
        root.loudStreak = 0
        root.silenceMs += 50
        if (root.heardSpeech && root.silenceMs >= 1500) {
          console.log("computer: endpoint — silence after speech at", root.listenedMs, "ms")
          root.stopListening()
        } else if (!root.heardSpeech && root.silenceMs >= 10000) {
          console.log("computer: endpoint — no speech heard, giving up")
          root.stopListening()
        }
      }
    }
    onExited: function() {
      if (root.expectedStop || !root.opened) return
      root.phase = "transcribing"
      transProc.command = [root.binDir + "/transcribe.sh", root.recFile]
      transProc.running = true
    }
  }

  Process {
    id: transProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.expectedStop || !root.opened) return
        root.transcript = String(text || "").trim()
      }
    }
    onExited: function(exitCode) {
      if (root.expectedStop || !root.opened) return
      // Whisper hallucinates lone punctuation on silence; treat it as nothing.
      var heard = root.transcript.replace(/[^a-zA-Z0-9]/g, "")
      if (exitCode !== 0 || heard === "") {
        root.transcript = ""
        root.error = "I didn't catch that"
        root.phase = "idle"
        return
      }
      root.phase = "thinking"
      askProc.command = [root.binDir + "/ask.sh", root.transcript, root.turnMode]
      askProc.running = true
    }
  }

  Process {
    id: askProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.expectedStop || !root.opened) return
        root.response = String(text || "").trim()
      }
    }
    onExited: function(exitCode) {
      root.refreshGrants()
      if (root.expectedStop || !root.opened) return
      if (exitCode !== 0 || root.response === "") {
        root.error = root.agentLabel + " didn't answer — try again"
        root.phase = "idle"
        return
      }
      root.turnMode = "follow"
      root.phase = "speaking"
      speakProc.command = [root.binDir + "/speak.sh", root.response]
      speakProc.running = true
    }
  }

  Process {
    id: speakProc
    stdout: SplitParser {
      onRead: function(line) {
        line = String(line).trim()
        if (line.indexOf("LEVEL ") === 0) {
          var db = line.slice(6) === "-inf" ? -90 : parseFloat(line.slice(6))
          // Push without rebinding the whole array each line.
          root.speechLevels.push(root.levelFromDb(db))
          return
        }
        if (line === "PLAY") {
          root.speechIndex = 0
          speechTimer.restart()
        }
      }
    }
    onExited: function() {
      speechTimer.stop()
      root.speechIndex = -1
      root.speechLevels = []
      if (!root.opened) return
      if (root.phase === "speaking") root.phase = "idle"
    }
  }

  // --- settings plumbing ---

  Process {
    id: settingsProc
    // command is built per-run by refreshSettings() (it embeds the current
    // agent to fetch that adapter's model list).
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var options = []
        var agents = []
        var models = []
        var current = ""
        var curModel = ""
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line === "") continue
          if (line.indexOf("current ") === 0) current = line.slice(8)
          else if (line.indexOf("curmodel ") === 0) curModel = line.slice(9)
          else if (line.indexOf("modelopt ") === 0) {
            var parts = line.slice(9).split("|")
            models.push({ value: parts[0], label: parts[1] || parts[0] })
          }
          else if (line.indexOf("agentopt ") === 0) {
            var name = line.slice(9)
            agents.push({ value: name, label: root.agentLabelFor(name) })
          }
          else if (line.indexOf("agent ") === 0) root.agent = line.slice(6)
          else options.push(line)
        }
        root.voiceOptions = options
        if (agents.length > 0) root.agentOptions = agents
        root.modelOptions = models
        if (root.resetModelOnProbe && root.agent === root.probedAgent) {
          root.resetModelOnProbe = false
          root.model = models.length > 0 ? models[0].value : ""
          if (root.model !== "") {
            setModelProc.command = [root.binDir + "/config-set.sh", "model_" + root.agent, JSON.stringify(root.model)]
            setModelProc.running = true
          }
        } else {
          root.model = curModel !== "" ? curModel : (models.length > 0 ? models[0].value : "")
        }
        root.voice = current !== "" ? current
          : (options.indexOf("kokoro:af_heart") >= 0 ? "kokoro:af_heart" : (options[0] || ""))
        // The model list was fetched for the agent we knew before this
        // probe; if the config named a different one, refetch for it.
        if (root.agent !== root.probedAgent) root.refreshSettings()
      }
    }
  }

  Process {
    id: setConfigProc
  }

  function selectVoice(name) {
    // Selection hands keyboard focus back to the panel so Enter speaks
    // again instead of re-opening the dropdown.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (name === "" || name === voice) return
    voice = name
    setConfigProc.command = [binDir + "/config-set.sh", "voice", JSON.stringify(name)]
    setConfigProc.running = true
    // Preview the new voice unless the assistant is mid-answer.
    if (phase === "idle" && !speakProc.running) say("Voice engaged.")
  }

  function selectAgent(name) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (name === "" || name === agent) return
    agent = name
    setConfigProc.command = [binDir + "/config-set.sh", "agent", JSON.stringify(name)]
    setConfigProc.running = true
    // Reload the model dropdown for the newly selected harness — and snap
    // to that harness's default (best/latest) model rather than restoring
    // an older override.
    modelOptions = []
    resetModelOnProbe = true
    Qt.callLater(refreshSettings)
  }

  function selectModel(name) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (name === "" || name === model) return
    model = name
    setModelProc.command = [binDir + "/config-set.sh", "model_" + agent, JSON.stringify(name)]
    setModelProc.running = true
  }

  Process {
    id: setModelProc
  }

  // --- UI ---

  FloatingWindow {
    id: window
    title: "Computer"
    visible: false
    // Frosted glass: translucent panel background; Hyprland's blur does the
    // rest behind it.
    color: Qt.alpha(Color.popups.background, 0.84)
    implicitWidth: Style.space(620)
    // Starts short and grows with content (grant card, response, settings);
    // the capped regions inside keep this bounded, so the orb always fits.
    // Height is pushed imperatively from syncHeight(): compositor configure
    // events overwrite the property and would sever a declarative binding.
    implicitHeight: content.implicitHeight + Style.space(48)

    function syncHeight() {
      var target = Math.round(content.implicitHeight + Style.space(48))
      if (Math.abs(height - target) > 2) height = target
    }
    // Growing minimumSize is what actually resizes the mapped window: the
    // compositor enforces client minimums on floating windows, while plain
    // height writes after map are ignored.
    minimumSize: Qt.size(Style.space(440),
      Math.max(Style.space(380), content.implicitHeight + Style.space(48)))
    maximumSize: Qt.size(Style.space(980), Style.space(1000))

    // User-initiated close (window button / compositor). Tell the shell so
    // its open-panel state stays consistent and the next summon works.
    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide((root.manifest && root.manifest.id) || "ajo.computer-ai")
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.dismiss()
      Keys.onReturnPressed: root.activate()
      Keys.onEnterPressed: root.activate()
      Keys.onSpacePressed: root.activate()
      Keys.onPressed: function(event) {
        if (root.pendingGrant === null) return
        if (event.key === Qt.Key_A) { root.resolveGrant(true); event.accepted = true }
        else if (event.key === Qt.Key_D) { root.resolveGrant(false); event.accepted = true }
      }

      // Fixed column: the orb and status never scroll away. Regions that can
      // outgrow their slot (grant card, settings) scroll independently, and
      // the window itself grows with content up to its cap.
      ColumnLayout {
        id: content
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          leftMargin: Style.space(32)
          rightMargin: Style.space(32)
          topMargin: Style.space(24)
        }
        spacing: Style.space(16)

        onImplicitHeightChanged: Qt.callLater(window.syncHeight)

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

          function barHeight(i) {
            var p = root.phase
            if (p === "listening" || p === "speaking") {
              var wob = 0.4 + 0.6 * Math.abs(Math.sin(i * 2.399 + root.animPhase * (p === "speaking" ? 2.4 : 1.7)))
              return minBar + maxBar * level * wob
            }
            if (p === "transcribing" || p === "thinking") {
              var crest = Math.cos((i / barCount) * Math.PI * 2 - root.animPhase)
              return minBar + maxBar * 0.7 * Math.pow(Math.max(0, crest), 3)
            }
            return minBar + maxBar * 0.07 * (1 + Math.sin(i * 0.7 + root.animPhase * 0.5))
          }

          Layout.alignment: Qt.AlignHCenter
          Layout.topMargin: Style.space(4)
          implicitWidth: (ringRadius + maxBar + Style.space(6)) * 2
          implicitHeight: implicitWidth

          // Radial bars.
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
                        DENS: 235, CX: 224, CY: 158, ZOOM: 1.62 }
            })
            property var cur: null
            readonly property int points: 1200

            function targetPreset() {
              if (root.phase === "thinking" || root.phase === "transcribing") return presets.storm
              if (root.phase === "idle") return presets.cocoon
              return presets.spark
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
        }

        Text {
          text: root.statusLine
          color: root.error !== "" && root.phase === "idle"
            ? Color.urgent
            : Qt.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Layout.alignment: Qt.AlignHCenter
        }

        // Permission-request card: the human gate for privilege escalation.
        // Capped in height; long requests scroll inside the card without
        // moving the rest of the panel.
        Rectangle {
          visible: root.pendingGrant !== null
          Layout.fillWidth: true
          implicitHeight: Math.min(grantCol.implicitHeight + Style.space(24), Style.space(170))
          radius: Style.cornerRadius
          color: Qt.alpha(Color.accent, 0.10)
          border.color: Qt.alpha(Color.accent, 0.45)
          border.width: Math.max(1, Style.normalBorderWidth)

          Flickable {
            anchors.fill: parent
            anchors.margins: Style.space(12)
            contentWidth: width
            contentHeight: grantCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: grantCol
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "PERMISSION REQUEST"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2
            }

            Text {
              text: root.pendingGrant ? String(root.pendingGrant.rule || "") : ""
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WrapAnywhere
              Layout.fillWidth: true
            }

            Text {
              visible: root.pendingGrant !== null && String(root.pendingGrant.reason || "") !== ""
              text: root.pendingGrant ? String(root.pendingGrant.reason || "") : ""
              color: Qt.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              Layout.fillWidth: true
            }

            RowLayout {
              spacing: Style.space(16)

              Text {
                text: "[A] Allow"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.resolveGrant(true)
                }
              }

              Text {
                text: "[D] Deny"
                color: Qt.alpha(Color.popups.text, 0.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.resolveGrant(false)
                }
              }
            }
          }
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
              if (root.speechLevels.length > 1 && root.speechIndex > 0)
                return Math.min(1, root.speechIndex / (root.speechLevels.length - 1))
              return 0
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
            text: root.response
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            lineHeight: 1.5
            wrapMode: Text.Wrap
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
          }
        }
      }
    }
  }
}
