// Modified for Barc: explicit scroll fallback for hibernated documents, 2026-10-26.
import Foundation
import WebKit

/// Interaction state can lag a recent scroll. Retain only coordinates and the
/// exact document URL as a fallback, without collecting page or form contents.
struct PageViewport: Codable, Equatable, Sendable {
    let url: URL
    let x: Double
    let y: Double

    var isValid: Bool { x.isFinite && y.isFinite && abs(x) < 100_000_000 && abs(y) < 100_000_000 }

    @MainActor
    func restore(in view: WKWebView) {
        guard isValid else { return }
        let address = WebNotificationCentre.javaScriptString(url.absoluteString)
        let script = "if (location.href === \(address)) { window.scrollTo(\(x), \(y)); }"
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }
}
