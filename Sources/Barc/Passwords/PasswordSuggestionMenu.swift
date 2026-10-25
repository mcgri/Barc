// Modified for Barc: native saved-login choices anchored to login fields, 2026-10-25.
import AppKit
import WebKit

/// Account names stay in native UI; only the selected login reaches the page.
@MainActor
final class PasswordSuggestionMenu: NSObject {
    private var selectedIndex: Int?

    static func fieldRect(_ value: Any?) -> NSRect? {
        guard let values = value as? [String: Any],
              let x = values["x"] as? Double, let y = values["y"] as? Double,
              let width = values["width"] as? Double, let height = values["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func choose(_ credentials: [PasswordCredential], in webView: WKWebView, field: NSRect) -> PasswordCredential? {
        let picker = PasswordSuggestionMenu()
        let menu = NSMenu()
        menu.addItem(withTitle: "Saved logins for this profile", action: nil, keyEquivalent: "").isEnabled = false
        if credentials.isEmpty {
            menu.addItem(withTitle: "No saved logins for this site", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            menu.addItem(.separator())
            for (index, credential) in credentials.enumerated() {
                let title = credential.username.isEmpty ? "Saved password" : credential.username
                let item = NSMenuItem(title: title, action: #selector(picker.pick(_:)), keyEquivalent: "")
                item.target = picker; item.tag = index
                item.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        show(menu, in: webView, field: field)
        return picker.selectedIndex.flatMap { credentials.indices.contains($0) ? credentials[$0] : nil }
    }

    static func showUnavailable(in webView: WKWebView, field: NSRect) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Couldn’t unlock saved passwords", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Click the login field to retry", action: nil, keyEquivalent: "").isEnabled = false
        show(menu, in: webView, field: field)
    }

    private static func show(_ menu: NSMenu, in webView: WKWebView, field: NSRect) {
        guard webView.window != nil else { return }
        let scale = webView.pageZoom
        let x = min(max(field.minX * scale, 0), webView.bounds.width)
        let topY = min(max(field.maxY * scale, 0), webView.bounds.height)
        let y = webView.isFlipped ? topY : webView.bounds.height - topY
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: webView)
    }

    @objc private func pick(_ sender: NSMenuItem) { selectedIndex = sender.tag }
}
