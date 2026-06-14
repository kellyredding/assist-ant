import SwiftUI
import AppKit

/// Multi-line text editor for the capture popover. Return inserts a newline,
/// ⌘Return sends. Backed by NSTextView for exact key handling; Wispr dictates
/// into it like any native editable text area. The field grows with its content
/// from `minHeight` up to `maxHeight`, then holds that height and scrolls
/// internally so a long capture never keeps stretching the popover.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 66
    /// Height ceiling. Past this the field stops growing and scrolls; ~440pt is
    /// roughly two dozen lines — a comfortable draft before the popover would
    /// otherwise dominate the screen.
    var maxHeight: CGFloat = 440
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GrowingScrollView {
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
        tv.autoresizingMask = [.width]
        // Floor the document view at minHeight so the whole resting field is the
        // editor (click anywhere to focus), not a one-line view atop dead space.
        tv.minSize = NSSize(width: 0, height: minHeight)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        // The scroll view is what SwiftUI sizes: its intrinsic height is the
        // text height clamped to [minHeight, maxHeight], so the field grows to
        // the cap and then scrolls the (taller) text view inside it.
        let scroll = GrowingScrollView()
        scroll.textView = tv
        scroll.maxHeight = maxHeight
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay     // floats over content; takes no width
        scroll.borderType = .noBorder
        scroll.drawsBackground = false       // the SwiftUI rounded fill shows through
        scroll.backgroundColor = .clear
        return scroll
    }

    func updateNSView(_ scroll: GrowingScrollView, context: Context) {
        guard let tv = scroll.textView else { return }
        if tv.string != text {
            tv.string = text
            tv.invalidateIntrinsicContentSize()
            scroll.invalidateIntrinsicContentSize()
        }
        tv.onSend = onSend
        tv.minHeight = minHeight
        tv.minSize = NSSize(width: 0, height: minHeight)
        scroll.maxHeight = maxHeight
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
            // The clamped height lives on the scroll view, so refresh it too.
            (tv.enclosingScrollView as? GrowingScrollView)?.invalidateIntrinsicContentSize()
            tv.needsDisplay = true // refresh the placeholder
        }
    }
}

/// Scroll view that reports a clamped intrinsic height — the document text
/// view's natural height, capped at `maxHeight`. Below the cap the field and
/// its content are the same height (no scrolling); at the cap the text view
/// stays taller and scrolls within.
final class GrowingScrollView: NSScrollView {
    weak var textView: SendingTextView?
    var maxHeight: CGFloat = 440

    override var intrinsicContentSize: NSSize {
        let natural = textView?.intrinsicContentSize.height ?? textView?.minHeight ?? 0
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: min(natural, maxHeight))
    }
}

/// NSTextView that sends on ⌘Return, draws a placeholder when empty, and reports
/// its full content height (floored at `minHeight`) as its intrinsic size — the
/// scroll view clamps that to a max and scrolls past it.
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
