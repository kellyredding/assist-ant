import AppKit
import SwiftUI

/// The Tasks tab's content: a read-only table of tasks over a run log.
///
/// Tasks are *authored agentically* — created and edited by talking to the
/// embedded agent (the `assist-ant task` CLI), not through a UI form — so this
/// pane has no add/edit affordances. It exposes only zero-form row verbs: an
/// enabled toggle, delete (with confirm), and a run-now ▶ placeholder that is
/// inert until the runner lands in a later phase. The list is a snapshot:
/// re-fetched on activation and on the control-bar refresh, mirroring
/// `IceboxPaneView` / `TrashPaneView`.
struct TasksPaneView: View {
    @ObservedObject private var model = TasksModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared
    /// Observed so a live 12h/24h clock change re-renders the timestamps.
    @ObservedObject private var settings = SettingsManager.shared
    /// Observed so the next-run chip stays minute-fresh and rolls to "due" on
    /// the minute boundary (mirrors SchedulePaneView).
    @ObservedObject private var clock = ClockService.shared

    @State private var pendingDelete: AgentTask?
    /// The run log is an overlay now (a control-bar glyph toggles it) so the
    /// task list owns the full pane height.
    @State private var showLog = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                controlBar
                Divider()
                // The task list now owns the full pane height and scrolls; the
                // run log lives in an overlay toggled from the control bar.
                tasksContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showLog { logOverlay }
            // Tapping a row opens its viewer over the pane — the same full-cover
            // reader pattern as the item viewers.
            if let task = model.openTask {
                TaskViewer(
                    task: task,
                    timeFormat: settings.settings.timeFormat,
                    runs: model.runs.filter { $0.taskID == task.id },
                    onClose: { model.closeViewer() },
                    onRunNow: { model.runNow(task) },
                    onToggle: { model.setEnabled(task, $0) },
                    onDelete: { pendingDelete = task; model.closeViewer() },
                    onSavePrompt: { model.updatePrompt(task, to: $0) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { if navigator.selectedTab == .tasks { model.activate() } }
        .onChange(of: navigator.selectedTab) { _, tab in
            if tab == .tasks { model.activate() }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { task in
            Button("Delete “\(task.name)”", role: .destructive) {
                model.delete(task)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { task in
            Text("“\(task.name)” will be removed. Its run history stays in the log.")
        }
    }

    // MARK: - Control bar

    /// A label and a refresh glyph that re-fetches the snapshot — the same
    /// idiom as `IceboxControlBar`.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Text("Tasks").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                PointerIconButton(
                    systemName: "clock.arrow.circlepath",
                    help: showLog ? "Hide run log" : "Show run log",
                    action: { showLog.toggle() }
                )
                if !model.runs.isEmpty {
                    Text("\(model.runs.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            PointerIconButton(
                systemName: "arrow.clockwise",
                help: "Reload tasks", action: { model.refresh() }
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    // MARK: - Tasks table

    @ViewBuilder
    private var tasksContent: some View {
        if model.isLoading && model.tasks.isEmpty {
            ProgressView().scaleEffect(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if model.tasks.isEmpty {
            // Compact, top-aligned empty line so the section stays small; same
            // style as the other panes' empty states.
            Text("No tasks yet")
                .font(.callout).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            // The list fills the pane and scrolls; the run log moved to an overlay.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.tasks, id: \.id) { task in
                        TaskRowView(
                            task: task,
                            timeFormat: settings.settings.timeFormat,
                            now: clock.currentTime,
                            onOpen: { model.openViewer(task) },
                            onRunNow: { model.runNow(task) },
                            onToggle: { model.setEnabled(task, $0) },
                            onDelete: { pendingDelete = task },
                            onReorder: { moved, anchor, edge in
                                model.reorder(movedID: moved, anchorID: anchor, edge: edge)
                            }
                        )
                        Divider().opacity(0.4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Run log (overlay)

    /// The run log as a full-cover reader over the Tasks pane — the same chrome
    /// as the item viewers: a header control bar over the scrollable content,
    /// opaque over the list (no dimmed card). Closed by the header ✕ or Esc.
    private var logOverlay: some View {
        VStack(spacing: 0) {
            // Reader-style header, mirroring ActionableItemViewer's.
            HStack(spacing: 10) {
                Text("Run Log").font(.headline)
                if !model.runs.isEmpty {
                    Text("\(model.runs.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                PointerIconButton(
                    systemName: "xmark", help: "Close (Esc)", action: { showLog = false }
                )
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            }
            logContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
        // Esc closes the log: a zero-size cancel-action button binds Escape
        // window-wide without needing focus (unlike .onExitCommand).
        .overlay {
            Button("", action: { showLog = false })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The log fills the remaining height and overflow-scrolls; its empty state
    /// is centered like the other panes (Icebox / Trash).
    @ViewBuilder
    private var logContent: some View {
        if model.runs.isEmpty {
            VStack {
                Spacer()
                Text("No runs yet").font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.runs, id: \.id) { run in
                        TaskRunRowView(run: run, timeFormat: settings.settings.timeFormat)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Task row

/// One task row: a trigger badge, the name + prompt preview, the recurring
/// last-run stamp, and the zero-form verbs (run-now, enabled toggle, delete).
/// A disabled task dims its text. Tapping the badge/name area opens the task
/// viewer; the trailing verbs stay independent hit targets.
private struct TaskRowView: View {
    let task: AgentTask
    let timeFormat: TimeFormat
    /// The current minute, from the pane's clock — drives the next-run chip.
    let now: Date
    let onOpen: () -> Void
    let onRunNow: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onReorder: (_ movedID: String, _ anchorID: String,
                    _ edge: TaskDragSession.Edge) -> Void

    @State private var isHovering = false
    /// The live drag, for revealing the grip and drawing the insertion line.
    @ObservedObject private var drag = TaskDragSession.shared
    /// Measured row height, so the drop delegate can split top/bottom halves.
    @State private var rowHeight: CGFloat = 36

    /// Hover effects are suppressed mid-drag so they don't fight the drag.
    private var showsHover: Bool { isHovering && !drag.isDragging }

    var body: some View {
        HStack(spacing: 8) {
            // The drag grip rides the leading edge; faint until the row is
            // hovered (or this row is the one being dragged).
            TaskDragHandle(task: task, isRowHovering: showsHover)

            // Tapping the badge/name/when region opens the task viewer; the
            // trailing verbs below stay independent hit targets.
            HStack(spacing: 8) {
                // Hugs its own text and sits as an inline prefix to the name —
                // no fixed column — so the name follows immediately on every row.
                // A short trigger ("today") and a long windowed/weekday summary
                // ("every 1h · 08:55–16:55 · Mon–Fri") both just push the name
                // along by their own width; the name column absorbs the rest.
                TriggerBadge(text: TaskFormat.triggerSummary(task))
                    .fixedSize(horizontal: true, vertical: false)

                nameLine
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(task.enabled ? 1 : 0.5)

                // The when-slot: a single secondary pill reading "{last} → {next}"
                // (no glyphs). today keeps its key label; manual shows nothing.
                if let when = TaskFormat.whenChipText(task, timeFormat, now: now) {
                    TriggerBadge(text: when)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .contentShape(Rectangle())
            .pointerButton(onHoverChange: { _ in }, action: onOpen)

            // Run now: deliver the task's prompt to the agent and log the run.
            // Stays enabled while the agent is down — it logs a skipped run.
            PointerIconButton(systemName: "play.fill", help: "Run now", action: onRunNow)

            Toggle("", isOn: Binding(get: { task.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .help(task.enabled ? "Disable task" : "Enable task")

            PointerIconButton(systemName: "trash", help: "Delete task", action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(showsHover ? 0.06 : 0))
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        // Measure the row so the drop delegate can split top/bottom halves.
        .background(GeometryReader { proxy in
            Color.clear.onAppear { rowHeight = proxy.size.height }
        })
        // The insertion line: a 2pt accent rule on the edge a drop will land on.
        .overlay(alignment: .top) {
            if drag.indicator == TaskDragSession.Indicator(rowID: task.id, edge: .above) {
                insertionLine
            }
        }
        .overlay(alignment: .bottom) {
            if drag.indicator == TaskDragSession.Indicator(rowID: task.id, edge: .below) {
                insertionLine
            }
        }
        .onDrop(of: [.text], delegate: TaskDropDelegate(
            rowTask: task, rowHeight: rowHeight, onReorder: onReorder))
    }

    /// The 2pt accent insertion line drawn at the row edge a drop will land on.
    private var insertionLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
    }

    /// Name (semibold) followed by a muted single-line prompt preview — the
    /// same Gmail-style one-liner as the actionable rows.
    private var nameLine: Text {
        let name = Text(task.name).fontWeight(.semibold).foregroundStyle(.primary)
        let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return name }
        return name + Text("  \(prompt)").foregroundStyle(.secondary)
    }
}

/// A small capsule labeling a task's trigger (e.g. "every 15m", "daily 07:00",
/// "one-shot", "manual"). Reused by the run-log rows and the task viewer.
struct TriggerBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
    }
}

// MARK: - Run-log row

/// One run-log entry: the fired-at time (leftmost, log convention), the run's
/// origin as a badge, then the (snapshot) task name with a one-line preview of
/// the prompt that was sent. A skipped run keeps its reason as a trailing note.
/// Reused by the run-log overlay and the task viewer's run history.
struct TaskRunRowView: View {
    let run: TaskRun
    let timeFormat: TimeFormat

    var body: some View {
        HStack(spacing: 8) {
            // Timestamp first, in the primary text color.
            Text(TaskFormat.dateTime(run.firedAt, timeFormat))
                .font(.caption).monospacedDigit().foregroundStyle(.primary)
                .frame(width: 116, alignment: .leading)

            // The run's origin as a badge in its own fixed column, so the name
            // column starts at the same x on every row (the capsule still hugs
            // its text, left-aligned within the column).
            TriggerBadge(text: TaskFormat.runTriggerLabel(run.trigger))
                .frame(width: 80, alignment: .leading)

            // Name + a muted one-line prompt preview, like the actionable rows.
            nameLine
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail = run.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Task name (semibold, primary) then the prompt-as-sent preview (secondary)
    /// — the same Gmail-style one-liner the task rows and actionable rows use.
    private var nameLine: Text {
        let name = Text(run.taskName).font(.caption).fontWeight(.semibold)
            .foregroundStyle(.primary)
        let prompt = (run.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return name }
        return name + Text("  \(prompt)").font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Display formatting

/// Pure formatting for the read-only table — lives in the view layer (not on
/// the GRDB record, which stays smoke-clean Foundation + GRDB). Reused by the
/// task viewer.
enum TaskFormat {
    static func triggerSummary(_ task: AgentTask) -> String {
        switch task.triggerType {
        case "recurring":
            // Base cadence, then the interval's time window, then the weekday
            // mask: "every 1h · 08:55–16:55 · Mon–Fri", "daily 08:55 · Mon–Fri".
            var parts = [cadenceText(task)]
            if task.cadenceKind == "interval",
               let s = task.windowStart, let e = task.windowEnd {
                parts.append("\(s)–\(e)")
            }
            if let weekdays = weekdayText(task.weekdaySet) { parts.append(weekdays) }
            return parts.joined(separator: " · ")
        case "one_shot":
            return "one-shot"
        case "today":
            return "today"
        case "manual":
            return "manual"
        default:
            return task.triggerType
        }
    }

    /// The Today glyph a `today` task is bound to — shown in the row's
    /// right-side slot (where recurring shows its last run).
    static func todayKeyLabel(_ key: String?) -> String? {
        switch key {
        case AgentTask.calendarRefreshKey: return "calendar refresh"
        case AgentTask.todoRefreshKey: return "to-do refresh"
        default: return key
        }
    }

    /// The bare recurring cadence, before any weekday/window refinement.
    private static func cadenceText(_ task: AgentTask) -> String {
        switch task.cadenceKind {
        case "interval":
            if let s = task.intervalSeconds { return "every \(intervalText(s))" }
            return "recurring"
        case "daily":
            if let t = task.dailyTime { return "daily \(t)" }
            return "daily"
        default:
            return "recurring"
        }
    }

    /// An ISO-weekday set (1=Mon…7=Sun) as compact text: a contiguous run of
    /// three or more becomes a range ("Mon–Fri"), shorter runs and isolated days
    /// join with commas ("Mon, Wed, Fri"). Returns nil for the full week — every
    /// day needs no qualifier — so an unfiltered task shows just its cadence.
    static func weekdayText(_ days: Set<Int>) -> String? {
        let sorted = days.sorted()
        guard !sorted.isEmpty, sorted != Array(1...7) else { return nil }
        let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var parts: [String] = []
        var runStart = sorted[0]
        var prev = sorted[0]
        func flush() {
            if prev - runStart >= 2 {
                parts.append("\(names[runStart])–\(names[prev])")
            } else {
                for d in runStart...prev { parts.append(names[d]) }
            }
        }
        for d in sorted.dropFirst() {
            if d == prev + 1 { prev = d; continue }
            flush(); runStart = d; prev = d
        }
        flush()
        return parts.joined(separator: ", ")
    }

    /// A compact interval, snapping to the largest whole unit (900 → "15m",
    /// 3600 → "1h", 86400 → "1d").
    static func intervalText(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// Right-side caption: a recurring task's last-run, a one-shot's scheduled
    /// run time (or "next tick" when it has no set time), or nil for manual
    /// (fires on demand). Times honor the user's clock setting; a same-day time
    /// drops the date.
    static func whenText(_ task: AgentTask, _ timeFormat: TimeFormat) -> String? {
        switch task.triggerType {
        case "recurring":
            guard let at = task.lastRunAt else { return "never run" }
            return "ran \(stamp(at, timeFormat))"
        case "one_shot":
            guard let at = task.runAt else { return "runs next tick" }
            return "runs \(stamp(at, timeFormat))"
        case "today":
            return todayKeyLabel(task.todayKey)
        default:
            return nil
        }
    }

    /// The last-run chip text (checkmark chip). Recurring + one_shot only; nil
    /// hides the chip — a never-run recurring task or an unfired one_shot has no
    /// last run.
    static func lastRunText(_ task: AgentTask, _ timeFormat: TimeFormat) -> String? {
        guard task.triggerType == "recurring" || task.triggerType == "one_shot",
              let at = task.lastRunAt else { return nil }
        return stamp(at, timeFormat)
    }

    /// The next-run chip text (clock chip). nil hides the chip; "next tick" /
    /// "due" are returned verbatim for the imminent cases.
    static func nextRunText(_ task: AgentTask, _ timeFormat: TimeFormat, now: Date) -> String? {
        guard task.enabled else { return nil }
        switch task.triggerType {
        case "one_shot":
            guard let at = task.runAt else { return "next tick" }
            return at <= now ? "due" : stamp(at, timeFormat)
        case "recurring":
            guard let at = TaskSchedule.nextRun(task, after: now) else { return nil }
            return at <= now ? "due" : stamp(at, timeFormat)
        default:
            return nil
        }
    }

    /// The row's when-slot text for a single pill: "{last} → {next}" when both
    /// sides exist, otherwise whichever one does (a disabled task shows just its
    /// last run; a never-run task just its next). today shows its key label;
    /// manual shows nothing.
    static func whenChipText(_ task: AgentTask, _ timeFormat: TimeFormat, now: Date) -> String? {
        switch task.triggerType {
        case "recurring", "one_shot":
            let last = lastRunText(task, timeFormat)
            let next = nextRunText(task, timeFormat, now: now)
            switch (last, next) {
            case let (l?, n?): return "\(l) → \(n)"
            case let (l?, nil): return l
            case let (nil, n?): return n
            default: return nil
            }
        case "today":
            return whenText(task, timeFormat)
        default:
            return nil
        }
    }

    /// A timestamp honoring the clock's 12h/24h setting; a same-day time shows
    /// only the time, otherwise the month/day too. The format is passed in (from
    /// the pane's observed settings) so a live 12h/24h change re-renders.
    private static func stamp(_ date: Date, _ timeFormat: TimeFormat) -> String {
        let time = timeFormat.dateFormat
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? time : "MMM d, \(time)"
        return f.string(from: date)
    }

    /// The run-log timestamp, honoring the user's 12h/24h clock (e.g.
    /// "Jun 15, 9:52 PM" / "Jun 15, 21:52"). Built per call so a live setting
    /// change re-renders when the pane re-reads the format.
    static func dateTime(_ date: Date, _ timeFormat: TimeFormat) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, \(timeFormat.dateFormat)"
        return f.string(from: date)
    }

    /// Humanize a run's origin for the log badge: "run_now" → "run now",
    /// "one_shot" → "one-shot"; "manual" / "recurring" pass through.
    static func runTriggerLabel(_ trigger: String) -> String {
        switch trigger {
        case "run_now": return "run now"
        case "one_shot": return "one-shot"
        default: return trigger
        }
    }
}
