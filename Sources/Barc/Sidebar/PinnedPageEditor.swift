// Modified for Barc: the retained tab's saved opening URL, 2026-10-24.
import AppKit

@MainActor
final class PinnedPageEditor: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    private let onSave: (URL) -> Void

    init(url: URL, onSave: @escaping (URL) -> Void) {
        self.onSave = onSave
        super.init()
        alert.messageText = "Edit Pinned URL"
        alert.informativeText = "This is what opens first when you click this tab or its favicon."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        field.stringValue = url.absoluteString
        field.placeholderString = "Enter a URL…"
        field.setAccessibilityLabel("Pinned URL")
        field.delegate = self
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        validate()
    }
    static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let candidate = input.contains(":") ? input : "https://" + input
        guard let url = ArcURL.parse(candidate), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "about", "barc"].contains(scheme) else { return nil }
        if ["http", "https"].contains(scheme) {
            guard let host = url.host, !host.isEmpty,
                  !(host.removingPercentEncoding ?? host).contains(where: { $0.isWhitespace }) else { return nil }
        }
        return url
    }
    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() { alert.buttons.first?.isEnabled = Self.url(from: field.stringValue) != nil }
    func present(in window: NSWindow?) {
        if let window {
            alert.beginSheetModal(for: window) { [self] response in finish(response) }
        } else { finish(alert.runModal()) }
    }
    private func finish(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn, let url = Self.url(from: field.stringValue) else { return }
        onSave(url)
    }
}
