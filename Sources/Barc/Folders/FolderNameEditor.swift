// Modified for Barc: inline folder naming with Arc's commit and cancel behavior, 2026-10-24.
import AppKit

@MainActor
final class FolderNameEditor: NSTextField, NSTextFieldDelegate {
    private let onFinish: (String?) -> Void
    private var finished = false

    init(name: String, onFinish: @escaping (String?) -> Void) {
        self.onFinish = onFinish
        super.init(frame: .zero)
        stringValue = name
        placeholderString = "Folder Title"
        font = Style.Fonts.groupHeader
        textColor = Style.Colors.primaryText
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.sendsActionOnEndEditing = false
        delegate = self
        setAccessibilityLabel("Folder name")
    }

    required init?(coder: NSCoder) { fatalError("FolderNameEditor is created in code only") }

    func beginEditing() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    func commit() { validateEditing(); finish(stringValue) }
    func cancel() { finish(nil) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        onFinish(value)
    }
}
