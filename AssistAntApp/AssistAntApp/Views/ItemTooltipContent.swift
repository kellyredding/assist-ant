import AppKit
import SwiftUI

/// The hover-tooltip body: a read-only preview of an item that mirrors the
/// reader — wrapped title, the kind / list / scheduled (or iceboxed) pills, and
/// the Markdown-rendered body — minus every affordance (no action cluster, edit,
/// close, or link buttons; the panel ignores mouse events, so nothing here is
/// interactive). One floating card on a theme-aware panel.
///
/// The controller bounds the width (the body wraps to it) and the height (bottom
/// overflow clips) when it hosts this in the panel.
struct ItemTooltipContent: View {
    let item: Item

    private var isResolved: Bool { item.resolvedAt != nil }
    private var trimmedBody: String? {
        guard let b = item.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !b.isEmpty else { return nil }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
                .strikethrough(isResolved)
                .foregroundStyle(isResolved ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            metaLine

            if let body = trimmedBody {
                TooltipMarkdownBody(markdown: body)
                    // The body renders its own text colors, so opacity (not a
                    // foreground style) mutes the whole resolved block — matching
                    // the dimmed title above, exactly as the reader does.
                    .opacity(isResolved ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    /// Kind / list / schedule pills for an actionable item; a single date-time
    /// pill for a calendar event (which has no actionable kind). Mirrors the
    /// reader's meta bar, minus the open-link button.
    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 8) {
            if ActionableKindLabel.badge(for: item) != nil {
                KindBadge(item: item)
                if let list = item.actionableListName, !list.isEmpty {
                    Text(list)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let at = item.deletedAt {
                    DeletedBadge(date: at)
                } else if let at = item.iceboxedAt {
                    IceboxedBadge(date: at)
                } else {
                    ScheduledBadge(date: item.scheduledOn ?? .today)
                }
            } else if let when = calendarMetaText {
                StatusPill(systemImage: "calendar", text: when, color: .secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A compact when-line for a calendar event: `Mon, Jun 9 · 10:00 AM` (start
    /// only — the tooltip is a glance, not the full reader), `· All Day` for
    /// all-day events, or just the day when there's no time. Nil for a
    /// non-calendar item.
    private var calendarMetaText: String? {
        guard case .calendar(let d) = item.typeData else { return nil }
        let day: String
        if let start = d.startAt {
            day = Self.dayFormatter.string(from: start)
        } else if let sched = item.scheduledOn {
            day = Self.dayFormatter.string(from: sched.noon)
        } else {
            day = ""
        }
        if d.allDay { return day.isEmpty ? "All Day" : "\(day)  ·  All Day" }
        guard let start = d.startAt else { return day.isEmpty ? nil : day }
        let time = Self.timeString(start)
        return day.isEmpty ? time : "\(day)  ·  \(time)"
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = SettingsManager.shared.settings.timeFormat.dateFormat
        return f.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"   // e.g. "Mon, Jun 9"
        return f
    }()
}

/// Non-scrolling, read-only Markdown body for the tooltip. Renders the same
/// block-level attributed text the reader's `EventBodyTextView` uses (via the
/// shared `MarkdownText` builder), but reports its wrapped height to SwiftUI so
/// the controller can grow the panel to fit and clip any overflow at the bottom.
/// Links render styled but inert — the panel ignores mouse events.
struct TooltipMarkdownBody: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSTextView {
        // Explicit TextKit 1 stack (a width-tracking container) so the text view
        // wraps to whatever width SwiftUI lays it out at.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
        ]
        tv.linkTextAttributes = linkAttributes
        tv.textStorage?.setAttributedString(MarkdownText.attributed(markdown))
        context.coordinator.lastMarkdown = markdown
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        tv.textStorage?.setAttributedString(MarkdownText.attributed(markdown))
        context.coordinator.lastMarkdown = markdown
    }

    /// Report the wrapped height at the proposed width. `boundingRect` honors the
    /// paragraph styles (heading spacing, list indents) the builder applies, so
    /// it matches the rendered layout.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSTextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let rect = MarkdownText.attributed(markdown).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: width, height: ceil(rect.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var lastMarkdown: String? }
}
