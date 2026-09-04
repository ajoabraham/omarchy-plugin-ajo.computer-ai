import QtQuick
import Quickshell
import Quickshell.Io
import "Decisions.js" as Decisions

// The assistant itself: one conversation, one agent, one voice — shared by
// every bar it appears on.
//
// A bar surface exists per monitor (Bar.qml builds one from
// `Variants { model: Quickshell.screens }`), so the widget entry point is
// instantiated once per screen. Everything that is genuinely singular — the
// running turn, the pipeline processes, the activity log, the IPC target —
// lives here instead, in the shell-wide service the plugin declares alongside
// its bar widget. Each Panel.qml is then a view onto this object, so a turn
// summoned on the laptop is the same turn the desktop's bar shows.
//
// A turn runs as a pipeline of processes —
// record (ffmpeg) → transcribe (voxtype) → ask (claude/grok) → speak (tts) —
// and never checks whether any panel is visible: only `expectedStop` halts
// it, so an answer finishes and is spoken with every panel closed.
Item {
  id: root

  // Injected by omarchy-shell (the plugin service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  // Services aren't handed their manifest's source directory either, so
  // resolve the plugin's own install location from this file's URL — robust
  // to a dev symlink under another name.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl(".")).replace(/\/+$/, "")
    return decodeURIComponent(u.replace(/^file:\/\//, ""))
  }
  readonly property string binDir: pluginDir + "/bin"

  // Where the microphone capture goes. XDG_RUNTIME_DIR is per-user and 0700;
  // the state directory (also 0700) is the fallback. /tmp is deliberately not
  // an option: it is shared and world-writable, and a fixed name there —
  // which is what this used to be — is a file another user can pre-create as
  // a symlink and then read your microphone through.
  readonly property string runtimeDir: {
    var xdg = Quickshell.env("XDG_RUNTIME_DIR")
    return (xdg && xdg !== "") ? xdg : (home + "/.local/share/computer-ai/state")
  }

  // A fresh unguessable name per turn — not a secret in itself, the 0700
  // directory is what keeps others out, but it removes the
  // pre-created-symlink race while the file is being written. Once there is
  // a transcript, transcribe.sh renames it to a single fixed name beside it,
  // because mic-calibrate.sh measures the turn you just spoke; so exactly
  // one capture is at rest at a time, and never more.
  property string recFile: ""

  function newRecFile() {
    var token = ""
    for (var i = 0; i < 4; i++)
      token += ("0000000" + Math.floor(Math.random() * 0x100000000).toString(16)).slice(-8)
    return runtimeDir + "/computer-ai-" + token + ".raw"
  }

  // --- views ----------------------------------------------------------------
  //
  // Every live Panel.qml registers itself here. The service needs them for
  // two things: to know whether any panel is on screen (animation that only
  // feeds a popup is idle work when none is), and to have somewhere to open
  // when the bar can't route a summon for us.

  property var views: []
  property int openViews: 0

  function registerView(view) {
    if (!view || views.indexOf(view) !== -1) return
    var next = views.slice()
    next.push(view)
    views = next
    recountOpenViews()
  }

  function unregisterView(view) {
    views = views.filter(function(v) { return v !== view })
    recountOpenViews()
  }

  function recountOpenViews() {
    var n = 0
    for (var i = 0; i < views.length; i++) if (views[i] && views[i].opened) n++
    openViews = n
  }

  // Show the panel on the screen the user is actually looking at. The bar
  // already knows how to pick it (an instance that is open already, else the
  // Hyprland-focused monitor); falling back to the first view only matters if
  // the bar is gone.
  function showPanel() {
    if (shell && shell.bar && typeof shell.bar.summonBarWidget === "function"
        && shell.bar.summonBarWidget("ajo.computer-ai")) return
    for (var i = 0; i < views.length; i++) {
      if (views[i] && typeof views[i].open === "function") { views[i].open(); return }
    }
  }

  function hidePanel() {
    for (var i = 0; i < views.length; i++) {
      if (views[i] && typeof views[i].close === "function") views[i].close()
    }
  }

  function togglePanel() {
    openViews > 0 ? hidePanel() : showPanel()
  }

  // Refresh the pickers/grants/mic — what a panel wants freshly read the
  // moment it becomes visible.
  function refreshOnOpen() {
    refreshSettings()
    refreshGrants()
    refreshMic()
  }

  // --- turn state -----------------------------------------------------------

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
  // First pending permission request from the agent ({rule, reason} or
  // null). The agent can only queue requests; approval happens in the panel —
  // click Allow/Deny or press A/D — and applies from the next question.
  property var pendingGrant: null
  // Set when the user allows a grant; once the queue drains the turn
  // auto-continues so they don't have to say "go ahead".
  property bool grantResumePending: false

  // Answering a card out loud, as an alternative to Y/N or a click — this is
  // a voice assistant, and reaching for the keyboard to say yes is a strange
  // thing for it to insist on. The card stays exactly as it was; this is a
  // second way to answer it, not a replacement, and Settings turns it off.
  //
  // The agent cannot use this to approve itself. The microphone is only ever
  // armed by a human gesture (the hotkey, or Enter in the panel), never by
  // anything the agent does, and the panel does not listen while the reply is
  // being spoken — so a reply that says the word "allow" is talking to nobody.
  property bool voiceApproval: true

  readonly property bool awaitingDecision: pendingConfirm !== null || pendingGrant !== null

  // What the current recording is for: a question for the agent, or an answer
  // to the card on screen while the turn it belongs to waits underneath.
  property string capture: ""
  property string capturePhase: ""
  // Shown under the card when something was heard but was not a yes or a no.
  property string decisionHint: ""

  // The tier-3 card: one specific action, waiting on one specific yes.
  // Unlike a grant, answering it approves nothing for next time — the script
  // that asked is blocked on this single answer and then forgets it.
  property var pendingConfirm: null
  // "new" for the first question after a fresh summon (ask.sh applies its
  // grace window), "follow" for later turns — they resume the same agent
  // conversation, so follow-ups keep their context.
  property string turnMode: "new"

  // Type-to-ask: when true the panel shows a text field instead of listening;
  // submitting skips record+transcribe and hands the text straight to the
  // agent. Shared rather than per-panel, so a draft started on one screen is
  // still there when the panel is reopened on another.
  property bool typing: false
  property string draft: ""

  // A soft ambient tone plays while the agent is thinking (off if other audio
  // is already going). Toggle in Settings; persisted as tone_enabled.
  property bool toneEnabled: true

  // --- what the agent is doing right now ---

  // Adapters that can watch their harness append a line per step to
  // COMPUTER_ACTIVITY_FILE (see agents/README); the service tails it, so a
  // long run shows its work instead of nothing.
  //
  // Newest non-trivial step, shown under the orb.
  property var lastActivity: null
  // Wall-clock seconds this turn has been working — the one number that
  // separates "still going" from "stuck".
  property int elapsedS: 0
  property double turnStartedMs: 0

  // Every tool call kicks the orb, so real progress is visible from across
  // the room without reading a word. Panels that are open answer it.
  signal toolPing()

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

  // Setting running=false sends SIGTERM; thinking-tone.sh execs ffmpeg so the
  // managed process IS the audio and dies with it.
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

  // --- audio levels driving the orb ---

  // Live mic RMS in dB while listening (~20 samples/s from record.sh).
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

  // Free-running phase for bar wobble / chase / idle drift. Lives here so
  // every screen's orb draws the same frame, and so the "thinking" pulse in
  // targetLevel keeps breathing with no panel open at all.
  property real animPhase: 0

  // Idle cycles slowly through several calm swarm moods so the resting orb
  // keeps evolving instead of sitting on one shape. The swarm cross-fades
  // toward whichever variant is current, so switching is a smooth morph.
  readonly property var idleVariants: ["cocoon", "halo", "lantern", "drift", "coil"]
  property string idleVariant: "cocoon"
  property int idleIndex: 0

  Timer {
    id: idleTimer
    interval: 14000            // ~14s per mood — a slow, unhurried drift
    repeat: true
    running: root.openViews > 0 && root.phase === "idle"
    onTriggered: {
      root.idleIndex = (root.idleIndex + 1) % root.idleVariants.length
      root.idleVariant = root.idleVariants[root.idleIndex]
    }
  }

  // --- bounds ---------------------------------------------------------------
  //
  // Every producer below feeds something that renders, is persisted, or ends
  // up in an argv: a transcript, a reply about to be spoken, a step in the
  // activity drawer, a permission record on the approval card. None of them
  // has a legitimate reason to be large, and each of them is written by
  // something this panel does not control — an agent, a harness, a page the
  // agent read. So they are clamped where they arrive rather than trusted to
  // be reasonable.
  readonly property int maxTranscriptChars: 2000
  readonly property int maxResponseChars: 8000
  readonly property int maxDraftChars: 8000
  readonly property int maxActivityLineBytes: 16000
  readonly property int maxActivityFieldChars: 400
  readonly property int maxRuleChars: 200
  readonly property int maxReasonChars: 300

  function clamp(text, limit) {
    var t = String(text === undefined || text === null ? "" : text)
    return t.length > limit ? t.slice(0, limit) : t
  }

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

  // Drives the orb canvases in every open panel, plus the thinking pulse
  // above — so it runs while a panel is up or while the agent is busy, and
  // stops when neither is true.
  Timer {
    id: animTimer
    interval: 40
    repeat: true
    running: root.openViews > 0 || root.busy
    onTriggered: root.animPhase = (root.animPhase + 0.16) % (Math.PI * 2000)
  }

  // Free-running phase for the bar-icon equalizer while speaking. Its own
  // timer (not animTimer, which idles with the popups) so the bars keep
  // bouncing on every bar even when no panel is open.
  property real barPhase: 0
  Timer {
    interval: 55
    repeat: true
    running: root.phase === "speaking" || root.phase === "listening"
    onTriggered: root.barPhase = (root.barPhase + 0.4) % (Math.PI * 2000)
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
    // A blocked action is the most urgent thing the panel can say: a script
    // is holding the turn open until this is answered.
    if (decisionHint !== "") return decisionHint
    if (pendingConfirm !== null)
      return voiceApproval && phase !== "listening"
        ? "Waiting on you — Y or N, or press End and say “allow” / “deny”"
        : "Waiting on you — Y to allow this once, N to refuse"
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

  // --- turn lifecycle -------------------------------------------------------

  // Hotkey entry point (End → summon.sh → IPC). Shows the panel on the
  // focused screen, and starts a fresh listening turn only when nothing is
  // already in flight — summoning while the agent is thinking or speaking
  // must not begin recording, it just brings the progress into view.
  function summon(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    showPanel()
    turnMode = "new"
    if (payload.say) { say(String(payload.say)); return }
    if (payload.listen === false) return
    // A card is up and the turn behind it is blocked: the hotkey means
    // "let me answer it", not "start something new".
    if (awaitingDecision && voiceApproval && phase !== "idle") {
      listenForDecision()
      return
    }
    if (phase === "idle") startListening()
  }

  // Stop every running process and reset turn state. Kept for a hard reset
  // (IPC or a future kill path); hiding a panel no longer calls this — a
  // turn survives every panel being closed.
  function teardown() {
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
    activityModel.clear()
    lastActivity = null
    typing = false
    draft = ""
    grantResumePending = false
    pendingConfirm = null
    capture = ""
    capturePhase = ""
    decisionHint = ""
  }

  // Stop whatever is happening right now (the "open panel + Enter" gesture,
  // also reachable by right-clicking any bar icon, or IPC `stop`).
  function stopAll() {
    if (phase === "listening") stopListening()
    else if (phase === "transcribing" || phase === "thinking") cancelTurn()
    else if (phase === "speaking") stopSpeaking()
  }

  // Answer the card on screen, if that is what was said. Returns false when
  // the words were not a decision at all, which leaves the card up and the
  // utterance free to be treated as ordinary speech.
  function applySpokenDecision(text) {
    if (!voiceApproval || !awaitingDecision) return false
    var verdict = Decisions.decide(text)
    if (verdict === "") return false
    // A blocked action outranks a queued capability, the same order the
    // keyboard uses: something is waiting on this one right now.
    if (pendingConfirm !== null) resolveConfirm(verdict === "allow")
    else resolveGrant(verdict === "allow")
    decisionHint = ""
    return true
  }

  // Listen for a yes or no while a turn is blocked on a confirmation card.
  // The turn keeps running underneath: this borrows the microphone, not the
  // pipeline, and puts `phase` back where it found it.
  function listenForDecision() {
    if (!voiceApproval || !awaitingDecision) return false
    if (recProc.running || transProc.running) return false
    capture = "decision"
    capturePhase = phase
    decisionHint = ""
    expectedStop = false
    micDb = -90
    heardSpeech = false
    silenceMs = 0
    loudStreak = 0
    listenedMs = 0
    refreshMic()
    phase = "listening"
    recFile = newRecFile()
    // A yes or no is short; a minute of recording is for a question.
    recProc.command = [binDir + "/record.sh", recFile, "20"]
    recProc.running = true
    return true
  }

  // Where a decision capture leaves the panel: back in the turn it
  // interrupted, unless that turn ended while the answer was being spoken.
  function endDecisionCapture() {
    var back = capturePhase
    capture = ""
    capturePhase = ""
    transcript = ""
    phase = (back !== "" && askProc.running) ? back : "idle"
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
    capture = "turn"
    phase = "listening"
    recFile = newRecFile()
    recProc.command = [binDir + "/record.sh", recFile, "60"]
    recProc.running = true
  }

  function stopListening() {
    // SIGTERM makes ffmpeg finalize the WAV; the pipeline continues onExited.
    if (recProc.running) recProc.running = false
  }

  // The Enter gesture, whichever panel it came from.
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
    // Whatever was blocked on a confirmation has just been killed with the
    // rest of the turn, so the card is answering nobody. Clearing it here
    // rather than trusting the dying script to say so keeps a dead question
    // off the panel.
    pendingConfirm = null
    capture = ""
    capturePhase = ""
    decisionHint = ""
    refreshGrants()
  }

  // --- typing a message instead of speaking ---

  function canType() {
    return phase !== "listening" && phase !== "transcribing" && phase !== "thinking"
  }

  function enterTyping() {
    if (!canType()) return
    if (speakProc.running) speakProc.running = false   // stop the voice to type
    typing = true
  }

  function cancelTyping() {
    typing = false
    draft = ""
  }

  // Submit typed text — the record→transcribe steps are skipped; from here it
  // is exactly a spoken turn, so the typed text shows as the transcript quote.
  function submitText(text) {
    var t = clamp(String(text || "").replace(/^\s+|\s+$/g, ""), maxDraftChars)
    if (t === "") return
    // Typing "allow" answers the card as readily as saying it does.
    if (applySpokenDecision(t)) {
      typing = false
      draft = ""
      return
    }
    typing = false
    draft = ""
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    expectedStop = false
    transcript = t
    response = ""
    error = ""
    phase = "thinking"
    if (!activityProc.running) activityProc.running = true
    askProc.command = [binDir + "/ask.sh", t, turnMode]
    askProc.running = true
  }

  // Cut the voice off mid-sentence; speakProc.onExited lands us in idle.
  function stopSpeaking() {
    if (speakProc.running) speakProc.running = false
  }

  // Speak arbitrary text (IPC `say`), bypassing the question pipeline — also
  // handy for other scripts that want a voice.
  function say(text) {
    var spoken = clamp(text, maxResponseChars)
    if (spoken === "") return
    if (speakProc.running) speakProc.running = false
    speechTimer.stop()
    speechLevels = []
    speechIndex = -1
    expectedStop = false
    response = spoken
    phase = "speaking"
    speakProc.command = [binDir + "/speak.sh", spoken]
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
      "jq -r '[(.mic_threshold_db // \"\"), (.mic_end_silence_ms // \"\"), (.tone_enabled // \"\"), " +
      "(.voice_approval // \"\")] | @tsv' " +
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
        var va = String(parts[3] || "").trim()
        if (va !== "") root.voiceApproval = (va !== "false")
      }
    }
  }

  function resolveGrant(allowIt) {
    if (grantAct.running || pendingGrant === null) return
    grantAct.command = [binDir + "/apply-grant.sh", allowIt ? "allow" : "deny"]
    grantAct.running = true
    if (allowIt) grantResumePending = true
  }

  // After the last queued grant is approved, pick the turn back up on its own.
  function resumeAfterGrants() {
    // Only when nothing is mid-flight (a reply may still be speaking — that is
    // fine, submitText stops it). Never interrupt an active turn.
    if (typing) return
    if (phase === "listening" || phase === "transcribing" || phase === "thinking") return
    submitText("The permission you asked for is approved now. Go ahead and finish what you were doing.")
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
          if (line !== "" && line.length <= root.maxActivityLineBytes) parsed = JSON.parse(line)
        } catch (e) {}
        // The queue file is written by the agent. What lands on the approval
        // card therefore has to be checked, not just parsed: a rule is one
        // short line of permission expression, and a reason is one line of
        // explanation — anything else is dropped rather than rendered.
        if (parsed !== null) {
          var rule = String(parsed.rule === undefined || parsed.rule === null ? "" : parsed.rule)
          if (rule === "" || rule.length > root.maxRuleChars || /[\r\n]/.test(rule)) {
            parsed = null
          } else {
            parsed = {
              rule: rule,
              reason: root.clamp(String(parsed.reason || "").replace(/[\r\n]+/g, " "),
                                 root.maxReasonChars)
            }
          }
        }
        root.pendingGrant = parsed
        if (parsed === null && root.grantResumePending) {
          root.grantResumePending = false
          Qt.callLater(root.resumeAfterGrants)
        }
      }
    }
  }

  Process {
    id: grantAct
    onExited: root.refreshGrants()
  }

  // Answer the tier-3 card. The card clears on the confirm-done line the
  // script emits as it unblocks, so a slow script never leaves a stale
  // question on screen — and never loses one either.
  function resolveConfirm(allowIt) {
    if (confirmAct.running || pendingConfirm === null) return
    confirmAct.command = [binDir + "/confirm-reply.sh", String(pendingConfirm.id),
                          allowIt ? "allow" : "deny"]
    confirmAct.running = true
    pendingConfirm = null
  }

  Process {
    id: confirmAct
  }

  // --- live activity ---

  ListModel { id: activityLog }

  // Exposed as `activityModel` so views can bind a ListView straight to it;
  // ids alone don't cross file boundaries.
  property alias activityModel: activityLog

  // -n 0 starts at the end of the file, so opening a panel never replays
  // a stale turn; ask.sh truncates the log before each turn and -F picks
  // that up. Adapters that can't stream simply never write to it. One tail
  // for the whole session, not one per monitor.
  Process {
    id: activityProc
    command: ["bash", "-c",
      "tail -n 0 -F -s 0.2 \"$HOME/.local/share/computer-ai/state/activity.jsonl\" 2>/dev/null"]
    stdout: SplitParser {
      onRead: function(line) { root.pushActivity(line) }
    }
  }

  Component.onCompleted: activityProc.running = true

  function pushActivity(line) {
    var raw = String(line)
    // A single step is a label and a short detail. Anything this size is a
    // malformed or hostile producer, and parsing it only costs memory.
    if (raw.length > maxActivityLineBytes) return
    var ev = null
    try { ev = JSON.parse(raw) } catch (e) { return }
    if (!ev || !ev.kind) return

    // A tier-3 gate: bin/confirm.sh is blocked on this, waiting for a human.
    // It rides the activity stream because the panel is already tailing it,
    // so the card appears mid-turn with no second watcher.
    if (ev.kind === "confirm") {
      var id = String(ev.id || "")
      if (!/^[0-9-]{1,64}$/.test(id)) return
      pendingConfirm = {
        id: id,
        label: clamp(ev.label, 80),
        detail: clamp(ev.detail, maxActivityFieldChars)
      }
      // The question is useless off-screen, and the script that asked it is
      // holding the turn open until it is answered.
      showPanel()
      return
    }
    if (ev.kind === "confirm-done") {
      decisionHint = ""
      if (pendingConfirm && pendingConfirm.id === String(ev.id || "")) pendingConfirm = null
      activityModel.append({
        kind: "meta",
        label: clamp(ev.label, 120),
        detail: clamp(ev.detail, maxActivityFieldChars)
      })
      return
    }
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
      kind: clamp(ev.kind, 32),
      label: clamp(ev.label, 120),
      detail: clamp(ev.detail, maxActivityFieldChars)
    })
    // Scrollback, not state — keep the drawer's memory flat on long runs.
    while (activityModel.count > 300) activityModel.remove(0)
    if (ev.kind !== "meta") root.lastActivity = ev
    if (ev.kind === "tool") root.toolPing()
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
      if (root.expectedStop) return
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
        if (root.expectedStop) return
        root.transcript = root.clamp(String(text || "").trim(), root.maxTranscriptChars)
      }
    }
    onExited: function(exitCode) {
      if (root.expectedStop) return
      // Whisper hallucinates lone punctuation on silence; treat it as nothing.
      var heard = root.transcript.replace(/[^a-zA-Z0-9]/g, "")

      // An answer to the card, not a question for the agent: resolve it and
      // hand the panel back to whatever it was doing.
      if (root.capture === "decision") {
        var answered = heard !== "" && root.applySpokenDecision(root.transcript)
        if (!answered) {
          root.decisionHint = heard === ""
            ? "I didn't catch that — say “allow” or “deny”, or use Y / N"
            : "That wasn't a yes or a no — say “allow” or “deny”, or use Y / N"
        }
        root.endDecisionCapture()
        return
      }

      if (exitCode !== 0 || heard === "") {
        root.transcript = ""
        root.error = "I didn't catch that"
        root.phase = "idle"
        return
      }

      // Idle with a card waiting: "allow" answers it instead of becoming the
      // next question. Anything else is a question, and the card stays.
      if (root.applySpokenDecision(root.transcript)) {
        root.transcript = ""
        root.capture = ""
        root.phase = "idle"
        return
      }

      root.capture = ""
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
        if (root.expectedStop) return
        // The reply is spoken and passed as an argument to speak.sh, so it is
        // bounded here as well as there.
        root.response = root.clamp(String(text || "").trim(), root.maxResponseChars)
      }
    }
    onExited: function(exitCode) {
      root.pendingConfirm = null
      if (root.expectedStop) { root.refreshGrants(); return }
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

  Process {
    id: setModelProc
  }

  function toggleVoiceApproval() {
    voiceApproval = !voiceApproval
    setConfigProc.command = [binDir + "/config-set.sh", "voice_approval",
                             voiceApproval ? "true" : "false"]
    setConfigProc.running = true
  }

  function toggleTone() {
    toneEnabled = !toneEnabled
    setConfigProc.command = [binDir + "/config-set.sh", "tone_enabled", toneEnabled ? "true" : "false"]
    setConfigProc.running = true
  }

  function selectVoice(name) {
    if (name === "" || name === voice) return
    voice = name
    setConfigProc.command = [binDir + "/config-set.sh", "voice", JSON.stringify(name)]
    setConfigProc.running = true
    // Preview the new voice unless the assistant is mid-answer.
    if (phase === "idle" && !speakProc.running) say("Voice engaged.")
  }

  function selectAgent(name) {
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
    if (name === "" || name === model) return
    model = name
    setModelProc.command = [binDir + "/config-set.sh", "model_" + agent, JSON.stringify(name)]
    setModelProc.running = true
  }

  // --- IPC: summon (hotkey), say, stop, and open/close/toggle ---
  //
  // The sole owner of the target. Registering this per bar widget meant one
  // monitor's copy won the target and the others were silently dropped by
  // Quickshell ("another handler is registered for target ajo.computer-ai"),
  // which is what made a hotkey summon light up one bar and leave the panel
  // on every other screen looking like a fresh, empty session.
  IpcHandler {
    target: "ajo.computer-ai"
    function open(): void { root.showPanel() }
    function close(): void { root.hidePanel() }
    function toggle(): void { root.togglePanel() }
    function summon(payload: string): void { root.summon(payload) }
    function say(text: string): void { root.showPanel(); root.say(text) }
    function stop(): void { root.stopAll() }
  }
}
