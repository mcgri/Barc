// Modified for Barc: duplicating a split keeps its pages in one sidebar unit, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Duplicating split sidebar units", .serialized)
@MainActor
struct SplitDuplicationTests {
    @Test("A complete duplicate keeps pane geometry and focus, with new page and group identities")
    func completeUnit() throws {
        let (session,store) = TestSession.make()
        let space = session.activeSpace
        let pages = (0..<3).map { index in
            let snapshot = SessionSnapshot.Tab(url:URL(string:"https://split-copy.invalid/same")!,
                customName:"Pane \(index)",interactionState:Data("same-profile page state".utf8),
                importedSourceID:"fixture/\(index)")
            let page = Tab(restoring:snapshot,identity:space.identity)
            space.insert(page,at:space.workspaceTabs.count)
            return page
        }
        session.splitTabs(pages,grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.2,0.3,0.5]))
        session.selectTab(pages[1]); session.toggleStickPane(pages[0].id)
        let original = try #require(session.activeSplit)
        let originalID = try #require(space.splits.identifier(containing:pages[0].id))
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        let copies = session.duplicateTabs(pages + [pages[0]])
        #expect(copies.count == 3)
        #expect(Set(copies.map(\.id)).isDisjoint(with:pages.map(\.id)))
        #expect(copies.map(\.customName) == pages.map(\.customName))
        #expect(copies.allSatisfy { $0.importedSourceID == nil && $0.snapshot().interactionState != nil })
        #expect(space.splits.layout(containing:pages[0].id) == original)
        let copied = try #require(space.splits.layout(containing:copies[0].id))
        #expect(copied.tabIDs == copies.map(\.id))
        for index in pages.indices { #expect(copied.unitFrames()[copies[index].id] == original.unitFrames()[pages[index].id]) }
        let copyID = try #require(space.splits.identifier(containing:copies[0].id))
        #expect(copyID != originalID)
        #expect(space.splits.preferredTab(containing:copies[0].id) == copies[1].id)
        #expect(space.splits.stickyTabIDs.contains(copies[0].id))
        #expect(session.activeTab === copies[1])
        #expect(sidebar.tabListTableView.numberOfRows == 3)
        #expect(sidebar.selectedTabs.map(\.id) == copies.map(\.id))
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"split.copy.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restoredCopies = restored.activeSpace.tabs.filter { $0.importedSourceID == nil && $0.customName != nil }
        #expect(restoredCopies.count == 3)
        #expect(restored.activeSpace.splits.identifier(containing:restoredCopies[0].id) == copyID)
        #expect(restored.activeSpace.splits.preferredTab(containing:restoredCopies[0].id) == restoredCopies[1].id)
        #expect(restored.activeTab === restoredCopies[1])
    }

    @Test("Duplicating a single pane keeps the original split and creates an ordinary independent page")
    func onePane() throws {
        let session = TestSession.make().0
        let pages = (0..<2).map { session.newTab(url:URL(string:"https://split-copy.invalid/\($0)")!) }
        session.splitTabs(pages)
        let before = session.activeSpace.splits
        let copies = session.duplicateTabs([pages[0]])
        #expect(copies.count == 1 && session.activeTab === copies[0])
        #expect(session.activeSpace.splits == before)
        #expect(session.activeSpace.splits.layout(containing:copies[0].id) == nil)
    }

    @Test("A copied folder retains its complete split and nested filing without selecting the copies")
    func folderUnit() throws {
        let session = TestSession.make().0
        let pages = (0..<2).map { session.newTab(url:URL(string:"https://split-copy.invalid/folder-\($0)")!) }
        let folder = session.createGroup(named:"Reading")
        let child = session.createGroup(named:"Nested",parent:folder)
        for page in pages { session.move(page,to:child) }
        session.splitTabs(pages,grid:.stacked)
        session.selectTab(pages[1])
        let selected = session.activeTab
        let originalID = try #require(session.activeSpace.splits.identifier(containing:pages[0].id))
        let copy = try #require(try session.duplicateFolder(folder))
        let copiedChild = try #require(session.activeSpace.groups.first { $0.parentID == copy.id })
        let copies = session.activeSpace.tabs(in:copiedChild)
        #expect(copies.count == 2 && session.activeTab === selected)
        #expect(copies.allSatisfy { $0.importedSourceID == nil && $0.groupID == copiedChild.id })
        let layout = try #require(session.activeSpace.splits.layout(containing:copies[0].id))
        #expect(layout.grid == .stacked && layout.tabIDs == copies.map(\.id))
        #expect(session.activeSpace.splits.identifier(containing:copies[0].id) != originalID)
        #expect(session.activeSpace.splits.preferredTab(containing:copies[0].id) == copies[1].id)
        #expect(session.activeSpace.splits.layout(containing:pages[0].id)?.tabIDs == pages.map(\.id))
    }

    @Test("A folder containing only one pane copies that page without attaching it to the source split")
    func partialFolder() throws {
        let session = TestSession.make().0
        let pages = (0..<2).map { session.newTab(url:URL(string:"https://split-copy.invalid/partial-\($0)")!) }
        let folder = session.createGroup(named:"Partial",containing:[pages[0]])
        // Older snapshots may contain a split whose panes have different
        // parents. New session-level joins now file the whole unit together.
        session.activeSpace.splits.join(pages.map(\.id),grid:.grid)
        let before = session.activeSpace.splits
        let copy = try #require(try session.duplicateFolder(folder))
        let copied = session.activeSpace.tabs(in:copy)
        #expect(copied.count == 1)
        #expect(session.activeSpace.splits == before)
        #expect(session.activeSpace.splits.layout(containing:copied[0].id) == nil)
    }
}
