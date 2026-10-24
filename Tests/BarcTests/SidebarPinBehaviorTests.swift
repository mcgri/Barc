// Modified for Barc: Space pin shortcuts, saved-page reset and profile isolation, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Space pin behavior", .serialized)
@MainActor
struct SidebarPinBehaviorTests {
    private func url(_ path: String) -> URL { URL(string: "https://pin-fixture.invalid/\(path)")! }

    @Test("Command-D toggles a Space pin without creating a Favorite or bookmark")
    func shortcutAndMenu() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let tab = session.newTab(url: url("original"))
        let owner = session.activeSpace
        let other = session.addSpace(named: "Same profile", profile: owner.profile)
        session.selectSpace(owner); session.selectTab(tab)
        let controller = BrowserWindowController(session: session)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let menu = NSMenuItem(title: "Pin Tab", action: #selector(BrowserWindowController.togglePinActiveTab(_:)), keyEquivalent: "d")
        #expect(controller.validateMenuItem(menu) && menu.title == "Pin Tab")
        controller.togglePinActiveTab(nil)
        #expect(tab.keepsInSidebar && tab.pinnedPageURL == url("original"))
        #expect(tab.pinnedSiteID == nil && owner.pinnedSites.isEmpty && session.bookmarks.isEmpty)
        #expect(!other.tabs.contains { $0 === tab })
        #expect(controller.validateMenuItem(menu) && menu.title == "Unpin Tab")
        controller.togglePinActiveTab(nil)
        #expect(!tab.isSidebarRetained && tab.pinnedPageURL == nil && owner.tabs.contains { $0 === tab })

        let definition = try #require(ShortcutManager.shared.definitions.first { $0.id == "pin-tab" })
        #expect(definition.defaultKey == "d" && definition.defaultModifiers == [.command])
        let bookmarks = NSMenu(title: "Bookmarks")
        StoredItemsMenu(kind: .bookmarks, session: session).menuNeedsUpdate(bookmarks)
        #expect(bookmarks.items.first { $0.action == #selector(BrowserWindowController.toggleBookmark(_:)) }?.keyEquivalent == "")
    }

    @Test("Folder unpin returns the same tab to Today and preserves the folder and custom icon")
    func folderUnpin() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("folder"))
        let folder = session.createGroup(named: "Research", containing: [tab])
        tab.setSidebarIcon(.symbol("ionicon.planet"))
        session.setSidebarPin(false, for: tab)
        #expect(!tab.isSidebarRetained && tab.groupID == nil && tab.pinnedPageURL == nil)
        #expect(tab.sidebarIcon == .symbol("ionicon.planet"))
        #expect(session.activeSpace.group(withID: folder.id) === folder)
        #expect(session.todayTabs(in: session.activeSpace).last === tab && session.archivedTabs.isEmpty)
    }

    @Test("Reset returns the same named pin to its saved URL without adding a tab")
    func reset() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url("original"))
        session.setSidebarPin(true, for: tab)
        session.rename(tab, to: "Research")
        tab.setSidebarIcon(.emoji("🐮"))
        tab.load(url("departing"))
        let count = session.allTabs.count
        #expect(session.resetSidebarPin(tab))
        #expect(tab.url == url("original") && tab.pinnedPageURL == tab.url)
        #expect(tab.customName == "Research" && tab.emoji == "🐮" && tab.keepsInSidebar)
        #expect(session.allTabs.count == count && session.activeTab === tab)
        #expect(!session.resetSidebarPin(tab, keepingCurrentPage: true))
        #expect(session.allTabs.count == count)
    }

    @Test("Command-reset keeps the departing page in the pin's Space and profile")
    func resetKeepsDepartingPage() throws {
        let session = TestSession.make().0
        let owner = session.addSpace(named: "Work")
        let tab = session.newTab(url: url("original"))
        let folder = session.createGroup(named: "Research", containing: [tab])
        tab.load(url("departing"))
        let other = session.addSpace(named: "Personal")
        let otherIDs = other.tabs.map(\.id)
        let count = session.allTabs.count
        #expect(session.resetSidebarPin(tab, keepingCurrentPage: true))
        let departing = try #require(owner.tabs.first { $0 !== tab && $0.url == url("departing") })
        #expect(departing.identity == owner.identity && departing.identity != other.identity)
        #expect(!departing.isSidebarRetained && departing.pinnedPageURL == nil && departing.groupID == nil)
        #expect(tab.groupID == folder.id && tab.url == url("original"))
        #expect(session.allTabs.count == count + 1 && session.activeSpace === owner && session.activeTab === tab)
        #expect(other.tabs.map(\.id) == otherIDs)
    }

    @Test("Favorite, locked, stale and removed-Space tabs cannot be converted through a Space pin action")
    func rejectsWrongOwners() {
        let session = TestSession.make().0
        let favorite = session.newTab(url: url("favorite")); session.pin(favorite)
        session.setSidebarPin(true, for: favorite)
        #expect(favorite.pinnedSiteID != nil && !favorite.keepsInSidebar)
        #expect(!session.canResetSidebarPin(favorite))
        let locked = session.newTab(url: url("locked")); locked.setLocked(true)
        session.setSidebarPin(false, for: locked)
        #expect(locked.isSidebarRetained && locked.isLocked && !session.canChangeSidebarPin(locked))
        let space = session.addSpace(named: "Removed")
        let stale = session.newTab(url: url("stale")); session.setSidebarPin(true, for: stale)
        stale.load(url("later")); session.removeSpace(space)
        let active = session.activeSpace
        #expect(!session.resetSidebarPin(stale, keepingCurrentPage: true))
        session.setSidebarPin(false, for: stale)
        #expect(stale.keepsInSidebar && session.activeSpace === active)
    }

    @Test("Palette presents separate applicable Pin, Unpin, Favorite and Reset actions")
    func palette() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let tab = session.newTab(url: url("original"))
        let controller = BrowserWindowController(session: session)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        func ids() -> Set<String> { Set(CommandCatalog.available(in: session).map(\.id)) }
        #expect(ids().contains("pin-tab") && !ids().contains("unpin-tab") && ids().contains("favorite-tab"))
        #expect(controller.runPaletteCommand("pin-tab"))
        #expect(!ids().contains("pin-tab") && ids().contains("unpin-tab") && !ids().contains("reset-tab"))
        tab.load(url("later"))
        #expect(ids().contains("reset-tab") && ids().contains("replace-pin-with-current-page"))
        #expect(controller.runPaletteCommand("replace-pin-with-current-page"))
        #expect(tab.pinnedPageURL == url("later") && !ids().contains("reset-tab"))
        #expect(controller.runPaletteCommand("unpin-tab"))
        #expect(!tab.isSidebarRetained)
        #expect(controller.runPaletteCommand("favorite-tab"))
        #expect(tab.pinnedSiteID != nil && !ids().contains("pin-tab") && !ids().contains("favorite-tab"))
    }

    @Test("The icon resets a pin while its title keeps ordinary selection and the row retains drag hit testing")
    func iconTargetAndReuse() throws {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 270, height: 38))
        row.configure(.init(title: "Research", canResetPinnedPage: true))
        row.layoutSubtreeIfNeeded()
        let icon = NSPoint(x: row.favicon.frame.midX, y: row.favicon.frame.midY)
        let title = NSPoint(x: 180, y: icon.y)
        var resets: [Bool] = []
        row.onResetPinnedPage = { resets.append($0); return true }
        #expect(row.hitTest(icon) === row)
        #expect(!row.activatePinnedIcon(at: title, keepingCurrentPage: false))
        #expect(row.activatePinnedIcon(at: icon, keepingCurrentPage: false))
        #expect(row.activatePinnedIcon(at: icon, keepingCurrentPage: true))
        #expect(resets == [false, true])
        #expect(row.accessibilityCustomActions()?.map(\.name) == ["Reset Tab"])
        row.prepareForReuse()
        #expect(row.onResetPinnedPage == nil && row.accessibilityCustomActions()?.isEmpty != false)
        #expect(!row.activatePinnedIcon(at: icon, keepingCurrentPage: true))
        row.configure(.init(title: "Today"))
        #expect(row.accessibilityCustomActions()?.isEmpty != false)
    }
}
