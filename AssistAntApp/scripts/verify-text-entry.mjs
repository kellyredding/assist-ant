#!/usr/bin/env node
// verify-text-entry.mjs — run the shipped JavaScript matcher against the same
// fixture table the Swift smoke target uses.
//
// This is a behaviour gate, not a syntax gate. validate-js.mjs proves the
// embedded literal parses; this proves it *agrees with Swift*. Two matchers
// implementing one rule in two languages will drift, and the drift is silent:
// a chord that stops working inside a WebView composer looks like a WebView
// quirk, not like a mismatched bitmask.
//
// It evaluates the real literal out of Views/TextEntryJS.swift rather than a
// copy, so what runs here is what ships. `window` is a bare object — the
// matcher touches no DOM beyond the event fields it reads, and `bind` is not
// exercised (that needs a real textarea, and stage 2 wires it).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { extractMarkedLiterals } from "./lib/swift-literals.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = join(SCRIPT_DIR, ".."); // .../GalaxyApp
const LITERAL_FILE = join(APP_ROOT, "AssistAntApp/Views/TextEntryJS.swift");
const LITERAL_NAME = "textEntryJS";
const FIXTURE = join(APP_ROOT, "fixtures/text-entry-cases.json");

// Must match Keystroke.Modifiers on the Swift side, and the bitmask the
// fixture table documents.
const MOD_COMMAND = 1;
const MOD_OPTION = 2;
const MOD_CONTROL = 4;
const MOD_SHIFT = 8;

let failures = 0;

function check(name, body) {
  let ok = false;
  try {
    ok = body();
  } catch (err) {
    console.log(`FAIL  ${name} — threw: ${err.message}`);
    failures++;
    return;
  }
  if (ok) {
    console.log(`PASS  ${name}`);
  } else {
    console.log(`FAIL  ${name}`);
    failures++;
  }
}

// --- Load the shipped literal ----------------------------------------

function loadMatcher() {
  const literals = extractMarkedLiterals(readFileSync(LITERAL_FILE, "utf8"));
  const found = literals.find((l) => l.name === LITERAL_NAME);

  if (!found) {
    throw new Error(
      `no marked literal named ${LITERAL_NAME} in ${LITERAL_FILE}`,
    );
  }
  if (found.error) {
    throw new Error(`${LITERAL_NAME}: ${found.error}`);
  }

  const sandbox = { window: {} };
  vm.createContext(sandbox);
  new vm.Script(found.js, { filename: `${LITERAL_NAME}` }).runInContext(
    sandbox,
  );

  if (!sandbox.window.GalaxyTextEntry) {
    throw new Error(`${LITERAL_NAME} did not define window.GalaxyTextEntry`);
  }
  return sandbox.window.GalaxyTextEntry;
}

/// A keydown event as the matcher sees it, built from the fixture's bitmask.
function eventFor(testCase) {
  return {
    code: testCase.code,
    metaKey: (testCase.modifiers & MOD_COMMAND) !== 0,
    altKey: (testCase.modifiers & MOD_OPTION) !== 0,
    ctrlKey: (testCase.modifiers & MOD_CONTROL) !== 0,
    shiftKey: (testCase.modifiers & MOD_SHIFT) !== 0,
  };
}

// --- Run --------------------------------------------------------------

let matcher;
try {
  matcher = loadMatcher();
} catch (err) {
  console.error(`\n✗ could not load the matcher — ${err.message}\n`);
  process.exit(1);
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));

for (const scenario of fixture.scenarios) {
  matcher.configure(scenario.bindings);
  for (const testCase of scenario.cases) {
    check(`${scenario.name}: ${testCase.name}`, () => {
      const resolved = matcher.actionFor(eventFor(testCase));
      // The matcher returns null for "not ours"; the fixture spells that as
      // JSON null, which parses to null too.
      return resolved === testCase.expect;
    });
  }
}

// Reconfiguring must replace the previous bindings outright rather than
// merging into them, or a settings change would leave stale bindings live.
check("configure replaces the previous bindings", () => {
  matcher.configure({
    submit: [{ code: "Enter", modifiers: MOD_COMMAND }],
    newline: [],
  });
  matcher.configure({ submit: [], newline: [] });
  return matcher.actionFor(eventFor({ code: "Enter", modifiers: MOD_COMMAND }))
    === null;
});

// The fail-safe contract: a document that never configures, or configures
// with a payload missing a list, must still submit and newline the way these
// composers did before the setting existed.
// The JS half of pinning the shipped default. KeystrokeSmoke holds the Swift
// half by asserting TextEntryBindings.default equals this same scenario.
// Without both, the two defaults could drift and every other check would
// still pass.
check("the module's own defaults are the fixture's shipped defaults", () => {
  const fresh = loadMatcher();
  const shipped = fixture.scenarios.find((s) => s.name === "shipped defaults");
  if (!shipped) return false;
  // An unconfigured module must resolve every default case exactly as a
  // configured one does.
  return shipped.cases.every((c) => fresh.actionFor(eventFor(c)) === c.expect);
});

check("a missing list falls back to its default, not to nothing", () => {
  const fresh = loadMatcher();
  fresh.configure({ newline: [{ code: "Enter", modifiers: MOD_SHIFT }] });
  // submit was absent from the payload, so it keeps its default: bare Return.
  return fresh.actionFor(eventFor({ code: "Enter", modifiers: 0 }))
      === "submit"
    && fresh.actionFor(eventFor({ code: "Enter", modifiers: MOD_SHIFT }))
      === "newline";
});

check("an explicitly empty list is honoured as an unbinding", () => {
  const fresh = loadMatcher();
  fresh.configure({ submit: [], newline: [] });
  return fresh.actionFor(eventFor({ code: "Enter", modifiers: 0 })) === null
    && fresh.actionFor(eventFor({ code: "Enter", modifiers: MOD_COMMAND }))
      === null;
});

// handleNewline decides between standing aside and inserting. Getting this
// wrong is how "unchanged at defaults" would quietly become false.
check("handleNewline stands aside for chords the browser handles", () => {
  let prevented = false;
  const e = {
    key: "Enter", metaKey: false, ctrlKey: false, altKey: false,
    preventDefault: () => { prevented = true; },
  };
  return matcher.handleNewline({}, e) === false && prevented === false;
});

check("handleNewline inserts for chords the browser would ignore", () => {
  let prevented = false;
  const e = {
    key: "Enter", metaKey: true, ctrlKey: false, altKey: false,
    preventDefault: () => { prevented = true; },
  };
  const ta = {
    value: "ab", selectionStart: 1, selectionEnd: 1,
    dispatchEvent: () => true,
  };
  return matcher.handleNewline(ta, e) === true
    && prevented === true
    && ta.value === "a\nb"
    && ta.selectionStart === 2;
});

// Label spelling is the other cross-language contract: Swift renders it in the
// settings card, this module in the composer placeholder. Two spellings of one
// binding would read as a bug in whichever surface the user distrusted.
check("every binding is spelled the way the fixture says", () => {
  const fresh = loadMatcher();
  return fixture.labels.every((entry) => {
    fresh.configure({
      submit: [{
        code: entry.code,
        modifiers: entry.modifiers,
        label: entry.label,
      }],
      newline: [],
    });
    return fresh.submitHint() === entry.label;
  });
});

// Swift now sends the label, because its key table is far too large to keep a
// second copy of here. The fallback covers a payload written before that field
// existed; it spells modifiers but can only echo the raw DOM code.
check("describeBinding falls back when a payload carries no label", () => {
  const fresh = loadMatcher();
  fresh.configure({ submit: [{ code: "Enter", modifiers: MOD_CONTROL }] });
  if (fresh.submitHint() !== "⌃Enter") return false;
  fresh.configure({ submit: [{ code: "KeyJ", modifiers: MOD_CONTROL }] });
  return fresh.submitHint() === "⌃KeyJ";
});

check("placeholderHint names the configured submit keystroke", () => {
  const fresh = loadMatcher();
  fresh.configure({ submit: [{ code: "Enter", modifiers: MOD_CONTROL }] });
  return fresh.placeholderHint("save")
    === " (⌃Enter to save · Esc to dismiss)";
});

check("placeholderHint drops the submit half when nothing is bound", () => {
  const fresh = loadMatcher();
  fresh.configure({ submit: [], newline: [{ code: "Enter", modifiers: 0 }] });
  return fresh.submitHint() === ""
    && fresh.placeholderHint("save") === " (Esc to dismiss)";
});

check("caps-lock is not a modifier the matcher reads", () => {
  matcher.configure({
    submit: [],
    newline: [{ code: "Enter", modifiers: 0 }],
  });
  // getModifierState('CapsLock') would report it; the matcher never asks.
  const event = eventFor({ code: "Enter", modifiers: 0 });
  event.getModifierState = () => true;
  return matcher.actionFor(event) === "newline";
});

if (failures === 0) {
  const total = fixture.scenarios.reduce((n, s) => n + s.cases.length, 0);
  console.log(
    `\n✅ text-entry JS matches Swift — ${total} shared case(s) ` +
      `across ${fixture.scenarios.length} scenario(s)`,
  );
  process.exit(0);
}
console.error(`\n❌ ${failures} text-entry check(s) failed`);
process.exit(1);
