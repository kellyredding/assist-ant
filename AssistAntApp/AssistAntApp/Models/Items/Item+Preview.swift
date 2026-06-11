import Foundation

extension Item {
    /// A one-line plain-text preview of the body for list rows (Gmail-style):
    /// links reduced to their text, common markdown markers dropped, and each
    /// source line kept as a segment joined by " | " (intra-line whitespace
    /// collapsed, blank lines dropped). nil when there's no usable body. The
    /// caller truncates to the available width.
    var bodyPlainPreview: String? {
        guard let raw = body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        var s = raw
        // [text](url) → text
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // drop inline/structural markdown markers
        s = s.replacingOccurrences(
            of: #"[*_`>#~]"#, with: "", options: .regularExpression)
        // Each source line becomes a segment: collapse intra-line whitespace,
        // drop blank lines, and join with a pipe so the preview reads as
        // "ticket | project · milestone · status | description…".
        let segments = s.components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(
                    of: #"[ \t]+"#, with: " ", options: .regularExpression
                ).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let joined = segments.joined(separator: " | ")
        return joined.isEmpty ? nil : joined
    }
}
