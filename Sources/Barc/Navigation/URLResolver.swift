// Modified for Barc: consistent address fixup, IPv6 and authority validation, 2026-10-25.
import Foundation
import Darwin

/// Turns raw address-bar text into something navigable.
///
/// This is the omnibox decision: is the user typing a URL, or a search? Kept as
/// pure, dependency-free logic so it can be unit tested without a web view.
enum URLResolver {
    /// Schemes we hand straight to WebKit when the user types them explicitly.
    private static let passthroughSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "javascript"
    ]

    /// Hosts that are valid without a dot.
    private static let dotlessHosts: Set<String> = ["localhost"]

    static func resolve(_ input: String, using engine: SearchEngine = .duckDuckGo) -> URL? {
        resolve(input, using: engine, engines: [])
    }

    /// As above, with quick searches: a first word that is an engine's
    /// keyword, followed by anything, searches that engine instead.
    static func resolve(_ input: String, using engine: SearchEngine, engines: [SearchEngine]) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let quick = quickSearch(text, engines: engines) {
            return quick.engine.url(for: quick.query)
        }

        return navigationURL(text) ?? engine.url(for: text)
    }

    /// The direct destination an address-shaped input names, without turning
    /// ordinary search words into a search-engine URL.
    static func navigationURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        // A pasted web scheme may be missing one or both slashes. This is a
        // typed-address fixup only; unsupported schemes still remain searches.
        if let colon = text.firstIndex(of: ":"),
           ["http", "https"].contains(text[..<colon].lowercased()) {
            let scheme = text[..<colon].lowercased()
            let remainder = text[text.index(after: colon)...].replacingOccurrences(of: "\\", with: "/")
            return webURL("\(scheme)://\(remainder.drop(while: { $0 == "/" }))")
        }
        if let scheme = explicitScheme(of: text) {
            return passthroughSchemes.contains(scheme) ? URL(string: text) : nil
        }
        let address = text.hasPrefix("//") ? String(text.dropFirst(2)) : text
        guard let url = webURL("\(defaultScheme(for: address))://\(address)"),
              let host = host(of: address), text.hasPrefix("//") || looksLikeHost(host, in: address),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // A bare email address is a query. A path, port or password supplies
        // additional navigation intent for an HTTP user-info destination.
        if parts.user != nil && parts.password == nil && parts.port == nil && parts.path.isEmpty
            && parts.query == nil && parts.fragment == nil { return nil }
        return url
    }

    /// `g cats` with an engine whose keyword is `g`. The keyword alone is not
    /// a search; there is nothing to search for.
    ///
    /// A bang works too, at either end: `!g cats` and `cats !g` search the
    /// engine whose keyword is `g`, the way DuckDuckGo's own bangs read.
    static func quickSearch(_ text: String, engines: [SearchEngine]) -> (engine: SearchEngine, query: String)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }

        func engine(forKeyword word: Substring) -> SearchEngine? {
            let keyword = word.lowercased()
            return engines.first(where: { $0.keyword == keyword })
        }

        if let engine = engine(forKeyword: words[0]) {
            return (engine, words.dropFirst().joined(separator: " "))
        }
        if let bang = bang(in: words[0]), let engine = engine(forKeyword: bang) {
            return (engine, words.dropFirst().joined(separator: " "))
        }
        if let last = words.last, let bang = bang(in: last), let engine = engine(forKeyword: bang) {
            return (engine, words.dropLast().joined(separator: " "))
        }
        return nil
    }

    /// The keyword in `!keyword`, or nil when the word is not a bang.
    private static func bang(in word: Substring) -> Substring? {
        guard word.count >= 2, word.first == "!" else { return nil }
        let keyword = word.dropFirst()
        guard !keyword.contains("!") else { return nil }
        return keyword
    }

    /// Schemes that are legitimately written without `//` after the colon.
    private static let opaqueSchemes: Set<String> = [
        "about", "data", "javascript", "blob", "mailto", "tel", "sms"
    ]

    /// Returns the lowercased scheme if the text really starts with `scheme:`.
    ///
    /// The colon alone is not enough: `localhost:8080` is a host and a port, not
    /// a `localhost` scheme. A scheme is recognised only when it is followed by
    /// `//` or when it is a known opaque scheme.
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = String(text[text.startIndex..<colon])
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
            return nil
        }

        let rest = text[text.index(after: colon)...]
        let scheme = candidate.lowercased()
        let customPathScheme = rest.hasPrefix("/") && !candidate.contains(".") && !dotlessHosts.contains(scheme)
        if rest.hasPrefix("//") || opaqueSchemes.contains(scheme) || passthroughSchemes.contains(scheme) || customPathScheme {
            return scheme
        }
        return nil
    }

    /// `https` for the web, `http` for this machine and the local network.
    ///
    /// A development server on `localhost:8080` or `192.168.1.5` has no
    /// certificate, so an upgraded address there never loads: it fails with a
    /// certificate error and no way to try plain HTTP short of typing the
    /// scheme. Safari and Chrome make the same exception.
    static func defaultScheme(for text: String) -> String {
        guard let host = host(of: text) else { return "https" }
        return isLocal(host: host) || (!host.contains(".") && ipv6Bytes(host) == nil) ? "http" : "https"
    }

    /// Validate the authority separately from the resource. Foundation escapes
    /// spaces in paths/queries, but spaces in a host must never become a URL.
    private static func webURL(_ text: String) -> URL? {
        guard let separator = text.range(of: "://") else { return nil }
        let authority = text[separator.upperBound...].prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty, !authority.contains(where: \.isWhitespace),
              !authority.contains("\\"),
              let parts = URLComponents(string: text), let host = parts.host,
              validHost(host), parts.port.map({ (0...65535).contains($0) }) ?? true,
              let url = parts.url, url.host() != nil else { return nil }
        return url
    }

    /// The host portion of schemeless text, including IPv6 brackets.
    private static func host(of text: String) -> String? {
        let authority = text.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty, !authority.contains(where: \.isWhitespace) else { return nil }
        return URLComponents(string: "http://\(authority)")?.host
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let name = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        guard name.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// Local names, loopback, private and link-local addresses use HTTP.
    private static func isLocal(host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        if let bytes = ipv6Bytes(name) {
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return true }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
            // IPv4-mapped addresses inherit the embedded address's policy.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocal(host: bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            return false
        }
        guard isIPv4(name) else { return false }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    private static func validHost(_ host: String) -> Bool {
        if ipv6Bytes(host) != nil { return true }
        guard !host.contains(":"), !host.contains("["), !host.contains("]") else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static func looksLikeHost(_ host: String, in address: String) -> Bool {
        if ipv6Bytes(host) != nil || isIPv4(host) { return true }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if dotlessHosts.contains(name.lowercased()) { return true }
        // Chromium treats an explicit slash as navigation intent for an
        // intranet name. An ordinary single word still searches.
        if !name.contains(".") { return address.contains("/") || URLComponents(string: "http://\(address)")?.port != nil }
        guard let tld = name.split(separator: ".").last else { return false }
        return (tld.count >= 2 && tld.allSatisfy(\.isLetter)) || tld.lowercased().hasPrefix("xn--")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 3 && label.allSatisfy(\.isNumber) && (Int(label) ?? 256) <= 255
        }
    }
}
