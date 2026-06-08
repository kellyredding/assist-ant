import SwiftUI
import Combine

/// Title-bar pill showing the active workspace's name. Clicking it opens the
/// Workspace settings tab. This is the reserved home for sync status/errors
/// once the sync backend exists.
struct WorkspacePill: View {
    @StateObject private var model = WorkspacePillModel()

    var body: some View {
        Button {
            PreferencesWindowController.showPreferences(initialTab: .workspace)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow").imageScale(.small)
                Text(model.name).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Workspace — click to open settings")
    }
}

/// Seeds the pill's label synchronously from the store, then tracks renames
/// live.
@MainActor
final class WorkspacePillModel: ObservableObject {
    @Published var name: String
    private var bag = Set<AnyCancellable>()

    init() {
        self.name = (try? WorkspaceStore.shared.current().name)
            ?? Workspace.defaultName()
        WorkspaceStore.shared.observe()
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workspace in
                self?.name = workspace?.name ?? ""
            }
            .store(in: &bag)
    }
}
