// Modified for Barc: complete split rows survive closed-window restoration, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Closed split window continuity", .serialized)
@MainActor
struct ClosedSplitWindowTests {
    private func page(_ name:String,in session:BrowserSession) -> Tab {
        let tab = session.newTab(url:URL(string:"https://closed-split.invalid/shared")!)
        session.rename(tab,to:name)
        return tab
    }

    @Test("Reopening a complete closed unit restores one row, its proportions, focus and sticky pane",
          arguments:[SplitLayout.Grid.sideBySide,.stacked,.grid])
    func complete(grid:SplitLayout.Grid) throws {
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let owner = session.activeSpace
        let pages = (0..<4).map { page("Pane \($0)",in:session) }
        session.splitTabs(pages,grid:grid)
        let layout = try #require(session.activeSplit).settingShares(at:[],to:grid == .grid ? [0.7,0.3]:[0.4,0.3,0.2,0.1])
        session.updateSplitLayout(layout);session.selectTab(pages[1]);session.toggleStickPane(pages[0].id)
        let groupID = try #require(owner.splits.identifier(containing:pages[0].id))
        let names = pages.map(\.customName)
        session.closeTabs(Array(pages.reversed()))
        #expect(owner.splits.layouts.isEmpty)
        var published:[Int] = []
        let sink = session.changes.sink { change in
            switch change {
            case .tabs,.spaces,.structure: published.append(owner.splits.layouts.count)
            default: break
            }
        }
        let restored = session.reopenClosedWindow()
        withExtendedLifetime(sink) {}
        #expect(restored.count == 4 && restored.map(\.customName) == Array(names.reversed()))
        let split = try #require(owner.splits.layout(containing:restored[0].id))
        let ordered = split.tabIDs.compactMap { id in restored.first { $0.id == id } }
        #expect(ordered.map(\.customName) == names)
        let frames = layout.unitFrames(),after = split.unitFrames()
        for (before,now) in zip(pages,ordered) { #expect(frames[before.id] == after[now.id]) }
        #expect(session.activeTab?.customName == "Pane 1")
        #expect(owner.splits.preferredTab(containing:ordered[0].id) == ordered[1].id)
        #expect(owner.splits.stickyTabIDs.contains(ordered[0].id))
        #expect(owner.splits.identifier(containing:ordered[0].id) == groupID)
        #expect(published == [1])
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        let rows = (0..<sidebar.tabListTableView.numberOfRows).compactMap {
            sidebar.tabListTableView.view(atColumn:0,row:$0,makeIfNecessary:true) as? SplitRowView
        }
        #expect(rows.count == 1 && rows.first?.members.count == 4)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"closed-split.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let saved = try #require(reopened.spaces.first { $0.id == owner.id })
        #expect(saved.splits.layouts.count == 1 && saved.activeTab?.customName == "Pane 1")
        let savedActiveID = try #require(saved.activeTabID)
        #expect(saved.splits.identifier(containing:savedActiveID) == groupID)
    }

    @Test("A partial closed unit stays separate from its surviving panes")
    func partial() throws {
        let session = TestSession.make().0
        let pages = (0..<4).map { page("Pane \($0)",in:session) }
        session.splitTabs(pages,grid:.grid)
        session.closeTabs([pages[0],pages[1]])
        let before = session.activeSpace.splits
        let restored = session.reopenClosedWindow()
        #expect(restored.count == 2 && session.activeSpace.splits == before)
        #expect(restored.allSatisfy { session.activeSpace.splits.layout(containing:$0.id) == nil })
    }

    @Test("Changing the owning profile keeps closed split geometry and restores pages in the new identity")
    func profileRebind() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let a = page("A",in:session),b = page("B",in:session)
        session.splitTabs([a,b]);session.closeTabs([a,b])
        let profile = try #require(session.addProfile(named:"New identity"))
        #expect(session.assignProfile(profile,to:owner))
        let restored = session.reopenClosedWindow()
        #expect(restored.count == 2 && restored.allSatisfy { $0.identity == profile.identity })
        #expect(owner.splits.layouts.count == 1)
    }

    @Test("Restoring a closed split preserves an unrelated active sticky group")
    func unrelatedSticky() throws {
        let session = TestSession.make().0,space = session.activeSpace
        let a = page("A",in:session),b = page("B",in:session)
        session.splitTabs([a,b]);session.selectTab(b);session.closeTabs([a,b])
        let x = page("X",in:session),y = page("Y",in:session)
        session.splitTabs([x,y]);session.toggleStickPane(x.id)
        let before = try #require(space.splits.layout(containing:x.id))
        let identity = try #require(space.splits.identifier(containing:x.id))
        let restored = session.reopenClosedWindow()
        #expect(space.splits.layouts.count == 2 && restored.count == 2)
        #expect(space.splits.layout(containing:x.id) == before)
        #expect(space.splits.identifier(containing:x.id) == identity && space.splits.stickyTabIDs.contains(x.id))
        #expect(session.activeTab?.customName == "B")
    }

    @Test("A repeated window snapshot copies full units with fresh group identities")
    func collisionAndFocus() throws {
        let session = TestSession.make().0,space = session.activeSpace
        let a = page("A",in:session),b = page("B",in:session)
        session.splitTabs([a,b]);session.selectTab(b)
        let originalID = try #require(space.splits.identifier(containing:a.id))
        session.recordClosedWindow(tabs:[b,a],in:space)
        let restored = session.reopenClosedWindow()
        #expect(space.splits.layouts.count == 2 && restored.count == 2)
        #expect(space.splits.identifier(containing:a.id) == originalID)
        #expect(space.splits.identifier(containing:restored[0].id) != originalID)
        #expect(session.activeTab === restored[0])
    }
}
