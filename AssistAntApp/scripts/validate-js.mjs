#!/usr/bin/env node
// validate-js.mjs — syntax-check the JavaScript that ships inside
// AssistAntApp, before xcodebuild runs.
//
// Two sources are checked:
//
//   1. Standalone bundle resources: AssistAntApp/Resources/*.js
//      (vendored *.min.js are skipped — third-party, already valid,
//      and huge).
//
//   2. JavaScript embedded in Swift `"""` string literals. xcodebuild
//      treats that JS as opaque string data, so a syntax error there
//      compiles cleanly and only fails at runtime in the WebView. To
//      opt a literal in, put a marker comment on the line immediately
//      above its declaration:
//
//          // js-validate
//          static let fooJS = """
//          ... javascript ...
//          """
//
// Reading a marked literal — finding it, and reproducing Swift's `"""`
// unescaping before parsing — lives in lib/swift-literals.mjs, shared with
// verify-text-entry.mjs. See that file for why the unescaping step is
// load-bearing rather than cosmetic.
//
// Syntax checking uses `new vm.Script(code)`, which parses without
// executing: no temp files, no subprocess, no network, no side effects.
// Undefined references and runtime/logic errors are out of scope — this
// guards syntax only, which is the class that silently passes the build.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { extractMarkedLiterals } from "./lib/swift-literals.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = join(SCRIPT_DIR, ".."); // .../AssistAntApp
const SRC_DIR = join(APP_ROOT, "AssistAntApp"); // .../AssistAntApp/AssistAntApp

// Coverage floor.
//
// The walker only sees this app's own source tree, so a marked literal that
// moves out of it is not reported missing — it simply stops being found. The
// count drops, every remaining literal still parses, and the run passes green.
// That is the one failure this gate cannot survive, because its whole purpose
// is catching JS that compiles clean and breaks at runtime in a WebView.
//
// Lowering these is a deliberate act: do it in the same change that moves the
// literal, and only once its new home validates it. Never to make a red build
// green.
// The emoji resources and several card literals now ship with the card UI in
// Galactic, which parses each of them in its own test suite. A zero resource
// floor is honest here rather than lax: this app no longer carries any
// non-minified JavaScript of its own under Resources/.
const EXPECTED_MIN_RESOURCE_FILES = 0;
const EXPECTED_MIN_LITERALS = 3;

const failures = [];
let checkedFiles = 0;
let checkedLiterals = 0;

// --- Syntax check ----------------------------------------------------
function checkSyntax(code, label) {
  try {
    new vm.Script(code, { filename: label });
    return null;
  } catch (err) {
    return err;
  }
}

function recordFailure({ file, literal, line, err }) {
  failures.push({ file, literal, line, err });
}

// --- Walk Swift source for marked embedded literals ------------------
function* swiftFiles(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      yield* swiftFiles(full);
    } else if (entry.endsWith(".swift")) {
      yield full;
    }
  }
}

function checkEmbeddedLiterals(file) {
  const rel = relative(APP_ROOT, file);

  for (const found of extractMarkedLiterals(readFileSync(file, "utf8"))) {
    if (found.error) {
      recordFailure({
        file: rel,
        literal: found.name,
        line: found.line,
        err: new Error(found.error),
      });
      continue;
    }

    const err = checkSyntax(found.js, `${rel}:${found.name}`);
    checkedLiterals++;
    if (err) {
      recordFailure({ file: rel, literal: found.name, line: found.line, err });
    }
  }
}

// --- Standalone bundle resources -------------------------------------
function checkResourceScripts() {
  const resDir = join(SRC_DIR, "Resources");
  let entries;
  try {
    entries = readdirSync(resDir);
  } catch {
    return; // no Resources dir — nothing to do
  }
  for (const entry of entries) {
    if (!entry.endsWith(".js") || entry.endsWith(".min.js")) continue;
    const full = join(resDir, entry);
    const rel = relative(APP_ROOT, full);
    const err = checkSyntax(readFileSync(full, "utf8"), rel);
    checkedFiles++;
    if (err) recordFailure({ file: rel, literal: null, line: 1, err });
  }
}

// --- Run -------------------------------------------------------------
checkResourceScripts();
for (const file of swiftFiles(SRC_DIR)) {
  checkEmbeddedLiterals(file);
}

if (
  failures.length === 0 &&
  checkedFiles >= EXPECTED_MIN_RESOURCE_FILES &&
  checkedLiterals >= EXPECTED_MIN_LITERALS
) {
  console.log(
    `✓ JS validation passed — ${checkedFiles} resource file(s), ` +
      `${checkedLiterals} embedded literal(s)`,
  );
  process.exit(0);
}

if (
  checkedFiles < EXPECTED_MIN_RESOURCE_FILES ||
  checkedLiterals < EXPECTED_MIN_LITERALS
) {
  console.error(
    `\n✗ JS validation coverage dropped — found ${checkedFiles} resource ` +
      `file(s) and ${checkedLiterals} embedded literal(s), expected at least ` +
      `${EXPECTED_MIN_RESOURCE_FILES} and ${EXPECTED_MIN_LITERALS}.\n\n` +
      `  Something that used to be validated here no longer is. A literal\n` +
      `  that moved out of this source tree is not reported missing — it\n` +
      `  just stops being found, and everything left still passes.\n\n` +
      `  If the move was intended, lower the floor in this file in the same\n` +
      `  change, once its new home validates it.\n`,
  );
  if (failures.length === 0) process.exit(1);
}

console.error(`\n✗ JS validation failed — ${failures.length} error(s)\n`);
for (const f of failures) {
  const where = f.literal
    ? `${f.file} → ${f.literal} (declared at line ${f.line})`
    : `${f.file}`;
  console.error(`  ${where}`);
  console.error(`    ${f.err.message.split("\n")[0]}`);
  // vm SyntaxErrors carry a code frame in the stack — surface a couple
  // of lines so the offending JS is visible without opening the file.
  const frame = (f.err.stack ?? "")
    .split("\n")
    .slice(0, 4)
    .filter((l) => l.includes("^") || l.trim().length)
    .slice(0, 3);
  for (const line of frame) console.error(`    ${line}`);
  console.error("");
}
process.exit(1);
