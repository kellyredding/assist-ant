import Foundation

/// Shared presentation tokens for note and annotation UI.
///
/// `textSize` is the single value both the edit textarea and the
/// saved card body resolve to, so composing and reading a note never
/// differ in size. Artifact readers pass a fixed `13px`. The
/// scrollback passes `var(--font-size)` so notes track the terminal
/// font they sit among — a note renders inline between terminal rows,
/// so matching the text it annotates is what reads as correct there.
/// Chrome (headers, hints) stays fixed on both surfaces: meta chrome
/// is UI, note text is content.
///
/// `--note-one-line` is the height of exactly one line of note text
/// including the text box's own padding and border. The collapsed
/// card and the empty textarea both use it, so a one-line note
/// occupies the same height whether it is being typed or read. `1em`
/// resolves against the element using the token, not `:root` —
/// custom property values substitute as tokens and resolve at the use
/// site — so it tracks whatever `--note-text-size` resolved to.
func noteUXTokens(textSize: String) -> String {
    """
    :root {
        --note-text-size: \(textSize);
        --note-text-line-height: 1.5;
        --note-text-font: var(--font-family-mono,
            "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace);
        --note-chrome-size: 13px;
        --note-chrome-font: -apple-system, sans-serif;
        --note-meta-size: 11px;
        --note-box-pad-y: 6px;
        --note-box-pad-x: 10px;
        --note-text-pad-y: 6px;
        --note-text-pad-x: 8px;
        --note-header-gap: 4px;
        --note-spacer-gap: 6px;
        --note-one-line: calc(
            1em * var(--note-text-line-height)
            + var(--note-text-pad-y) * 2 + 2px);
    }
    """
}

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
/// We also reset `<pre>`'s user-agent margin so switching from a
/// `<div>` host to a `<pre>` doesn't shift the card's vertical
/// rhythm.
///
/// Both this rule and `.annotation-card-content` /
/// `.note-card-content` declare `font-size`, and
/// `pre.verbatim-card-content` outranks them (one class each, but
/// this one also names an element). Rather than pick a winner, both
/// sides point at `--note-text-size`, so the outcome is the same
/// whichever wins and a future third class on the card body cannot
/// reintroduce a size mismatch. This previously read `inherit`,
/// which won the tie and then resolved against the *container* —
/// 13px in artifacts, the terminal font size in the scrollback —
/// while the textarea stayed at 12px.
///
/// The card body carries the textarea's padding plus a transparent
/// border so the text-bearing box has identical content width in
/// both states: text cannot re-wrap on save. The visible border and
/// background tint on the textarea remain the edit-mode affordance.
/// `box-sizing` is explicit because two readers lack the `*` reset
/// that supplies it elsewhere.
///
/// Single source of truth: scrollback notes and artifact +
/// snapshot annotations apply identical rules so the card display
/// matches the edit textarea byte-for-byte.
let verbatimCardCSS: String = """
    pre.verbatim-card-content {
        margin: 0;
        font-size: var(--note-text-size, 13px);
    }
    .verbatim-card-content {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        font-family: var(--note-text-font,
            "SF Mono", "Menlo", "Monaco",
            "Courier New", monospace);
        padding: var(--note-text-pad-y, 6px)
            var(--note-text-pad-x, 8px);
        border: 1px solid transparent;
        box-sizing: border-box;
    }
"""
