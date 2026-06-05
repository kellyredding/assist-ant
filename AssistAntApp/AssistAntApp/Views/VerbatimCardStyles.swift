import Foundation

/// CSS for verbatim text rendering inside annotation/note card
/// bodies. Targets `.verbatim-card-content`, the marker class
/// applied to every card-style container that displays user-typed
/// note/annotation text.
///
/// Notes and annotations render exactly as typed — no markdown,
/// no auto-linking. The container element is `<pre>` so the
/// browser's user-agent styling (monospace + whitespace
/// preservation) gives a correct rendering even if our CSS
/// variables fail to load. `white-space: pre-wrap` then upgrades
/// `<pre>`'s default `pre` to wrap inside the card width.
/// `overflow-wrap: anywhere` keeps long unbreakable strings
/// (URLs, paths, hashes) from blowing past the card. The mono
/// font matches the textarea the user typed into and makes
/// pasted indented/tabular content align.
///
/// We also reset `<pre>`'s user-agent margin and font-size so
/// switching from a `<div>` host to a `<pre>` doesn't shift
/// the card's vertical rhythm or text sizing.
///
/// Single source of truth: scrollback notes and artifact +
/// snapshot annotations apply identical rules so the card display
/// matches the edit textarea byte-for-byte.
let verbatimCardCSS: String = """
    pre.verbatim-card-content {
        margin: 0;
        font-size: inherit;
    }
    .verbatim-card-content {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        font-family: var(--font-family-mono,
            "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace);
    }
"""
