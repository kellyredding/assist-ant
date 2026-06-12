import SwiftUI

/// UI strings + styling for an actionable item's kind. Presentation only —
/// the code layer keeps the "actionable" vocabulary; these are what the user
/// sees.
enum ActionableKindLabel {
    /// Kind badge text, or nil for a non-actionable item.
    static func badge(for item: Item) -> String? {
        switch item.typeData {
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        default: return nil
        }
    }

    /// Resolve-button verb for one item — delegates to the model-layer
    /// `ItemActionState` so the single source of truth also covers batches.
    static func resolveVerb(for item: Item) -> String {
        ItemActionState.verb(for: [item])
    }

    /// Menu title for a kind offered by the reclassify menu.
    static func menuTitle(_ kind: ItemType) -> String {
        switch kind {
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        case .calendar: return ""   // never offered
        }
    }

    /// Badge background color (always paired with white text), or nil for a
    /// non-actionable item.
    static func color(for item: Item) -> Color? {
        switch item.typeData {
        // One deep navy for both themes: dark enough to stay clearly distinct
        // from Explore's brighter royal blue, light enough to hold contrast
        // against the dark-mode window.
        case .todo: return Color(red: 0.16, green: 0.21, blue: 0.55)     // navy
        case .explore: return Color(red: 0.25, green: 0.41, blue: 0.88)  // royal blue
        case .reminder: return Color(red: 0.13, green: 0.48, blue: 0.24) // royal green
        default: return nil
        }
    }

    /// Frosty accent for the iceboxed status pill. Pale and slightly
    /// cyan-leaning in dark mode so it reads on the dark window; deeper and
    /// bolder in light mode so it holds contrast on white. Resolved per
    /// appearance so the outline pill never goes too faint either way.
    static func iceColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.56, green: 0.80, blue: 0.98)
            : Color(red: 0.13, green: 0.42, blue: 0.70)
    }
}

/// The colored kind pill (white text) shown in the icebox list and the item
/// reader header. Renders nothing for a non-actionable item.
struct KindBadge: View {
    let item: Item

    var body: some View {
        if let text = ActionableKindLabel.badge(for: item),
           let bg = ActionableKindLabel.color(for: item) {
            Text(text)
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(bg))
                // Faint, theme-aware edge: Color.primary resolves dark in
                // light mode and light in dark mode, so the pill keeps a
                // subtle outline against either background.
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                )
        }
    }
}

/// The shared outline status-pill chrome used in the reader's meta line: a
/// glyph + text in a capsule whose border, glyph, and text all carry `color`,
/// over a faint same-color tint so it reads as a chip, not a hollow ring.
/// Callers pick the color — an accent for a special status like iceboxed, or
/// `.secondary` for the everyday scheduled date.
struct StatusPill: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption).fontWeight(.medium)
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color, lineWidth: 1))
    }
}

/// Iceboxed status pill: a snowflake + "Iceboxed on {date}" in the ice accent —
/// the special set-aside state, so it stands out. The snowflake mirrors the
/// Icebox tab glyph. Shown only for an item that's iceboxed.
struct IceboxedBadge: View {
    let date: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        StatusPill(
            systemImage: "snowflake",
            text: "Iceboxed on \(Self.dateFormatter.string(from: date))",
            color: ActionableKindLabel.iceColor(scheme)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

/// Scheduled status pill: just the calendar glyph and the friendly date, in
/// secondary — the everyday state, so it stays quiet rather than carrying a
/// status accent like the iceboxed pill. The year is appended only when it
/// isn't the current year. The calendar glyph mirrors the Schedule tab, as the
/// iceboxed pill's snowflake mirrors the Icebox tab.
struct ScheduledBadge: View {
    let date: CivilDate

    var body: some View {
        StatusPill(
            systemImage: "calendar",
            text: Self.friendly(date),
            color: .secondary
        )
    }

    /// "Jun 12" in the current year; "Jun 12, 2027" otherwise.
    private static func friendly(_ date: CivilDate) -> String {
        let formatter = date.year == CivilDate.today.year
            ? sameYearFormatter : otherYearFormatter
        return formatter.string(from: date.noon)
    }

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()
}
