import Foundation

/// Sites known to refuse Barc while its anti-fingerprinting script is on.
///
/// Only consulted where WebKit's own protection is unavailable and Barc
/// falls back to the script (`NativeFingerprintingProtection`).
///
/// Bot checks such as Akamai's read the very values the protection masks
/// (canvas, audio, WebGL, screen, hardware) and refuse a browser whose
/// readouts do not add up. Rather than switch the protection off for them
/// silently, Barc floats a toggle over these sites so the person decides.
enum FingerprintingCompatibility {
    /// Each entry covers itself and its subdomains, as site settings do.
    ///
    /// Only sites confirmed to break belong here. sso.godaddy.com: sign-in
    /// answers "Your browser is a bit unusual..." with the protection on, and
    /// signs in normally with it off.
    static let knownHosts: Set<String> = [
        "sso.godaddy.com"
    ]

    static func isKnown(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The host to offer the toggle for on `url`, or nil when there is no
    /// toggle to offer: an unknown site, protection off for every site, or
    /// a site the person closed the toggle on.
    static func toggleHost(for url: URL?, protectionEnabled: Bool, dismissed: Set<String>) -> String? {
        guard protectionEnabled, isKnown(url), let host = url?.host()?.lowercased() else { return nil }
        return dismissed.contains(host) ? nil : host
    }
}
