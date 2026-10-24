// Modified for Barc: split units keep their structure when moved between Spaces, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Moving complete split units", .serialized)
@MainActor
struct SplitTransferTests {
    private func page(_ name:String, in session:BrowserSession) -> Tab {
        session.newTab(url:URL(string:"https://split-transfer.invalid/\(name)")!)
    }

    @Test("Moving a complete split within a profile keeps the pages, geometry, sticky choice and pane focus")
    func sameProfile() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let a = page("a",in:session), b = page("b",in:session)
        let c = page("c",in:session), d = page("d",in:session)
        session.splitTabs([c,d],grid:.stacked)
        let unrelated = try #require(session.activeSplit)
        session.splitTabs([a,b],grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.7,0.3]))
        session.toggleStickPane(a.id)
        session.selectTab(b)
        let movedLayout = try #require(session.activeSplit)
        let id = try #require(source.splits.identifier(containing:a.id))
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        let targetPage = try #require(session.activeTab)
        session.selectSpace(source)
        session.moveTabs([a,b,a],toSpace:target)
        #expect(session.activeSpace === source)
        #expect(!source.tabs.contains { $0 === a || $0 === b })
        #expect(target.tabs.contains { $0 === a } && target.tabs.contains { $0 === b })
        #expect(source.splits.layouts == [unrelated])
        #expect(target.splits.layout(containing:a.id) == movedLayout)
        #expect(target.splits.identifier(containing:a.id) == id)
        #expect(target.splits.preferredTab(containing:a.id) == b.id)
        #expect(target.splits.stickyTabIDs.contains(a.id))
        #expect(target.activeTab === targetPage)
        #expect(!session.canReopenClosedTab)
    }

    @Test("Cross-profile moves rebuild every page without opaque state and map duplicate URLs to the right panes")
    func acrossProfiles() throws {
        let (session,store) = TestSession.make()
        let source = session.activeSpace
        let stored = SessionSnapshot.Tab(url:URL(string:"https://split-transfer.invalid/same")!,
            interactionState:Data("private source page state".utf8),keepsInSidebar:true)
        let pages = (0..<3).map { index in
            var snapshot = stored
            snapshot.customName = "Pane \(index)"
            let tab = Tab(restoring:snapshot,identity:source.identity)
            source.insert(tab,at:source.workspaceTabs.count)
            return tab
        }
        session.splitTabs(pages,grid:.stacked)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.2,0.3,0.5]))
        session.selectTab(pages[1])
        session.toggleStickPane(pages[2].id)
        let id = try #require(source.splits.identifier(containing:pages[0].id))
        let target = session.addSpace(named:"Separate profile")
        session.selectSpace(source)
        session.moveTabs(pages,toSpace:target)
        let moved = target.tabs.filter { $0.url == stored.url }
        #expect(moved.map(\.customName) == ["Pane 0","Pane 1","Pane 2"])
        #expect(moved.allSatisfy { $0.identity == target.identity && $0.snapshot().interactionState == nil })
        #expect(Set(moved.map(\.id)).isDisjoint(with:pages.map(\.id)))
        let layout = try #require(target.splits.layout(containing:moved[0].id))
        #expect(layout.tabIDs == moved.map(\.id) && layout.grid == .stacked)
        #expect(abs((layout.unitFrames()[moved[0].id]?.height ?? 0)-0.2) < 0.000001)
        #expect(abs((layout.unitFrames()[moved[2].id]?.height ?? 0)-0.5) < 0.000001)
        #expect(target.splits.identifier(containing:moved[0].id) == id)
        #expect(target.splits.preferredTab(containing:moved[0].id) == moved[1].id)
        #expect(target.splits.stickyTabIDs == [moved[2].id])
        #expect(source.splits.layouts.isEmpty)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"split.transfer.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restoredTarget = try #require(restored.spaces.first { $0.id == target.id })
        let restoredPanes = restoredTarget.tabs.filter { $0.url == stored.url }
        #expect(restoredTarget.splits.layout(containing:restoredPanes[0].id)?.tabIDs == restoredPanes.map(\.id))
        #expect(restoredTarget.splits.preferredTab(containing:restoredPanes[0].id) == restoredPanes[1].id)
    }

    @Test("Moving a folder carries its complete splits and leaves unrelated target groups intact", arguments:[true,false])
    func folderMove(sharedProfile:Bool) throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let a = page("a",in:session), b = page("b",in:session)
        let folder = session.createGroup(named:"Reading",containing:[a,b])
        session.splitTabs([a,b],grid:.stacked)
        session.selectTab(b)
        let target = session.addSpace(named:"Destination",profile:sharedProfile ? source.profile : nil)
        let c = page("c",in:session), d = page("d",in:session)
        session.splitTabs([c,d])
        let existing = try #require(session.activeSplit)
        session.selectSpace(source)
        session.move(folder,toSpace:target)
        let moved = target.tabs(in:folder)
        #expect(moved.count == 2 && source.splits.layouts.isEmpty)
        #expect(target.splits.layout(containing:c.id) == existing)
        let layout = try #require(target.splits.layout(containing:moved[0].id))
        #expect(layout.grid == .stacked && layout.tabIDs == moved.map(\.id))
        #expect(target.splits.preferredTab(containing:moved[0].id) == moved[1].id)
    }

    @Test("Moving only one page repairs its old group and creates no partial split in the destination")
    func partialMove() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let pages = (0..<3).map { page("partial-\($0)",in:session) }
        session.splitTabs(pages)
        let id = source.splits.identifier(containing:pages[0].id)
        let target = session.addSpace(named:"Destination",profile:source.profile)
        session.selectSpace(source)
        session.moveTabs([pages[1]],toSpace:target)
        #expect(source.splits.layout(containing:pages[0].id)?.tabIDs == [pages[0].id,pages[2].id])
        #expect(source.splits.identifier(containing:pages[0].id) == id)
        #expect(target.splits.layouts.isEmpty)
    }

    @Test("Moving a complete unit to its current Space changes nothing")
    func ownSpace() {
        let session = TestSession.make().0
        let pages = (0..<2).map { page("same-\($0)",in:session) }
        session.splitTabs(pages)
        let snapshot = session.snapshot()
        session.moveTabs(pages,toSpace:session.activeSpace)
        #expect(session.snapshot() == snapshot)
    }

    @Test("A complete unit containing a shared Favorite moves without creating duplicate pages")
    func sharedFavorite() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let favorite = page("favorite",in:session)
        session.pin(favorite)
        let companion = page("companion",in:session)
        session.splitTabs([companion,favorite])
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        session.selectSpace(source)
        session.moveTabs([companion,favorite],toSpace:target)
        #expect(source.splits.layouts.isEmpty)
        #expect(target.tabs.filter { $0 === favorite }.count == 1)
        #expect(source.tabs.contains { $0 === favorite })
        #expect(target.splits.layout(containing:companion.id)?.tabIDs == [companion.id,favorite.id])
    }

    @Test("A shared Favorite already used by another destination split refuses the whole incoming unit")
    func favoriteCollision() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let favorite = page("shared",in:session)
        session.pin(favorite)
        let a = page("source",in:session)
        session.splitTabs([a,favorite])
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        let b = page("target",in:session)
        session.splitTabs([b,favorite])
        session.selectSpace(source)
        let before = session.snapshot()
        session.moveTabs([a,favorite],toSpace:target)
        #expect(session.snapshot() == before)
    }

    @Test("An all-Favorite split transfers its layout while its shared pages remain available in both Spaces")
    func allFavorites() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let pages = (0..<2).map { page("favorite-\($0)",in:session) }
        for page in pages { session.pin(page) }
        session.splitTabs(pages)
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        session.selectSpace(source)
        session.moveTabs(pages,toSpace:target)
        #expect(source.splits.layouts.isEmpty)
        #expect(target.splits.layouts.first?.tabIDs == pages.map(\.id))
        #expect(pages.allSatisfy { page in source.tabs.contains { $0 === page } && target.tabs.contains { $0 === page } })
    }

    @Test("A split created around the already active pane remembers that pane immediately")
    func initiallyFocusedPane() throws {
        let session = TestSession.make().0
        let a = page("first",in:session), b = page("already-active",in:session)
        session.splitTabs([a,b])
        #expect(session.activeTab === b)
        #expect(session.activeSpace.splits.preferredTab(containing:a.id) == b.id)
    }

    @Test("A background source split resolves its shared Favorite from the complete requested unit")
    func backgroundFavoriteOwner() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let favorite = page("background-favorite",in:session)
        session.pin(favorite)
        let companion = page("background-companion",in:session)
        session.splitTabs([companion,favorite])
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        // The destination is active and already shares the Favorite object.
        session.moveTabs([favorite,companion],toSpace:target)
        #expect(source.splits.layouts.isEmpty)
        #expect(target.splits.layout(containing:companion.id)?.tabIDs == [companion.id,favorite.id])
    }

    @Test("The moved unit appears as one selectable native sidebar row in the destination")
    func nativeDestinationRow() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let a = page("native-a",in:session), b = page("native-b",in:session)
        session.splitTabs([a,b]); session.selectTab(b)
        let target = session.addSpace(named:"Sibling",profile:source.profile)
        session.selectSpace(source)
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        session.moveTabs([a,b],toSpace:target)
        session.selectSpace(target)
        host.layoutSubtreeIfNeeded()
        let table = sidebar.tabListTableView
        #expect(table.numberOfRows == 2)
        let index = try #require((0..<table.numberOfRows).first {
            table.view(atColumn:0,row:$0,makeIfNecessary:true) is SplitRowView
        })
        table.selectRowIndexes([index],byExtendingSelection:false)
        #expect(session.activeTab === b)
        #expect(sidebar.selectedTabs.map(\.id) == [a.id,b.id])
    }
}
