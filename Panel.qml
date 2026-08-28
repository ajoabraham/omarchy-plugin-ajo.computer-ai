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
// live mic RMS while listening and the reply audio's RMS timeline while
// speaking. While the agent works the bars retract and the gyre takes over
// — sweeping arcs, an elapsed clock, and the newest step the agent took —
// because a turn can run for minutes and a still orb reads as a hang.
// Keys (Enter/Space to speak, Ctrl+I for the activity log, Esc to close)
// only act while the window has keyboard focus, like any other window.
// Summoned by hotkey via `omarchy-shell shell summon ajo.computer-ai
// '{"listen": true}'`; payload {"say": "text"} speaks arbitrary text.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  // The shell stamps the plugin's own directory onto its manifest, so the
  // panel locates its scripts wherever it was actually installed rather than
  // assuming the canonical path — a dev symlink under another name included.
  // The literal stays as a fallback in case a shell build doesn't stamp it.
  readonly property string pluginDir: (manifest && manifest.__sourceDir)
    ? String(manifest.__sourceDir).replace(/\/+$/, "")
    : home + "/.config/omarchy/plugins/ajo.computer-ai"
  readonly property string binDir: pluginDir + "/bin"
  readonly property string recFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/computer-ai-question.wav"

  property bool opened: false
  property bool closingFromHost: false
  // idle | listening | transcribing | thinking | speaking
  property string phase: "idle"
  // The agent is off doing something and there is nothing to hear.
  readonly property bool busy: phase === "thinking" || phase === "transcribing"
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

  // Type-to-ask: when true the panel shows a text field instead of listening;
  // submitting skips record+transcribe and hands the text straight to the
  // agent. Toggle with '/'.
  property bool typing: false

  // A soft ambient tone plays while the agent is thinking (off if other audio
  // is already going). Toggle in Settings; persisted as tone_enabled.
  property bool toneEnabled: true

  // --- what the agent is doing right now ---

  // Ctrl+I opens the activity drawer. Adapters that can watch their harness
  // append a line per step to COMPUTER_ACTIVITY_FILE (see agents/README);
  // the panel tails it, so a long run shows its work instead of nothing.
  property bool activityOpen: false
  // Newest non-trivial step, shown under the orb.
  property var lastActivity: null
  // Wall-clock seconds this turn has been working — the one number that
  // separates "still going" from "stuck".
  property int elapsedS: 0
  property double turnStartedMs: 0

  // Token accounting, all of it reported by the harness rather than
  // guessed here. `ctx` is what the latest API call actually carried — it
  // grows as tool results pile up, so it doubles as a sign of life. Output
  // tokens are only trustworthy from the end-of-turn summary: the
  // per-message usage in the stream is a partial snapshot and does not sum
  // to the total, so accumulating it would show a confidently wrong number.
  property int turnCtx: 0
  property int ctxWindow: 0       // learned from a completed turn, then kept
  property var turnSummary: null
  property var limits: null       // account usage windows, if the plan reports them

  function fmtTokens(n) {
    var v = Number(n) || 0
    if (v < 1000) return String(v)
    if (v < 1000000) return (v / 1000).toFixed(v < 10000 ? 1 : 0) + "k"
    var m = v / 1000000
    // Trailing zeros make a round window read as false precision: 1M, not 1.00M.
    return (m >= 10 ? m.toFixed(0) : m.toFixed(2).replace(/\.?0+$/, "")) + "M"
  }

  function pctLabel(frac) {
    var v = Math.round(100 * (Number(frac) || 0))
    return (v < 1 && frac > 0 ? "<1" : String(v)) + "%"
  }

  // The drawer's status strip. Only chips whose numbers actually arrived
  // are built, so nothing shows a placeholder zero.
  readonly property var statChips: {
    var out = []
    if (turnCtx > 0) {
      out.push({ k: "ctx", v: fmtTokens(turnCtx)
        + (ctxWindow > 0 ? " / " + fmtTokens(ctxWindow)
                           + "  " + Math.round(100 * turnCtx / ctxWindow) + "%" : ""),
        warn: false })
    }
    var sum = turnSummary
    if (sum) {
      if (Number(sum.tout) > 0) out.push({ k: "out", v: fmtTokens(sum.tout), warn: false })
      if (Number(sum.cread) > 0) out.push({ k: "cached", v: fmtTokens(sum.cread), warn: false })
      if (Number(sum.cost) > 0) out.push({ k: "cost", v: "$" + Number(sum.cost).toFixed(3), warn: false })
      if (String(sum.session || "") !== "") out.push({ k: "session", v: String(sum.session), warn: false })
    }
    if (limits) {
      if (limits.five_hour !== null && limits.five_hour !== undefined)
        out.push({ k: "5h", v: pctLabel(limits.five_hour), warn: Number(limits.five_hour) >= 0.8 })
      if (limits.seven_day !== null && limits.seven_day !== undefined)
        out.push({ k: "7d", v: pctLabel(limits.seven_day), warn: Number(limits.seven_day) >= 0.8 })
      // The reset time only matters once you are close enough to care.
      if (Number(limits.five_hour) >= 0.5 && Number(limits.resets) > 0)
        out.push({ k: "resets", warn: false,
          v: Qt.formatTime(new Date(Number(limits.resets) * 1000), "HH:mm") })
    }
    return out
  }

  function elapsedLabel() {
    var m = Math.floor(elapsedS / 60)
    var sec = elapsedS % 60
    return m + ":" + (sec < 10 ? "0" : "") + sec
  }

  onBusyChanged: {
    if (busy) {
      turnStartedMs = Date.now()
      elapsedS = 0
      activityModel.clear()
      lastActivity = null
      turnCtx = 0
      turnSummary = null
      // Start the ambient tone (the script itself bails if other audio plays).
      if (toneEnabled && !toneProc.running) toneProc.running = true
    } else {
      // Leaving thinking → the reply is about to speak; the script fades out.
      if (toneProc.running) toneProc.running = false
    }
  }

  // Setting running=false sends SIGTERM; thinking-tone.sh traps it and fades.
  Process {
    id: toneProc
    command: [binDir + "/thinking-tone.sh"]
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.busy
    onTriggered: root.elapsedS = Math.floor((Date.now() - root.turnStartedMs) / 1000)
  }

  // The orb's rust ramp, shared by the bars, the swarm and the gyre.
  readonly property color rust: Qt.rgba(183 / 255, 65 / 255, 14 / 255, 1)
  readonly property color ember: Qt.rgba(245 / 255, 177 / 255, 66 / 255, 1)

  // --- audio levels driving the orb ---

  // Live mic RMS in dB while listening (~20 samples/s from miclevel.sh).
  property real micDb: -90
  // Voice-activity endpointing. Speech only counts after 3 consecutive loud
  // frames (150ms) so the capture-stream's opening click or a cough can't
  // arm the endpointer, and the first 600ms are ignored entirely as stream
  // warm-up. The two thresholds below are the tuning knobs:
  //   speechThresholdDb  — quieter than this counts as silence. Sits well
  //                        above the room's noise floor but below speech, so
  //                        between-word dips don't read as a pause.
  //   endSilenceMs       — sustained silence after speech that ends the turn.
  //                        Raise it if it cuts you off mid-sentence; lower it
  //                        for a snappier hand-off. (Enter always sends now.)
  // Defaults; refreshMic() replaces them from computer.json (mic_threshold_db,
  // mic_end_silence_ms) when the calibration tool has written values there.
  // Re-read at the start of every turn, so a tweak applies to the very next
  // question without restarting the shell or closing the panel.
  property real speechThresholdDb: -50
  property real endSilenceMs: 2200
  // No speech heard at all for this long: give up and return to idle.
  property real noSpeechTimeoutMs: 10000
  property bool heardSpeech: false
  property real silenceMs: 0
  property int loudStreak: 0
  property real listenedMs: 0
  // Per-chunk RMS timeline of the reply audio; stepped by speechTimer.
  // chunkFrac* map the current chunk onto the whole reply text for the
  // teleprompter (set by speak.sh's FRAC lines).
  property var speechLevels: []
  property int speechIndex: -1
  property real chunkFracStart: 0
  property real chunkFracEnd: 1

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
      if (!window.visible) return
      swarm.requestPaint()
      if (gyre.visible) gyre.requestPaint()
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
    if (phase === "thinking")
      return agentLabel + " is working — Enter cancels, Ctrl+I for details"
    if (phase === "speaking") return "Speaking — Enter interrupts"
    if (error !== "") return error
    if (response !== "") return "Press Enter to ask a follow-up · / to type"
    return "Press Enter to speak · / to type"
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
    refreshMic()
    if (!activityProc.running) activityProc.running = true
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
    if (activityProc.running) activityProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    micDb = -90
    phase = "idle"
    transcript = ""
    response = ""
    error = ""
    activityModel.clear()
    lastActivity = null
    typing = false
    if (inputEdit) inputEdit.text = ""
    if (toneProc.running) toneProc.running = false
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
    refreshMic()
    phase = "listening"
    recProc.command = [binDir + "/record.sh", recFile, "60"]
    recProc.running = true
  }

  function stopListening() {
    // SIGTERM makes ffmpeg finalize the WAV; the pipeline continues onExited.
    if (recProc.running) recProc.running = false
  }

  function activate() {
    if (typing) return
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
    refreshGrants()
  }

  // --- typing a message instead of speaking ---

  function enterTyping() {
    if (phase === "listening" || phase === "transcribing" || phase === "thinking") return
    if (speakProc.running) speakProc.running = false   // stop the voice to type
    typing = true
    Qt.callLater(function() { inputEdit.forceActiveFocus() })
  }

  function cancelTyping() {
    typing = false
    inputEdit.text = ""
    keyCatcher.forceActiveFocus()
  }

  // Submit typed text — the record→transcribe steps are skipped; from here it
  // is exactly a spoken turn, so the typed text shows as the transcript quote.
  function submitText(text) {
    var t = String(text || "").replace(/^\s+|\s+$/g, "")
    if (t === "") return
    typing = false
    inputEdit.text = ""
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    expectedStop = false
    transcript = t
    response = ""
    error = ""
    phase = "thinking"
    askProc.command = [binDir + "/ask.sh", t, turnMode]
    askProc.running = true
    keyCatcher.forceActiveFocus()
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
    var agentsDir = root.pluginDir + "/agents"
    settingsProc.command = ["bash", "-c",
      "cd \"$HOME/.local/share/computer-ai/voices\" 2>/dev/null && ls -1 *.onnx 2>/dev/null | sed 's/\\.onnx$//'; " +
      "[ -f \"$HOME/.local/share/computer-ai/kokoro/kokoro-v1.0.onnx\" ] && printf 'kokoro:%s\\n' af_heart af_bella af_sky am_michael am_puck bf_emma bf_isabella bm_george bm_fable; " +
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

  function refreshMic() {
    if (!micProc.running) micProc.running = true
  }

  Process {
    id: micProc
    command: ["bash", "-c",
      "jq -r '[(.mic_threshold_db // \"\"), (.mic_end_silence_ms // \"\"), (.tone_enabled // \"\")] | @tsv' " +
      "\"$HOME/.config/omarchy/computer.json\" 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text || "").trim().split("\t")
        var thr = parseFloat(parts[0])
        var sil = parseFloat(parts[1])
        if (!isNaN(thr)) root.speechThresholdDb = Math.max(-70, Math.min(-20, thr))
        if (!isNaN(sil)) root.endSilenceMs = Math.max(800, Math.min(5000, sil))
        var te = String(parts[2] || "").trim()
        if (te !== "") root.toneEnabled = (te !== "false")
      }
    }
  }

  function resolveGrant(allowIt) {
    if (grantAct.running || pendingGrant === null) return
    grantAct.command = [binDir + "/apply-grant.sh", allowIt ? "allow" : "deny"]
    grantAct.running = true
    if (allowIt && phase === "idle" && !speakProc.running) say("Permission granted.")
  }

  Process {
    id: grantProbe
    command: ["bash", "-c", "head -n1 \"$HOME/.local/share/computer-ai/state/pending-grants.jsonl\" 2>/dev/null"]
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

  // --- live activity ---

  ListModel { id: activityModel }

  // -n 0 starts at the end of the file, so opening the panel never replays
  // a stale turn; ask.sh truncates the log before each turn and -F picks
  // that up. Adapters that can't stream simply never write to it.
  Process {
    id: activityProc
    command: ["bash", "-c",
      "tail -n 0 -F -s 0.2 \"$HOME/.local/share/computer-ai/state/activity.jsonl\" 2>/dev/null"]
    stdout: SplitParser {
      onRead: function(line) { root.pushActivity(line) }
    }
  }

  function pushActivity(line) {
    var ev = null
    try { ev = JSON.parse(String(line)) } catch (e) { return }
    if (!ev || !ev.kind) return
    // usage/limits/summary are state, not steps — they update the numbers
    // without adding a row to scroll past.
    if (ev.kind === "usage") { root.turnCtx = Number(ev.ctx) || root.turnCtx; return }
    if (ev.kind === "limits") { root.limits = ev; return }
    if (ev.kind === "summary") {
      root.turnSummary = ev
      if (Number(ev.window) > 0) root.ctxWindow = Number(ev.window)
      return
    }
    activityModel.append({
      kind: String(ev.kind),
      label: String(ev.label || ""),
      detail: String(ev.detail || "")
    })
    // Scrollback, not state — keep the drawer's memory flat on long runs.
    while (activityModel.count > 300) activityModel.remove(0)
    if (ev.kind !== "meta") root.lastActivity = ev
    // Every tool call kicks the orb, so real progress is visible from
    // across the room without reading a word.
    if (ev.kind === "tool" && window.visible) gyre.ping()
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
        if (root.heardSpeech && root.silenceMs >= root.endSilenceMs) {
          console.log("computer: endpoint — silence after speech at", root.listenedMs, "ms")
          root.stopListening()
        } else if (!root.heardSpeech && root.silenceMs >= root.noSpeechTimeoutMs) {
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
      if (root.expectedStop || !root.opened) { root.refreshGrants(); return }
      if (exitCode !== 0 || root.response === "") {
        root.error = root.agentLabel + " didn't answer — try again"
        root.phase = "idle"
        // Nothing will be spoken, so there is nothing to wait for.
        root.refreshGrants()
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
        // Sentence-streamed replies arrive as repeating CHUNK/LEVEL*/PLAY
        // groups: each chunk resets the level timeline so the orb tracks
        // the sentence that's actually playing.
        if (line === "CHUNK") {
          speechTimer.stop()
          root.speechLevels = []
          root.speechIndex = -1
          return
        }
        if (line.indexOf("FRAC ") === 0) {
          var fr = line.slice(5).split(" ")
          root.chunkFracStart = parseFloat(fr[0]) || 0
          root.chunkFracEnd = parseFloat(fr[1]) || 1
          return
        }
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
      // Ask, then show: the agent explains the request out loud and the
      // card lands as it finishes — including when you cut it off with
      // Enter, which is still an answer to the question.
      root.refreshGrants()
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

  function toggleTone() {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    toneEnabled = !toneEnabled
    setConfigProc.command = [binDir + "/config-set.sh", "tone_enabled", toneEnabled ? "true" : "false"]
    setConfigProc.running = true
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

    // The panel is sized by what is in it: opening the activity drawer, the
    // settings or a grant card makes it taller, closing them makes it short
    // again. Only the compositor can resize a mapped floating window — a
    // plain `height` write after map is ignored — and it does that by
    // enforcing the client's min/max. So *both* bounds track the content:
    // a growing minimum alone can push the window open but never pull it
    // back. The capped regions inside keep the total bounded, and the floor
    // keeps the orb from ever being clipped.
    readonly property int fitHeight: Math.max(Style.space(380),
      Math.min(Style.space(1000), Math.round(content.implicitHeight + Style.space(48))))

    implicitHeight: fitHeight
    // Width stays adjustable; only height is pinned to the content.
    minimumSize: Qt.size(Style.space(440), fitHeight)
    maximumSize: Qt.size(Style.space(980), fitHeight)

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
        if (event.key === Qt.Key_I && (event.modifiers & Qt.ControlModifier)) {
          root.activityOpen = !root.activityOpen
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
              var t = root.animPhase * (1 + 1.6 * surge)

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

        // Permission-request card: the human gate for privilege escalation.
        // Capped in height; long requests scroll inside the card without
        // moving the rest of the panel.
        Rectangle {
          visible: root.pendingGrant !== null
          opacity: root.pendingGrant !== null ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
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
            text: root.response
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
                text: activityModel.count + (activityModel.count === 1 ? " step" : " steps")
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
              model: activityModel
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
              visible: activityModel.count === 0
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

            // Ambient "thinking" tone on/off.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                text: "Thinking sound"
                color: Qt.alpha(Color.popups.text, 0.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                Layout.fillWidth: true
              }

              Rectangle {
                implicitWidth: Style.space(58)
                implicitHeight: Style.space(24)
                radius: height / 2
                color: root.toneEnabled ? Qt.alpha(root.ember, 0.22)
                                        : Qt.alpha(Color.popups.text, 0.08)
                border.width: Math.max(1, Style.normalBorderWidth)
                border.color: root.toneEnabled ? Qt.alpha(root.ember, 0.6)
                                               : Qt.alpha(Color.popups.text, 0.2)
                Behavior on color { ColorAnimation { duration: 150 } }

                Rectangle {
                  width: Style.space(18); height: width; radius: width / 2
                  y: (parent.height - height) / 2
                  x: root.toneEnabled ? parent.width - width - Style.space(3) : Style.space(3)
                  color: root.toneEnabled ? root.ember : Qt.alpha(Color.popups.text, 0.5)
                  Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                  Behavior on color { ColorAnimation { duration: 150 } }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleTone()
                }
              }
            }
          }
        }
      }
    }
  }
}
