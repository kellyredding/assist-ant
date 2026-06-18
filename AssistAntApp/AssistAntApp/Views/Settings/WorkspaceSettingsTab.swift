import SwiftUI
import Combine

/// Settings tab for the install's workspace. Two controls: the workspace name
/// and the persona the embedded agent runs. Both back the database
/// (WorkspaceStore), not prefs.json, because the workspace record lives
/// alongside the item rows it scopes and travels with the same backup.
struct WorkspaceSettingsTab: View {
    @StateObject private var model = WorkspaceSettingsModel()

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Workspace") {
                SettingsRow(label: "Name") {
                    TextField("", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { model.commit() }
                }
                SettingsRow(label: "Persona") {
                    PersonaPicker(
                        personas: model.availablePersonas,
                        selection: Binding<String?>(
                            get: { model.personaName },
                            set: { model.setPersona($0) }
                        )
                    )
                    .frame(width: 220)
                }
            }
            SettingsCard(title: "Spend") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show in title bar", isOn: Binding(
                        get: { model.spendShow },
                        set: { model.setSpendShow($0) }
                    ))
                    .toggleStyle(.checkbox)

                    staleAfterRow
                }
            }
            SettingsCard(title: "Priority") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show in title bar", isOn: Binding(
                        get: { model.priorityShow },
                        set: { model.setPriorityShow($0) }
                    ))
                    .toggleStyle(.checkbox)

                    priorityStaleAfterRow
                }
            }
            Spacer()
        }
        .padding(20)
        .onDisappear {
            model.commit()
            model.commitSpendStaleHours()
            model.commitPriorityStaleHours()
        }
    }

    /// A type-or-step stale-threshold field, mirroring the Desk timer's minute
    /// stepper but with an hours/days unit picker. The text field and stepper
    /// edit the value in the chosen unit; the model stores the equivalent in
    /// hours (0 = never).
    private var staleAfterRow: some View {
        let value = Binding<Int>(
            get: { model.staleDisplayValue },
            set: { model.setStaleDisplayValue($0) }
        )
        return SettingsRow(label: "Stale after") {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                Picker("", selection: $model.staleUnit) {
                    Text("hours").tag(SpendStaleUnit.hours)
                    Text("days").tag(SpendStaleUnit.days)
                }
                .labelsHidden()
                .frame(width: 84)
                Stepper("", value: value, in: 0...Int.max, step: 1)
                    .labelsHidden()
            }
        }
    }

    /// The priority widget's stale-after field — parallel to `staleAfterRow`,
    /// backed by the priority threshold so the two pills age independently.
    private var priorityStaleAfterRow: some View {
        let value = Binding<Int>(
            get: { model.priorityStaleDisplayValue },
            set: { model.setPriorityStaleDisplayValue($0) }
        )
        return SettingsRow(label: "Stale after") {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                Picker("", selection: $model.priorityStaleUnit) {
                    Text("hours").tag(PriorityStaleUnit.hours)
                    Text("days").tag(PriorityStaleUnit.days)
                }
                .labelsHidden()
                .frame(width: 84)
                Stepper("", value: value, in: 0...Int.max, step: 1)
                    .labelsHidden()
            }
        }
    }
}

/// The unit the stale-after threshold is edited in. Storage is always hours;
/// `days` is a display convenience (×24).
enum SpendStaleUnit {
    case hours
    case days
}

/// The priority widget's stale-after unit. Parallel to SpendStaleUnit so the two
/// pills' settings stay independent.
enum PriorityStaleUnit {
    case hours
    case days
}

/// Drives the workspace name + persona fields. Seeds synchronously from the
/// store so the fields open populated, then tracks external changes live. The
/// name writes through `WorkspaceStore.rename`, the persona through
/// `WorkspaceStore.setPersonaName` — neither changes the workspace id.
@MainActor
final class WorkspaceSettingsModel: ObservableObject {
    @Published var name: String
    @Published var personaName: String
    @Published var spendShow: Bool
    @Published var spendStaleHours: Int
    @Published var staleUnit: SpendStaleUnit
    @Published var priorityShow: Bool
    @Published var priorityStaleHours: Int
    @Published var priorityStaleUnit: PriorityStaleUnit
    let availablePersonas: [String]
    private var bag = Set<AnyCancellable>()

    init() {
        let current = try? WorkspaceStore.shared.current()
        self.name = current?.name ?? ""
        let persona = current?.personaName ?? Workspace.defaultPersonaName
        self.personaName = persona
        self.spendShow = current?.spendShow ?? false
        let hrs = current?.spendStaleHours ?? 24
        self.spendStaleHours = hrs
        // Open in days when the stored hours are a whole number of days (≥ 1 day),
        // else hours — so 24h shows as "1 day", 6h as "6 hours".
        self.staleUnit = (hrs >= 24 && hrs % 24 == 0) ? .days : .hours
        self.priorityShow = current?.priorityShow ?? false
        let phrs = current?.priorityStaleHours ?? 24
        self.priorityStaleHours = phrs
        self.priorityStaleUnit = (phrs >= 24 && phrs % 24 == 0) ? .days : .hours

        // Enumerate personas by globbing the persona dir (mirrors Galaxy's new
        // session picker). Keep the stored selection in the list even if its
        // .toml was removed, so the picker still shows the current value.
        var names = Self.globPersonaNames()
        if !names.contains(persona) {
            names.append(persona)
            names.sort()
        }
        self.availablePersonas = names

        WorkspaceStore.shared.observe()
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workspace in
                guard let self, let workspace else { return }
                if workspace.name != self.name { self.name = workspace.name }
                if workspace.personaName != self.personaName {
                    self.personaName = workspace.personaName
                }
                if workspace.spendShow != self.spendShow {
                    self.spendShow = workspace.spendShow
                }
                if workspace.spendStaleHours != self.spendStaleHours {
                    self.spendStaleHours = workspace.spendStaleHours
                }
                if workspace.priorityShow != self.priorityShow {
                    self.priorityShow = workspace.priorityShow
                }
                if workspace.priorityStaleHours != self.priorityStaleHours {
                    self.priorityStaleHours = workspace.priorityStaleHours
                }
            }
            .store(in: &bag)
    }

    /// All persona names under `~/.claude-persona/personas/` (extension stripped,
    /// sorted). Empty when the directory is absent or unreadable.
    static func globPersonaNames() -> [String] {
        let dir = NSHomeDirectory() + "/.claude-persona/personas"
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { $0.hasSuffix(".toml") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// Persist the edited name. An empty/whitespace value is ignored — the name
    /// is required, so a blank field leaves the stored name untouched.
    func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? WorkspaceStore.shared.rename(to: trimmed)
    }

    /// Commit a persona-picker selection live. A nil/blank pick (the picker's
    /// index-0 blank row) is ignored — the persona is required, so it keeps the
    /// stored value. Takes effect on the next fresh agent session.
    func setPersona(_ newValue: String?) {
        let trimmed = (newValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        personaName = trimmed
        try? WorkspaceStore.shared.setPersonaName(trimmed)
    }

    /// Toggle the title-bar spend pill; writes through immediately.
    func setSpendShow(_ show: Bool) {
        spendShow = show
        try? WorkspaceStore.shared.setSpendShow(show)
    }

    /// Persist the stale-after threshold (hours; clamped at 0 = never).
    func commitSpendStaleHours() {
        try? WorkspaceStore.shared.setSpendStaleHours(max(0, spendStaleHours))
    }

    /// The stale threshold expressed in the currently-selected unit.
    var staleDisplayValue: Int {
        staleUnit == .days ? spendStaleHours / 24 : spendStaleHours
    }

    /// Set the threshold from a value in the selected unit, store it in hours,
    /// and persist. Floors at 0 (= never).
    func setStaleDisplayValue(_ value: Int) {
        let clamped = max(0, value)
        spendStaleHours = staleUnit == .days ? clamped * 24 : clamped
        commitSpendStaleHours()
    }

    /// Toggle the title-bar priority pill; writes through immediately.
    func setPriorityShow(_ show: Bool) {
        priorityShow = show
        try? WorkspaceStore.shared.setPriorityShow(show)
    }

    /// Persist the priority stale-after threshold (hours; clamped at 0 = never).
    func commitPriorityStaleHours() {
        try? WorkspaceStore.shared.setPriorityStaleHours(max(0, priorityStaleHours))
    }

    /// The priority stale threshold expressed in the currently-selected unit.
    var priorityStaleDisplayValue: Int {
        priorityStaleUnit == .days ? priorityStaleHours / 24 : priorityStaleHours
    }

    /// Set the priority threshold from a value in the selected unit, store it in
    /// hours, and persist. Floors at 0 (= never).
    func setPriorityStaleDisplayValue(_ value: Int) {
        let clamped = max(0, value)
        priorityStaleHours = priorityStaleUnit == .days ? clamped * 24 : clamped
        commitPriorityStaleHours()
    }
}
