// swift-literals.mjs — read JavaScript out of Swift `"""` string literals.
//
// Shared by scripts/validate-js.mjs (syntax gate) and
// scripts/verify-text-entry.mjs (behaviour gate). Both need the identical
// reader: a second copy of the unescaping below would be a slow-rotting
// duplicate of logic whose whole value is being exactly right.
//
// A literal opts in with a marker comment on the line immediately above its
// declaration:
//
//     // js-validate
//     let fooJS = """
//     ... javascript ...
//     """

export const MARKER = "// js-validate";

// --- Swift `"""` string-literal unescaping ---------------------------
// Reproduces how the Swift compiler materializes the literal at build
// time. `\(...)` interpolations are replaced with a neutral `0` token
// so the surrounding JS still parses.
//
// This step is load-bearing: the source text `/\n/g` is the two characters
// backslash-n, which Node parses as a valid "match a newline" regex. Swift
// turns that `\n` into a real newline at compile time, which is an invalid
// regex. Unescaping BEFORE parsing is what catches that class of bug.
export function unescapeSwiftMultiline(src) {
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

/// Pull every marked literal out of one Swift source text.
///
/// Returns `{ name, line, js }` for each well-formed literal and
/// `{ name, line, error }` for a marker that is malformed, so callers can
/// report a broken marker rather than silently skipping it.
export function extractMarkedLiterals(text) {
  const lines = text.split("\n");
  const found = [];

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
      found.push({
        name: "(unknown)",
        line: i + 1,
        error: `${MARKER} marker not followed by a """ literal within 3 lines`,
      });
      continue;
    }

    const name =
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
      found.push({
        name,
        line: openIdx + 1,
        error: 'unterminated """ literal',
      });
      continue;
    }

    found.push({
      name,
      line: openIdx + 1,
      js: unescapeSwiftMultiline(body.join("\n")),
    });
  }

  return found;
}
