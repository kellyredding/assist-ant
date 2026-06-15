import AppKit

extension Item {
    /// One item serialized as a `---`-fenced Markdown block, paste-ready for an
    /// external agent: the title as a heading, a short metadata list (only the
    /// fields present), then the raw body. Internal status (iceboxed /
    /// resolved), source, and ids are intentionally omitted — an external agent
    /// works on the content, not our bookkeeping. The leading + trailing `---`
    /// frame the item so a single copy and one item within a batch look
    /// identical and parse the same way. A blank line precedes the closing fence
    /// so a body's last line is never read as a setext heading. Deterministic
    /// and dependency-light so it is unit-testable in the smoke runner.
    func clipboardMarkdown() -> String {
        var lines: [String] = ["---", "# \(title)", ""]

        lines.append("- Kind: \(clipboardKindLabel)")
        if let list = actionableListName { lines.append("- List: \(list)") }
        if let on = scheduledOn { lines.append("- Scheduled: \(on.iso)") }
        if let url = externalURL { lines.append("- Link: \(url)") }

        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        lines.append("")     // blank line before the closing fence
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// "To-do" / "Reminder" / "Explore" / "Calendar" / custom — a readable kind
    /// for the metadata line.
    private var clipboardKindLabel: String {
        switch typeData.kind {
        case ItemType.todo.rawValue: return "To-do"
        case ItemType.reminder.rawValue: return "Reminder"
        case ItemType.explore.rawValue: return "Explore"
        case ItemType.calendar.rawValue: return "Calendar"
        default: return typeData.kind.capitalized
        }
    }
}

/// Serialize one or more items and write them to the general pasteboard. The
/// `CopyButton` writes via its own (Galaxy-ported) path using `serialize`; the
/// `a c` chord calls `copy` directly. One serializer, one framing rule.
enum ItemClipboard {
    /// Framed blocks joined by a blank line — each item self-delimited by its
    /// own `---` fences, so single and batch share one shape.
    static func serialize(_ items: [Item]) -> String {
        items.map { $0.clipboardMarkdown() }.joined(separator: "\n\n")
    }

    static func copy(_ items: [Item]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(serialize(items), forType: .string)
        // The `a c` chord copies without a click; broadcast so any mounted copy
        // glyph (the visible one is the batch control bar's) flashes the green
        // checkmark — the keyboard path gets the same confirmation as a click.
        NotificationCenter.default.post(name: .itemsCopiedToClipboard, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `ItemClipboard.copy` (the `a c` chord path) so copy glyphs in
    /// any mounted control bar flash their green-check confirmation.
    static let itemsCopiedToClipboard = Notification.Name("AssistAnt.itemsCopiedToClipboard")
}
