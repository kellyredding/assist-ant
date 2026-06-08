import SwiftUI
import Combine

/// Settings tab for the install's workspace. The only control is the workspace
/// name — there is exactly one workspace per install and it is never switched
/// here. Backed by the database (WorkspaceStore), not prefs.json, because the
/// workspace record lives alongside the item rows it scopes.
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
            }
            Spacer()
        }
        .padding(20)
        .onDisappear { model.commit() }
    }
}

/// Drives the workspace name field. Seeds synchronously from the store so the
/// field opens populated, then tracks external changes live; writes go through
/// `WorkspaceStore.rename`, which never changes the workspace id.
@MainActor
final class WorkspaceSettingsModel: ObservableObject {
    @Published var name: String
    private var bag = Set<AnyCancellable>()

    init() {
        self.name = (try? WorkspaceStore.shared.current().name) ?? ""
        WorkspaceStore.shared.observe()
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workspace in
                guard let self, let workspace, workspace.name != self.name else {
                    return
                }
                self.name = workspace.name
            }
            .store(in: &bag)
    }

    /// Persist the edited name. An empty/whitespace value is ignored — the name
    /// is required, so a blank field leaves the stored name untouched.
    func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? WorkspaceStore.shared.rename(to: trimmed)
    }
}
