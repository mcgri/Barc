// Modified for Barc: complete sidebar group operations, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Complete split operation transitions", .serialized)
@MainActor
struct SplitOperationTransitionTests {
    enum Operation: String, CaseIterable { case close, closeAll, closeOthers, duplicate, moveSameProfile, moveOtherProfile }

    @Test("A compact row never unfolds or arrives a pane at a time", arguments:Operation.allCases)
    func wholeRow(operation:Operation) throws {
        let session = TestSession.make().0, source = session.activeSpace
        let pages = (0..<4).map { session.newTab(url:URL(string:"https://unit-transition.invalid/\($0)")!) }
        session.splitTabs(pages,grid:.grid);session.selectTab(pages[2])
        let keep = session.newTab(url:URL(string:"https://unit-transition.invalid/keep")!)
        session.selectTab(pages[2])
        let target = session.addSpace(named:"Target",profile:operation == .moveSameProfile ? source.profile : nil)
        session.selectSpace(source)
        let sidebar = SidebarViewController(session:session)
        let root = UITestSupport.host(sidebar.view,width:228,height:760)
        let table = sidebar.tabListTableView
        #expect(table.numberOfRows == 3)
        var snapshots: [[String:Int]] = []
        let urls = Set(pages.map(\.url))
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .tabs,.structure,.spaces: layout = 1; case .activeTab: layout = 0; default: return }
            root.layoutSubtreeIfNeeded()
            snapshots.append(["rows":table.numberOfRows,"sourcePages":source.tabs.filter { urls.contains($0.url) }.count,
                "sourceGroups":source.splits.layouts.count,"targetPages":target.tabs.filter { urls.contains($0.url) }.count,
                "targetGroups":target.splits.layouts.count,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        switch operation {
        case .close: session.closeTabs(pages)
        case .closeAll: session.closeAllTabs(in:source)
        case .closeOthers: session.closeOtherTabs(than:keep)
        case .duplicate: #expect(session.duplicateTabs(pages).count == 4)
        case .moveSameProfile,.moveOtherProfile: session.moveTabs(pages,toSpace:target)
        }
        let sourcePages = operation == .duplicate ? 8 : 0
        let sourceGroups = operation == .duplicate ? 2 : 0
        let targetPages = operation == .moveSameProfile || operation == .moveOtherProfile ? 4 : 0
        #expect(snapshots.allSatisfy { $0["sourcePages"] == sourcePages && $0["sourceGroups"] == sourceGroups
            && $0["targetPages"] == targetPages && $0["targetGroups"] == (targetPages == 4 ? 1 : 0) })
        let finalRows = operation == .duplicate ? 4 : operation == .closeAll ? 1 : 2
        #expect(table.numberOfRows == finalRows)
        #expect(snapshots.allSatisfy { $0["rows"]! <= max(3,finalRows) })
        #expect(snapshots.filter { $0["layoutUpdate"] == 1 }.count == 1)
        if let directory = ProcessInfo.processInfo.environment["BARC_OPERATION_TRANSITION_DIR"] {
            let output = URL(fileURLWithPath:directory).appending(path:operation.rawValue+".json")
            try JSONSerialization.data(withJSONObject:snapshots,options:[.prettyPrinted,.sortedKeys]).write(to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        }
    }

    @Test("A mixed-Space close keeps each public history separate and records no private page")
    func mixedOwnersHistory() {
        let session = TestSession.make().0, first = session.activeSpace
        let a = (0..<2).map { session.newTab(url:URL(string:"https://first-owner.invalid/\($0)")!) }
        let second = session.addSpace(named:"Second")
        let b = (0..<2).map { session.newTab(url:URL(string:"https://second-owner.invalid/\($0)")!) }
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let privatePages = (0..<2).map { session.newTab(url:URL(string:"https://private-owner.invalid/\($0)")!) }
        session.selectSpace(first)
        session.closeTabs(a+privatePages+b)
        #expect(session.closedWindows.count == 2)
        #expect(session.closedWindows.allSatisfy { record in
            record.spaceID != secret.id && record.tabs.allSatisfy { page in
                page.url.host() == (record.spaceID == first.id ? "first-owner.invalid" : "second-owner.invalid")
            }
        })
        #expect(session.closedTabs.allSatisfy { $0.spaceID != secret.id })
        #expect(Set(session.closedWindows.map(\.spaceID)) == Set([first.id,second.id]))
    }
}
