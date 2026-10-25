// Modified for Barc: Space pins treat a compact split as one complete row, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Whole split Space pins", .serialized)
@MainActor
struct SplitSidebarPinTests {
    private func pages(_ session:BrowserSession) -> [Tab] {
        (0..<4).map { index in
            let tab = session.newTab(url:URL(string:"https://unit-pin.invalid/\(index)")!)
            session.rename(tab,to:"Pane \(index)")
            return tab
        }
    }

    @Test("Pin and unpin move the complete row, retain layout and publish completed states",
          arguments:[SplitLayout.Grid.sideBySide,.stacked,.grid])
    func wholeRow(grid:SplitLayout.Grid) throws {
        let session = TestSession.make().0, owner = session.activeSpace
        let tabs = pages(session)
        session.splitTabs(tabs,grid:grid)
        session.selectTab(tabs[2]);session.toggleStickPane(tabs[0].id)
        let original = owner.splits
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        let table = sidebar.tabListTableView
        var samples:[[String:Int]] = []
        let token = session.changes.sink { change in
            let layout:Int
            switch change { case .spaces,.structure,.tabs:layout = 1;case .tab:layout = 0;default:return }
            samples.append(["retained":tabs.filter(\.isSidebarRetained).count,
                "savedURLs":tabs.filter { $0.pinnedPageURL != nil }.count,"layoutUpdate":layout])
        }
        defer { token.cancel() }
        var trace:[String:[[String:Int]]] = [:]
        for retained in [true,false] {
            samples.removeAll()
            session.setSidebarPin(retained,for:tabs[2])
            host.layoutSubtreeIfNeeded()
            let count = retained ? 4:0
            #expect(samples.allSatisfy { $0["retained"] == count && $0["savedURLs"] == count })
            #expect(samples.filter { $0["layoutUpdate"] == 1 }.count == 1)
            #expect(tabs.allSatisfy { $0.isSidebarRetained == retained && $0.groupID == nil })
            #expect(owner.splits == original && session.activeTab === tabs[2])
            #expect(owner.pinnedSites.isEmpty && owner.profile.favoriteTabs.isEmpty)
            #expect(table.numberOfRows == 2)
            #expect((table.view(atColumn:0,row:0,makeIfNecessary:true) is SplitRowView) == retained)
            trace[retained ? "pin":"unpin"] = samples
        }
        if let directory = ProcessInfo.processInfo.environment["BARC_UNIT_PIN_CAPTURE_DIR"] {
            let file = URL(fileURLWithPath:directory).appending(path:"\(grid).json")
            try JSONSerialization.data(withJSONObject:trace,options:[.prettyPrinted,.sortedKeys]).write(to:file)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
    }

    @Test("Removing one folder pin returns the complete split to Today without deleting its folder")
    func folderRemoval() {
        let session = TestSession.make().0, owner = session.activeSpace
        let tabs = pages(session)
        let folder = session.createGroup(named:"Research",containing:tabs)
        session.splitTabs(tabs,grid:.grid);session.selectTab(tabs[1])
        let original = owner.splits
        session.removeSidebarPin(tabs[2],in:owner)
        #expect(tabs.allSatisfy { !$0.isSidebarRetained && $0.groupID == nil && $0.pinnedPageURL == nil })
        #expect(owner.group(withID:folder.id) === folder && owner.tabs(in:folder).isEmpty)
        #expect(owner.splits == original && session.activeTab === tabs[1])
    }

    @Test("A split pin keeps its owner and survives reopening with all saved page URLs")
    func ownerAndReopen() throws {
        let (session,store) = TestSession.make(), owner = session.activeSpace
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let tabs = pages(session)
        session.splitTabs(tabs,grid:.grid);session.selectTab(tabs[2])
        let original = owner.splits
        let other = session.addSpace(named:"Other")
        let otherBefore = other.tabs.map { $0.snapshot() }
        session.setSidebarPin(true,for:tabs[1])
        #expect(session.activeSpace === owner && session.activeTab === tabs[2] && owner.splits == original)
        #expect(other.tabs.map { $0.snapshot() } == otherBefore)
        #expect(tabs.allSatisfy { $0.pinnedPageURL == $0.url && $0.keepsInSidebar })
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"unit-pin.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restored = try #require(reopened.spaces.first { $0.id == owner.id })
        let panes = restored.tabs.filter { $0.url.host() == "unit-pin.invalid" }
        #expect(panes.count == 4 && panes.allSatisfy { $0.pinnedPageURL == $0.url && $0.keepsInSidebar })
        #expect(restored.splits.layouts.first?.paneCount == 4 && restored.activeTab?.customName == "Pane 2")
        #expect(restored.pinnedSites.isEmpty)
    }

    @Test("One protected or Favorite member refuses a partial Space-pin change")
    func protectedMembers() {
        let session = TestSession.make().0
        let tabs = pages(session)
        session.splitTabs(tabs,grid:.grid)
        tabs[0].setLocked(true)
        let locked = session.snapshot()
        #expect(!session.canChangeSidebarPin(tabs[2]))
        session.setSidebarPin(true,for:tabs[2])
        #expect(session.snapshot() == locked)
        tabs[0].setLocked(false)
        session.pin(tabs[0])
        let favorite = session.snapshot()
        #expect(!session.canChangeSidebarPin(tabs[2]))
        session.setSidebarPin(true,for:tabs[2])
        #expect(session.snapshot() == favorite)
    }

    @Test("An older partially pinned split is repaired even when its anchor already has the requested state")
    func partialState() {
        let session = TestSession.make().0, owner = session.activeSpace
        let tabs = pages(session)
        session.splitTabs(tabs,grid:.grid)
        tabs[2].setKeepsInSidebar(true)
        let original = owner.splits
        session.setSidebarPin(true,for:tabs[2])
        #expect(tabs.allSatisfy { $0.keepsInSidebar && $0.pinnedPageURL == $0.url })
        #expect(owner.splits == original)
        session.setSidebarPin(false,for:tabs[0])
        #expect(tabs.allSatisfy { !$0.isSidebarRetained && $0.pinnedPageURL == nil })
        #expect(owner.splits == original)
    }

    @Test("The browser's Space-pin shortcut keeps all rendered panes and their focused page")
    func shortcut() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let tabs = pages(session)
        session.splitTabs(tabs,grid:.grid);session.selectTab(tabs[2])
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let original = session.activeSpace.splits
        let item = NSMenuItem(title:"Pin Tab",action:#selector(BrowserWindowController.togglePinActiveTab(_:)),keyEquivalent:"d")
        for retained in [true,false] {
            #expect(controller.validateMenuItem(item))
            controller.togglePinActiveTab(nil)
            let root = try #require(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            let panes = UITestSupport.descendants(of:root).compactMap { $0 as? SplitPaneView }
            #expect(panes.count == 4 && panes.filter(\.isFocused).count == 1)
            #expect(tabs.allSatisfy { $0.isSidebarRetained == retained })
            #expect(session.activeTab === tabs[2] && session.activeSpace.splits == original)
            #expect(session.visibleTabIDs == Set(tabs.map(\.id)))
            #expect(controller.validateMenuItem(item) && item.title == (retained ? "Unpin Tab":"Pin Tab"))
        }
    }
}
