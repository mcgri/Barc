// Modified for Barc: preserve imported page icons without sharing profile data, 2026-10-24.
import Foundation

struct PageFavicon: Codable, Equatable, Sendable {
    let pageURL: URL
    let data: Data

    func matches(_ url: URL) -> Bool {
        Self.key(for: pageURL).map { $0 == Self.key(for: url) } ?? false
    }

    static func key(for url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        return parts.url?.absoluteString
    }
}
