import SwiftUI

/// The Quick Capture popover's content: a glyph chooser row + a native text
/// field (type or dictate via Wispr) + a stubbed Send. Phase 1 — "send" only
/// logs; wiring to the live agent / inbox lands in later phases.
struct CaptureContentView: View {
    var onClose: () -> Void

    @State private var kind: CaptureKind = .ask
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    // ⌘1–⌘4 select a kind. (The bare-number / arrow chooser-state machine is a
    // follow-up refinement; ⌘-number avoids fighting typing for now.)
    private let numberKeys: [KeyEquivalent] = ["1", "2", "3", "4"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(CaptureKind.allCases.enumerated()), id: \.element.id) { idx, k in
                    chooserGlyph(k, index: idx)
                }
                Spacer()
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3...6)
                .focused($fieldFocused)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.25)))

            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onExitCommand { onClose() }
    }

    private var placeholder: String {
        kind == .ask
            ? "Ask the agent… (type or dictate)"
            : "Capture a \(kind.title.lowercased())…"
    }

    private var hint: String { "\(kind.title) · ⌘⏎ to send · esc to close" }

    private func chooserGlyph(_ k: CaptureKind, index: Int) -> some View {
        let selected = (k == kind)
        return Button {
            kind = k
            fieldFocused = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: k.sfSymbol).font(.system(size: 16))
                Text(k.title).font(.caption2)
            }
            .frame(width: 70, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(numberKeys[index], modifiers: [.command])
        .help("\(k.title) (⌘\(index + 1))")
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Phase 1: stubbed — log what would be sent. Wiring lands in Phase 2.
        NSLog("QuickCapture: [\(kind.rawValue)] would send: \(trimmed)")
        onClose()
    }
}
