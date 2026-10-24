import Foundation
import Testing
@testable import Barc

@Suite("Private local profile migration preview")
@MainActor
struct LiveProfileMigrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARC_PROFILE_MIGRATION_FIXTURE_20261024"] != nil))
    func preservesSavedSession() throws {
        let path = try #require(ProcessInfo.processInfo.environment["BARC_PROFILE_MIGRATION_FIXTURE_20261024"])
        var original = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // This preview must never start timers for the user's live sites.
        for index in original.spaces.indices {
            for tab in original.spaces[index].tabs.indices { original.spaces[index].tabs[tab].autoReloadSeconds = nil }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "barc-profile-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(fileURL: root.appending(path: "session.json"))
        try store.save(original)
        let defaults = UserDefaults(suiteName: "barc-profile-preview.\(UUID())")!
        let session = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let migrated = session.snapshot()
        let sameIdentities = original.spaces.map(\.identity) == migrated.spaces.map(\.identity)
        let sameNamesAndIDs = zip(original.spaces, migrated.spaces).allSatisfy { $0.id == $1.id && $0.name == $1.name }
        let sameTabs = zip(original.spaces, migrated.spaces).allSatisfy { normalized($0.tabs) == normalized($1.tabs) }
        let samePinsAndFolders = zip(original.spaces, migrated.spaces).allSatisfy { $0.pinnedSites == $1.pinnedSites && $0.groups == $1.groups }
        let sameActivePages = zip(original.spaces, migrated.spaces).allSatisfy { activeURL($0) == activeURL($1) }
        let sameLayoutsAndPreferences = zip(original.spaces, migrated.spaces).allSatisfy { layout($0) == layout($1) }
        #expect(sameIdentities)
        #expect(sameNamesAndIDs)
        #expect(sameTabs)
        #expect(samePinsAndFolders)
        #expect(sameActivePages)
        #expect(sameLayoutsAndPreferences)
        #expect(migrated.spaces.count == original.spaces.count)
        #expect(session.allTabs.count == original.spaces.reduce(0) { $0 + $1.tabs.count })
        #expect(session.allTabs.allSatisfy { $0.currentWebView == nil })
        session.saveNow()
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let stableAfterReopen = zip(migrated.spaces, reopened.snapshot().spaces).allSatisfy {
            $0.identity == $1.identity && normalized($0.tabs) == normalized($1.tabs) && activeURL($0) == activeURL($1)
        }
        #expect(stableAfterReopen)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    private func normalized(_ tabs: [SessionSnapshot.Tab]) -> [Data] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return tabs.map { stored in
            var tab = stored; tab.lastActiveAt = nil
            return (try? encoder.encode(tab)) ?? Data()
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    private func layout(_ stored: SessionSnapshot.Space) -> SessionSnapshot.Space {
        var copy = stored
        copy.tabs = []; copy.activeTabIndex = nil
        copy.profileID = nil; copy.profileName = nil; copy.activeFavoriteID = nil
        return copy
    }
    private func activeURL(_ space: SessionSnapshot.Space) -> URL? {
        guard let index = space.activeTabIndex, space.tabs.indices.contains(index) else { return nil }
        return space.tabs[index].url
    }
}
