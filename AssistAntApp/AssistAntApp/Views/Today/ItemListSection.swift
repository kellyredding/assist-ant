import SwiftUI

/// A titled list section: a pinned header (emoji + title) with the rows
/// scrolling beneath it, plus an empty state. The reusable unit the today
/// sidebar's columns are built from — future Todo / Reminder / Explore lists
/// reuse it as-is. Fills its container's height so the header pins to the top
/// and the scroll region takes the rest.
struct ItemListSection<Row: View>: View {
    let title: String
    let emoji: String
    let isEmpty: Bool
    let emptyText: String
    /// Optional control shown at the trailing edge of the header (e.g. a
    /// re-sync glyph). Omit for a plain heading.
    var headerAccessory: AnyView? = nil
    @ViewBuilder var rows: () -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pinned header — stays put while the rows scroll beneath it.
            HStack(spacing: 4) {
                Text("\(emoji)  \(title.uppercased())")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if let headerAccessory {
                    Spacer(minLength: 8)
                    headerAccessory
                }
            }
            // The list margin: the title emoji aligns with the group carets and
            // row badges below, and the trailing glyph with the rows' right edge.
            .padding(.horizontal, 8)

            if isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    // Align with the header title emoji + the rows' content margin.
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    rows()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
