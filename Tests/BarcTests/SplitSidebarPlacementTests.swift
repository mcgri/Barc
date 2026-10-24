// Modified for Barc: a split owns one sidebar position and separates into adjacent pages, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Split units keep one sidebar position", .serialized)
@MainActor
struct SplitSidebarPlacementTests {
    private func page(_ name:String, in session:BrowserSession) -> Tab {
        let tab = session.newTab(url:URL(string:"https://split-position.invalid/\(name)")!)
        session.rename(tab,to:name)
        return tab
    }
    private func siblings(_ session:BrowserSession, parent:UUID? = nil) -> [UUID] {
        SidebarOrder.items(groups:session.activeSpace.groups,tabs:session.activeSpace.sidebarVisibleTabs,parentID:parent).map(\.id)
    }

    @Test("Combining separated rows keeps the target's position and separates into adjacent pages", arguments:[false,true])
    func adjacentAfterSeparation(reverse:Bool) {
        let session = TestSession.make().0
        let a = page("A",in:session), middle = page("Middle",in:session)
        let b = page("B",in:session), tail = page("Tail",in:session)
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        #expect(session.splitTabs(reverse ? [b,a] : [a,b]))
        #expect(sidebar.tabListTableView.numberOfRows == 4)
        session.unsplit()
        let expected = reverse ? [middle.id,b.id,a.id,tail.id] : [a.id,b.id,middle.id,tail.id]
        #expect(siblings(session) == expected)
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == expected)
        #expect(sidebar.tabListTableView.numberOfRows == 5)
        #expect(session.activeTab === (reverse ? b : a))
    }

    @Test("A pinned target keeps the whole unit above the divider without crossing a following folder")
    func pinnedPlacement() {
        let session = TestSession.make().0
        let before = page("Before",in:session), anchor = page("Anchor",in:session)
        let after = page("After",in:session), ordinary = page("Ordinary",in:session), incoming = page("Incoming",in:session)
        for tab in [before,anchor,after] { tab.setKeepsInSidebar(true) }
        let fence = session.createGroup(named:"Fence")
        before.sidebarPosition = 0; anchor.sidebarPosition = 1; fence.sidebarPosition = 2
        after.sidebarPosition = 3; ordinary.sidebarPosition = 4; incoming.sidebarPosition = 5
        session.splitTabs([anchor,incoming])
        #expect(incoming.keepsInSidebar && incoming.pinnedPageURL == incoming.url)
        session.unsplit()
        #expect(siblings(session) == [before.id,anchor.id,incoming.id,fence.id,after.id,ordinary.id])
        #expect(!ordinary.keepsInSidebar && after.keepsInSidebar)
    }

    @Test("Joining two groups files all pages at the original target unit, preserving unrelated splits")
    func mergeFolders() throws {
        let session = TestSession.make().0
        let root = session.createGroup(named:"Root")
        let target = session.createGroup(named:"Target",parent:root)
        let elsewhere = session.createGroup(named:"Elsewhere")
        let prefix = page("Prefix",in:session), a = page("A",in:session)
        let b = page("B",in:session), suffix = page("Suffix",in:session)
        for tab in [prefix,a,b,suffix] { session.move(tab,to:target) }
        let c = page("C",in:session), d = page("D",in:session)
        for tab in [c,d] { session.move(tab,to:elsewhere) }
        session.splitTabs([a,b])
        let targetID = session.activeSpace.splits.identifier(containing:a.id)
        session.splitTabs([c,d],grid:.stacked)
        let e = page("E",in:session), f = page("F",in:session)
        session.splitTabs([e,f])
        let unrelated = try #require(session.activeSplit)
        session.splitTabs([b,d])
        #expect(session.activeSpace.splits.identifier(containing:a.id) == targetID)
        #expect(session.activeSpace.splits.layout(containing:e.id) == unrelated)
        #expect([a,b,c,d].allSatisfy { $0.groupID == target.id })
        #expect(session.activeSpace.tabs(in:elsewhere).isEmpty)
        #expect(session.activeSpace.groups.contains { $0 === elsewhere })
        session.unsplit()
        #expect(siblings(session,parent:target.id) == [prefix.id,a.id,b.id,c.id,d.id,suffix.id])
        #expect(session.activeSpace.tabs(in:target).map(\.id) == [prefix.id,a.id,b.id,c.id,d.id,suffix.id])
        #expect(session.activeSpace.splits.layout(containing:e.id) == unrelated)
    }

    @Test("A saved unit retains its sidebar placement and remembered pane after reopening and separating")
    func persistedPlacement() throws {
        let (session,store) = TestSession.make()
        let a = page("A",in:session), middle = page("Middle",in:session), b = page("B",in:session)
        session.splitTabs([a,b]); session.selectTab(b)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"split.position.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        #expect(restored.activeTab?.customName == "B")
        restored.unsplit()
        #expect(restored.activeSpace.sidebarVisibleTabs.map(\.customName) == ["A","B","Middle"])
        #expect(restored.activeSpace.sidebarVisibleTabs.map(\.url) == [a.url,b.url,middle.url])
    }

    @Test("A refused oversized or foreign join leaves folder, pin and ordering metadata unchanged")
    func refusedJoin() {
        let session = TestSession.make().0
        let owner = session.activeSpace
        let pages = (0..<5).map { page("Page-\($0)",in:session) }
        let folder = session.createGroup(named:"Existing",containing:[pages[0]])
        pages[1].setKeepsInSidebar(true)
        let before = session.snapshot()
        #expect(!session.splitTabs(pages))
        #expect(session.snapshot() == before)
        #expect(pages[0].groupID == folder.id)
        session.addSpace(named:"Foreign",profile:owner.profile)
        let foreign = page("Foreign",in:session)
        session.selectSpace(owner)
        let beforeForeign = session.snapshot()
        #expect(!session.splitTabs([pages[0],foreign]))
        #expect(session.snapshot() == beforeForeign)
    }

    @Test("Normalizing a split never rewrites shared Favorite metadata or another Space's layout")
    func sharedFavoriteMetadata() {
        let session = TestSession.make().0
        let source = session.activeSpace
        let favorite = page("Favorite",in:session)
        session.pin(favorite)
        let sibling = session.addSpace(named:"Sibling",profile:source.profile)
        let siblingPage = page("Sibling",in:session)
        session.splitTabs([siblingPage,favorite])
        let siblingSplits = sibling.splits
        session.selectSpace(source)
        let first = page("First",in:session), gap = page("Gap",in:session), second = page("Second",in:session)
        let favoriteBefore = favorite.snapshot()
        session.splitTabs([first,favorite,second])
        #expect(favorite.snapshot() == favoriteBefore)
        #expect(sibling.splits == siblingSplits)
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [first.id,second.id,gap.id])
    }

    @Test("A collapsed target folder exposes the complete split and keeps the active pane after separating")
    func collapsedTarget() throws {
        let session = TestSession.make().0
        let anchor = page("Anchor",in:session), incoming = page("Incoming",in:session)
        let folder = session.createGroup(named:"Collapsed",containing:[anchor])
        folder.isCollapsed = true
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        session.splitTabs([anchor,incoming])
        let table = sidebar.tabListTableView
        let cell = try #require(table.view(atColumn:0,row:table.selectedRow,makeIfNecessary:true) as? SplitRowView)
        #expect(cell.members.count == 2)
        #expect(sidebar.selectedTabs.map(\.id) == [anchor.id,incoming.id])
        #expect(incoming.groupID == folder.id && folder.isCollapsed)
        session.unsplit()
        #expect(session.activeTab === incoming && folder.isCollapsed)
        #expect(sidebar.selectedTabs.map(\.id) == [incoming.id])
    }

    @Test("Separating a restored older split repairs its scattered page positions without changing focus")
    func legacySeparation() throws {
        let (session,store) = TestSession.make()
        let a = page("A",in:session), gap = page("Gap",in:session), b = page("B",in:session)
        session.activeSpace.splits.join([a.id,b.id],grid:.sideBySide)
        session.activeSpace.splits.focus(b.id)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"split.position.legacy.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        #expect(restored.activeSpace.sidebarVisibleTabs.map(\.url) == [a.url,gap.url,b.url])
        restored.unsplit()
        #expect(restored.activeSpace.sidebarVisibleTabs.map(\.url) == [a.url,b.url,gap.url])
        #expect(restored.activeTab?.customName == "B")
        #expect(restored.activeSplit == nil)
    }
}
