// Modified for Barc: complete folder/Space conversions preserve compact split rows, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Folder and Space conversion transitions", .serialized)
@MainActor
struct SpaceFolderTransitionTests {
    @Test("Promoting a folder reveals only the finished Space, with its split and chosen page")
    func promotion() throws {
        let session = TestSession.make().0, source = session.activeSpace
        let pages = (0..<4).map { session.newTab(url:URL(string:"https://promotion-transition.invalid/\($0)")!) }
        let folder = session.createGroup(named:"Project",containing:pages)
        let child = session.createGroup(named:"References",parent:folder)
        for page in pages { session.move(page,to:child) }
        folder.isCollapsed = false;child.isCollapsed = false
        session.splitTabs(pages,grid:.grid);session.selectTab(pages[2])
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            switch change { case .tabs,.spaces,.structure,.activeTab: break;default:return }
            host.layoutSubtreeIfNeeded()
            let target = session.spaces.last!
            samples.append(["activeTarget":session.activeSpace === target ? 1:0,
                "rootRemoved":target.group(withID:folder.id) == nil ? 1:0,
                "childRoot":child.parentID == nil ? 1:0,"pages":target.workspaceTabs.count,
                "splits":target.splits.layouts.count,"selected":target.activeTab === pages[2] ? 1:0,
                "layoutUpdate":isLayout(change) ? 1:0])
        }
        defer { token.cancel() }
        let target = try #require(session.turnFolderIntoSpace(folder))
        #expect(samples.allSatisfy { $0["activeTarget"] == 1 && $0["rootRemoved"] == 1 && $0["childRoot"] == 1
            && $0["pages"] == 4 && $0["splits"] == 1 && $0["selected"] == 1 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(sidebar.tabListTableView.numberOfRows == 3)
        #expect(target.profile === source.profile && source.groups.isEmpty)
        try save(samples,name:"promotion")
    }

    @Test("Copying a Space into a folder keeps split geometry, focus and sticky panes through reopening",
          arguments:[SplitLayout.Grid.sideBySide,.stacked,.grid])
    func export(grid:SplitLayout.Grid) throws {
        let (session,store) = TestSession.make(), source = session.activeSpace
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let pages = (0..<4).map { i in
            let page = session.newTab(url:URL(string:"https://export-transition.invalid/same")!)
            session.rename(page,to:"Page \(i)");return page
        }
        let folder = session.createGroup(named:"References",containing:pages)
        folder.isCollapsed = false
        session.splitTabs(pages,grid:grid)
        let layout = try #require(session.activeSplit)
        session.updateSplitLayout(layout.settingShares(at:[],to:grid == .grid ? [0.65,0.35]:[0.1,0.2,0.3,0.4]))
        session.selectTab(pages[2]);session.toggleStickPane(pages[0].id)
        let originalSplits = source.splits, before = source.tabs.map { $0.snapshot() }
        let target = session.addSpace(named:"Destination")
        let selected = target.activeTab
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            switch change { case .tabs,.spaces,.structure,.activeTab:break;default:return }
            host.layoutSubtreeIfNeeded()
            samples.append(["pages":target.workspaceTabs.filter { $0.url.host() == "export-transition.invalid" }.count,
                "groups":target.groups.count,"splits":target.splits.layouts.count,
                "layoutUpdate":isLayout(change) ? 1:0])
        }
        defer { token.cancel() }
        let root = try #require(try session.exportSpace(source,intoFolderIn:target))
        let copies = FolderContents.tabs(in:root,space:target)
        #expect(copies.count == 4 && copies.map(\.customName) == pages.map(\.customName))
        #expect(samples.allSatisfy { $0["pages"] == 4 && $0["groups"] == 2 && $0["splits"] == 1 })
        #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
        #expect(sidebar.tabListTableView.numberOfRows == 4)
        #expect(source.splits == originalSplits && source.tabs.map { $0.snapshot() } == before)
        #expect(target.activeTab === selected && copies.allSatisfy { $0.identity == target.identity && !$0.isLoaded })
        try save(samples,name:"export-\(grid)")
        let copied = try #require(target.splits.layout(containing:copies[0].id))
        let original = try #require(originalSplits.layouts.first)
        for (a,b) in zip(pages,copies) { #expect(original.unitFrames()[a.id] == copied.unitFrames()[b.id]) }
        #expect(target.splits.preferredTab(containing:copies[0].id) == copies[2].id)
        #expect(target.splits.stickyTabIDs == [copies[0].id])
        try store.save(session.snapshot())
        let settings = Settings(defaults:UserDefaults(suiteName:"space-transition.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restored = try #require(reopened.spaces.first { $0.id == target.id })
        let restoredRoot = try #require(restored.group(withID:root.id))
        let restoredPages = FolderContents.tabs(in:restoredRoot,space:restored)
        let restoredLayout = try #require(restored.splits.layout(containing:restoredPages[0].id))
        let bindings = Dictionary(uniqueKeysWithValues:zip(copies.map(\.id),restoredPages.map(\.id)))
        #expect(copied.mappingTabs { bindings[$0] } == restoredLayout)
        #expect(restored.splits.identifier(containing:restoredPages[0].id) == target.splits.identifier(containing:copies[0].id))
        #expect(restored.splits.preferredTab(containing:restoredPages[0].id) == restoredPages[2].id)
        #expect(restored.splits.stickyTabIDs == [restoredPages[0].id])
    }

    @Test("Repeated exports preserve independent groups and exclude incomplete Favorite splits")
    func repeatedAndPartialGroups() throws {
        let session = TestSession.make().0, source = session.activeSpace
        let pages = (0..<2).map { session.newTab(url:URL(string:"https://export-boundary.invalid/\($0)")!) }
        session.splitTabs(pages,grid:.sideBySide)
        let lone = session.newTab(url:URL(string:"https://export-boundary.invalid/lone")!)
        let favorite = session.newTab(url:URL(string:"https://export-boundary.invalid/favorite")!)
        session.pin(favorite)
        let joined = source.splits.join([lone.id,favorite.id],grid:.stacked)
        #expect(joined)
        let original = source.splits
        let target = session.addSpace(named:"Target",profile:source.profile)
        let a = session.newTab(url:URL(string:"https://target-boundary.invalid/a")!)
        let b = session.newTab(url:URL(string:"https://target-boundary.invalid/b")!)
        session.splitTabs([a,b],grid:.stacked)
        let existing = target.splits.layout(containing:a.id)
        let first = try #require(try session.exportSpace(source,intoFolderIn:target))
        let second = try #require(try session.exportSpace(source,intoFolderIn:target))
        let firstPages = FolderContents.tabs(in:first,space:target)
        let secondPages = FolderContents.tabs(in:second,space:target)
        #expect(firstPages.count == 3 && secondPages.count == 3)
        #expect(target.splits.layouts.count == 3 && target.splits.layout(containing:a.id) == existing)
        #expect(target.activeTab === b && source.splits == original)
        let firstIDs = Set(firstPages.map(\.id)),secondIDs = Set(secondPages.map(\.id))
        #expect(firstIDs.isDisjoint(with:secondIDs))
        let firstMember = try #require(firstPages.first { $0.url == pages[0].url })
        let secondMember = try #require(secondPages.first { $0.url == pages[0].url })
        let firstLone = try #require(firstPages.first { $0.url == lone.url })
        let secondLone = try #require(secondPages.first { $0.url == lone.url })
        let firstSplit = try #require(target.splits.layout(containing:firstMember.id))
        let secondSplit = try #require(target.splits.layout(containing:secondMember.id))
        #expect(firstSplit.paneCount == 2 && secondSplit.paneCount == 2)
        #expect(target.splits.identifier(containing:firstMember.id) != target.splits.identifier(containing:secondMember.id))
        #expect(target.splits.layout(containing:firstLone.id) == nil && target.splits.layout(containing:secondLone.id) == nil)
        #expect(target.tabs.filter { $0 === favorite }.count == 1)
    }

    private func isLayout(_ change:BrowserSession.Change) -> Bool {
        switch change { case .tabs,.spaces,.structure:true;default:false }
    }

    private func save(_ samples:[[String:Int]],name:String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BARC_SPACE_TRANSITION_DIR"] else { return }
        let file = URL(fileURLWithPath:directory).appending(path:name+".json")
        try JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
