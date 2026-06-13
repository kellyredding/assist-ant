import SwiftUI

/// The Quick Capture popover's content: a centered glyph chooser + a growing
/// native text field (type or dictate via Wispr) + a stubbed Send. Phase 1 —
/// "send" only logs; wiring to the live agent / inbox lands in later phases.
struct CaptureContentView: View {
    @ObservedObject var model: CaptureModel
    var colorScheme: ColorScheme?
    var onKindSelected: () -> Void = {}
    var onClose: () -> Void

    @State private var text: String = ""

    // ⌘1–⌘4 select a kind. (The bare-number / arrow chooser-state machine is a
    // follow-up refinement; ⌘-number avoids fighting typing for now.)
    private let numberKeys: [KeyEquivalent] = ["1", "2", "3", "4"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(CaptureKind.allCases.enumerated()), id: \.element.id) { idx, k in
                    chooserGlyph(k, index: idx)
                }
                Spacer(minLength: 0)
            }

            GrowingTextEditor(text: $text, placeholder: placeholder, onSend: send)
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(colorScheme)
        .onExitCommand { onClose() }
    }

    private var placeholder: String {
        model.kind == .ask
            ? "Ask the agent… (type or dictate)"
            : "Capture a \(model.kind.title.lowercased())…"
    }

    private var hint: String {
        "\(model.kind.title) · return for newline · ⌘⏎ to send · esc to close"
    }

    private func chooserGlyph(_ k: CaptureKind, index: Int) -> some View {
        let selected = (k == model.kind)
        return Button {
            model.kind = k
            onKindSelected()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: k.sfSymbol).font(.system(size: 16))
                Text(k.title).font(.caption2)
            }
            .frame(width: 70, height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 8)) // full-cell hit area
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
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Phase 1: stubbed — log what would be sent. Wiring lands in Phase 2.
        NSLog("QuickCapture: [\(model.kind.rawValue)] would send: \(trimmed)")
        onClose()
    }
}
