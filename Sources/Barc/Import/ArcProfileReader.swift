import Foundation
import CryptoKit

enum ArcProfileReader {
    struct Visit: Sendable {
        let id: Int64
        let url: URL
        let title: String
        let date: Date
    }
    struct Password: Sendable {
        let id: Int64
        let host: String
        let scheme: String
        let username: String
        let value: String
        var port: Int = 0
    }
    struct Bookmark: Sendable {
        let url: URL
        let title: String
        let folder: String
        let date: Date
    }
    struct Cookie: Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        let sameSite: Int
        let partitioned: Bool
    }
    struct ReadResult<T: Sendable>: Sendable {
        var records: [T] = []
        var source = 0
        var skipped = 0
        var failed = 0
    }
    static let epochOffset: Double = 11_644_473_600

    static func chromeDate(_ value: Int64) -> Date? {
        let (microseconds, overflow) = value.subtractingReportingOverflow(11_644_473_600_000_000)
        guard !overflow else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    static func history(_ profile: URL) throws -> [Visit] {
        let file = profile.appending(path: "History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try SQLiteDatabase(readingOnly: file.path)
        return try db.query("SELECT v.id, u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url ORDER BY v.id;") { row -> Visit? in
            guard let raw = row.text(1), let url = ArcURL.parse(raw), let scheme = url.scheme,
                  ["http", "https", "file"].contains(scheme), let date = chromeDate(row.integer(3)) else { return nil }
            return Visit(id: row.integer(0), url: url, title: row.text(2) ?? "", date: date)
        }.compactMap { $0 }
    }

    static func passwords(_ profile: URL, key: Data) throws -> ReadResult<Password> {
        let file = profile.appending(path: "Login Data")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let db = try SQLiteDatabase(readingOnly: file.path)
        var result = ReadResult<Password>()
        let columns = Set(try db.query("PRAGMA table_info(logins);") { $0.text(1) ?? "" })
        let authentication = columns.contains("scheme") ? "scheme" : "0"
        let rows = try db.query("SELECT rowid, origin_url, signon_realm, username_value, password_value, blacklisted_by_user, \(authentication) FROM logins ORDER BY rowid;") {
            (id: $0.integer(0), origin: $0.text(1) ?? "", realm: $0.text(2) ?? "", user: $0.text(3) ?? "", encrypted: $0.blob(4), blocked: $0.integer(5) != 0, authentication: $0.integer(6))
        }
        for row in rows {
            if row.blocked || row.encrypted.isEmpty { continue }
            result.source += 1
            // Chromium's persisted scheme 0 is an HTML form login. HTTP
            // authentication realms cannot be flattened into form autofill.
            guard row.authentication == 0 else { result.skipped += 1; continue }
            guard let url = ArcURL.parse(row.origin.isEmpty ? row.realm : row.origin), let host = url.host(),
                  let scheme = url.scheme, ["http", "https"].contains(scheme) else { result.skipped += 1; continue }
            guard let raw = decrypt(row.encrypted, key: key), let value = String(data: raw, encoding: .utf8) else {
                result.failed += 1; continue
            }
            result.records.append(Password(id: row.id, host: host, scheme: scheme, username: row.user, value: value, port: KeychainPasswordStore.port(for: url)))
        }
        return result
    }

    static func cookies(_ profile: URL, key: Data) throws -> ReadResult<Cookie> {
        let manager = FileManager.default
        let paths = [profile.appending(path: "Network/Cookies"), profile.appending(path: "Cookies")]
        guard let file = paths.first(where: { manager.fileExists(atPath: $0.path) }) else { return .init() }
        let db = try SQLiteDatabase(readingOnly: file.path)
        let columns = Set(try db.query("PRAGMA table_info(cookies);") { $0.text(1) ?? "" })
        guard ["host_key", "name", "value", "encrypted_value", "path", "expires_utc", "is_secure", "is_httponly"].allSatisfy(columns.contains) else {
            throw ArcImportFailure.invalidDatabase("cookies")
        }
        let sameSite = columns.contains("samesite") ? "samesite" : "-1"
        let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
        let hasExpiry = columns.contains("has_expires") ? "has_expires" : "expires_utc != 0"
        let version = (try? db.query("SELECT value FROM meta WHERE key = 'version';") { Int($0.text(0) ?? "") ?? 0 }.first) ?? 0
        var result = ReadResult<Cookie>()
        let rows = try db.query("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, \(sameSite), \(partition), \(hasExpiry) FROM cookies;") {
            (host: $0.text(0) ?? "", name: $0.text(1) ?? "", plain: $0.text(2) ?? "", encrypted: $0.blob(3), path: $0.text(4) ?? "/",
             expires: $0.integer(5), secure: $0.integer(6) != 0, httpOnly: $0.integer(7) != 0, sameSite: Int($0.integer(8)),
             partition: $0.text(9) ?? "", hasExpiry: $0.integer(10) != 0)
        }
        result.source = rows.count
        for row in rows {
            guard !row.host.isEmpty else { result.failed += 1; continue }
            let expires = row.hasExpiry ? chromeDate(row.expires) : nil
            if row.hasExpiry && expires == nil { result.failed += 1; continue }
            var value = row.plain
            if !row.encrypted.isEmpty {
                guard var plain = decrypt(row.encrypted, key: key) else { result.failed += 1; continue }
                if version >= 24 {
                    let expected = Data(SHA256.hash(data: Data(row.host.utf8)))
                    guard plain.count >= 32, plain.prefix(32) == expected else { result.failed += 1; continue }
                    plain.removeFirst(32)
                }
                guard let text = String(data: plain, encoding: .utf8) else { result.failed += 1; continue }
                value = text
            }
            result.records.append(Cookie(name: row.name, value: value, domain: row.host, path: row.path.isEmpty ? "/" : row.path,
                expires: expires,
                secure: row.secure, httpOnly: row.httpOnly, sameSite: row.sameSite, partitioned: !row.partition.isEmpty))
        }
        return result
    }

    static func decrypt(_ encrypted: Data, key: Data) -> Data? {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else { return nil }
        return ChromiumCookieCrypto.aes128CBCDecrypt(Data(encrypted.dropFirst(3)), key: key, iv: Data(repeating: 0x20, count: 16))
    }

    static func bookmarks(_ profile: URL) throws -> [Bookmark] {
        let file = profile.appending(path: "Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let roots = json["roots"] as? [String: [String: Any]] else { throw ArcImportFailure.unreadable("bookmarks") }
        var entries: [Bookmark] = []
        func walk(_ node: [String: Any], path: [String]) {
            if node["type"] as? String == "url", let raw = node["url"] as? String, let url = ArcSidebarReader.validURL(raw) {
                let added = (node["date_added"] as? String).flatMap(Int64.init)
                entries.append(Bookmark(url: url, title: node["name"] as? String ?? raw, folder: path.joined(separator: "/"),
                    date: added.flatMap(chromeDate) ?? .now))
            } else {
                let name = node["name"] as? String ?? ""
                let next = name.isEmpty ? path : path + [name]
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: next) }
            }
        }
        for name in roots.keys.sorted() { if let node = roots[name] { walk(node, path: []) } }
        return entries
    }
}
