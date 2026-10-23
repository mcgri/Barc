import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import Testing
import WebKit
import os
@testable import Barc

enum ArcFlowBench {
    static func source(in directory: URL, profiles: [ArcProfile] = ArcImportBench.profiles) throws -> ArcSourceSnapshot {
        let manager = FileManager.default
        try manager.createDirectory(at: directory.appending(path: "User Data"), withIntermediateDirectories: true)
        for profile in profiles {
            try manager.createDirectory(at: directory.appending(path: "User Data/" + profile.folder), withIntermediateDirectories: true)
        }
        let state: [String: Any] = ["profile": ["info_cache": Dictionary(uniqueKeysWithValues: profiles.map { ($0.folder, ["name": $0.name]) })]]
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appending(path: "User Data/Local State"))
        let sidebar = try ArcImportBench.sidebar(twoProfiles: profiles.count > 1)
        try sidebar.write(to: directory.appending(path: "StorableSidebar.json"))
        return ArcSourceSnapshot(root: directory, sourceFingerprint: "fixture-source", profiles: profiles,
            sidebar: try ArcSidebarReader.read(sidebar: sidebar, archive: nil, profiles: profiles), unsupportedIndexedDBFolders: [:], extensions: [:])
    }
    static func history(_ profile: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: profile.appending(path: "History").path)
        try db.execute("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT); CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);")
        try db.run("INSERT INTO urls VALUES(1, 'https://history.invalid/', 'History fixture');")
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000_000) + 11_644_473_600_000_000
        for id in 1...2 { try db.run("INSERT INTO visits VALUES(?, 1, ?);", [.integer(Int64(id)), .integer(stamp)]) }
        return db
    }
    static func encrypted(_ bytes: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: bytes.count + 16)
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, iv.baseAddress, source.baseAddress, source.count,
                                destination.baseAddress, destination.count, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ArcImportFailure.invalidDatabase("encrypted fixture") }
        return Data("v10".utf8) + output.prefix(length)
    }
    static func login(_ profile: URL, password: String, key: Data) throws {
        let db = try SQLiteDatabase(path: profile.appending(path: "Login Data").path)
        try db.execute("CREATE TABLE logins(origin_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);")
        try db.run("INSERT INTO logins VALUES('https://accounts.invalid/login', 'https://accounts.invalid/', 'same-user', ?, 0);", [.blob(encrypted(Data(password.utf8), key: key))])
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }
}

@Suite("Arc import source snapshot")
struct ArcSnapshotTests {
    @Test("A WAL-backed database is copied consistently without changing the source files")
    func walSnapshot() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arc = root.appending(path: "Arc")
        _ = try ArcFlowBench.source(in: arc, profiles: [.init(folder: "Default", name: "Personal")])
        let history = try ArcFlowBench.history(arc.appending(path: "User Data/Default"))
        let file = arc.appending(path: "User Data/Default/History")
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let before = try [file, wal].map { try Data(contentsOf: $0) }
        try withExtendedLifetime(history) {
            let copy = try ArcSourceSnapshotter.capture(arc, temporaryParent: root)
            defer { copy.remove() }
            let records = try ArcProfileReader.history(copy.profileURL(copy.profiles[0]))
            #expect(records.count == 2)
            #expect(try [file, wal].map { try Data(contentsOf: $0) } == before)
            #expect(!FileManager.default.fileExists(atPath: copy.profileURL(copy.profiles[0]).appending(path: "History-wal").path))
        }
    }

    @Test("Corrupt databases fail before a destination import and the private copy is cleaned up")
    func corruptSnapshot() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arc = root.appending(path: "Arc")
        _ = try ArcFlowBench.source(in: arc, profiles: [.init(folder: "Default", name: "Personal")])
        try Data("not a database".utf8).write(to: arc.appending(path: "User Data/Default/History"))
        #expect(throws: (any Error).self) { try ArcSourceSnapshotter.capture(arc, temporaryParent: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("barc-arc-import-") }.isEmpty)
    }
}

@Suite("Arc import orchestration", .serialized)
@MainActor
struct ArcImportFlowTests {
    @Test("Search choices in Secure Preferences and keyword GUIDs are restored on a repeated import")
    func protectedSearchPreferences() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arc = root.appending(path: "Arc")
        _ = try ArcFlowBench.source(in: arc)
        let personal = arc.appending(path: "User Data/Default")
        let work = arc.appending(path: "User Data/Profile 1")
        try JSONSerialization.data(withJSONObject: ["default_search_provider_data": ["template_url_data": ["short_name": "Google"]]])
            .write(to: personal.appending(path: "Secure Preferences"))
        try JSONSerialization.data(withJSONObject: ["default_search_provider": ["guid": "fictional-selected-engine"]])
            .write(to: work.appending(path: "Preferences"))
        let web = try SQLiteDatabase(path: work.appending(path: "Web Data").path)
        try web.execute("""
            CREATE TABLE keywords(short_name TEXT, keyword TEXT, url TEXT, prepopulate_id INTEGER, safe_for_autoreplace INTEGER, sync_guid TEXT);
            INSERT INTO keywords VALUES('Bing', 'bing', 'https://bing.invalid/?q={searchTerms}', 3, 1, 'fictional-selected-engine');
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        let source = try ArcSourceSnapshotter.capture(arc, temporaryParent: root)
        defer { source.remove() }
        #expect(FileManager.default.fileExists(atPath: source.profileURL(source.profiles[0]).appending(path: "Secure Preferences").path))
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let original = try #require(session.spaces.first)
        original.searchEngineID = "duckduckgo"
        let coordinator = ArcImportCoordinator(session: session,
            downloads: DownloadManager(store: DownloadStore(fileURL: root.appending(path: "downloads.json"))), reportDirectory: root.appending(path: "reports"))
        coordinator.autofillProvider = { AutofillStore(fileURL: root.appending(path: "autofill-" + ProfileDataPaths.key(for: $0) + ".json")) }
        var options = ArcImportOptions(profileIDs: ["Default", "Profile 1"])
        options.history = false; options.bookmarks = false; options.passwords = false
        options.cookies = false; options.localStorage = false; options.supplementary = false
        _ = try await coordinator.run(source, options: options)
        options.supplementary = true
        _ = try await coordinator.run(source, options: options)
        let built = ArcSpaceBuilder.build(source, options: options)
        for item in built {
            let space = try #require(session.spaces.first { $0.id == item.snapshot.id })
            #expect(space.searchEngineID == (item.profile == "Default" ? "google" : "bing"))
        }
        #expect(original.searchEngineID == "duckduckgo")
    }

    @Test("Arc Space order survives profile-by-profile import without moving unrelated Spaces")
    func sidebarSpaceOrder() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ArcFlowBench.source(in: root.appending(path: "Arc"))
        var sidebar = source.sidebar
        sidebar.spaces.reverse()
        let reordered = ArcSourceSnapshot(root: source.root, sourceFingerprint: source.sourceFingerprint, profiles: source.profiles,
            sidebar: sidebar, unsupportedIndexedDBFolders: [:], extensions: [:])
        let store = SessionStore(fileURL: root.appending(path: "session.json"))
        let session = BrowserSession(database: nil, sessionStore: store)
        let previousIDs = session.spaces.map(\.id)
        let coordinator = ArcImportCoordinator(session: session, reportDirectory: root.appending(path: "reports"))
        var options = ArcImportOptions(profileIDs: ["Default", "Profile 1"])
        options.history = false; options.bookmarks = false; options.passwords = false
        options.cookies = false; options.localStorage = false; options.supplementary = false
        _ = try await coordinator.run(reordered, options: options)
        let expected = ArcSpaceBuilder.build(reordered, options: options).compactMap { $0.snapshot.id }
        #expect(Array(session.spaces.prefix(previousIDs.count)).map(\.id) == previousIDs)
        #expect(session.spaces.filter { !previousIDs.contains($0.id) }.map(\.id) == expected)
        let persisted = try #require(store.load())
        #expect(persisted.spaces.compactMap(\.id) == session.spaces.map(\.id))
    }

    @Test("Empty selection changes nothing, and two windows cannot import concurrently")
    func selectionAndConcurrency() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ArcFlowBench.source(in: root.appending(path: "Arc"))
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let before = session.snapshot()
        let coordinator = ArcImportCoordinator(session: session, reportDirectory: root.appending(path: "reports"))
        do { _ = try await coordinator.run(source, options: .init(profileIDs: [])); Issue.record("Empty selection must fail") }
        catch { #expect(error as? ArcImportFailure == .noSelection) }
        #expect(session.snapshot() == before)
        let (events, started) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.keyProvider = { started.yield(()); release.wait(); return nil }
        var options = ArcImportOptions(profileIDs: ["Default"])
        options.sidebar = false; options.history = false; options.bookmarks = false
        options.cookies = false; options.localStorage = false; options.supplementary = false
        let selected = options
        let first = Task { defer { started.finish() }; return try await coordinator.run(source, options: selected) }
        var signals = events.makeAsyncIterator()
        #expect(await signals.next() != nil)
        let second = ArcImportCoordinator(session: session, reportDirectory: root.appending(path: "other-reports"))
        do { _ = try await second.run(source, options: selected); Issue.record("Concurrent imports must fail") }
        catch { #expect(error as? ArcImportFailure == .alreadyRunning) }
        release.signal()
        _ = try await first.value
    }

    @Test("An interrupted session save can be retried without duplicating committed history or tabs")
    func interruptedSave() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ArcFlowBench.source(in: root.appending(path: "Arc"))
        let leaf: [String: Any] = ["type": "url", "name": "Nested fixture", "url": "https://bookmarks.invalid/nested", "date_added": "13353408000123456"]
        let folder: [String: Any] = ["type": "folder", "name": "Reports", "children": [leaf]]
        let bookmarks: [String: Any] = ["roots": ["bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [folder]]]]
        try JSONSerialization.data(withJSONObject: bookmarks).write(to: source.profileURL(source.profiles[0]).appending(path: "Bookmarks"))
        let history = try ArcFlowBench.history(source.profileURL(source.profiles[0]))
        try history.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let db = try BrowserDatabase(path: root.appending(path: "browser.sqlite"))
        let sessionFile = root.appending(path: "not-created/session.json")
        let session = BrowserSession(database: db, sessionStore: SessionStore(fileURL: sessionFile))
        let coordinator = ArcImportCoordinator(session: session, reportDirectory: root.appending(path: "reports"))
        var options = ArcImportOptions(profileIDs: ["Default"])
        options.passwords = false; options.cookies = false; options.localStorage = false; options.supplementary = false
        do { _ = try await coordinator.run(source, options: options); Issue.record("An unavailable session destination must fail") }
        catch { }
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retry = try await coordinator.run(source, options: options)
        #expect(retry.profiles.first?.counts["History visits"]?.imported == 0)
        #expect(retry.profiles.first?.counts["History visits"]?.verified == 2)
        #expect(retry.profiles.first?.counts["Bookmarks"]?.imported == 0)
        #expect(retry.profiles.first?.counts["Bookmarks"]?.existing == 1)
        let identity = try #require(ArcSpaceBuilder.build(source, options: options).first?.snapshot.identity)
        let profileDatabase = try #require(session.database(for: identity))
        let savedBookmark = try #require(try await profileDatabase.bookmarks().first)
        #expect(savedBookmark.folder == "From Arc/Personal/Bookmarks bar/Reports")
        #expect(abs(savedBookmark.created.timeIntervalSince1970 - 1_708_934_400.123456) < 0.000001)
        #expect(session.spaces.flatMap(\.tabs).compactMap(\.importedSourceID).count == 5)
        #expect(SessionStore(fileURL: sessionFile).load() != nil)
    }

    private final class MemoryPasswords {
        var records: [Space.Identity: [PasswordCredential]] = [:]
        var access: ArcImportCoordinator.PasswordAccess {
            .init(read: { self.records[$0] ?? [] }, save: { source, identity, id in
                self.records[identity, default: []].append(.init(host: source.host, username: source.username, password: source.value,
                    storagePath: KeychainPasswordStore.path(for: identity, sourceID: id), scheme: source.scheme, port: source.port))
                return true
            })
        }
    }

    @Test("Denied key access keeps the tab/history import available and repeating it adds no duplicates")
    func declinedKey() async throws {
        _ = NSApplication.shared
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ArcFlowBench.source(in: root.appending(path: "Arc"))
        let db = try BrowserDatabase(path: root.appending(path: "browser.sqlite"))
        let session = BrowserSession(database: db, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let profile = source.profileURL(source.profiles[0])
        let history = try ArcFlowBench.history(profile)
        try history.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try ArcFlowBench.login(profile, password: "fictional-only", key: Data(repeating: 3, count: 16))
        let coordinator = ArcImportCoordinator(session: session, downloads: DownloadManager(store: DownloadStore(fileURL: root.appending(path: "downloads.json"))), reportDirectory: root.appending(path: "reports"))
        coordinator.keyProvider = { nil }
        var options = ArcImportOptions(profileIDs: Set(source.profiles.map(\.folder)))
        options.cookies = false; options.localStorage = false; options.supplementary = false
        let first = try await coordinator.run(source, options: options)
        #expect(first.profiles.first?.counts["Saved passwords"]?.failed == 1)
        #expect(first.profiles.first?.counts["History visits"]?.imported == 2)
        #expect(first.profiles.reduce(0) { $0 + ($1.counts["Sidebar tabs"]?.imported ?? 0) } == 6)
        let second = try await coordinator.run(source, options: options)
        #expect(second.profiles.reduce(0) { $0 + ($1.counts["Sidebar tabs"]?.imported ?? 0) } == 0)
        #expect(second.profiles.first?.counts["History visits"]?.imported == 0)
        #expect(coordinator.reportURL != nil)
    }

    @Test("Conflicting same-host credentials remain in their source identities and verify without a key export")
    func credentialProfiles() async throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ArcFlowBench.source(in: root.appending(path: "Arc"))
        let key = Data(repeating: 9, count: 16)
        for (index, profile) in source.profiles.enumerated() {
            try ArcFlowBench.login(source.profileURL(profile), password: "fictional-profile-\(index)", key: key)
        }
        let db = try BrowserDatabase(path: root.appending(path: "browser.sqlite"))
        let session = BrowserSession(database: db, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let coordinator = ArcImportCoordinator(session: session, downloads: DownloadManager(store: DownloadStore(fileURL: root.appending(path: "downloads.json"))), reportDirectory: root.appending(path: "reports"))
        let memory = MemoryPasswords()
        coordinator.passwords = memory.access
        let keyReads = OSAllocatedUnfairLock(initialState: 0)
        coordinator.keyProvider = { keyReads.withLock { $0 += 1 }; return key }
        var options = ArcImportOptions(profileIDs: Set(source.profiles.map(\.folder)))
        options.history = false; options.bookmarks = false; options.cookies = false; options.localStorage = false; options.supplementary = false
        let report = try await coordinator.run(source, options: options)
        #expect(report.profiles.reduce(0) { $0 + ($1.counts["Saved passwords"]?.verified ?? 0) } == 2)
        #expect(memory.records.count == 2)
        for credentials in memory.records.values { #expect(credentials.count == 1) }
        #expect(Set(memory.records.values.flatMap { $0.map(\.password) }).count == 2)
        let identity = try #require(memory.records.keys.first)
        let original = try #require(memory.records[identity]?.first)
        memory.records[identity] = [.init(host: original.host, username: original.username, password: "newer-native-password",
            storagePath: original.storagePath, scheme: original.scheme, port: original.port)]
        let repeated = try await coordinator.run(source, options: options)
        #expect(repeated.profiles.reduce(0) { $0 + ($1.counts["Saved passwords"]?.imported ?? 0) } == 0)
        #expect(repeated.profiles.reduce(0) { $0 + ($1.counts["Saved passwords"]?.existing ?? 0) } == 2)
        #expect(repeated.profiles.reduce(0) { $0 + ($1.counts["Saved passwords"]?.verified ?? 0) } == 1)
        #expect(memory.records[identity]?.first?.password == "newer-native-password")
        #expect(keyReads.withLock { $0 } == 1)
        coordinator.clearSensitiveState()
        _ = try await coordinator.run(source, options: options)
        #expect(keyReads.withLock { $0 } == 2)
    }

    @Test("The normal recent-download cap does not truncate an explicit Arc archive")
    func downloadArchive() throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(fileURL: root.appending(path: "downloads.json"))
        let manager = DownloadManager(store: store)
        let records = (0..<150).map { value in
            DownloadRecord(id: UUID(), sourceURL: URL(string: "https://download.invalid/\(value)")!, destination: root.appending(path: "\(value).txt"),
                           state: .finished, startedAt: .now, finishedAt: .now, byteCount: 10, importedFromArc: true, sourceProfileKey: "profile")
        }
        #expect(try manager.importArcRecords(records) == 150)
        #expect(store.load().count == 150)
        #expect(try manager.importArcRecords(records) == 0)
        manager.visibleProfile = { .standard }
        #expect(manager.visibleDownloads.isEmpty)
    }
}
