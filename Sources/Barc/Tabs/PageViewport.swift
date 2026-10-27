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
        // WebKit can apply its cached history scroll after didFinish. Hold
        // automatic restoration while the fresher fallback reaches the view.
        // Yield immediately if the user starts interacting in the meantime.
        let script = """
        (() => {
          if (location.href !== \(address)) return;
          let cancelled = false;
          let timeout;
          const previousRestoration = history.scrollRestoration;
          history.scrollRestoration = 'manual';
          const inputs = ['wheel', 'touchstart', 'pointerdown', 'keydown'];
          const cleanup = () => {
            clearTimeout(timeout);
            inputs.forEach(name => document.removeEventListener(name, cancel, true));
            if (history.scrollRestoration === 'manual') history.scrollRestoration = previousRestoration;
          };
          const cancel = () => { cancelled = true; cleanup(); };
          inputs.forEach(name => document.addEventListener(name, cancel, {capture:true, passive:true}));
          // A hidden document may not paint. End the temporary history policy
          // and listeners even when its animation frames are throttled.
          timeout = setTimeout(cancel, 500);
          window.scrollTo({left:\(x), top:\(y), behavior:'instant'});
          requestAnimationFrame(() => requestAnimationFrame(() => {
            if (!cancelled && location.href === \(address)) window.scrollTo({left:\(x), top:\(y), behavior:'instant'});
            cleanup();
          }));
        })();
        """
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }
}
