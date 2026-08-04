import Foundation
import Galactic

/// assist-ant's side of the ⌘/ cheat sheet: the catalog, resolved into the
/// rows Galactic draws.
///
/// The seam the extraction left behind. Above this line is app knowledge —
/// which keys exist, what they are called, when they are live. Below it is
/// mechanism — search, highlighting, layout, dismissal. Rows cross already
/// resolved, so `CheatSheetView` never learns what a `MainTab` is and
/// `KeystrokeCatalog` never learns what a `View` is.
///
/// Deliberately not under `Models/Keystrokes/`. That directory is compiled
/// whole by the ItemsSmoke target, which has no `KeyboardShortcuts` — which
/// the resolver needs — and must not need one. Keeping the builder one level
/// up is what keeps the catalog checkable.
///
/// Not an `ObservableObject`, and holds nothing. `KeystrokeSheetModel` had to
/// be a model because it owned both the presentation state and the snapshot.
/// `CheatSheetPresenter` owns the first now, and the second is a value that
/// lives for the length of one call.
@MainActor
enum KeystrokeSheet {

    /// Hand the shared presenter its rows. Called once, at launch.
    static func install() {
        CheatSheetPresenter.shared.sectionsProvider = { sections() }
    }

    /// The sheet's whole content, snapshot and all.
    ///
    /// The snapshot is taken here, on the first line, and that placement is
    /// the contract: the presenter invokes this at present time — before the
    /// overlay mounts, and so before the sheet's own search field takes first
    /// responder. Read a moment later, `editableTextFocused` would be true for
    /// that field and every chord row would dim: the exact inverse of the
    /// truth. Nothing else may call `snapshot()`, which is why it is private.
    ///
    /// Called once per presentation, not once per body pass. Each call
    /// resolves every rebindable binding through user defaults — the old
    /// view-side build had to be careful to ask only once per pass; now the
    /// shape makes asking twice impossible.
    ///
    /// No filtering happens here, and that is deliberate. The view owns the
    /// search field, so it owns the filter — and it needs the unfiltered set
    /// to say "N of M" at all. Pre-filtering here would collapse M onto N and
    /// the header would read "12 of 12" for every query.
    ///
    /// Rows keep their authored order within a section, and sections their
    /// authored order in the sheet — enforced here, by `KeystrokeSection`'s
    /// own case order and by appending within a section rather than sorting.
    /// The catalog groups related chords together on purpose, and the view is
    /// contracted not to reshuffle what it is handed.
    static func sections() -> [CheatSheetSection] {
        let ctx = snapshot()
        let opening = KeystrokeSection.opening(for: ctx)
        var bySection: [KeystrokeSection: [CheatSheetRow]] = [:]

        // A row is one keystroke, not one command. A rebindable binding can
        // carry several — three keys inserting a newline is an ordinary thing
        // to configure — and the catalog already writes ⌘H and ⌘← as two rows
        // for one command, so listing each key on its own line is the shape
        // that was already here. The alternative, stacking them into one
        // cell, would blow out a column every other row is aligned to.
        for (index, entry) in KeystrokeCatalog.all.enumerated() {
            // Both read once per entry rather than once per rendered row.
            // Availability is a function of the snapshot alone, and the
            // snapshot cannot change while the sheet is up.
            let isActive = entry.availability.isActive(in: ctx)
            let condition = entry.availability.conditionText

            for (keyIndex, keys) in KeystrokeBindingResolver
                .displayTexts(for: entry.binding).enumerated()
            {
                bySection[entry.section, default: []].append(
                    CheatSheetRow(
                        // The catalog index and the key's place within its
                        // entry. Either alone can repeat; together they
                        // cannot, so two configured keystrokes that render
                        // alike still get their own identity rather than
                        // colliding in one container.
                        id: "\(index).\(keyIndex)"
                            + "|\(entry.section.rawValue)|\(keys)",
                        keys: keys,
                        label: entry.label,
                        condition: condition,
                        isActive: isActive,
                        // The authored synonyms only. This row's own glyphs,
                        // spelled out, are derived from `keys` on the other
                        // side — where a row cannot ship without them.
                        aliases: entry.aliases))
            }
        }

        // Authored order, and every section that has rows. A section with
        // nothing authored into it is dropped here so the sheet never shows a
        // bare header; a section the *query* empties is dropped over there,
        // for the same reason on different evidence.
        return KeystrokeSection.allCases.compactMap { section in
            guard let rows = bySection[section], !rows.isEmpty else {
                return nil
            }
            return CheatSheetSection(
                id: section.rawValue,
                title: section.title,
                rows: rows,
                isOpening: section == opening)
        }
    }

    /// Read the surface the user is looking at.
    ///
    /// Focus questions are delegated to `MenuActions`, which already answers
    /// them for menu validation — asking the same question two ways is how the
    /// sheet would end up disagreeing with which commands are actually live.
    private static func snapshot() -> KeystrokeContext {
        let tab = MainTabNavigator.shared.selectedTab
        return KeystrokeContext(
            tab: tab,
            readerOpen: ItemViewerModel.shared.openItem != nil,
            hasSelection: hasSelection(on: tab),
            terminalPaneFocused: MenuActions.agentTerminalIsFocused(),
            editableTextFocused: MenuActions.editableTextIsFocused(),
            findBarOpen: FindBarPanelController.shared.isPresenting
        )
    }

    /// Whether the surface on screen has anything selected.
    ///
    /// Each list surface owns its own selection, so this is a question only
    /// the active tab can answer — and the tabs that install no chords have no
    /// selection to speak of, which is why they answer false rather than
    /// reaching for a shared one that does not exist.
    private static func hasSelection(on tab: MainTab) -> Bool {
        switch tab {
        case .icebox: return IceboxModel.shared.selection.hasSelection
        case .schedule: return ScheduleAgendaModel.shared.selection.hasSelection
        case .trash: return TrashModel.shared.selection.hasSelection
        case .scratch: return ScratchModel.shared.selection.hasSelection
        case .terminal, .tasks: return false
        }
    }
}
