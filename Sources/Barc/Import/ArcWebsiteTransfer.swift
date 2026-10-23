import Foundation
import WebKit

enum ArcLocalStorageReader {
    struct EncodedPair: Sendable {
        let key: String
        let value: String
    }
    struct Contents: Sendable {
        var origins: [String: [String: String]] = [:]
        var encodedOrigins: [String: [EncodedPair]] = [:]
        var source = 0
        var unsupported = 0
        var invalid = 0
    }
    static func text(_ raw: Data) -> String? {
        guard let tag = raw.first else { return "" }
        switch tag {
        case 1: return String(data: raw.dropFirst(), encoding: .isoLatin1)
        case 0: return String(data: raw.dropFirst(), encoding: .utf16LittleEndian)
        default: return nil
        }
    }
    /// JavaScript strings may contain unpaired UTF-16 surrogates, which Swift
    /// String cannot represent. Keep those code units intact for WebKit.
    static func encodedUTF16(_ raw: Data) -> String? {
        guard let tag = raw.first else { return "" }
        if tag == 0 {
            guard (raw.count - 1).isMultiple(of: 2) else { return nil }
            return raw.dropFirst().base64EncodedString()
        }
        if tag == 1 { return Data(raw.dropFirst().flatMap { [$0, UInt8(0)] }).base64EncodedString() }
        return nil
    }
    static func read(_ profile: URL) throws -> Contents {
        let path = profile.appending(path: "Local Storage/leveldb")
        guard FileManager.default.fileExists(atPath: path.appending(path: "CURRENT").path) else { return Contents() }
        let records = try ArcLevelDBReader.read(path)
        var output = Contents()
        for (key, entry) in records {
            guard let value = entry.value, key.first == 0x5f, let separator = key.dropFirst().firstIndex(of: 0) else { continue }
            output.source += 1
            guard let origin = String(data: key[1..<separator], encoding: .utf8), !origin.contains("^"),
                  let components = URLComponents(string: origin), let scheme = components.scheme,
                  ["http", "https"].contains(scheme), components.host != nil, components.user == nil,
                  components.password == nil, components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/" else { output.unsupported += 1; continue }
            let canonical = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let rawKey = Data(key.dropFirst(separator + 1))
            if let name = text(rawKey), let value = text(value) {
                output.origins[canonical, default: [:]][name] = value
            } else if let name = encodedUTF16(rawKey), let value = encodedUTF16(value) {
                output.encodedOrigins[canonical, default: []].append(EncodedPair(key: name, value: value))
            } else { output.invalid += 1 }
        }
        return output
    }
}

@MainActor
enum ArcCookieTransfer {
    static func nativeCookie(_ input: ArcProfileReader.Cookie) -> HTTPCookie? {
        guard !input.partitioned else { return nil }
        if input.name.hasPrefix("__Host-") && (input.domain.hasPrefix(".") || input.path != "/" || !input.secure) { return nil }
        if input.name.hasPrefix("__Secure-") && !input.secure { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: input.name, .value: input.value, .domain: input.domain, .path: input.path,
            .version: 0
        ]
        if let expires = input.expires { properties[.expires] = expires }
        else { properties[.discard] = "TRUE" }
        if input.secure { properties[.secure] = "TRUE" }
        if input.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch input.sameSite {
        case 0: properties[.sameSitePolicy] = "None"
        case 1: properties[.sameSitePolicy] = "Lax"
        case 2: properties[.sameSitePolicy] = "Strict"
        default: break
        }
        return HTTPCookie(properties: properties)
    }

    static func key(_ cookie: HTTPCookie) -> String { cookie.domain + "\u{0}" + cookie.path + "\u{0}" + cookie.name }

    static func matches(_ native: HTTPCookie, expected: ArcProfileReader.Cookie) -> Bool {
        guard native.value == expected.value, native.domain == expected.domain, native.path == expected.path,
              native.isSecure == expected.secure, native.isHTTPOnly == expected.httpOnly else { return false }
        if let date = expected.expires {
            guard let actual = native.expiresDate, abs(actual.timeIntervalSince(date)) <= 1 else { return false }
        } else if !native.isSessionOnly || native.expiresDate != nil { return false }
        let policy = native.sameSitePolicy?.rawValue.lowercased()
        switch expected.sameSite {
        case 0: return policy == "none"
        case 1: return policy == "lax"
        case 2: return policy == "strict"
        default: return true
        }
    }

    static func transfer(_ input: ArcProfileReader.ReadResult<ArcProfileReader.Cookie>, to store: WKWebsiteDataStore) async -> ArcImportReport.Count {
        var result = ArcImportReport.Count(source: input.source, skipped: input.skipped, failed: input.failed)
        if input.failed > 0 { result.failureReasons = ["Unreadable source cookies": input.failed] }
        let existing = await store.httpCookieStore.allCookies()
        let known = Dictionary(existing.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var planned: [(HTTPCookie, ArcProfileReader.Cookie)] = []
        for row in input.records {
            if row.partitioned {
                result.skipped += 1
                result.skipReasons = (result.skipReasons ?? [:]).merging(["Partitioned cookies": 1], uniquingKeysWith: +)
                continue
            }
            if row.expires.map({ $0 <= Date() }) ?? false {
                result.skipped += 1
                result.skipReasons = (result.skipReasons ?? [:]).merging(["Expired cookies": 1], uniquingKeysWith: +)
                continue
            }
            guard let native = nativeCookie(row) else {
                result.failed += 1
                result.failureReasons = (result.failureReasons ?? [:]).merging(["Unsupported cookie attributes": 1], uniquingKeysWith: +)
                continue
            }
            guard matches(native, expected: row) else {
                result.failed += 1
                result.failureReasons = (result.failureReasons ?? [:]).merging(["Native cookie attributes differ": 1], uniquingKeysWith: +)
                continue
            }
            if let existing = known[key(native)] {
                result.existing += 1
                if matches(existing, expected: row) { result.verified += 1 }
                continue
            }
            planned.append((native, row))
        }
        for start in stride(from: 0, to: planned.count, by: 32) {
            let batch = Array(planned[start..<min(start + 32, planned.count)])
            await withCheckedContinuation { continuation in
                let pending = CookieBatch(count: batch.count, done: { continuation.resume() })
                for (cookie, _) in batch {
                    store.httpCookieStore.setCookie(cookie) { Task { @MainActor in pending.finishedOne() } }
                }
            }
        }
        let actual = Dictionary((await store.httpCookieStore.allCookies()).map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for (cookie, source) in planned {
            if let saved = actual[key(cookie)], matches(saved, expected: source) { result.imported += 1; result.verified += 1 }
            else {
                result.failed += 1
                result.failureReasons = (result.failureReasons ?? [:]).merging(["WebKit did not retain the cookie exactly": 1], uniquingKeysWith: +)
            }
        }
        return result
    }

    private final class CookieBatch {
        private var count: Int
        private var done: (() -> Void)?
        init(count: Int, done: @escaping () -> Void) { self.count = count; self.done = done }
        func finishedOne() {
            count -= 1
            if count == 0 { let action = done; done = nil; action?() }
        }
    }
}

/// An empty document with the source origin. Values are arguments, never script
/// source. No remote page, external resource or source website code is loaded.
@MainActor
final class ArcLocalStorageTransfer: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private let navigationTimeout: Duration
    private var navigation: CheckedContinuation<Void, Error>?
    private var expectedNavigation: WKNavigation?
    private var timeout: Task<Void, Never>?

    init(store: WKWebsiteDataStore, navigationTimeout: Duration = .seconds(20)) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        view = WKWebView(frame: .zero, configuration: configuration)
        self.navigationTimeout = navigationTimeout
        super.init()
        view.navigationDelegate = self
    }

    private func load(_ origin: String) async throws {
        guard let base = URL(string: origin + "/") else { throw ArcImportFailure.unsupportedStorage("invalid origin") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            let duration = navigationTimeout
            timeout = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.view.stopLoading()
                self?.finish(.failure(ArcImportFailure.unsupportedStorage("WebKit did not finish loading the local document")))
            }
            expectedNavigation = view.loadHTMLString("<!doctype html><meta charset=utf-8><title>Importing website data</title>", baseURL: base)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        expectedNavigation = nil
        let pending = navigation; navigation = nil
        pending?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === expectedNavigation else { return }; finish(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }; finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === expectedNavigation else { return }; finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(ArcImportFailure.unsupportedStorage("WebKit stopped during import"))) }

    func transfer(_ input: ArcLocalStorageReader.Contents, progress: (Int, Int) -> Void = { _, _ in }) async -> ArcImportReport.Count {
        var result = ArcImportReport.Count(source: input.source, skipped: input.unsupported, failed: input.invalid)
        if input.unsupported > 0 { result.skipReasons = ["Partitioned or unsupported origins": input.unsupported] }
        if input.invalid > 0 { result.failureReasons = ["Unsupported source string encoding": input.invalid] }
        let origins = Set(input.origins.keys).union(input.encodedOrigins.keys).sorted()
        for (index, origin) in origins.enumerated() {
            let values = input.origins[origin] ?? [:]
            let encoded = input.encodedOrigins[origin] ?? []
            do {
                try Task.checkCancellation()
                try await load(origin)
                let answer = try await view.callAsyncJavaScript(Self.script, arguments: ["origin": origin, "values": values,
                    "encoded": encoded.map { ["key": $0.key, "value": $0.value] }], in: nil, contentWorld: .page)
                guard let counts = answer as? [String: Int] else { throw ArcImportFailure.unsupportedStorage("WebKit returned no result") }
                result.imported += counts["imported"] ?? 0
                result.existing += counts["existing"] ?? 0
                result.verified += counts["verified"] ?? 0
                result.failed += counts["failed"] ?? 0
                for (key, reason) in [("quota", "WebKit local-storage quota reached"), ("security", "WebKit blocked local-storage access"), ("mismatch", "WebKit did not retain the local-storage value exactly"), ("other", "WebKit rejected storage writes")] {
                    if let failed = counts[key], failed > 0 {
                        result.failureReasons = (result.failureReasons ?? [:]).merging([reason: failed], uniquingKeysWith: +)
                    }
                }
            } catch {
                let failed = values.count + encoded.count
                result.failed += failed
                result.failureReasons = (result.failureReasons ?? [:]).merging(["WebKit could not open an offline origin": failed], uniquingKeysWith: +)
            }
            progress(index + 1, origins.count)
        }
        view.stopLoading()
        return result
    }

    private static let script = """
    if (location.origin !== origin) throw new Error('The local document has the wrong origin');
    const counts = {imported: 0, existing: 0, verified: 0, failed: 0, quota: 0, security: 0, mismatch: 0, other: 0};
    function decode(encoded) {
        const bytes = atob(encoded); let result = '';
        for (let start = 0; start < bytes.length; start += 4096) {
            const units = [];
            for (let i = start; i < Math.min(start + 4096, bytes.length); i += 2)
                units.push(bytes.charCodeAt(i) | (bytes.charCodeAt(i + 1) << 8));
            result += String.fromCharCode(...units);
        }
        return result;
    }
    const entries = Object.entries(values).concat(encoded.map(pair => [decode(pair.key), decode(pair.value)]));
    for (const [key, value] of entries) {
        try {
            const old = localStorage.getItem(key);
            if (old !== null) {
                counts.existing++;
                if (old === value) counts.verified++;
                continue;
            }
            localStorage.setItem(key, value);
            if (localStorage.getItem(key) !== value) { counts.failed++; counts.mismatch++; continue; }
            counts.imported++; counts.verified++;
        } catch (error) {
            counts.failed++;
            if (error && error.name === 'QuotaExceededError') counts.quota++;
            else if (error && error.name === 'SecurityError') counts.security++;
            else counts.other++;
        }
    }
    return counts;
    """
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}
