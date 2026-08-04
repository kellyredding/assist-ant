import SwiftUI

/// The ⌘/ cheat sheet: every keystroke Assist Ant answers to, grouped by
/// context, filtered by a fuzzy search field.
///
/// An in-window overlay rather than a panel. A floating panel would reopen the
/// key/main-window questions the capture and status panels already cost us,
/// and this needs none of what a panel buys.
///
/// Rows that are not usable right now are dimmed, never hidden or filtered
/// out: the sheet is a reference first, so its job is to show what exists and
/// let the dimming say what is live. Availability comes from the snapshot the
/// model took as the sheet opened, not from live state — see `KeystrokeContext`.
struct KeystrokeSheetView: View {
    @ObservedObject private var model = KeystrokeSheetModel.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let cardWidth: CGFloat = 660
    private static let inactiveOpacity: CGFloat = 0.45

    var body: some View {
        ZStack {
            scrim
            card
        }
        .onAppear { searchFocused = true }
    }

    /// Click-anywhere-to-dismiss backdrop.
    private var scrim: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.dismiss() }
    }

    private var card: some View {
        // Resolved once. Every read rebuilds the whole list and re-resolves ~75
        // keystrokes through user defaults, so asking twice per body pass was
        // paying for the catalog four times over.
        let sections = self.sections
        let matched = sections.reduce(0) { $0 + $1.rows.count }
        return VStack(spacing: 0) {
            header(matched: matched)
            Divider()
            if sections.isEmpty {
                emptyState
            } else {
                list(sections)
            }
        }
        .frame(width: Self.cardWidth)
        .frame(maxHeight: 620)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 30, y: 10)
    }

    private func header(matched: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search shortcuts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                // Enter should not beep or submit anything — the field only
                // filters.
                .onSubmit {}
            if !query.isEmpty {
                // The matched count against the whole catalog, so a short list
                // reads as "the query is narrow" rather than "the sheet is
                // broken" — the same reassurance the scratch feed's count gives.
                Text("\(matched) of \(KeystrokeCatalog.all.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                PointerIconButton(systemName: "xmark.circle.fill") {
                    query = ""
                }
            }
            Text("esc")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        Text("No shortcuts match “\(query)”")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    /// A plain `VStack`, deliberately not lazy. The catalog is a fixed ~75
    /// rows, so laziness buys nothing measurable, and it costs the whole class
    /// of recycling bug that a duplicated row identity produces — rows landing
    /// under the wrong header and blank gaps where the list believed it had
    /// already built something.
    private func list(_ sections: [Group]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { group in
                        sectionHeader(group.section)
                        ForEach(group.rows) { row in
                            self.row(row)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .onAppear {
                // Open where the user already is. Only on first appear — doing
                // it as the query changes would yank the list around mid-search.
                proxy.scrollTo(
                    KeystrokeSection.opening(for: model.context),
                    anchor: .top)
            }
        }
    }

    private func sectionHeader(_ section: KeystrokeSection) -> some View {
        Text(section.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 16).padding(.bottom, 6)
            .id(section)
    }

    private func row(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(highlighted(row.keys, row.hit.keysOffsets))
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                )
                .frame(minWidth: 74, alignment: .leading)

            Text(highlighted(row.entry.label, row.hit.labelOffsets))
                .font(.system(size: 13))

            Spacer(minLength: 8)

            if !row.entry.availability.conditionText.isEmpty {
                Text(row.entry.availability.conditionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .opacity(row.isActive ? 1 : Self.inactiveOpacity)
    }

    // MARK: - Filtering

    /// One rendered row: the entry, its resolved keystroke text, and whether
    /// it is live under the snapshot.
    ///
    /// The identity is composed rather than positional. An index alone
    /// restarts at zero in every section, and since all rows share one
    /// container that collides — which is precisely what put rows under the
    /// wrong heading and left holes in the list.
    private struct Row: Identifiable {
        let id: String
        let entry: KeystrokeEntry
        let keys: String
        let hit: KeystrokeSearch.Hit
        let isActive: Bool
    }

    /// `text` with the matched characters tinted, from the offsets the filter
    /// already computed — so the highlight cannot disagree with the filter about
    /// what matched, the same arrangement the scratch feed's rows use. Walked
    /// character by character rather than indexed, which keeps a stray offset
    /// from trapping.
    private func highlighted(
        _ text: String, _ offsets: [Int]
    ) -> AttributedString {
        guard !offsets.isEmpty else { return AttributedString(text) }
        let marked = Set(offsets)
        var out = AttributedString()
        for (i, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(i) {
                piece.backgroundColor = .yellow.opacity(0.35)
            }
            out += piece
        }
        return out
    }

    private struct Group: Identifiable {
        var id: KeystrokeSection { section }
        let section: KeystrokeSection
        let rows: [Row]
    }

    /// Sections in catalog order, each holding its matching rows. A section
    /// with no matches is dropped so the sheet never shows a bare header.
    ///
    /// Within a section, rows keep their authored order rather than sorting by
    /// score: the catalog groups related chords together on purpose, and
    /// reshuffling them by match quality would scatter the `a` leaders apart
    /// the moment a query touched them. Highlighting is what tells the reader
    /// why a row is in the list, which is the job ranking would otherwise do.
    ///
    /// What a query may match is `KeystrokeSearch`'s to decide — the condition
    /// text and the section title are rendered here but never searched.
    private var sections: [Group] {
        let entries = KeystrokeCatalog.all
        let keys = entries.map {
            KeystrokeBindingResolver.displayText(for: $0.binding)
        }
        let hits = KeystrokeSearch.hits(
            zip(entries, keys).map {
                KeystrokeSearch.Candidate(label: $0.label, keys: $1)
            },
            query: query)

        let rows = entries.indices.compactMap { index -> Row? in
            guard let hit = hits[index] else { return nil }
            let entry = entries[index]
            // The catalog index makes this unique even where two rows
            // share a section, a keystroke, and a label.
            return Row(
                id: "\(index)|\(entry.section.rawValue)|\(keys[index])",
                entry: entry,
                keys: keys[index],
                hit: hit,
                isActive: entry.availability.isActive(in: model.context))
        }

        return KeystrokeSection.allCases.compactMap { section in
            let matching = rows.filter { $0.entry.section == section }
            return matching.isEmpty
                ? nil : Group(section: section, rows: matching)
        }
    }
}
