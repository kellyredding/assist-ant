import Foundation

extension Item {
    /// A one-line plain-text preview of the body for list rows (Gmail-style):
    /// links reduced to their text, common markdown markers dropped, and all
    /// whitespace/newlines collapsed to single spaces. nil when there's no
    /// usable body. The caller truncates to the available width.
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
        // collapse all whitespace (incl. newlines) to single spaces
        s = s.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
