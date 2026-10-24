// Modified for Barc: owner-safe compact tab actions and persisted icon/URL behavior, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Compact sidebar tab actions", .serialized)
@MainActor
struct SidebarTabActionsTests {
    private func fire(_ title: String, in menu: NSMenu) async throws {
        _ = NSApplication.shared
        let item = try #require(menu.items.first { $0.title == title })
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
    private func url(_ path: String) -> URL { URL(string: "https://tab-fixture.invalid/\(path)")! }

    @Test("Icon, retained address, duplicate and archive restoration keep the complete user choice")
    func persistence() throws {
        let (session, store) = TestSession.make()
        let tab = session.newTab(url: url("original"))
        tab.setKeepsInSidebar(true)
        tab.setSidebarIcon(.symbol("ionicon.planet"))
        session.rename(tab, to: "Research")
        tab.load(url("later"))
        #expect(tab.pinnedPageURL == url("original"))
        let snapshot = tab.snapshot()
        let decoded = try JSONDecoder().decode(SessionSnapshot.Tab.self, from: JSONEncoder().encode(snapshot))
        let restored = Tab(restoring: decoded, identity: tab.identity)
        #expect(restored.sidebarIcon == .symbol("ionicon.planet"))
        #expect(restored.pinnedPageURL == url("original") && restored.url == url("later"))
        let copy = try #require(session.duplicate(tab))
        #expect(copy !== tab && copy.sidebarIcon == tab.sidebarIcon && copy.pinnedPageURL == tab.pinnedPageURL)
        #expect(copy.customName == "Research" && copy.keepsInSidebar)
        copy.setSidebarIcon(.emoji("🐮"))
        #expect(copy.emoji == "🐮" && copy.sidebarSymbolName == nil)
        copy.setSidebarIcon(.automatic)
        #expect(copy.emoji == nil && copy.sidebarSymbolName == nil && tab.sidebarSymbolName != nil)
        copy.setSidebarIcon(.symbol("ionicon.leaf"))
        copy.setKeepsInSidebar(false)
        session.archive([copy])
        let record = try #require(session.archivedTabs.last)
        let revived = try #require(session.restoreArchived(record))
        #expect(revived.sidebarIcon == .symbol("ionicon.leaf"))
        session.saveNow()
        #expect(try store.load()?.spaces.first?.tabs.contains { $0.sidebarSymbolName == "ionicon.planet" } == true)
    }

    @Test("Pinned rows use source menu grouping, saved URL editing and non-destructive Remove Pin")
    func retainedMenu() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("pinned"))
        let folder = session.createGroup(named: "Folder", containing: [tab])
        let sidebar = SidebarViewController(session: session)
        let menu = sidebar.makeTabMenu(for: tab)
        let titles = menu.items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Copy Link", "-", "Change Icon…", "Rename…", "Mute", "Edit Pinned Page", "-",
                           "Open in Split View", "Duplicate", "Move to", "-", "Remove Pin"])
        let options = try #require(menu.items.first { $0.title == "Edit Pinned Page" }?.submenu)
        #expect(options.items.map(\.title) == ["Replace Pinned URL with Current", "Edit…"])
        #expect(options.items[0].isEnabled == false)
        tab.load(url("changed"))
        let updated = try #require(sidebar.makeTabMenu(for: tab).items.first { $0.title == "Edit Pinned Page" }?.submenu)
        try await fire("Replace Pinned URL with Current", in: updated)
        #expect(tab.pinnedPageURL == url("changed"))
        try await fire("Remove Pin", in: sidebar.makeTabMenu(for: tab))
        #expect(tab.groupID == nil && !tab.keepsInSidebar && tab.pinnedPageURL == nil)
        #expect(session.activeSpace.tabs.contains { $0 === tab })
        #expect(session.activeSpace.group(withID: folder.id) === folder && session.archivedTabs.isEmpty)
    }

    @Test("Archive Below follows visible Today order and stays in its original Space after a switch")
    func archiveOrderAndOwner() async throws {
        let session = TestSession.make().0
        let owner = session.activeSpace
        let a = session.newTab(url: url("a")), b = session.newTab(url: url("b")), c = session.newTab(url: url("c"))
        c.sidebarPosition = 0; a.sidebarPosition = 1; b.sidebarPosition = 2
        let kept = session.newTab(url: url("kept")); kept.setKeepsInSidebar(true)
        let locked = session.newTab(url: url("locked")); locked.setLocked(true)
        let playing = session.newTab(url: url("playing"))
        playing.setMediaState(isPlaying: true, hasAudio: true, hasVideo: false, isMuted: false, title: "", artist: "")
        let sidebar = SidebarViewController(session: session)
        let menu = sidebar.makeTabMenu(for: a)
        let other = session.addSpace(named: "Other")
        let untouched = session.newTab(url: url("other"))
        try await fire("Archive Tabs Below", in: menu)
        #expect(!owner.tabs.contains { $0 === b })
        #expect([a,c,kept,locked,playing].allSatisfy { candidate in owner.tabs.contains { $0 === candidate } })
        #expect(other.tabs.contains { $0 === untouched } && session.activeSpace === other)
        #expect(session.archivedTabs.count == 1 && session.archivedTabs[0].snapshot.url == b.url)
    }

    @Test("Old menu callbacks do nothing after the tab or its Space is removed")
    func staleMenu() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("gone"))
        let sidebar = SidebarViewController(session: session)
        let menu = sidebar.makeTabMenu(for: tab)
        session.closeTab(tab)
        let count = session.activeSpace.tabs.count
        try await fire("Duplicate", in: menu)
        #expect(session.activeSpace.tabs.count == count)
        #expect(session.archivedTabs.isEmpty)
    }

    @Test("Private archival closes locally without recording page data")
    func privateArchive() {
        let session = TestSession.make().0
        let space = session.addSpace(named: "Private", isPrivate: true)
        let tab = session.newTab(url: url("private"))
        session.archiveSidebarTabs(relativeTo: tab, in: space, scope: .tab)
        #expect(!space.tabs.contains { $0 === tab })
        #expect(session.archivedTabs.isEmpty)
        #expect(!session.snapshot().spaces.contains { $0.tabs.contains { $0.url == url("private") } })
    }

    @Test("Symbol rendering yields back to the favicon and mute is enabled only when usable")
    func rowAndMute() async throws {
        let row = TabRowView()
        row.configure(.init(title: "Custom", sidebarSymbolName: "ionicon.planet"))
        #expect(row.showsCustomSymbol && !row.showsEmoji && row.favicon.isHidden)
        row.configure(.init(title: "Emoji", emoji: "🐮"))
        #expect(row.showsEmoji && !row.showsCustomSymbol)
        row.configure(.init(title: "Default"))
        #expect(!row.showsCustomSymbol && !row.showsEmoji && !row.favicon.isHidden)
        let session = TestSession.make().0
        let tab = session.newTab(url: url("audio"))
        let sidebar = SidebarViewController(session: session)
        #expect(sidebar.makeTabMenu(for: tab).items.first { $0.title == "Mute" }?.isEnabled == false)
        tab.setMediaState(isPlaying: true, hasAudio: true, hasVideo: false, isMuted: false, title: "", artist: "")
        try await fire("Mute", in: sidebar.makeTabMenu(for: tab))
        #expect(tab.isMuted)
        try await fire("Unmute", in: sidebar.makeTabMenu(for: tab))
        #expect(!tab.isMuted)
    }

    @Test("Pinned URL editing validates local input and the older session shape still decodes")
    func pinnedURLValidation() throws {
        #expect(PinnedPageEditor.url(from: "example.org/path") == URL(string: "https://example.org/path"))
        #expect(PinnedPageEditor.url(from: "") == nil)
        #expect(PinnedPageEditor.url(from: "not a url") == nil)
        #expect(PinnedPageEditor.url(from: "https://example.org/a b")?.absoluteString == "https://example.org/a%20b")
        #expect(PinnedPageEditor.url(from: "javascript:alert(1)") == nil)
        let original = SessionSnapshot.Tab(url: url("old"), keepsInSidebar: true)
        let tab = Tab(restoring: original, identity: .standard)
        #expect(tab.pinnedPageURL == original.url && tab.sidebarIcon == .automatic)
    }
}
