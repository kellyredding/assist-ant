import SwiftUI
import AppKit

/// Bridge allowing SwiftUI to programmatically open the native popup menu
/// on the wrapped NSPopUpButton (e.g. in response to a Space key press).
class PersonaPickerBridge {
    var performClick: (() -> Void)?
}

/// NSViewRepresentable wrapping NSPopUpButton for full native keyboard
/// support: Space opens the popup, arrow keys navigate, Return confirms.
/// Mirrors Galaxy's PersonaPicker.
struct PersonaPicker: NSViewRepresentable {
    var personas: [String]
    @Binding var selection: String?
    var bridge: PersonaPickerBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        context.coordinator.popUpButton = button
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))

        bridge?.performClick = { [weak button] in
            button?.performClick(nil)
        }

        rebuildMenu(button)
        syncSelection(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        rebuildMenu(button)
        syncSelection(button)

        bridge?.performClick = { [weak button] in
            button?.performClick(nil)
        }
    }

    private func rebuildMenu(_ button: NSPopUpButton) {
        let currentTitle = button.titleOfSelectedItem
        button.removeAllItems()
        button.addItem(withTitle: "")
        for persona in personas {
            button.addItem(withTitle: persona)
        }
        // Restore selection after rebuild
        if let title = currentTitle {
            button.selectItem(withTitle: title)
        }
    }

    private func syncSelection(_ button: NSPopUpButton) {
        if let sel = selection {
            if button.titleOfSelectedItem != sel {
                button.selectItem(withTitle: sel)
            }
        } else if button.indexOfSelectedItem != 0 {
            button.selectItem(at: 0)
        }
    }

    class Coordinator: NSObject {
        var parent: PersonaPicker
        weak var popUpButton: NSPopUpButton?

        init(_ parent: PersonaPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if sender.indexOfSelectedItem == 0 {
                parent.selection = nil
            } else {
                parent.selection = sender.titleOfSelectedItem
            }
        }
    }
}
