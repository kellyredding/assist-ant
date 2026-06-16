import SwiftUI

/// The Quick Capture popover's content: a centered glyph chooser + a growing
/// native text field (type or dictate via Wispr) + Send. Send routes through
/// `onSend`, which delivers Ask to the live agent and item kinds to the ingest
/// skill; it returns an error string (shown inline, popover kept open) or nil on
/// success (the controller dismisses).
struct CaptureContentView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject private var agent = AgentSessionController.shared
    var colorScheme: ColorScheme?
    var onKindSelected: () -> Void = {}
    var onClose: () -> Void
    /// Performs the send. Returns nil on success (the controller dismisses) or an
    /// error message to show inline while keeping the captured content.
    var onSend: (CaptureKind, String) -> String?

    @State private var text: String = ""
    @State private var sendError: String?

    // ⌘1–⌘4 select a kind. (The bare-number / arrow chooser-state machine is a
    // follow-up refinement; ⌘-number avoids fighting typing for now.)
    private let numberKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5"]

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

            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(sendError != nil ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        .onChange(of: text) { _, _ in sendError = nil }
        .onChange(of: model.kind) { _, _ in sendError = nil }
    }

    private var agentRunning: Bool { agent.state == .running }

    /// The inline status line: a send error takes precedence (red); otherwise a
    /// passive heads-up when the agent isn't running (orange), so the user knows
    /// a send won't go through before committing to one.
    private var statusMessage: String? {
        if let sendError { return sendError }
        if !agentRunning {
            return "Agent isn’t running — start it from the main window, then send."
        }
        return nil
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
        // onSend delivers to the live agent and, on success, the controller
        // dismisses (Ask surfaces the agent; items restore the prior app). On
        // failure it returns a message — keep the popover open and the content.
        if let error = onSend(model.kind, trimmed) {
            sendError = error
        }
    }
}
