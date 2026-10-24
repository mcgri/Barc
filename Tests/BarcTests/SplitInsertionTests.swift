// Modified for Barc: sidebar split ordering and durable pane placement, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar split insertion", .serialized)
@MainActor
struct SplitInsertionTests {
    private func pages(_ count:Int, in session:BrowserSession) -> [Tab] {
        (0..<count).map { session.newTab(url:URL(string:"https://split-insertion.invalid/\($0)")!) }
    }

    @Test("Horizontal insertion scales siblings proportionally and retains the destination's identity and focus", arguments:[false,true])
    func horizontal(left:Bool) throws {
        let session = TestSession.make().0
        let tabs = pages(3,in:session), a = tabs[0], b = tabs[1], incoming = tabs[2]
        session.splitTabs([a,b],grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.7,0.3]))
        session.selectTab(b); session.toggleStickPane(b.id)
        let id = session.activeSpace.splits.identifier(containing:b.id)
        #expect(session.splitSidebarTabs([incoming],beside:b,on:left ? .left : .right))
        let layout = try #require(session.activeSplit)
        #expect(layout.tabIDs == (left ? [a.id,incoming.id,b.id] : [a.id,b.id,incoming.id]))
        #expect(abs(try #require(layout.unitFrames()[a.id]).width-0.7*2/3) < 0.000001)
        #expect(abs(try #require(layout.unitFrames()[b.id]).width-0.3*2/3) < 0.000001)
        #expect(abs(try #require(layout.unitFrames()[incoming.id]).width-1.0/3) < 0.000001)
        #expect(session.activeSpace.splits.identifier(containing:b.id) == id)
        #expect(session.activeSpace.splits.preferredTab(containing:b.id) == b.id)
        #expect(session.isSticky(b.id))
    }

    @Test("Dragging a complete split preserves its internal proportions and destination folder", arguments:[false,true])
    func incomingUnit(left:Bool) throws {
        let session = TestSession.make().0
        let tabs = pages(6,in:session), a = tabs[0], b = tabs[1], c = tabs[2], d = tabs[3]
        let folder = session.createGroup(named:"Destination",containing:[a,b])
        session.splitTabs([a,b],grid:.stacked)
        let destinationID = session.activeSpace.splits.identifier(containing:a.id)
        session.splitTabs([c,d],grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.8,0.2]))
        session.splitTabs(Array(tabs.suffix(2)))
        let unrelated = try #require(session.activeSplit)
        session.selectTab(b)
        #expect(session.splitSidebarTabs([c],beside:b,on:left ? .left : .right))
        let result = try #require(session.activeSplit)
        let expected = left ? [a.id,c.id,d.id,b.id] : [a.id,b.id,c.id,d.id]
        #expect(result.tabIDs == expected)
        let cFrame = try #require(result.unitFrames()[c.id]), dFrame = try #require(result.unitFrames()[d.id])
        #expect(abs(cFrame.width/dFrame.width-4) < 0.000001)
        #expect(cFrame.minY == dFrame.minY && cFrame.height == dFrame.height)
        #expect(session.activeSpace.splits.layouts.count == 2)
        #expect(session.activeSpace.splits.layout(containing:tabs[4].id) == unrelated)
        #expect(session.activeSpace.splits.identifier(containing:c.id) == destinationID)
        #expect(tabs.prefix(4).allSatisfy { $0.groupID == folder.id })
        #expect(session.activeTab === b)
    }

    @Test("Oversized, empty, self and overlapping insertions are atomic")
    func invalidInsertions() throws {
        let session = TestSession.make().0
        let tabs = pages(5,in:session)
        session.splitTabs(Array(tabs.prefix(3)))
        let before = session.snapshot()
        for incoming in [[],[tabs[0]],[tabs[1],tabs[3]],Array(tabs.suffix(2))] {
            #expect(!session.splitSidebarTabs(incoming,beside:tabs[0],on:.left))
            #expect(session.snapshot() == before)
        }
        let other = session.addSpace(named:"Foreign")
        let foreign = try #require(other.activeTab)
        session.selectSpace(session.spaces[0])
        let local = session.snapshot()
        #expect(!session.splitSidebarTabs([foreign],beside:tabs[0],on:.right))
        #expect(session.snapshot() == local)
    }

    @Test("Multi-row input is inserted in order once, including complete split cohorts")
    func selectionOrder() throws {
        let session = TestSession.make().0
        let tabs = pages(4,in:session)
        session.splitTabs(Array(tabs.suffix(2)),grid:.stacked)
        #expect(session.splitSidebarTabs([tabs[1],tabs[3],tabs[2]],beside:tabs[0],on:.left))
        #expect(session.activeSplit?.tabIDs == [tabs[1].id,tabs[2].id,tabs[3].id,tabs[0].id])
        #expect(session.activeSpace.splits.layouts.count == 1)
    }

    @Test("A positioned drop can be undone and its saved pane order survives fresh runtime tab identities")
    func persistenceAndUndo() throws {
        let (session,store) = TestSession.make()
        let tabs = pages(3,in:session)
        session.splitTabs(Array(tabs.prefix(2)),grid:.stacked)
        session.selectTab(tabs[1])
        let before = session.activeSpace.splits
        #expect(session.splitSidebarTabs([tabs[2]],beside:tabs[1],on:.left))
        let formed = session.activeSpace.splits
        let id = formed.identifier(containing:tabs[0].id)
        session.undoSplit()
        #expect(session.activeSpace.splits == before)
        #expect(session.splitSidebarTabs([tabs[2]],beside:tabs[1],on:.left))
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"barc.split-insertion.restore.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let pages = try tabs.map { original in try #require(restored.activeSpace.tabs.first { $0.url == original.url }) }
        let layout = try #require(restored.activeSplit)
        #expect(layout.tabIDs == [pages[0].id,pages[2].id,pages[1].id])
        #expect(restored.activeSpace.splits.identifier(containing:pages[0].id) == id)
        for (old,new) in zip(tabs,pages) {
            #expect(formed.layout(containing:old.id)?.unitFrames()[old.id] == layout.unitFrames()[new.id])
        }
        #expect(restored.activeTab === pages[1])
    }
}
