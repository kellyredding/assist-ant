import Foundation

/// Where a binding is usable.
///
/// One value drives both the dim state and the condition label, so a row
/// cannot look available while its text says otherwise. Foundation-only, and
/// evaluated against a snapshot rather than live app state — see
/// `KeystrokeContext` for why that distinction matters.
enum KeystrokeAvailability: Equatable {
    /// A global hotkey: works whatever has focus, including another app.
    case always
    /// A menu command: live whenever Assist Ant is focused.
    case app
    /// View switching, which stands aside for a focused text editor so its
    /// own line navigation keeps working.
    case viewSwitch
    /// Single-key commands on a list surface.
    case tabs(Set<MainTab>)
    /// Batch chords, which arm only once something is selected.
    case tabsWithSelection(Set<MainTab>)
    /// While an item reader is open.
    case reader
    /// While a terminal pane holds first responder.
    case terminalPane
    /// While the find bar is up.
    case findBar
    /// Inside a separate popover window, named for the row's condition text.
    case panel(String)

    /// Usable under this snapshot?
    ///
    /// Panel entries always answer false, which is honest rather than a gap:
    /// the sheet opens only from the main window, so a popover's own keys are
    /// never live at the moment you are reading about them.
    func isActive(in ctx: KeystrokeContext) -> Bool {
        switch self {
        case .always:
            return true
        case .app:
            return true
        case .viewSwitch:
            return !ctx.editableTextFocused
        case .tabs(let tabs):
            return tabs.contains(ctx.tab) && !ctx.readerOpen
                && !ctx.editableTextFocused
        case .tabsWithSelection(let tabs):
            return tabs.contains(ctx.tab) && ctx.hasSelection
                && !ctx.readerOpen && !ctx.editableTextFocused
        case .reader:
            return ctx.readerOpen
        case .terminalPane:
            return ctx.terminalPaneFocused
        case .findBar:
            return ctx.findBarOpen
        case .panel:
            return false
        }
    }

    /// The same condition in words, for the row's trailing text. Empty when
    /// the binding carries no condition worth stating.
    var conditionText: String {
        switch self {
        case .always:
            return "anywhere, even in another app"
        case .app:
            return ""
        case .viewSwitch:
            return "unless editing text"
        case .tabs(let tabs):
            return "in \(Self.name(tabs))"
        case .tabsWithSelection(let tabs):
            return "in \(Self.name(tabs)), with a selection"
        case .reader:
            return "with an item open"
        case .terminalPane:
            return "with a terminal focused"
        case .findBar:
            return "with the find bar open"
        case .panel(let name):
            return "in the \(name)"
        }
    }

    /// Tab names in tab-strip order, so two entries covering the same surfaces
    /// always read the same way round.
    private static func name(_ tabs: Set<MainTab>) -> String {
        let ordered = MainTab.allCases.filter { tabs.contains($0) }
        if ordered.count == MainTab.allCases.count { return "any view" }
        return ordered.map(\.title).joined(separator: ", ")
    }
}

/// A keystroke's text, held symbolically when the user controls it.
///
/// The rebindable cases exist so the catalog can stay a Foundation-only value
/// and still never contradict Settings: it names *which* binding a row shows,
/// and `KeystrokeBindingResolver` reads the live value at display time.
enum KeystrokeBinding: Equatable {
    /// A fixed keystroke, already formatted for display ("⌘T", "a i", "j").
    case literal(String)
    /// The global capture hotkey for a kind — user-rebindable.
    case capture(CaptureKind)
    /// The global status-popover hotkey — user-rebindable.
    case statusPopover
    /// The keystroke that commits text — user-configurable.
    case textEntryCommit
    /// The keystroke that inserts a newline — user-configurable.
    case textEntryNewline
}

/// A group of rows in the sheet, in display order.
enum KeystrokeSection: String, CaseIterable {
    case global
    case windowAndViews
    case lists
    case scratch
    case reader
    case terminal
    case find
    case textEntry
    case popovers

    var title: String {
        switch self {
        case .global: return "Global"
        case .windowAndViews: return "Window & Views"
        case .lists: return "Lists"
        case .scratch: return "Scratch"
        case .reader: return "Item Reader"
        case .terminal: return "Terminal & Agent"
        case .find: return "Find"
        case .textEntry: return "Text Entry"
        case .popovers: return "Capture & Status Popovers"
        }
    }

    /// The section to scroll to when the sheet opens over `tab`, so the reader
    /// lands where they already are.
    static func opening(for ctx: KeystrokeContext) -> KeystrokeSection {
        if ctx.readerOpen { return .reader }
        switch ctx.tab {
        case .terminal: return .terminal
        case .schedule, .icebox, .trash, .tasks: return .lists
        case .scratch: return .scratch
        }
    }
}

/// One documented keystroke.
struct KeystrokeEntry: Equatable {
    let binding: KeystrokeBinding
    let label: String
    let section: KeystrokeSection
    let availability: KeystrokeAvailability
}
