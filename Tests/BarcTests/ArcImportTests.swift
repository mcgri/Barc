import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

enum ArcImportBench {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "barc-arc-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func item(_ id: String, parent: String? = nil, children: [String] = [], url: String? = nil, folder: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["id": id, "childrenIds": children, "data": folder ? ["list": [:]] : ["tab": ["savedURL": url ?? "https://example.invalid/" + id, "savedTitle": id]]]
        if let parent { value["parentID"] = parent }
        return value
    }
    static func sidebar(twoProfiles: Bool = true) throws -> Data {
        var spaces: [Any] = ["personal-space", ["id": "personal-space", "profile": ["default": true],
            "customInfo": ["title": "Personal", "windowTheme": ["primaryColorPalette": ["midTone": ["red": 1.0, "green": 0.0, "blue": 0.0]]]],
            "containerIDs": ["pinned", "personal-pins", "unpinned", "personal-tabs"]] as [String: Any]]
        if twoProfiles {
            spaces += ["work-space", ["id": "work-space", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]],
                                      "containerIDs": ["pinned", "work-pins", "unpinned", "work-tabs"]] as [String: Any]]
        }
        let items: [Any] = [
            "personal-pins", item("personal-pins", children: ["folder"], folder: true),
            "folder", item("folder", parent: "personal-pins", children: ["nested", "pin"], folder: true),
            "nested", item("nested", parent: "folder", children: ["nested-pin"], folder: true),
            "nested-pin", item("nested-pin", parent: "nested"),
            "pin", item("pin", parent: "folder"),
            "personal-tabs", item("personal-tabs", children: ["one", "two"], folder: true),
            "one", item("one", parent: "personal-tabs", url: "https://same.invalid/"),
            "two", item("two", parent: "personal-tabs", url: "https://same.invalid/"),
            "favorites", item("favorites", children: ["favorite"], folder: true),
            "favorite", item("favorite", parent: "favorites"),
            "work-tabs", item("work-tabs", children: ["work-tab"], folder: true),
            "work-tab", item("work-tab", parent: "work-tabs")
        ]
        return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["global": [:]],
            ["spaces": spaces, "items": items, "topAppsContainerIDs": [["default": true], "favorites"]]]],
            "sidebarSyncState": ["items": ["stale-sync-tab": ["data": ["tab": ["savedURL": "https://wrong.invalid/"]]]]]])
    }
    static var profiles: [ArcProfile] { [.init(folder: "Default", name: "Personal"), .init(folder: "Profile 1", name: "Work")] }
    static func snapshot() throws -> ArcSourceSnapshot {
        let root = try directory()
        return ArcSourceSnapshot(root: root, sourceFingerprint: "test-source", profiles: profiles,
            sidebar: try ArcSidebarReader.read(sidebar: sidebar(), archive: nil, profiles: profiles), unsupportedIndexedDBFolders: [:], extensions: [:])
    }
}

@Suite("Arc's current local sidebar")
@MainActor
struct ArcSidebarReaderTests {
    @Test("The front window's expanded folders survive the import alongside mixed sibling order")
    func folderExpansionAndOrder() throws {
        let original = try ArcImportBench.snapshot()
        defer { original.remove() }
        let windows = try JSONSerialization.data(withJSONObject: ["lastFocusedSpaceID": "personal-space", "windows": [
            ["focusedSpaceID": "personal-space", "expandedItems": ["folder"]]
        ]])
        let sidebar = try ArcSidebarReader.read(sidebar: ArcImportBench.sidebar(), archive: nil,
                                                profiles: original.profiles, windows: windows)
        let source = ArcSourceSnapshot(root: original.root, sourceFingerprint: original.sourceFingerprint,
            profiles: original.profiles, sidebar: sidebar, unsupportedIndexedDBFolders: [:], extensions: [:])
        let built = try #require(ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default"])).first?.snapshot)
        let groups = try #require(built.groups)
        #expect(groups.first { $0.name == "Folder" && $0.parentID == nil }?.isCollapsed == false)
        #expect(groups.first { $0.parentID != nil }?.isCollapsed == true)
        let nested = try #require(groups.first { $0.parentID != nil }?.sidebarPosition)
        let nestedTab = try #require(built.tabs.first { $0.importedSourceID?.hasSuffix("/nested-pin") == true }?.sidebarPosition)
        let sibling = try #require(built.tabs.first { $0.importedSourceID?.hasSuffix("/pin") == true }?.sidebarPosition)
        #expect(nested < nestedTab && nestedTab < sibling)
    }

    @Test("Arc Favorites become tiles; a root pinned tab stays a retained list row")
    func favoritesAndPinnedListAreSeparate() throws {
        let original = try ArcImportBench.snapshot()
        defer { original.remove() }
        var sidebar = original.sidebar
        sidebar.items["root-pin"] = .init(id: "root-pin", parentID: "personal-pins", title: "Pinned list tab",
            children: [], url: URL(string: "https://retained.invalid/")!, isFolder: false, lastActiveAt: nil)
        sidebar.orderedItemIDs.append("root-pin")
        let source = ArcSourceSnapshot(root: original.root, sourceFingerprint: original.sourceFingerprint,
            profiles: original.profiles, sidebar: sidebar, unsupportedIndexedDBFolders: [:], extensions: [:])
        let built = try #require(ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default"])).first?.snapshot)
        #expect(built.pinnedSites?.count == 1)
        let retained = try #require(built.tabs.first { $0.url.host() == "retained.invalid" })
        #expect(retained.keepsInSidebar == true)
        #expect(retained.pinnedSiteID == nil)
        let favorite = try #require(built.tabs.first { $0.importedSourceID?.hasSuffix("/favorite") == true })
        #expect(favorite.pinnedSiteID != nil)
    }

    @Test("Extended-sRGB Space colours map into the destination gamut instead of falling back to blue")
    func extendedColours() throws {
        var root = try #require(JSONSerialization.jsonObject(with: ArcImportBench.sidebar()) as? [String: Any])
        var sidebar = try #require(root["sidebar"] as? [String: Any])
        var containers = try #require(sidebar["containers"] as? [[String: Any]])
        var spaces = try #require(containers[1]["spaces"] as? [Any])
        var space = try #require(spaces[1] as? [String: Any])
        for (components, expected) in [([1.00000012, 0.5, 0.25], "#ff8040"), ([0.5, 0.8, -0.24], "#80cc00")] {
            space["customInfo"] = ["windowTheme": ["primaryColorPalette": ["midTone":
                ["red": components[0], "green": components[1], "blue": components[2]]]]]
            spaces[1] = space; containers[1]["spaces"] = spaces
            sidebar["containers"] = containers; root["sidebar"] = sidebar
            let parsed = try ArcSidebarReader.read(sidebar: JSONSerialization.data(withJSONObject: root), archive: nil, profiles: ArcImportBench.profiles)
            #expect(parsed.spaces.first?.color == expected)
        }
    }

    @Test("Alternating dictionaries, folders, repeated URLs and profile favourites survive")
    func currentFormat() throws {
        let source = try ArcImportBench.snapshot()
        defer { source.remove() }
        let built = ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default", "Profile 1"]))
        #expect(built.count == 2)
        let personal = try #require(built.first { $0.profile == "Default" }?.snapshot)
        let work = try #require(built.first { $0.profile == "Profile 1" }?.snapshot)
        #expect(personal.tabs.count == 5)
        #expect(personal.tabs.filter { $0.url.host() == "same.invalid" }.count == 2)
        #expect(personal.groups?.count == 2)
        #expect(personal.pinnedSites?.count == 1)
        #expect(work.tabs.count == 1)
        #expect(work.tabs.allSatisfy { $0.url.host() != "wrong.invalid" })
        #expect(personal.identity != work.identity)
        #expect(personal.look?.customColorHex == "#ff0000")
        #expect(personal.tabs.map(\.importedSourceID) == ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default"]))[0].snapshot.tabs.map(\.importedSourceID))
    }

    @Test("Malformed or empty metadata is an error, never an empty successful import")
    func malformed() throws {
        for value in [Data("{}".utf8), Data("not json".utf8), try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["spaces": ["odd"], "items": []]]]])] {
            #expect(throws: (any Error).self) { try ArcSidebarReader.read(sidebar: value, archive: nil, profiles: ArcImportBench.profiles) }
        }
        #expect(!ArcSourceSnapshotter.validProfileName("../outside"))
        #expect(!ArcSourceSnapshotter.validProfileName(".."))
    }

    @Test("Archive entries from deleted Spaces are preserved without assigning an account")
    func orphanedArchive() throws {
        let record: [String: Any] = ["sidebarItem": ["data": ["tab": ["savedURL": "https://archive.invalid/"]]],
                                     "source": ["space": ["_0": "deleted-space"]], "archivedAt": 800_000_000]
        let data = try JSONSerialization.data(withJSONObject: ["items": ["archive-record", record]])
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ArcSourceSnapshot(root: root, sourceFingerprint: "test", profiles: ArcImportBench.profiles,
            sidebar: try ArcSidebarReader.read(sidebar: ArcImportBench.sidebar(), archive: data, profiles: ArcImportBench.profiles), unsupportedIndexedDBFolders: [:], extensions: [:])
        let archive = try #require(ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default", "Profile 1"])).first { $0.profile == nil })
        #expect(archive.snapshot.name == "Unassigned Arc archive")
        #expect(archive.snapshot.archivedTabs?.count == 1)
    }
}

@Suite("Arc import persistence and identity")
@MainActor
struct ArcImportPersistenceTests {
    @Test("Importing twice preserves repeated tabs without doubling them or replacing unrelated Spaces")
    func repeatImport() throws {
        _ = NSApplication.shared
        let source = try ArcImportBench.snapshot()
        defer { source.remove() }
        let file = source.root.appending(path: "session.json")
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: file))
        let previous = session.spaces.map(\.id)
        let incoming = ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: ["Default", "Profile 1"])).map(\.snapshot)
        let first = try session.applyArcSpaces(incoming)
        let second = try session.applyArcSpaces(incoming)
        #expect(first.tabs == 6)
        #expect(second.tabs == 0)
        #expect(second.spaces == 0)
        #expect(previous.allSatisfy { id in session.spaces.contains { $0.id == id } })
        let saved = try #require(SessionStore(fileURL: file).load())
        let restored = try #require(BrowserSession.spaces(from: saved))
        #expect(restored.flatMap(\.tabs).compactMap(\.importedSourceID).count == 6)
        #expect(Set(restored.filter { !previous.contains($0.id) }.map(\.identity)).count == 2)
    }

    @Test("Profile history databases do not share same-host visits and imports keep same-second visits")
    func profileHistory() async throws {
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try BrowserDatabase(path: root.appending(path: "browser.sqlite"))
        let session = BrowserSession(database: database, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let left = Space.Identity.makeIsolated(), right = Space.Identity.makeIsolated()
        let first = try #require(session.database(for: left)), second = try #require(session.database(for: right))
        let url = try #require(URL(string: "https://history.invalid/"))
        let visits = [ArcProfileReader.Visit(id: 1, url: url, title: "Personal", date: .now),
                      ArcProfileReader.Visit(id: 2, url: url, title: "Personal", date: .now)]
        #expect(try await first.importArcVisits(visits, source: "test") == 2)
        #expect(try await first.importArcVisits(visits, source: "test") == 0)
        #expect(try await second.recentHistory().isEmpty)
        #expect(try await first.recentHistory().first?.visitCount == 2)
        #expect(KeychainPasswordStore.label(for: left) != KeychainPasswordStore.label(for: right))
        #expect(KeychainPasswordStore.path(for: left) != KeychainPasswordStore.path(for: right))
    }
}

@Suite("Native Arc website conversion")
@MainActor
struct ArcWebsiteTransferTests {
    @Test("Cookie construction keeps session, HttpOnly, Secure and SameSite flags")
    func flags() throws {
        for policy in [0, 1, 2] {
            let source = ArcProfileReader.Cookie(name: "__Host-session", value: "synthetic", domain: "import.invalid", path: "/",
                expires: nil, secure: true, httpOnly: true, sameSite: policy, partitioned: false)
            let cookie = try #require(ArcCookieTransfer.nativeCookie(source))
            #expect(ArcCookieTransfer.matches(cookie, expected: source))
            #expect(cookie.isSessionOnly)
        }
    }

    @Test("Partitioned cookies cannot silently become unpartitioned cookies")
    func partitionBoundary() {
        let source = ArcProfileReader.Cookie(name: "session", value: "synthetic", domain: "import.invalid", path: "/",
            expires: nil, secure: true, httpOnly: false, sameSite: 0, partitioned: true)
        #expect(ArcCookieTransfer.nativeCookie(source) == nil)
    }

    @Test("Native cookie writes stay in their store and preserve a newer destination session")
    func cookieIsolation() async throws {
        _ = NSApplication.shared
        let left = WKWebsiteDataStore.nonPersistent(), right = WKWebsiteDataStore.nonPersistent()
        let source = ArcProfileReader.Cookie(name: "session", value: "synthetic-left", domain: "import.invalid", path: "/",
            expires: Date().addingTimeInterval(3600), secure: true, httpOnly: true, sameSite: 1, partitioned: false)
        let result = await ArcCookieTransfer.transfer(.init(records: [source], source: 1), to: left)
        #expect(result.imported == 1)
        #expect(result.verified == 1)
        let absent: [HTTPCookie] = await withCheckedContinuation { c in right.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        #expect(absent.isEmpty)
        let newer = try #require(ArcCookieTransfer.nativeCookie(.init(name: "session", value: "newer-destination", domain: "import.invalid", path: "/",
            expires: Date().addingTimeInterval(7200), secure: true, httpOnly: true, sameSite: 1, partitioned: false)))
        await withCheckedContinuation { continuation in
            left.httpCookieStore.setCookie(newer) { continuation.resume() }
        }
        let seeded = await left.httpCookieStore.allCookies()
        #expect(seeded.first { $0.name == "session" }?.value == "newer-destination")
        let again = await ArcCookieTransfer.transfer(.init(records: [source], source: 1), to: left)
        #expect(again.existing == 1)
        #expect(again.imported == 0)
        #expect(again.verified == 0)
        let retained = await left.httpCookieStore.allCookies()
        #expect(retained.first { $0.name == "session" }?.value == "newer-destination")
    }

    @Test("Offline local storage writes use WebKit and do not overwrite existing values")
    func localStorage() async throws {
        _ = NSApplication.shared
        let store = WKWebsiteDataStore.nonPersistent()
        let transfer = ArcLocalStorageTransfer(store: store, navigationTimeout: .seconds(120))
        let values = ArcLocalStorageReader.Contents(origins: ["https://barc-import.invalid": ["text": "fictional & + ☕", "empty": ""]], source: 2)
        let first = await transfer.transfer(values)
        #expect(first.imported == 2)
        #expect(first.verified == 2)
        let changed = ArcLocalStorageReader.Contents(origins: ["https://barc-import.invalid": ["text": "older-source-conflict", "empty": ""]], source: 2)
        let second = await transfer.transfer(changed)
        #expect(second.existing == 2)
        #expect(second.imported == 0)
        #expect(second.verified == 1)
        let preserved = await transfer.transfer(values)
        #expect(preserved.existing == 2)
        #expect(preserved.verified == 2)
    }
}

@Suite("Arc LevelDB format")
struct ArcLevelDBTests {
    @Test("Snappy literal and overlapping copy are decoded, corrupt streams fail")
    func snappy() throws {
        let input = Data([9, 8, 97, 98, 99, 22, 3, 0])
        #expect(try ArcLevelDBReader.snappy(input) == Data("abcabcabc".utf8))
        #expect(throws: (any Error).self) { try ArcLevelDBReader.snappy(Data([9, 22, 3, 0])) }
    }

    @Test("Storage strings preserve Latin-1, UTF-16 and empty values")
    func strings() {
        #expect(ArcLocalStorageReader.text(Data([1, 0xe9])) == "é")
        #expect(ArcLocalStorageReader.text(Data([0, 0x15, 0x26])) == "☕")
        #expect(ArcLocalStorageReader.text(Data([1])) == "")
        #expect(ArcLocalStorageReader.text(Data([7, 65])) == nil)
    }
}

@Suite("Owner-authorized Arc source verification")
struct ArcLiveSourceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARC_ARC_TEST_ROOT"] != nil))
    @MainActor
    func liveIconSnapshot() async throws {
        let input = try #require(ProcessInfo.processInfo.environment["BARC_ARC_TEST_ROOT"])
        let source = try await Task.detached { try ArcSourceSnapshotter.capture(URL(fileURLWithPath: input), sidebarOnly: true) }.value
        defer { source.remove() }
        let spaces = ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: Set(source.profiles.map(\.folder))))
        var counts: [[String: Any]] = []
        for profile in source.profiles {
            let pages = spaces.filter { $0.profile == profile.folder }.flatMap { $0.snapshot.tabs.map(\.url) }
            let directory = source.profileURL(profile)
            let icons = try await Task.detached { try ArcFaviconReader.read(directory, pages: pages) }.value
            let badge = try await Task.detached { try ArcFaviconReader.githubBadge(directory) }.value
            counts.append(["profile": profile.folder, "tabs": pages.count, "cachedPageIcons": icons.icons.count, "githubBadge": badge != nil])
            for file in ["Login Data", "Cookies", "Network/Cookies", "Web Data", "History"] {
                #expect(!FileManager.default.fileExists(atPath: directory.appending(path: file).path))
            }
        }
        #expect(source.profiles.count == 6)
        #expect(counts.reduce(0) { $0 + ($1["cachedPageIcons"] as? Int ?? 0) } > 0)
        if let output = ProcessInfo.processInfo.environment["BARC_ARC_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: ["profiles": counts], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARC_ARC_TEST_ROOT"] != nil))
    @MainActor
    func liveSnapshot() async throws {
        let input = try #require(ProcessInfo.processInfo.environment["BARC_ARC_TEST_ROOT"])
        let source = try await Task.detached { try ArcSourceSnapshotter.capture(URL(fileURLWithPath: input)) }.value
        defer { source.remove() }
        let spaces = ArcSpaceBuilder.build(source, options: ArcImportOptions(profileIDs: Set(source.profiles.map(\.folder))))
        var counts: [[String: Any]] = []
        for profile in source.profiles {
            let own = spaces.filter { $0.profile == profile.folder }
            let profileURL = source.profileURL(profile)
            let (visitCount, storage) = try await Task.detached {
                (try ArcProfileReader.history(profileURL).count, try ArcLocalStorageReader.read(profileURL))
            }.value
            let pages = own.flatMap { $0.snapshot.tabs.map(\.url) }
            let icons = try await Task.detached { try ArcFaviconReader.read(profileURL, pages: pages) }.value
            counts.append(["profile": profile.folder, "spaces": own.count, "tabs": own.reduce(0) { $0 + $1.snapshot.tabs.count },
                           "folders": own.reduce(0) { $0 + ($1.snapshot.groups?.count ?? 0) },
                           "archive": own.reduce(0) { $0 + ($1.snapshot.archivedTabs?.count ?? 0) },
                           "history": visitCount, "localStorage": storage.source, "localStorageUnsupported": storage.unsupported,
                           "localStorageInvalid": storage.invalid, "cachedPageIcons": icons.icons.count])
        }
        #expect(source.profiles.count == 6)
        #expect(Set(spaces.filter { $0.profile != nil }.compactMap { $0.snapshot.identity }).count == source.profiles.count)
        if let output = ProcessInfo.processInfo.environment["BARC_ARC_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: ["profiles": counts, "unassignedArchive": spaces.first { $0.profile == nil }?.snapshot.archivedTabs?.count ?? 0], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }
}
