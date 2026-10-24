// Modified for Barc: whole-row archive transitions, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Split archive transitions", .serialized)
@MainActor
struct SplitArchiveTransitionTests {
    enum RestoreAction: CaseIterable { case one, all, undo }
    @Test("A four-pane row disappears without unfolding into loose native rows", arguments:[false,true])
    func compactTransition(active:Bool) throws {
        let session = TestSession.make().0
        let pages = (0..<4).map { session.newTab(url:URL(string:"https://archive-transition.invalid/\($0)")!) }
        session.splitTabs(pages,grid:.grid)
        let other = session.newTab(url:URL(string:"https://archive-transition.invalid/keep")!)
        if active { session.selectTab(pages[2]) }
        let sidebar = SidebarViewController(session:session)
        let root = UITestSupport.host(sidebar.view,width:228,height:760)
        let table = sidebar.tabListTableView
        let before = table.numberOfRows
        #expect(before == 3)
        var samples: [[String:Int]] = []
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .structure,.tabs: layout = 1; case .activeTab: layout = 0; default: return }
            root.layoutSubtreeIfNeeded()
            let remaining = session.activeSpace.tabs.filter { page in pages.contains { $0 === page } }.count
            samples.append(["rows":table.numberOfRows,"remainingPanes":remaining,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        session.archive(pages)
        #expect(table.numberOfRows == 2)
        #expect(samples.allSatisfy { $0["rows"]! <= before })
        #expect(samples.allSatisfy { $0["remainingPanes"] == 0 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(session.activeTab === other)
        if let directory = ProcessInfo.processInfo.environment["BARC_ARCHIVE_TRANSITION_DIR"] {
            let output = URL(fileURLWithPath:directory).appending(path:active ? "active.json" : "background.json")
            try JSONSerialization.data(withJSONObject:["beforeRows":before,"afterRows":table.numberOfRows,"samples":samples],options:[.prettyPrinted,.sortedKeys]).write(to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        }
    }

    @Test("Unloading a live local page cannot announce a half-archived split")
    func livePageUnload() throws {
        let session = TestSession.make().0
        let pages = (0..<2).map { session.newTab(url:URL(string:"data:text/html,pane-\($0)")!) }
        session.splitTabs(pages)
        _ = pages[0].webView()
        #expect(pages[0].isLoaded)
        var remaining:[Int] = [], pageAnnouncements = 0
        let token = session.changes.sink { change in
            remaining.append(session.activeSpace.tabs.filter { page in pages.contains { $0 === page } }.count)
            if case .tab = change { pageAnnouncements += 1 }
        }
        defer { token.cancel() }
        session.archive(pages)
        #expect(remaining.allSatisfy { $0 == 0 })
        #expect(pageAnnouncements == 0 && pages.allSatisfy { !$0.isLoaded })
        #expect(session.archivedTabs.count == 1)
    }

    @Test("Explicitly archiving one of three panes keeps the other panes, focus and proportions usable")
    func partialLayout() throws {
        let session = TestSession.make().0
        let pages = (0..<3).map { session.newTab(url:URL(string:"https://archive-transition.invalid/\($0)")!) }
        session.splitTabs(pages,grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.2,0.3,0.5]))
        session.selectTab(pages[1])
        session.toggleStickPane(pages[2].id)
        session.archive([pages[1]])
        let layout = try #require(session.activeSplit)
        #expect(layout.tabIDs == [pages[0].id,pages[2].id])
        #expect(abs((layout.unitFrames()[pages[0].id]?.width ?? 0)-2/7.0) < 0.000001)
        #expect(session.activeTab === pages[0] && session.isSticky(pages[2].id))
        #expect(session.activeSpace.splits.preferredTab(containing:pages[0].id) == pages[0].id)
    }

    @Test("Restoration opens complete rows in one layout update", arguments:RestoreAction.allCases)
    func restoreTransition(action:RestoreAction) throws {
        let session = TestSession.make().0
        let pages = (0..<4).map { session.newTab(url:URL(string:"https://restore-transition.invalid/\($0)")!) }
        session.splitTabs(Array(pages.prefix(2)))
        session.splitTabs(Array(pages.suffix(2)),grid:.stacked)
        _ = session.newTab(url:URL(string:"https://restore-transition.invalid/keep")!)
        var toast:Toast?;session.showToast = { toast = $0 }
        session.archive(pages)
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        let expectedGroups = action == .one ? 1 : 2
        var layouts = 0, groups:[Int] = []
        let token = session.changes.sink { change in
            switch change {
            case .structure,.tabs: layouts += 1
            case .activeTab,.spaces: break
            default: return
            }
            groups.append(session.splitGroups(in:session.activeSpace).count)
        }
        defer { token.cancel() }
        switch action {
        case .one: session.restoreArchived(try #require(session.archivedTabs.first))
        case .all: session.restoreAllArchived(in:session.activeSpace)
        case .undo: try #require(toast?.action).handler()
        }
        #expect(layouts == 1)
        #expect(groups.allSatisfy { $0 == expectedGroups })
        #expect(sidebar.tabListTableView.numberOfRows == expectedGroups+2)
    }

    @Test("Undo across Spaces announces only the finished destination and remembers every group's focused pane")
    func crossSpaceUndo() throws {
        let session = TestSession.make().0, first = session.activeSpace
        let a = session.newTab(url:URL(string:"https://cross-space-transition.invalid/a")!)
        let b = session.newTab(url:URL(string:"https://cross-space-transition.invalid/b")!)
        session.splitTabs([a,b]);session.selectTab(b)
        let second = session.addSpace(named:"Second")
        let c = session.newTab(url:URL(string:"https://cross-space-transition.invalid/c")!)
        let d = session.newTab(url:URL(string:"https://cross-space-transition.invalid/d")!)
        session.splitTabs([c,d]);session.selectTab(d)
        var toast:Toast?;session.showToast = { toast = $0 }
        session.archive([a,b,c,d])
        session.selectSpace(first)
        var destinations:[Space.ID] = [], focused:[URL?] = [], complete:[Bool] = []
        let token = session.changes.sink { change in
            if case .spaces = change {
                destinations.append(session.activeSpaceID)
                focused.append(session.activeTab?.url)
                complete.append(session.spaces.allSatisfy { session.splitGroups(in:$0).count == 1 })
            }
        }
        defer { token.cancel() }
        try #require(toast?.action).handler()
        #expect(destinations == [second.id] && focused == [d.url])
        #expect(complete == [true])
        #expect(first.activeTab?.url == b.url && second.activeTab?.url == d.url)
        #expect(first.tabs.allSatisfy { $0.identity == first.identity })
        #expect(second.tabs.allSatisfy { $0.identity == second.identity })
    }
}
