// Modified for Barc: Arc-style local development address hints, 2026-10-24.
import Foundation

enum SidebarLocalAddress {
    static func label(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost") else { return nil }
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return displayHost + (url.port.map { ":\($0)" } ?? "")
    }
}
