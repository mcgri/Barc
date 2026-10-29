import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("WebKit's own fingerprinting protection")
@MainActor
struct NativeFingerprintingProtectionTests {
    /// Sets the protection on each navigation, the way `Tab` does.
    private final class Navigator: NSObject, WKNavigationDelegate {
        let protect: Bool
        var continuation: CheckedContinuation<Void, Never>?
        init(protect: Bool) { self.protect = protect }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            NativeFingerprintingProtection.set(protect, in: preferences)
            return (.allow, preferences)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A canvas drawn the same way every time, read back as a hash, and
    /// whether the page's functions and screen are WebKit's own.
    private static let probe = """
        var c = document.createElement('canvas'); c.width = 200; c.height = 50;
        var x = c.getContext('2d'); x.textBaseline = 'top'; x.font = '16px Helvetica';
        x.fillStyle = '#f60'; x.fillRect(10, 10, 100, 20); x.fillStyle = '#069'; x.fillText('Barc fingerprint', 2, 15);
        var d = x.getImageData(0, 0, 200, 50).data, h = 0;
        for (var i = 0; i < d.length; i++) { h = (h * 31 + d[i]) | 0; }
        return [h, HTMLCanvasElement.prototype.toDataURL.toString().indexOf('[native code]') >= 0,
                Object.getOwnPropertyDescriptor(screen, 'availWidth') === undefined].join(',');
        """

    private func readouts(protect: Bool, policy: SitePolicy? = nil) async throws -> [String] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let policy {
            policy.attach(configuration.userContentController)
            policy.apply(for: URL(string: "https://site.example/")!, to: configuration.userContentController)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let navigator = Navigator(protect: protect)
        webView.navigationDelegate = navigator
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigator.continuation = continuation
            webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://site.example/"))
        }
        let result = try await webView.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, contentWorld: .page) as? String
        return (result ?? "").split(separator: ",").map(String.init)
    }

    @Test("Setting the protection keeps WebKit's other privacy protections as they were")
    func keepsOtherBits() throws {
        try #require(NativeFingerprintingProtection.isAvailable, "This WebKit has no native fingerprinting protection")
        let preferences = WKWebpagePreferences()
        NativeFingerprintingProtection.write(1 << 1, to: preferences)
        #expect(NativeFingerprintingProtection.set(true, in: preferences))
        #expect(NativeFingerprintingProtection.isEnabled(in: preferences))
        #expect(NativeFingerprintingProtection.read(preferences) == (1 << 1) | (1 << 6))
        NativeFingerprintingProtection.set(false, in: preferences)
        #expect(!NativeFingerprintingProtection.isEnabled(in: preferences))
        #expect(NativeFingerprintingProtection.read(preferences) == 1 << 1)
    }

    @Test("The choice made on navigation reaches the page, and leaves its functions WebKit's own")
    func navigationChoiceReachesThePage() async throws {
        try #require(NativeFingerprintingProtection.isAvailable, "This WebKit has no native fingerprinting protection")
        let plain = try await readouts(protect: false)
        let plainAgain = try await readouts(protect: false)
        let protected = try await readouts(protect: true)
        #expect(plain.count == 3 && protected.count == 3)
        // Without the protection the canvas reads back the same each time;
        // with it, the readout carries WebKit's noise.
        #expect(plain[0] == plainAgain[0])
        #expect(protected[0] != plain[0])
        #expect(protected[1] == "true" && protected[2] == "true")
    }

    @Test("With WebKit's protection, Barc's anti-fingerprinting script stands down")
    func scriptStandsDown() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "barc-sites-\(UUID().uuidString).json")
        let withNative = SitePolicy(settings: SiteSettings(file: file), nativeFingerprinting: true)
        let readings = try await readouts(protect: false, policy: withNative)
        #expect(readings.count == 3)
        #expect(readings[1] == "true" && readings[2] == "true")

        let scriptOnly = SitePolicy(settings: SiteSettings(file: file), nativeFingerprinting: false)
        let scripted = try await readouts(protect: false, policy: scriptOnly)
        #expect(scripted[1] == "false" && scripted[2] == "false")
    }
}
