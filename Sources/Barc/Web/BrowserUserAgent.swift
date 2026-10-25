// Added for Barc: identify the system WebKit generation to browser-gated sites, 2026-10-25.
import Foundation

/// WKWebView's bare default omits Version and Safari tokens. Sites such as
/// Gmail consequently treat a current system WebKit as an unsupported browser.
/// Track the bundled Safari release instead of freezing a version in source.
enum BrowserUserAgent {
    static let safariVersion: String? = {
        for path in ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"] {
            guard let version = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !version.isEmpty,
                  version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                  }) else { continue }
            return version
        }
        // Do not invent an engine version if Safari's metadata is unavailable.
        return nil
    }()

    /// Appended through WebKit's public configuration API. WebKit supplies the
    /// platform and engine tokens itself, for both request headers and JS.
    static var applicationName: String? {
        safariVersion.map { "Version/\($0) Safari/605.1.15" }
    }

    /// Explicit per-site Safari mode must override a profile's custom identity.
    /// The platform and WebKit tokens match macOS WebKit's frozen desktop UA.
    static var safari: String? {
        applicationName.map { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + $0 }
    }
}
