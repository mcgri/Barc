// Modified for Barc: complete nested folder and bulk-close transitions, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Remaining sidebar bulk transitions", .serialized)
@MainActor
struct SidebarBulkTransitionTests {
    @Test("An expanded nested folder duplicate arrives with its split already assembled")
    func folderDuplicate() throws {
        let session = TestSession.make().0, space = session.activeSpace
        let pages = (0..<4).map { TestSession.appendTab(in:session,url:URL(string:"https://folder-transition.invalid/\($0)")!) }
        let rootFolder = session.createGroup(named:"Project")
        let child = session.createGroup(named:"Research",parent:rootFolder)
        for page in pages { session.move(page,to:child) }
        rootFolder.isCollapsed = false;child.isCollapsed = false
        session.splitTabs(pages,grid:.grid)
        let selected = session.activeTab
        let sidebar = SidebarViewController(session:session)
        let root = UITestSupport.host(sidebar.view,width:228,height:760)
        let before = sidebar.tabListTableView.numberOfRows
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .tabs,.structure,.spaces: layout = 1; case .activeTab: layout = 0; default: return }
            root.layoutSubtreeIfNeeded()
            samples.append(["rows":sidebar.tabListTableView.numberOfRows,"pages":space.workspaceTabs.filter { $0.url.host() == "folder-transition.invalid" }.count,
                "groups":space.groups.count,"splits":space.splits.layouts.count,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        let copy = try #require(try session.duplicateFolder(rootFolder))
        #expect(samples.allSatisfy { $0["pages"] == 8 && $0["groups"] == 4 && $0["splits"] == 2 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(sidebar.tabListTableView.numberOfRows == before+3)
        #expect(samples.allSatisfy { $0["rows"]! <= before+3 })
        #expect(session.activeTab === selected && copy.isCollapsed == false)
        try save(samples,name:"folder-duplicate")
    }

    @Test("Close Tabs Below removes the complete suffix with one list update")
    func closeBelow() throws {
        let session = TestSession.make().0, space = session.activeSpace
        let keep = TestSession.appendTab(in:session,url:URL(string:"https://below-transition.invalid/keep")!)
        let pages = (0..<4).map { TestSession.appendTab(in:session,url:URL(string:"https://below-transition.invalid/\($0)")!) }
        session.splitTabs(pages,grid:.grid)
        let sidebar = SidebarViewController(session:session)
        let root = UITestSupport.host(sidebar.view,width:228,height:760)
        let before = sidebar.tabListTableView.numberOfRows
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .tabs,.structure,.spaces: layout = 1; case .activeTab: layout = 0; default: return }
            root.layoutSubtreeIfNeeded()
            samples.append(["rows":sidebar.tabListTableView.numberOfRows,"remaining":space.tabs.filter { page in pages.contains { $0 === page } }.count,
                "splits":space.splits.layouts.count,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        session.closeTabs(below:keep)
        #expect(samples.allSatisfy { $0["remaining"] == 0 && $0["splits"] == 0 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(samples.allSatisfy { $0["rows"]! <= before })
        #expect(sidebar.tabListTableView.numberOfRows == 2 && session.activeTab === keep)
        try save(samples,name:"close-below")
    }

    @Test("Duplicate cleanup keeps the selected copy and never exposes a partially removed group")
    func duplicateCleanup() throws {
        let session = TestSession.make().0, space = session.activeSpace
        let pages = (0..<4).map { _ in TestSession.appendTab(in:session,url:URL(string:"https://duplicates-transition.invalid/same")!) }
        session.splitTabs(pages,grid:.grid);session.selectTab(pages[2])
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .tabs,.structure,.spaces: layout = 1; case .activeTab: layout = 0; default: return }
            samples.append(["remaining":space.tabs.filter { $0.url.host() == "duplicates-transition.invalid" }.count,
                "splits":space.splits.layouts.count,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        #expect(session.closeDuplicateTabs() == 3)
        #expect(samples.allSatisfy { $0["remaining"] == 1 && $0["splits"] == 0 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(session.activeTab === pages[2] && sidebar.tabListTableView.numberOfRows == 2)
        try save(samples,name:"duplicate-cleanup")
    }

    private func save(_ samples:[[String:Int]], name:String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BARC_BULK_TRANSITION_DIR"] else { return }
        let output = URL(fileURLWithPath:directory).appending(path:name+".json")
        try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
    }
}
