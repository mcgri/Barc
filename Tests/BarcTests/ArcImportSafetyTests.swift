import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Arc import data boundaries")
struct ArcImportSafetyTests {
    private func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func log(_ payload: Data) -> Data {
        var crc: UInt32 = 0xffff_ffff
        for byte in Data([1]) + payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f6_3b78 : 0) }
        }
        crc = ~crc
        let masked = ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8
        return integer(UInt64(masked), bytes: 4) + integer(UInt64(payload.count), bytes: 2) + Data([1]) + payload
    }
    private func batch(_ sequence: UInt64, _ entries: [(String, String?)]) -> Data {
        var result = integer(sequence, bytes: 8) + integer(UInt64(entries.count), bytes: 4)
        for (key, value) in entries {
            result.append(value == nil ? 0 : 1)
            result.append(UInt8(key.utf8.count)); result.append(Data(key.utf8))
            if let value { result.append(UInt8(value.utf8.count)); result.append(Data(value.utf8)) }
        }
        return result
    }

    @Test("Manifest replay excludes obsolete files and respects deletion tombstones")
    func levelDBManifest() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MANIFEST-000010\n".utf8).write(to: root.appending(path: "CURRENT"))
        // Current log 2, previous log 0. Table 9 was added then deleted.
        let manifest = Data([2, 2, 9, 0, 7, 0, 9, 0, 0, 0, 6, 0, 9])
        try log(manifest).write(to: root.appending(path: "MANIFEST-000010"))
        try log(batch(100, [("gone", "obsolete")])).write(to: root.appending(path: "000001.log"))
        try (log(batch(5, [("gone", "before"), ("kept", "old")])) + log(batch(7, [("gone", nil)]))).write(to: root.appending(path: "000002.log"))
        try log(batch(8, [("kept", "new")])).write(to: root.appending(path: "000003.log"))
        try Data("obsolete table must not be opened".utf8).write(to: root.appending(path: "000009.ldb"))
        let result = try ArcLevelDBReader.read(root)
        #expect(result[Data("gone".utf8)]?.value == nil)
        #expect(result[Data("gone".utf8)]?.sequence == 7)
        #expect(result[Data("kept".utf8)]?.value == Data("new".utf8))
        var corrupt = log(batch(9, [("kept", "corrupt")]))
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: root.appending(path: "000003.log"))
        #expect(throws: (any Error).self) { try ArcLevelDBReader.read(root) }
    }

    @Test("Unusual URL characters do not change existing percent-encoded query values")
    func urlEscapes() throws {
        let raw = "https://fixture.invalid/path with space/?q=☕&literal=100%&already=x%20y&array=[a]#fragment#tail"
        let url = try #require(ArcURL.parse(raw))
        #expect(url.absoluteString == "https://fixture.invalid/path%20with%20space/?q=%E2%98%95&literal=100%25&already=x%20y&array=%5Ba%5D#fragment%23tail")
        #expect(ArcURL.parse("https://[::1]:9443/?q=%20")?.host() == "::1")
        #expect(ArcURL.parse("https://☕.invalid/?q=%20")?.absoluteString.contains("q=%20") == true)
    }

    @Test("Encrypted cookies require the correct domain hash and a supported envelope")
    func cookieEncryption() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 17, count: 16)
        let db = try SQLiteDatabase(path: root.appending(path: "Cookies").path)
        try db.execute("""
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES('version', '24');
            CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER,
                samesite INTEGER, top_frame_site_key TEXT, has_expires INTEGER);
            """)
        let domain = "cookies.invalid"
        let good = try ArcFlowBench.encrypted(Data(SHA256.hash(data: Data(domain.utf8))) + Data("fictional".utf8), key: key)
        let wrongDomain = try ArcFlowBench.encrypted(Data(SHA256.hash(data: Data("other.invalid".utf8))) + Data("fictional".utf8), key: key)
        for (index, bytes) in [good, wrongDomain, Data("v11unsupported".utf8), Data()].enumerated() {
            try db.run("INSERT INTO cookies VALUES(?, ?, '', ?, '/', 0, 1, 1, 1, '', 0);",
                       [.text(domain), .text("fixture-\(index)"), .blob(bytes)])
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let result = try ArcProfileReader.cookies(root, key: key)
        #expect(result.source == 4)
        #expect(result.failed == 2)
        #expect(result.records.count == 2)
        #expect(result.records.first?.value == "fictional")
        #expect(result.records.last?.value == "")
    }

    @Test("HTTP authentication credentials are not offered as HTML form passwords")
    func authenticationSchemes() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 6, count: 16)
        try ArcFlowBench.login(root, password: "fictional", key: key)
        let db = try SQLiteDatabase(path: root.appending(path: "Login Data").path)
        try db.execute("ALTER TABLE logins ADD COLUMN scheme INTEGER DEFAULT 0;")
        try db.execute("UPDATE logins SET origin_url = 'https://accounts.invalid:8443/login';")
        try db.execute("INSERT INTO logins SELECT origin_url, signon_realm, username_value, password_value, blacklisted_by_user, 1 FROM logins;")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let result = try ArcProfileReader.passwords(root, key: key)
        #expect(result.source == 2)
        #expect(result.records.count == 1)
        #expect(result.records.first?.port == 8443)
        #expect(result.skipped == 1)
        #expect(result.failed == 0)
    }

    @Test("History timestamps retain microseconds and SQLite text retains embedded NULs")
    func exactValues() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try SQLiteDatabase(path: root.appending(path: "fixture.sqlite").path)
        let text = "before\u{0}after☕"
        try db.execute("CREATE TABLE fixture(value TEXT);")
        try db.run("INSERT INTO fixture VALUES(?);", [.text(text)])
        #expect(try db.query("SELECT value FROM fixture;") { $0.text(0) }.first == text)
        let stamp: Int64 = 13_434_199_234_567_891
        let date = try #require(ArcProfileReader.chromeDate(stamp))
        let restored = Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) + 11_644_473_600_000_000
        #expect(restored == stamp)
        #expect(ArcProfileReader.chromeDate(.min) == nil)
    }
}

@Suite("Arc native storage boundaries")
@MainActor
struct ArcNativeStorageSafetyTests {
    @Test("A local build saves, reads and preserves imported Keychain records",
          .enabled(if: ProcessInfo.processInfo.environment["BARC_TEST_SYNTHETIC_KEYCHAIN"] == "1"))
    func nativeKeychain() throws {
        let identity = Space.Identity.makeIsolated()
        let sourceID = "synthetic-only-" + UUID().uuidString
        let path = KeychainPasswordStore.path(for: identity, sourceID: sourceID)
        defer { _ = KeychainPasswordStore.delete(host: "barc-keychain-fixture.invalid", username: "fictional-user", identity: identity, storagePath: path, scheme: "https") }
        #expect(KeychainPasswordStore.save(host: "barc-keychain-fixture.invalid", username: "fictional-user", password: "fictional-first",
            identity: identity, sourceID: sourceID, overwrite: false))
        let first = KeychainPasswordStore.all(identity: identity)
        #expect(first.count == 1)
        #expect(first.first?.password == "fictional-first")
        #expect(first.first?.scheme == "https")
        #expect(KeychainPasswordStore.save(host: "barc-keychain-fixture.invalid", username: "fictional-user", password: "fictional-second",
            identity: identity, sourceID: sourceID, overwrite: false))
        #expect(KeychainPasswordStore.all(identity: identity).first?.password == "fictional-first")
        #expect(KeychainPasswordStore.credentials(host: "barc-keychain-fixture.invalid", identity: .standard).isEmpty)
        let customSource = sourceID + "-custom-port"
        let customPath = KeychainPasswordStore.path(for: identity, sourceID: customSource)
        defer { _ = KeychainPasswordStore.delete(host: "barc-keychain-fixture.invalid", username: "fictional-user", identity: identity,
            storagePath: customPath, scheme: "https", port: 8443) }
        #expect(KeychainPasswordStore.save(host: "barc-keychain-fixture.invalid", username: "fictional-user", password: "fictional-custom-port",
            identity: identity, port: 8443, sourceID: customSource, overwrite: false))
        #expect(KeychainPasswordStore.credentials(host: "barc-keychain-fixture.invalid", identity: identity).count == 1)
        let custom = KeychainPasswordStore.credentials(host: "barc-keychain-fixture.invalid", identity: identity, port: 8443)
        #expect(custom.count == 1)
        #expect(custom.first?.password == "fictional-custom-port")
        #expect(custom.first?.port == 8443)
    }

    @Test("Unpaired JavaScript UTF-16 code units survive the native local-storage transfer")
    func unpairedUTF16() async throws {
        _ = NSApplication.shared
        let store = WKWebsiteDataStore.nonPersistent()
        // Other suites can occupy the test host's main actor while WebKit loads.
        let transfer = ArcLocalStorageTransfer(store: store, navigationTimeout: .seconds(120))
        let key = try #require(ArcLocalStorageReader.encodedUTF16(Data([0, 0, 0xd8])))
        let value = try #require(ArcLocalStorageReader.encodedUTF16(Data([0, 0, 0xdc, 0, 0])))
        let input = ArcLocalStorageReader.Contents(encodedOrigins: ["https://utf16.invalid": [.init(key: key, value: value)]], source: 1)
        let first = await transfer.transfer(input)
        #expect(first.imported == 1)
        #expect(first.verified == 1)
        #expect(first.failed == 0)
        let second = await transfer.transfer(input)
        #expect(second.existing == 1)
        #expect(second.imported == 0)
    }

    @Test("Expired and partitioned cookies have separate skip reasons")
    func cookieSkipReasons() async {
        _ = NSApplication.shared
        func cookie(partitioned: Bool) -> ArcProfileReader.Cookie {
            .init(name: "fictional", value: "fictional", domain: "cookies.invalid", path: "/",
                  expires: partitioned ? nil : .distantPast, secure: true, httpOnly: false, sameSite: 1, partitioned: partitioned)
        }
        let result = await ArcCookieTransfer.transfer(.init(records: [cookie(partitioned: false), cookie(partitioned: true)], source: 2), to: .nonPersistent())
        #expect(result.skipped == 2)
        #expect(result.skipReasons?["Expired cookies"] == 1)
        #expect(result.skipReasons?["Partitioned cookies"] == 1)
        #expect(result.failed == 0)
    }

    @Test("Spaces sharing an Arc profile keep one identity when a sibling Space is removed")
    func sharedProfile() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sidebar = try ArcSidebarReader.read(sidebar: ArcImportBench.sidebar(), archive: nil, profiles: ArcImportBench.profiles)
        let old = try #require(sidebar.spaces.last)
        sidebar.spaces[1] = .init(id: old.id, name: "Second personal Space", profile: "Default", pinnedRoot: old.pinnedRoot,
            unpinnedRoot: old.unpinnedRoot, color: old.color, emoji: old.emoji)
        let source = ArcSourceSnapshot(root: root, sourceFingerprint: UUID().uuidString, profiles: ArcImportBench.profiles,
            sidebar: sidebar, unsupportedIndexedDBFolders: [:], extensions: [:])
        let built = ArcSpaceBuilder.build(source, options: .init(profileIDs: ["Default"]))
        #expect(built.count == 2)
        let identity = try #require(built.first?.snapshot.identity)
        #expect(built.allSatisfy { $0.snapshot.identity == identity })
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        _ = try session.applyArcSpaces(built.map(\.snapshot))
        let first = try #require(session.spaces.first { $0.id == built[0].snapshot.id })
        let store = WebEnvironment.shared.dataStore(for: identity)
        let cookie = try #require(HTTPCookie(properties: [.name: "fixture", .value: "fictional", .domain: "shared.invalid", .path: "/"]))
        await store.httpCookieStore.setCookie(cookie)
        session.removeSpace(first)
        #expect(WebEnvironment.shared.dataStore(for: identity) === store)
        #expect(await store.httpCookieStore.allCookies().contains { $0.name == "fixture" })
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        WebEnvironment.shared.releaseDataStore(for: identity)
    }
}
