// Modified for Barc: saved-login suggestions leave keyboard focus with the page, 2026-10-27.
import AppKit
import WebKit

/// Account names stay in native UI; only an explicitly selected login reaches the page.
@MainActor
final class PasswordSuggestionMenu: NSObject {
    private static var active: PasswordSuggestionMenu?
    private weak var webView: WKWebView?
    private weak var owner: NSWindow?
    private let credentials: [PasswordCredential]
    private let panel: LoginSuggestionPanel
    private var buttons: [NSButton] = []
    private var selectedIndex: Int?
    private var completion: CheckedContinuation<PasswordCredential?, Never>?
    private var eventMonitor: Any?

    static func fieldRect(_ value: Any?) -> NSRect? {
        guard let values = value as? [String: Any],
              let x = values["x"] as? Double, let y = values["y"] as? Double,
              let width = values["width"] as? Double, let height = values["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func choose(_ credentials: [PasswordCredential], in webView: WKWebView, field: NSRect) async -> PasswordCredential? {
        guard !credentials.isEmpty else { return nil }
        active?.finish(nil)
        let picker = PasswordSuggestionMenu(credentials: credentials, webView: webView)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                picker.completion = continuation
                guard !Task.isCancelled, picker.show(field: field) else { picker.finish(nil); return }
                active = picker
            }
        } onCancel: {
            Task { @MainActor in picker.finish(nil) }
        }
    }

    static func dismiss(in webView: WKWebView) {
        guard active?.webView === webView else { return }
        active?.finish(nil)
    }

    static func showUnavailable(in webView: WKWebView, field: NSRect) {
        active?.finish(nil)
        let picker = PasswordSuggestionMenu(credentials: [], webView: webView)
        if picker.show(field: field) { active = picker }
    }

    private init(credentials: [PasswordCredential], webView: WKWebView) {
        self.credentials = credentials
        self.webView = webView
        panel = LoginSuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "Saved logins"
        panel.identifier = NSUserInterfaceItemIdentifier("BarcSavedLoginSuggestions")
        panel.setAccessibilityLabel("Saved logins for this profile")
        let background = NSVisualEffectView()
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let heading = NSTextField(labelWithString: credentials.isEmpty ? "Could not unlock saved passwords" : "Saved logins for this profile")
        heading.font = .systemFont(ofSize: 12); heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        if credentials.isEmpty {
            let retry = NSTextField(labelWithString: "Click the login field to retry")
            retry.font = .systemFont(ofSize: 12); stack.addArrangedSubview(retry)
        }
        for (index, credential) in credentials.enumerated() {
            let title = credential.username.isEmpty ? "Saved password" : credential.username
            let button = LoginSuggestionButton(title: title, target: self, action: #selector(pick(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 13); button.imagePosition = .imageLeading
            button.contentTintColor = .labelColor
            button.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true; button.layer?.cornerRadius = 5
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button); buttons.append(button)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    private func show(field: NSRect) -> Bool {
        guard let webView, let owner = webView.window, owner.isVisible,
              !webView.isHiddenOrHasHiddenAncestor else { return false }
        let scale = webView.pageZoom
        let rect = NSRect(x: field.minX * scale,
            y: webView.isFlipped ? field.minY * scale : webView.bounds.height - field.maxY * scale,
            width: field.width * scale, height: field.height * scale).intersection(webView.bounds)
        guard !rect.isEmpty else { return false }
        let anchor = owner.convertToScreen(webView.convert(rect, to: nil))
        let screen = owner.screen?.visibleFrame ?? owner.frame
        let width = min(max(anchor.width, 280), min(420, screen.width))
        let height = min(credentials.isEmpty ? 62 : CGFloat(44 + credentials.count * 34), min(250, screen.height))
        let x = min(max(anchor.minX, screen.minX), screen.maxX - width)
        let below = anchor.minY - height - 4
        let y = max(screen.minY, min(below >= screen.minY ? below : anchor.maxY + 4, screen.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        self.owner = owner
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // A child panel must never become key or replace WebKit's responder.
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(self, selector: #selector(contextChanged), name: name, object: owner)
        }
        center.addObserver(self, selector: #selector(contextChanged), name: NSApplication.didResignActiveNotification, object: nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        return true
    }

    /// Returns ordinary input untouched. Only explicit suggestion navigation is consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let webView, webView.window === owner, !webView.isHiddenOrHasHiddenAncestor else { finish(nil); return event }
        if event.type != .keyDown {
            if event.window !== panel { finish(nil) }
            return event
        }
        guard event.window === owner else { finish(nil); return event }
        let shortcuts = event.modifierFlags.intersection([.command, .control, .option])
        if shortcuts.isEmpty {
            switch event.keyCode {
            case 125, 126:
                guard !credentials.isEmpty else { finish(nil); return event }
                let change = event.keyCode == 125 ? 1 : -1
                let next = selectedIndex.map { ($0 + change + credentials.count) % credentials.count }
                    ?? (change == 1 ? 0 : credentials.count - 1)
                guard credentials.indices.contains(next) else { finish(nil); return event }
                selectedIndex = next
                for (index, button) in buttons.enumerated() {
                    button.layer?.backgroundColor = index == next ? NSColor.selectedContentBackgroundColor.cgColor : nil
                    button.contentTintColor = index == next ? .alternateSelectedControlTextColor : .labelColor
                }
                buttons[next].scrollToVisible(buttons[next].bounds)
                return nil
            case 36, 76:
                if let selectedIndex { finish(credentials[selectedIndex]); return nil }
            case 53:
                finish(nil); return nil
            default: break
            }
        }
        finish(nil)
        return event
    }

    @objc private func pick(_ sender: NSButton) {
        guard credentials.indices.contains(sender.tag) else { return }
        finish(credentials[sender.tag])
    }

    @objc private func contextChanged() { finish(nil) }

    private func finish(_ credential: PasswordCredential?) {
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        let reply = completion; completion = nil
        if Self.active === self { Self.active = nil }
        reply?.resume(returning: credential)
    }
}

@MainActor
private final class LoginSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class LoginSuggestionButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
}
