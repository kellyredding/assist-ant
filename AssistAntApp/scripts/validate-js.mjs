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
// The load-bearing step for embedded literals is Swift unescaping: the
// source text `/\n/g` is the two characters backslash-n, which Node
// parses as a valid "match a newline" regex. Swift turns that `\n`
// into a real newline at compile time, which is an invalid regex. So
// the validator must reproduce Swift's `"""` unescaping BEFORE parsing
// — otherwise it would miss exactly the class of bug it exists to catch.
//
// Syntax checking uses `new vm.Script(code)`, which parses without
// executing: no temp files, no subprocess, no network, no side effects.
// Undefined references and runtime/logic errors are out of scope — this
// guards syntax only, which is the class that silently passes the build.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = join(SCRIPT_DIR, ".."); // .../AssistAntApp
const SRC_DIR = join(APP_ROOT, "AssistAntApp"); // .../AssistAntApp/AssistAntApp
const MARKER = "// js-validate";

const failures = [];
let checkedFiles = 0;
let checkedLiterals = 0;

// --- Swift `"""` string-literal unescaping ---------------------------
// Reproduces how the Swift compiler materializes the literal at build
// time. `\(...)` interpolations are replaced with a neutral `0` token
// so the surrounding JS still parses.
function unescapeSwiftMultiline(src) {
  let out = "";
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    const next = src[i + 1];
    switch (next) {
      case "n": out += "\n"; i++; break;
      case "t": out += "\t"; i++; break;
      case "r": out += "\r"; i++; break;
      case "0": out += "\0"; i++; break;
      case "\\": out += "\\"; i++; break;
      case '"': out += '"'; i++; break;
      case "'": out += "'"; i++; break;
      case "\n": i++; break; // line continuation: backslash-newline
      case "u": {
        // \u{XXXX}
        const m = /^\\u\{([0-9A-Fa-f]+)\}/.exec(src.slice(i));
        if (m) {
          out += String.fromCodePoint(parseInt(m[1], 16));
          i += m[0].length - 1;
        } else {
          out += ch;
        }
        break;
      }
      case "(": {
        // \( ... ) interpolation — skip with balanced-paren scan
        let depth = 0;
        let j = i + 1;
        for (; j < src.length; j++) {
          if (src[j] === "(") depth++;
          else if (src[j] === ")") {
            depth--;
            if (depth === 0) break;
          }
        }
        out += "0";
        i = j;
        break;
      }
      default:
        // Unknown escape — Swift would have rejected it at compile
        // time, so the committed source can't contain one. Pass the
        // backslash through rather than silently dropping it.
        out += ch;
    }
  }
  return out;
}

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
  const text = readFileSync(file, "utf8");
  const lines = text.split("\n");
  const rel = relative(APP_ROOT, file);

  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== MARKER) continue;

    // Find the opening `"""` — the declaration line at or just below
    // the marker that ends with `"""`.
    let openIdx = -1;
    for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
      if (/"""\s*$/.test(lines[j])) {
        openIdx = j;
        break;
      }
    }
    if (openIdx === -1) {
      recordFailure({
        file: rel,
        literal: "(unknown)",
        line: i + 1,
        err: new Error(
          `${MARKER} marker not followed by a \"\"\" literal within 3 lines`,
        ),
      });
      continue;
    }

    const literalName =
      /(?:let|var)\s+(\w+)/.exec(lines[openIdx])?.[1] ?? "(anonymous)";

    // Capture body until the closing delimiter line (trimmed === `"""`).
    const body = [];
    let closeIdx = -1;
    for (let j = openIdx + 1; j < lines.length; j++) {
      if (lines[j].trim() === '"""') {
        closeIdx = j;
        break;
      }
      body.push(lines[j]);
    }
    if (closeIdx === -1) {
      recordFailure({
        file: rel,
        literal: literalName,
        line: openIdx + 1,
        err: new Error("unterminated \"\"\" literal"),
      });
      continue;
    }

    const js = unescapeSwiftMultiline(body.join("\n"));
    const err = checkSyntax(js, `${rel}:${literalName}`);
    checkedLiterals++;
    if (err) {
      recordFailure({ file: rel, literal: literalName, line: openIdx + 1, err });
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

if (failures.length === 0) {
  console.log(
    `✓ JS validation passed — ${checkedFiles} resource file(s), ` +
      `${checkedLiterals} embedded literal(s)`,
  );
  process.exit(0);
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
