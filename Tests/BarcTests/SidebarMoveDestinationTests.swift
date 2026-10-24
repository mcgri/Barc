// Modified for Barc: visible Space destinations, icons and current-owner menu behavior, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar Move to destinations", .serialized)
@MainActor
struct SidebarMoveDestinationTests {
    private func fixture() -> (BrowserSession, SidebarViewController, Space, Space, Space, Tab, TabGroup) {
        let session = TestSession.make().0
        let owner = session.activeSpace
        owner.icon = .emoji("🪐")
        let tab = session.newTab(url: URL(string: "https://move-fixture.invalid/pinned")!)
        tab.setKeepsInSidebar(true)
        let folder = session.createGroup(named: "Folder", containing: [tab])
        let hidden = session.addSpace(named: "Hidden migration archive")
        var look = hidden.look; look.showsInDock = false; session.setLook(look, for: hidden)
        let other = session.addSpace(named: "Work", icon: .symbol("ionicon.planet"))
        return (session, SidebarViewController(session: session), owner, other, hidden, tab, folder)
    }

    private func moveMenu(_ menu: NSMenu, title: String = "Move to") throws -> NSMenu {
        try #require(menu.items.first { $0.title == title }?.submenu)
    }

    private func fire(_ item: NSMenuItem) async throws {
        _ = NSApplication.shared
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test("Tab and folder destinations match the dock, render Space icons and keep the owner selectable")
    func visibleDestinations() async throws {
        let (session, sidebar, owner, other, hidden, tab, folder) = fixture()
        let before = session.snapshot()
        for menu in [sidebar.makeTabMenu(for: tab), sidebar.makeGroupMenu(for: folder)] {
            let move = try moveMenu(menu)
            #expect(move.items.map { $0.isSeparatorItem ? "-" : $0.title } == [owner.name, other.name, "-", "New Space…"])
            #expect(!move.items.contains { $0.title == hidden.name })
            for item in move.items.prefix(2) {
                #expect(item.isEnabled && item.image?.size == NSSize(width: 16, height: 16))
                #expect(item.image?.accessibilityDescription == item.title)
            }
            let current = try #require(move.items.first { $0.title == owner.name })
            #expect(current.state == .on && move.items[1].state == .off)
            try await fire(current)
            #expect(session.snapshot() == before)
            #expect(session.activeSpace === other && owner.group(withID: folder.id) === folder)
            #expect(owner.tabs.contains { $0 === tab })
        }
    }

    @Test("Choosing a different profile from an inactive tab menu preserves the destination's isolation")
    func moveTabAcrossProfiles() async throws {
        let (session, sidebar, owner, other, _, tab, _) = fixture()
        let move = try moveMenu(sidebar.makeTabMenu(for: tab))
        let target = try #require(move.items.first { $0.title == other.name })
        session.selectSpace(owner)
        try await fire(target)
        #expect(!owner.tabs.contains { $0 === tab })
        let moved = try #require(other.tabs.first { $0.url == tab.url })
        #expect(moved !== tab && moved.identity == other.identity && moved.identity != owner.identity)
        #expect(moved.groupID == nil && moved.keepsInSidebar && moved.pinnedPageURL == tab.pinnedPageURL)
        #expect(session.activeSpace === owner)
    }

    @Test("Folder moves retain their nested contents and do not move the active Space's unrelated tabs")
    func moveFolder() async throws {
        let (session, sidebar, owner, other, _, tab, folder) = fixture()
        session.selectSpace(owner)
        let childTab = session.newTab(url: URL(string: "https://move-fixture.invalid/child")!)
        let child = session.createGroup(named: "Nested", containing: [childTab], parent: folder)
        let move = try moveMenu(sidebar.makeGroupMenu(for: folder))
        let target = try #require(move.items.first { $0.title == other.name })
        session.selectSpace(other)
        let unrelated = other.tabs.map(\.id)
        try await fire(target)
        #expect(owner.group(withID: folder.id) == nil && owner.group(withID: child.id) == nil)
        #expect(other.group(withID: folder.id) === folder && other.group(withID: child.id) === child)
        #expect(child.parentID == folder.id)
        #expect([tab.url, childTab.url].allSatisfy { url in other.tabs.contains { $0.url == url && $0.identity == other.identity } })
        #expect(unrelated.allSatisfy { id in other.tabs.contains { $0.id == id } })
        #expect(session.activeSpace === other)
    }

    @Test("Extended and multi-tab menus also omit hidden migration Spaces")
    func secondaryMenus() throws {
        let (_, sidebar, owner, other, hidden, tab, _) = fixture()
        for menu in [sidebar.makeExtendedTabMenu(for: tab), sidebar.makeMultiTabMenu(for: [tab])] {
            let move = try moveMenu(menu, title: "Move to Space")
            #expect(!move.items.contains { $0.title == hidden.name })
            // The multi-tab menu excludes its active owner; the extended menu excludes the clicked owner.
            #expect(move.items.map(\.title) == [menu.items.contains { $0.title == "Reload 1 Tabs" } ? owner.name : other.name])
        }
    }

    @Test("Opening a hidden Space deliberately keeps that Space available as the checked current owner")
    func activeHiddenOwner() throws {
        let (session, sidebar, owner, other, hidden, _, _) = fixture()
        session.selectSpace(hidden)
        let tab = session.newTab(url: URL(string: "https://move-fixture.invalid/hidden")!)
        let move = try moveMenu(sidebar.makeTabMenu(for: tab))
        #expect(move.items.prefix(3).map(\.title) == [owner.name, hidden.name, other.name])
        #expect(move.items[1].state == .on && move.items[1].isEnabled)
    }
}
