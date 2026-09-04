// Turning a spoken sentence into an answer to a permission card.
//
// The panel asks two kinds of question — "may I have this capability?" and
// "shall I do this one thing?" — and both were answered by keyboard or
// mouse only, which is an odd place for a voice assistant to insist on a
// keypress. This is the vocabulary that lets you just say it.
//
// Two rules shape the lists below, and they are not symmetric:
//
//   Approving is exact. The whole utterance, once punctuation and courtesy
//   words are stripped, has to BE one of the approval phrases. "yes" counts;
//   "yes but tell me what it does first" does not, and is treated as a
//   question rather than a yes.
//
//   Refusing is generous. A refusal only has to START with one of the
//   refusal phrases, because when the two failure modes are "the user has to
//   repeat themselves" and "something happened that they did not agree to",
//   only one of them matters.
//
// Anything that matches neither is not a decision at all: the caller leaves
// the card up and treats the words as ordinary speech.

var APPROVALS = [
  "allow", "allow it", "allow that", "allow this",
  "yes", "yep", "yeah", "yes please",
  "approve", "approve it", "approved",
  "confirm", "confirmed",
  "go ahead", "do it", "proceed", "continue",
  "grant it", "permit it", "accept",
  "sure", "okay", "ok", "fine",
  "affirmative", "make it so", "engage"
]

var REFUSALS = [
  "deny", "deny it", "deny that", "deny this",
  "no", "nope", "no thanks", "no thank you",
  "refuse", "reject", "decline", "declined",
  "cancel", "cancel it", "stop", "stop it",
  "dont", "do not", "dont do it", "do not do it",
  "never mind", "nevermind", "forget it", "not now",
  "negative", "belay that", "abort"
]

// Speech-to-text hands us capitals, commas and full stops that no phrase
// list should have to know about. Apostrophes go too, so "don't" and "dont"
// are the same word.
function normalize(text) {
  return String(text === undefined || text === null ? "" : text)
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9 ]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

// Politeness and hesitation carry no meaning here, and the transcriber is
// fond of both. "um, allow it please" is "allow it".
function strip(words) {
  var lead = ["um", "uh", "erm", "hey", "computer", "so", "well", "please"]
  var tail = ["please", "thanks", "thank you", "computer"]
  var out = normalize(words)
  var changed = true
  while (changed) {
    changed = false
    for (var i = 0; i < lead.length; i++) {
      if (out === lead[i]) return ""
      if (out.indexOf(lead[i] + " ") === 0) {
        out = out.slice(lead[i].length + 1)
        changed = true
      }
    }
    for (var j = 0; j < tail.length; j++) {
      var suffix = " " + tail[j]
      if (out.length > suffix.length && out.lastIndexOf(suffix) === out.length - suffix.length) {
        out = out.slice(0, out.length - suffix.length)
        changed = true
      }
    }
  }
  return out
}

// "allow" | "deny" | "" — the empty string meaning "this was not an answer".
function decide(text) {
  var said = strip(text)
  if (said === "") return ""

  for (var i = 0; i < APPROVALS.length; i++) {
    if (said === APPROVALS[i]) return "allow"
  }
  for (var j = 0; j < REFUSALS.length; j++) {
    if (said === REFUSALS[j]) return "deny"
    if (said.indexOf(REFUSALS[j] + " ") === 0) return "deny"
  }
  return ""
}

// What the panel offers as an example, so the card and the docs cannot
// drift from the list above.
function examples() {
  return { allow: "allow", deny: "deny" }
}
