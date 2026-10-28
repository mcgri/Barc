// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit
import Foundation
import WebKit

/// Coordinates Link Hints mode between WebKit and Barc.
///
/// Attaches a message handler in `.defaultClient` world, injects the hints script
/// into the focused or active web view, and opens tabs or performs navigation
/// when a target link or button is chosen.
@MainActor
public final class LinkHintsCoordinator: NSObject {
    public static let shared = LinkHintsCoordinator()

    public static let handlerName = "barcLinkHints"

    public var onOpenNewTab: ((URL) -> Void)?
    private let settings: Settings

    override public init() {
        settings = .shared
        super.init()
    }

    init(settings: Settings) {
        self.settings = settings
        super.init()
    }

    /// Registers the message handler in the configuration's content controller.
    public func attach(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)
    }

    /// Triggers link hints overlay in the given web view.
    public func showHints(in webView: WKWebView?, openInNewTab: Bool = false) {
        guard let webView, let js = script(openInNewTab: openInNewTab) else { return }
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
    }

    func script(openInNewTab: Bool) -> String? {
        guard settings.linkHintsEnabled else { return nil }
        return LinkHintsScript.script(openInNewTab: openInNewTab)
    }
}

extension LinkHintsCoordinator: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String
        else { return }

        switch action {
        case "openNewTab":
            guard let urlString = dict["url"] as? String,
                  let url = URL(string: urlString)
            else { return }

            if let onOpenNewTab {
                onOpenNewTab(url)
                return
            }

            if let window = message.webView?.window?.windowController as? BrowserWindowController {
                _ = window.session.newTab(url: url)
                window.session.showToast?(
                    Toast(
                        symbolName: "link.badge.plus",
                        message: "Opened in new tab",
                        identity: "link-hints-tab"
                    )
                )
            }

        default:
            break
        }
    }
}
