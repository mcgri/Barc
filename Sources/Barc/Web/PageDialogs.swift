import AppKit
import WebKit

/// `alert()`, `confirm()` and `prompt()`. WebKit shows nothing unless the UI
/// delegate answers, and Barc's never did: alerts vanished and every confirm
/// silently answered Cancel, so "Delete this?" quietly did nothing.
///
/// Each dialog is a sheet on the page's window naming the site that asked. A
/// page that is not in a window (a background tab) gets WebKit's default
/// answer straight away, as before, rather than a dialog over another tab.
/// From a page's second dialog on, the person can stop it showing more.
@MainActor
enum PageDialogs {
    enum Kind { case alert, confirm, prompt(defaultText: String?) }
    enum Answer: Equatable { case dismissed, confirmed, cancelled, text(String) }

    /// Tests answer for the person; the alert is fully configured.
    static var testResponder: ((NSAlert) -> Answer)?

    /// Dialog counts and the person's "no more" per page, until it navigates.
    private final class PageState {
        var url: URL?
        var shown = 0
        var silenced = false
    }
    private static let states = NSMapTable<WKWebView, PageState>.weakToStrongObjects()

    static func alert(_ message: String, frame: WKFrameInfo, in webView: WKWebView, completion: @escaping @MainActor () -> Void) {
        present(.alert, message: message, frame: frame, in: webView) { _ in completion() }
    }

    static func confirm(_ message: String, frame: WKFrameInfo, in webView: WKWebView, completion: @escaping @MainActor (Bool) -> Void) {
        present(.confirm, message: message, frame: frame, in: webView) { completion($0 == .confirmed) }
    }

    static func prompt(_ message: String, defaultText: String?, frame: WKFrameInfo, in webView: WKWebView,
                       completion: @escaping @MainActor (String?) -> Void) {
        present(.prompt(defaultText: defaultText), message: message, frame: frame, in: webView) { answer in
            if case .text(let text) = answer { completion(text) } else { completion(nil) }
        }
    }

    /// "example.com says", or for a frame from elsewhere, "An embedded page at
    /// ads.example says": a page cannot pass its words off as another site's.
    static func title(for frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        if host.isEmpty { return frame.isMainFrame ? "This page says" : "An embedded page says" }
        return frame.isMainFrame ? "\(host) says" : "An embedded page at \(host) says"
    }

    private static func present(_ kind: Kind, message: String, frame: WKFrameInfo, in webView: WKWebView,
                                completion: @escaping @MainActor (Answer) -> Void) {
        let state = states.object(forKey: webView) ?? PageState()
        states.setObject(state, forKey: webView)
        if state.url != webView.url { state.url = webView.url; state.shown = 0; state.silenced = false }
        let window = webView.window
        guard !state.silenced, window != nil || testResponder != nil else { completion(.cancelled); return }
        state.shown += 1

        let alert = NSAlert()
        alert.messageText = title(for: frame)
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        var field: NSTextField?
        switch kind {
        case .alert: break
        case .confirm: alert.addButton(withTitle: "Cancel")
        case .prompt(let defaultText):
            alert.addButton(withTitle: "Cancel")
            let input = NSTextField(string: defaultText ?? "")
            input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = input
            field = input
        }
        if state.shown > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show more dialogs from this page"
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on { state.silenced = true }
            guard response == .alertFirstButtonReturn else { completion(.cancelled); return }
            switch kind {
            case .alert: completion(.dismissed)
            case .confirm: completion(.confirmed)
            case .prompt: completion(.text(field?.stringValue ?? ""))
            }
        }
        if let testResponder {
            let answer = testResponder(alert)
            if alert.suppressionButton?.state == .on { state.silenced = true }
            completion(answer)
            return
        }
        guard let window else { completion(.cancelled); return }
        if let field { alert.window.initialFirstResponder = field }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
