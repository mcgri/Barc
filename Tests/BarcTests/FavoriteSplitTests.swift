// Modified for Barc: a profile Favorite retains a complete split group, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Profile Favorite split groups", .serialized)
@MainActor
struct FavoriteSplitTests {
    private func pages(_ session:BrowserSession,count:Int = 4) -> [Tab] {
        (0..<count).map { index in
            let page = session.newTab(url:URL(string:"https://favorite-split.invalid/shared")!)
            session.rename(page,to:"Pane \(index)")
            return page
        }
    }
    private func reopen(_ store:SessionStore) -> BrowserSession {
        let settings = Settings(defaults:UserDefaults(suiteName:"favorite-split.\(UUID())")!)
        settings.restoresSession = true
        return BrowserSession(database:nil,sessionStore:store,settings:settings)
    }

    @Test("A split becomes one Favorite and opens all original panes in a sibling Space",
          arguments:[SplitLayout.Grid.sideBySide,.stacked,.grid])
    func sharedUnit(grid:SplitLayout.Grid) throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let pages = pages(session)
        session.splitTabs(pages,grid:grid)
        let layout = try #require(session.activeSplit).settingShares(at:[],to:grid == .grid ? [0.7,0.3]:[0.4,0.3,0.2,0.1])
        session.updateSplitLayout(layout);session.selectTab(pages[1]);session.toggleStickPane(pages[0].id)
        let groupID = try #require(owner.splits.identifier(containing:pages[0].id))
        session.pin(pages[2])
        let site = try #require(owner.pinnedSites.first)
        #expect(owner.pinnedSites.count == 1 && owner.profile.favoriteTabs.count == 4)
        #expect(pages.allSatisfy { page in page.pinnedSiteID == site.id && owner.profile.favoriteTabs.contains(where:{ $0 === page }) })
        #expect(owner.workspaceTabs.allSatisfy { page in !pages.contains(where:{ $0 === page }) })
        let sibling = session.addSpace(named:"Sibling",profile:owner.profile)
        let count = session.allTabs.count
        session.openPinnedSite(site)
        let split = try #require(session.activeSplit)
        #expect(split == layout && split.tabIDs == pages.map(\.id))
        #expect(session.activeTab === pages[1] && sibling.splits.identifier(containing:pages[0].id) == groupID)
        #expect(sibling.splits.stickyTabIDs.contains(pages[0].id))
        session.openPinnedSite(site)
        #expect(session.allTabs.count == count && sibling.profile.favoriteTabs.count == 4)
        #expect(pages.allSatisfy { $0.currentWebView == nil })
    }

    @Test("Saving and reopening keeps duplicate-URL members distinct and retains the focused pane")
    func savedMembers() throws {
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let pages = pages(session,count:2),owner = session.activeSpace
        session.splitTabs(pages);session.selectTab(pages[1]);session.pin(pages[0])
        let profileID = owner.profile.id
        let site = try #require(owner.pinnedSites.first)
        let sibling = session.addSpace(named:"Sibling",profile:owner.profile)
        session.openPinnedSite(site);session.saveNow()
        let restored = reopen(store)
        let profile = try #require(restored.profiles.first { $0.id == profileID })
        #expect(profile.favoriteTabs.count == 2 && Set(profile.favoriteTabs.map(\.customName)).count == 2)
        #expect(restored.activeSpace.id == sibling.id && restored.activeTab?.customName == "Pane 1")
        #expect(restored.activeSplit?.paneCount == 2)
        restored.openPinnedSite(try #require(profile.pinnedSites.first))
        #expect(profile.favoriteTabs.count == 2 && restored.activeSplit?.paneCount == 2)
    }

    @Test("Removing a Favorite in another Space returns its whole unit only to that Space")
    func unpinUnit() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.selectTab(pages[1]);session.pin(pages[0])
        let site = try #require(owner.pinnedSites.first)
        let sibling = session.addSpace(named:"Sibling",profile:owner.profile)
        session.openPinnedSite(site);session.removePinnedSite(site)
        #expect(owner.profile.pinnedSites.isEmpty && owner.profile.favoriteTabs.isEmpty)
        #expect(pages.allSatisfy { page in sibling.workspaceTabs.contains(where:{ $0 === page }) && page.pinnedSiteID == nil })
        #expect(pages.allSatisfy { page in !owner.workspaceTabs.contains(where:{ $0 === page }) })
        #expect(owner.splits.layouts.isEmpty && sibling.splits.layouts.count == 1)
        #expect(session.activeTab === pages[1])
    }

    @Test("Reopening the tile recreates a closed member without duplicating its sibling")
    func missingMember() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.selectTab(pages[1]);session.pin(pages[0])
        let site = try #require(owner.pinnedSites.first)
        session.closeTab(pages[1]);session.openPinnedSite(site)
        #expect(owner.profile.favoriteTabs.count == 2 && owner.profile.favoriteTabs.contains(where:{ $0 === pages[0] }))
        #expect(owner.profile.favoriteTabs.filter { $0.customName == "Pane 1" }.count == 1)
        #expect(owner.splits.layouts.count == 1 && session.activeTab?.customName == "Pane 1")
    }

    @Test("A protected member prevents a partial conversion")
    func protectedUnit() {
        let session = TestSession.make().0,owner = session.activeSpace
        let pages = pages(session,count:2)
        session.splitTabs(pages);pages[1].setLocked(true)
        session.pin(pages[0])
        #expect(owner.pinnedSites.isEmpty && owner.profile.favoriteTabs.isEmpty)
        #expect(pages.allSatisfy { $0.pinnedSiteID == nil })
    }

    @Test("A split does not alias a single Favorite with the same address")
    func sameAddressDestination() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let single = pages(session,count:1)[0];session.pin(single)
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.pin(pages[0])
        #expect(owner.pinnedSites.count == 2 && owner.profile.favoriteTabs.count == 3)
        #expect(pages[0].pinnedSiteID != single.pinnedSiteID && pages[0].pinnedSiteID == pages[1].pinnedSiteID)
        #expect(pages[0].pinnedMemberID != pages[1].pinnedMemberID)
    }

    @Test("Edited proportions and focus are reused when opening the tile in another Space")
    func editedDestination() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.pin(pages[0])
        let stale = try #require(owner.pinnedSites.first)
        _ = session.addSpace(named:"Sibling",profile:owner.profile);session.openPinnedSite(stale)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.8,0.2]))
        session.selectTab(pages[1]);session.toggleStickPane(pages[0].id)
        session.selectSpace(owner);session.openPinnedSite(stale)
        let layout = try #require(session.activeSplit)
        #expect(abs((layout.unitFrames()[pages[0].id]?.width ?? 0)-0.8)<0.0000001)
        #expect(session.activeTab === pages[1] && owner.splits.stickyTabIDs.contains(pages[0].id))
    }

    @Test("A Favorite split survives losing its last Space and remains isolated from another profile")
    func unusedAndIsolated() throws {
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let profile = try #require(session.addProfile(named:"Favorite owner"))
        let owner = session.addSpace(named:"Temporary",profile:profile)
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.selectTab(pages[1]);session.pin(pages[0])
        let site = try #require(owner.pinnedSites.first)
        session.removeSpace(owner)
        let count = session.allTabs.count
        session.openPinnedSite(site)
        #expect(session.allTabs.count == count && session.activeSpace.profile !== profile)
        session.saveNow()
        let restored = reopen(store)
        let saved = try #require(restored.profiles.first { $0.id == profile.id })
        #expect(saved.favoriteTabs.count == 2)
        let replacement = restored.addSpace(named:"Replacement",profile:saved)
        restored.openPinnedSite(try #require(saved.pinnedSites.first))
        #expect(replacement.splits.layouts.count == 1 && restored.activeTab?.customName == "Pane 1")
    }

    @Test("The native Favorite strip accepts a complete split drop and its tile opens the whole group")
    func nativeDrop() throws {
        let session = TestSession.make().0
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.selectTab(pages[1])
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        let strip = try #require(UITestSupport.descendants(of:host).compactMap { $0 as? PinnedTilesView }.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(pages[1].id.uuidString,forType:SidebarTabDrag.type)
        #expect(strip.canAcceptDrop(from:pasteboard) && strip.acceptDrop(from:pasteboard))
        host.layoutSubtreeIfNeeded()
        #expect(strip.tileCount == 1 && sidebar.tabListTableView.numberOfRows == 1)
        let title = try #require(session.activeSpace.pinnedSites.first?.title)
        let tile = try #require(UITestSupport.descendants(of:strip).first { $0.accessibilityLabel() == title })
        #expect(tile.accessibilityPerformPress())
        #expect(session.activeSplit?.paneCount == 2 && session.activeTab === pages[1])
        #expect(session.activeSpace.profile.favoriteTabs.count == 2)
    }

    @Test("Private Favorite groups never write their destinations or member snapshots")
    func privatePersistence() throws {
        let session = TestSession.make().0
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let pages = pages(session,count:2)
        session.splitTabs(pages);session.pin(pages[0])
        #expect(secret.profile.favoriteTabs.count == 2)
        let snapshot = session.snapshot()
        let stored = try #require(snapshot.spaces.first { $0.id == secret.id })
        let profile = try #require(snapshot.profiles?.first { $0.id == secret.profile.id })
        #expect(stored.tabs.isEmpty && stored.pinnedSites == nil && stored.splits == nil)
        #expect(profile.favoriteTabs == nil && profile.pinnedSites == nil)
        #expect(!String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self).contains("favorite-split.invalid"))
    }

    @Test("Snapshot merge binds every Favorite member despite matching URLs and is repeatable")
    func snapshotMerge() throws {
        let source = TestSession.make().0
        let pages = pages(source,count:2)
        source.splitTabs(pages);source.pin(pages[0])
        let snapshot = source.snapshot(),target = TestSession.make().0
        target.mergeSnapshot(snapshot)
        #expect(target.activeSpace.profile.favoriteTabs.count == 2)
        let site = try #require(target.activeSpace.pinnedSites.first)
        target.openPinnedSite(site)
        #expect(target.activeSplit?.paneCount == 2)
        target.mergeSnapshot(snapshot)
        #expect(target.activeSpace.profile.favoriteTabs.count == 2 && target.activeSpace.splits.layouts.count == 1)
        #expect(target.isPinnedSite(pages[0].url))
    }
}
