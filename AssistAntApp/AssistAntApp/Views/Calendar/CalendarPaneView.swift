import SwiftUI

/// The Calendar tab's content: a control bar over a spinner-gated, vertically
/// scrolled agenda. Activates the model on first appear (if the tab is already
/// selected) and on every switch to `.calendar`. Observes the clock so past-
/// dimming and the today highlight refresh each minute without re-fetching.
struct CalendarPaneView: View {
    @ObservedObject private var model = CalendarAgendaModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared
    @ObservedObject private var clock = ClockService.shared

    var body: some View {
        VStack(spacing: 0) {
            CalendarControlBar(
                monthYear: monthYearLabel,
                onToday: { model.goToToday() },
                onBack: { model.goBack() },
                onForward: { model.goForward() },
                onRefresh: { model.refresh() },
                isWorking: model.isWorking
            )
            Divider()
            agenda
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            if navigator.selectedTab == .calendar { model.activate() }
        }
        .onChange(of: navigator.selectedTab) { _, tab in
            if tab == .calendar { model.activate() }
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
                            CalendarDaySection(day: day, now: clock.currentTime)
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
}
