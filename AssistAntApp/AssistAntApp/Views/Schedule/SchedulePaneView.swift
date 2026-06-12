import AppKit
import SwiftUI

/// The Schedule tab's content: a control bar over a spinner-gated, vertically
/// scrolled agenda — or, when an event is open, a full-takeover event reader
/// in its place. Activates the model on first appear (if the tab is already
/// selected) and on every switch to `.schedule`. Observes the clock so past-
/// dimming and the today highlight refresh each minute without re-fetching.
///
/// Actionable rows on the agenda reuse the icebox list machinery: a list-level
/// key monitor (J/K focus, X toggle, Enter opens, `*a` / `*n`) drives the
/// model's shared `ActionableSelection`, mutually exclusive with the icebox and
/// reader monitors by tab/state gating.
struct SchedulePaneView: View {
    @ObservedObject private var model = ScheduleAgendaModel.shared
    @ObservedObject private var selection = ScheduleAgendaModel.shared.selection
    @ObservedObject private var navigator = MainTabNavigator.shared
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var sync = CalendarSyncCoordinator.shared

    @State private var keyMonitor: Any?
    @State private var pendingStar = false          // saw `*`, awaiting a / n
    @State private var starTimer: DispatchWorkItem?

    var body: some View {
        // The agenda fills the pane; the event reader is presented centrally by
        // ItemViewerModel as an overlay above the tab content, not here.
        agendaPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onAppear {
                if navigator.selectedTab == .schedule { model.activate() }
                installScheduleKeyMonitor()
            }
            .onChange(of: navigator.selectedTab) { _, tab in
                if tab == .schedule { model.activate() }
            }
            .onDisappear { removeScheduleKeyMonitor() }
    }

    private var agendaPane: some View {
        VStack(spacing: 0) {
            ScheduleControlBar(
                monthYear: monthYearLabel,
                onToday: { model.goToToday() },
                onBack: { model.goBack() },
                onForward: { model.goForward() },
                onOpenGoogleCalendar: { Self.openGoogleCalendar() },
                onRefresh: {
                    CalendarSyncCoordinator.shared.requestSync()
                    model.refresh()
                },
                isWorking: model.isWorking || sync.isSyncing,
                selection: selection,
                actions: model.actions,
                selectedItems: model.selectedItems
            )
            Divider()
            agenda
        }
    }

    @ViewBuilder
    private var agenda: some View {
        if model.isLoading && model.days.isEmpty {
            VStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.days) { day in
                            ScheduleDaySection(
                                day: day,
                                now: clock.currentTime,
                                onOpen: { ItemViewerModel.shared.open($0, over: .schedule) },
                                selection: selection,
                                actions: model.actions,
                                isCollapsed: model.isCollapsed,
                                onToggle: { name in model.toggleCollapse(name) }
                            )
                            .id(day.date)
                            .background(dayPositionReader(day.date))
                        }
                    }
                }
                .coordinateSpace(name: "agenda")
                .onPreferenceChange(DayTopPreferenceKey.self) { tops in
                    if let top = Self.topmost(tops) { model.topVisibleDay = top }
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    DispatchQueue.main.async { model.scrollTarget = nil }
                }
                // Keep the keyboard-focused actionable row visible as J/K move it.
                .onChange(of: selection.focusedItemID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// Reports each day header's minY in the "agenda" space via preference.
    private func dayPositionReader(_ date: CivilDate) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: DayTopPreferenceKey.self,
                value: [date: geo.frame(in: .named("agenda")).minY]
            )
        }
    }

    /// The day whose header is closest to (but not past) the top edge.
    private static func topmost(_ tops: [CivilDate: CGFloat]) -> CivilDate? {
        tops.filter { $0.value <= 1 }.max { $0.value < $1.value }?.key
            ?? tops.min { $0.value < $1.value }?.key
    }

    private var monthYearLabel: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"   // e.g. "June 2026"
        return f.string(from: model.topVisibleDay.noon)
    }

    // MARK: - List key monitor (mutually exclusive with the icebox + reader)

    private func installScheduleKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only when the Schedule is the live surface: on its tab, no reader
            // up, and not typing in a text field.
            guard navigator.selectedTab == .schedule,
                  ItemViewerModel.shared.openItem == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView)
            else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased()

            // `*` prefix → wait briefly for a / n (Gmail-style sequence).
            if event.characters == "*" {
                pendingStar = true
                starTimer?.cancel()
                let work = DispatchWorkItem { pendingStar = false }
                starTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
                return nil
            }
            if pendingStar {
                pendingStar = false
                starTimer?.cancel()
                if chars == "a" {
                    selection.selectAll(in: ActionableListNavigation.idsInGroup(
                        of: selection.focusedItemID, model.allGroups))
                    return nil
                }
                if chars == "n" { selection.clearSelection(); return nil }
                // any other key cancels the sequence and falls through
            }

            switch chars {
            case "j": selection.moveFocus(by: 1, order: visibleOrder()); return nil
            case "k": selection.moveFocus(by: -1, order: visibleOrder()); return nil
            case "x": selection.toggleSelectedFocused(); return nil
            default: break
            }
            if event.keyCode == 36 || event.keyCode == 76 {        // Return / Enter
                if let item = selection.focusedItem(in: model.allGroups) {
                    ItemViewerModel.shared.open(item, over: .schedule)
                    return nil
                }
            }
            return event
        }
    }

    private func visibleOrder() -> [String] {
        ActionableListNavigation.visibleIDs(model.allGroups, collapsed: model.collapsedLists)
    }

    private func removeScheduleKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        starTimer?.cancel()
        pendingStar = false
    }

    // MARK: - Google Calendar

    /// Google Calendar's web home. Opening the bare URL lands on whatever
    /// calendar and view the user last had in the browser, which is the
    /// least-surprising target for a "jump to the real calendar" affordance.
    private static let googleCalendarURL =
        URL(string: "https://calendar.google.com/")!

    /// Hand the URL to the system default browser. The control bar's glyph
    /// routes here, mirroring how its navigation actions route to the model.
    private static func openGoogleCalendar() {
        NSWorkspace.shared.open(googleCalendarURL)
    }

}
