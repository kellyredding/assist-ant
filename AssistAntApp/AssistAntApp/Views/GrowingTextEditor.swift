import SwiftUI
import AppKit

/// Multi-line text editor for the capture popover. Return inserts a newline,
/// ⌘Return sends, and it grows to fit its content (never scrolls). Backed by
/// NSTextView for exact key handling; Wispr dictates into it like any native
/// editable text area. Reports a minimum height and grows from there.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 66
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SendingTextView {
        let tv = SendingTextView()
        tv.delegate = context.coordinator
        tv.onSend = onSend
        tv.minHeight = minHeight
        tv.placeholder = placeholder
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return tv
    }

    func updateNSView(_ tv: SendingTextView, context: Context) {
        if tv.string != text {
            tv.string = text
            tv.invalidateIntrinsicContentSize()
        }
        tv.onSend = onSend
        if tv.placeholder != placeholder {
            tv.placeholder = placeholder
            tv.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: GrowingTextEditor
        init(_ parent: GrowingTextEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? SendingTextView else { return }
            parent.text = tv.string
            tv.invalidateIntrinsicContentSize()
            tv.needsDisplay = true // refresh the placeholder
        }
    }
}

/// NSTextView that sends on ⌘Return, draws a placeholder when empty, and grows
/// to fit its content (no scrolling — SwiftUI sizes it to its intrinsic height).
final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?
    var minHeight: CGFloat = 66
    var placeholder: String = ""

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minHeight)
        }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let total = textHeight + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: max(minHeight, ceil(total)))
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Return sends; plain Return falls through to insert a newline.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerInset.width + padding,
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}
