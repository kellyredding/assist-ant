import Foundation

/// The `title` a scratch entry stores alongside its body.
///
/// Scratch is body-only to the user — the feed renders the body and nothing
/// asks for a title. But `title` is `NOT NULL`, and the shared Trash renders
/// its rows by title, so an empty one would show a trashed note as a blank
/// row. Hence a derived title: the first non-empty line, trimmed and
/// truncated. Re-derived on every edit so it never describes stale text.
enum ScratchTitle {
    /// Long enough to identify a note in a Trash row, short enough not to be a
    /// second copy of the body.
    static let maxLength = 80

    /// Shown when the body holds no renderable line at all. Never seen in the
    /// feed, which renders the body — this exists so a blank note is still
    /// identifiable once trashed.
    static let fallback = "Empty note"

    static func derive(from body: String) -> String {
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line = firstLine else { return fallback }
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)) + "…"
    }
}
