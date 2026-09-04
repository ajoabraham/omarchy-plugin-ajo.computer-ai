// Phrase matching for spoken approvals: does "allow" answer the card, and
// does everything that only sounds like a yes get left alone?
//
//   node tests/decisions.js
//
// Decisions.js is a QML JavaScript resource (the same shape the Omarchy
// shell uses for its own model files), so it is loaded here as source and
// evaluated rather than imported.
const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "..", "Decisions.js"), "utf8");
const decide = new Function(src + "; return decide;")();

// The asymmetry is the point: approving takes the whole utterance, refusing
// only takes the opening. Half the cases below are things that must NOT be
// read as an answer.
const cases = [
  // plainly yes
  ["allow", "allow"],
  ["Allow it.", "allow"],
  ["allow that", "allow"],
  ["yes", "allow"],
  ["Yes, please.", "allow"],
  ["yep", "allow"],
  ["approve", "allow"],
  ["approved", "allow"],
  ["go ahead", "allow"],
  ["Go ahead!", "allow"],
  ["do it", "allow"],
  ["confirm", "allow"],
  ["okay", "allow"],
  ["OK", "allow"],
  ["sure", "allow"],
  ["make it so", "allow"],
  ["um, allow it please", "allow"],
  ["hey computer, yes", "allow"],

  // plainly no
  ["deny", "deny"],
  ["Deny it.", "deny"],
  ["no", "deny"],
  ["No.", "deny"],
  ["nope", "deny"],
  ["no thanks", "deny"],
  ["cancel", "deny"],
  ["stop it please", "deny"],
  ["never mind", "deny"],
  ["nevermind", "deny"],
  ["don't", "deny"],
  ["do not do that", "deny"],
  ["belay that", "deny"],
  ["negative", "deny"],
  // a refusal only has to start like one — erring toward not acting
  ["no, don't do that", "deny"],
  ["no I'd rather you didn't", "deny"],
  ["stop, that's not what I meant", "deny"],

  // NOT an answer: these must leave the card up and be treated as speech
  ["", ""],
  ["yes but tell me what it does first", ""],
  ["yes if it's safe", ""],
  ["allow me to explain something", ""],
  ["I know that", ""],
  ["what does that even do?", ""],
  ["okay so what is the weather", ""],
  ["can you confirm the meeting time", ""],
  ["approve the pull request on github", ""],
  ["tell me about the no fly zone", ""],
  ["do it later when I'm back", ""],
  ["sure, but first check my calendar", ""],
];

let failed = 0;
for (const [input, want] of cases) {
  const got = decide(input);
  if (got !== want) {
    failed++;
    console.log(`  FAIL ${JSON.stringify(input)} -> ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`);
  }
}
console.log(`  ${cases.length - failed}/${cases.length} phrase cases pass`);
process.exit(failed === 0 ? 0 : 1);
