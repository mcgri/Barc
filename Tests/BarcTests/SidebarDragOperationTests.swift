// Modified for Barc: sidebar copy gestures and stable drag identity, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@MainActor
private final class SidebarDragInfoFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation
    var draggingLocation: NSPoint = .zero
    var draggingDestinationWindow: NSWindow?
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, operations: NSDragOperation) {
        draggingPasteboard = board; draggingSourceOperationMask = operations
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Suite("Sidebar drag operations", .serialized)
@MainActor
struct SidebarDragOperationTests {
    private func page(_ name:String, in session:BrowserSession) -> Tab {
        let page = TestSession.appendTab(in:session,url:URL(string:"https://sidebar-drag.invalid/\(name)")!)
        session.rename(page,to:name)
        return page
    }
    private func sidebar(_ session:BrowserSession) -> SidebarViewController {
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        return sidebar
    }
    private func row(_ name:String, in sidebar:SidebarViewController) throws -> Int {
        let table = sidebar.tabListTableView
        return try #require((0..<table.numberOfRows).first { index in
            guard let cell = table.view(atColumn:0,row:index,makeIfNecessary:true) else { return false }
            return UITestSupport.textFields(in:cell).contains { $0.stringValue == name }
        })
    }
    private func board(for row:Int, in sidebar:SidebarViewController) throws -> NSPasteboard {
        try board(for:[row],in:sidebar)
    }
    private func board(for rows:[Int], in sidebar:SidebarViewController) throws -> NSPasteboard {
        let writers = try rows.map { row in try #require(sidebar.tableView(sidebar.tabListTableView,pasteboardWriterForRow:row)) }
        let board = NSPasteboard(name:.init("barc.sidebar-drag-test.\(UUID())"))
        #expect(board.writeObjects(writers))
        return board
    }

    private func point(in row:Int, of sidebar:SidebarViewController, member:Int? = nil, left:Bool) throws -> NSPoint {
        let cell = try #require(sidebar.tabListTableView.view(atColumn:0,row:row,makeIfNecessary:true))
        cell.layoutSubtreeIfNeeded()
        let rect: NSRect
        if let split = cell as? SplitRowView, let member {
            rect = split.members[member].frame
        } else {
            rect = try #require((cell as? TabRowView)?.pillRect)
        }
        return cell.convert(NSPoint(x:rect.minX+rect.width*(left ? 0.25 : 0.75),y:rect.midY),to:nil)
    }

    @Test("Reordering during a drag still moves the page identified by its stable ID")
    func stableIdentity() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session), c = page("C",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("B",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        session.moveTab(from:try #require(session.activeSpace.index(of:b)),to:0)
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [a.id,c.id,b.id])
    }

    @Test("A stale modern ID never falls back to a still-valid old array index")
    func staleIdentity() throws {
        let session = TestSession.make().0
        _ = page("A",in:session); _ = page("B",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = NSPasteboard(name:.init("barc.sidebar-stale-test.\(UUID())")); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(UUID().uuidString,forType:SidebarTabDrag.type)
        item.setString("0",forType:.init("io.github.mcgri.Barc.tabRow"))
        board.writeObjects([item])
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        let before = session.snapshot()
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above).isEmpty)
        #expect(!sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.snapshot() == before)
    }

    @Test("A copy-only source duplicates above a tab instead of splitting or moving the original")
    func copyPage() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session), target = page("Target",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("A",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .copy)
        #expect((table as? SidebarTableView)?.splitDropPreviewRect == nil)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        let copy = try #require(session.activeSpace.sidebarVisibleTabs.first { $0.url == a.url && $0 !== a })
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [a.id,b.id,copy.id,target.id])
        #expect(session.activeSpace.splits.layouts.isEmpty)
    }

    @Test("Copy-dragging a split duplicates the complete unit with its focused pane and geometry")
    func copySplit() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session)
        let gap = page("Gap",in:session), target = page("Target",in:session)
        session.splitTabs([a,b],grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.7,0.3]))
        session.selectTab(b)
        let original = try #require(session.activeSplit)
        let originalID = session.activeSpace.splits.identifier(containing:a.id)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:table.selectedRow,in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .copy)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        let copies = session.activeSpace.sidebarVisibleTabs.filter { $0 !== a && $0 !== b && $0 !== gap && $0 !== target }
        #expect(copies.count == 2)
        #expect(session.activeSpace.splits.layout(containing:a.id) == original)
        #expect(session.activeSpace.splits.identifier(containing:a.id) == originalID)
        let copied = try #require(copies.first.flatMap { session.activeSpace.splits.layout(containing:$0.id) })
        #expect(copied.tabIDs == copies.map(\.id))
        #expect(copied.unitFrames()[copies[0].id] == original.unitFrames()[a.id])
        #expect(session.activeTab === copies[1])
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [a.id,b.id,gap.id,copies[0].id,copies[1].id,target.id])
    }

    @Test("Unsupported source operations refuse the drop without changing the session", arguments:[NSDragOperation(),.link])
    func unsupportedOperations(operations:NSDragOperation) throws {
        let session = TestSession.make().0
        _ = page("A",in:session); _ = page("B",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("A",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:operations)
        let before = session.snapshot()
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above).isEmpty)
        #expect(!sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.snapshot() == before)
    }

    @Test("Copying multiple selected rows preserves their order and leaves every original in place")
    func copyMultipleRows() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session), target = page("Target",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:[row("A",in:sidebar),row("B",in:sidebar)],in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above) == .copy)
        #expect(sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        let copied = session.activeSpace.sidebarVisibleTabs.filter { $0 !== a && $0 !== b && $0 !== target }
        #expect(copied.map(\.url) == [a.url,b.url])
        #expect(session.activeSpace.sidebarVisibleTabs.prefix(3).map(\.id) == [a.id,b.id,target.id])
        #expect(session.activeSpace.sidebarVisibleTabs.suffix(2).map(\.id) == copied.map(\.id))
    }

    @Test("An ordinary multi-row drag moves the complete selection in its existing order")
    func moveMultipleRows() throws {
        let session = TestSession.make().0
        let pages = ["A","B","C","D"].map { page($0,in:session) }
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:[row("A",in:sidebar),row("C",in:sidebar)],in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:[.copy,.move])
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [pages[1].id,pages[3].id,pages[0].id,pages[2].id])
    }

    @Test("A closed page cannot copy the page that later occupies its old array index")
    func closedPageIdentity() throws {
        let session = TestSession.make().0
        _ = page("A",in:session); let b = page("B",in:session); _ = page("C",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("B",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        session.closeTab(b)
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        let before = session.snapshot()
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above).isEmpty)
        #expect(!sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.snapshot() == before)
    }

    @Test("One stale page in a multi-row payload rejects the entire drop before any copy is created")
    func partiallyStaleSelection() throws {
        let session = TestSession.make().0
        _ = page("A",in:session); _ = page("B",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let valid = try #require(sidebar.tableView(table,pasteboardWriterForRow:row("A",in:sidebar)))
        let invalid = NSPasteboardItem(); invalid.setString("not-a-uuid",forType:SidebarTabDrag.type)
        let board = NSPasteboard(name:.init("barc.sidebar-multi-stale.\(UUID())")); defer { board.releaseGlobally() }
        board.writeObjects([valid,invalid])
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        let before = session.snapshot()
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above).isEmpty)
        #expect(!sidebar.tableView(table,acceptDrop:info,row:table.numberOfRows,dropOperation:.above))
        #expect(session.snapshot() == before)
    }

    @Test("A split can be copy-dragged above itself without altering the original group")
    func copyAboveOriginalUnit() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session)
        session.splitTabs([a,b]); session.selectTab(b)
        let original = try #require(session.activeSplit)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let targetRow = table.selectedRow
        let board = try board(for:targetRow,in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .copy)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        #expect(session.activeSpace.splits.layout(containing:a.id) == original)
        #expect(session.activeSpace.splits.layouts.count == 2)
        let visible = session.activeSpace.sidebarVisibleTabs
        #expect(visible.suffix(2).map(\.id) == [a.id,b.id])
        #expect(visible.prefix(2).map(\.url) == [a.url,b.url])
    }

    @Test("Invalid copy destinations are refused without creating partial duplicate pages")
    func invalidCopyDestination() {
        let session = TestSession.make().0
        let a = page("A",in:session)
        let before = session.snapshot()
        #expect(!session.duplicateSidebarTabs([a],to:0,group:TabGroup(name:"Foreign"),before:nil,retained:false))
        #expect(session.snapshot() == before)
    }

    @Test("A normal drag onto another tab still creates a split rather than copying it")
    func ordinarySplitDrop() throws {
        let session = TestSession.make().0
        let a = page("A",in:session), target = page("Target",in:session)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("A",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:[.copy,.move])
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:false)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        #expect(session.activeSpace.splits.layout(containing:a.id)?.tabIDs == [target.id,a.id])
        #expect(session.activeSpace.sidebarVisibleTabs.count == 2)
    }

    @Test("An explicit sidebar URL drop stays in its destination profile despite domain routing", arguments:[false,true],[false,true])
    func placedURLBypassesRouting(split:Bool, left:Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path:"barc-dropped-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let routing = SpaceRoutingService(store:SpaceRoutingStore(fileURL:root.appending(path:"routing.json")))
        let defaults = UserDefaults(suiteName:"barc.dropped-link.\(UUID())")!
        let session = BrowserSession(database:nil,sessionStore:SessionStore(fileURL:root.appending(path:"session.json")),
                                     settings:Settings(defaults:defaults),routing:routing)
        let destination = session.activeSpace
        let target = page("Target",in:session)
        let unrelated = page("Unrelated",in:session)
        let routed = session.addSpace(named:"Routed")
        let routedBefore = routed.tabs.map(\.id)
        session.selectSpace(destination)
        routing.add(SpaceRoute(reference:"explicit-drop.invalid",match:.contains,destination:.space(routed.id)))
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = NSPasteboard(name:.init("barc.sidebar-url-test.\(UUID())")); defer { board.releaseGlobally() }
        let url = URL(string:"https://explicit-drop.invalid/page")!
        #expect(board.writeObjects([url as NSURL]))
        let info = SidebarDragInfoFixture(board:board,operations:.copy)
        let targetRow = try row("Target",in:sidebar)
        let operation: NSTableView.DropOperation = split ? .on : .above
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:left)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:operation) == .copy)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:operation))
        let inserted = try #require(destination.tabs.first { $0.url == url })
        #expect(inserted.identity == destination.identity)
        #expect(routed.tabs.map(\.id) == routedBefore)
        #expect(session.activeSpace === destination)
        if split {
            let expected = left ? [inserted.id,target.id] : [target.id,inserted.id]
            #expect(destination.splits.layout(containing:target.id)?.tabIDs == expected)
            #expect(destination.sidebarVisibleTabs.map(\.id) == expected+[unrelated.id])
        } else {
            #expect(destination.splits.layouts.isEmpty)
            #expect(destination.sidebarVisibleTabs.map(\.id) == [inserted.id,target.id,unrelated.id])
            #expect(session.activeTab === unrelated)
        }
    }

    @Test("A folder accepts copies of its own pages and a mixed selection whose first page is already inside", arguments:[false,true])
    func folderSelectionDrop(copy:Bool) throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session)
        let folder = session.createGroup(named:"Folder",containing:[a])
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:[row("A",in:sidebar),row("B",in:sidebar)],in:sidebar); defer { board.releaseGlobally() }
        let folderRow = try row("Folder",in:sidebar)
        let header = try #require(table.view(atColumn:0,row:folderRow,makeIfNecessary:true))
        let info = SidebarDragInfoFixture(board:board,operations:copy ? .copy : .move)
        info.draggingLocation = header.convert(NSPoint(x:header.bounds.midX,y:header.bounds.midY),to:nil)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:folderRow,proposedDropOperation:.on) == (copy ? .copy : .move))
        #expect(sidebar.tableView(table,acceptDrop:info,row:folderRow,dropOperation:.on))
        if copy {
            let copies = session.activeSpace.tabs.filter { $0 !== a && $0 !== b && !$0.isSidebarPlaceholder }
            #expect(copies.map(\.url) == [a.url,b.url])
            #expect(copies.allSatisfy { $0.groupID == folder.id })
            #expect(a.groupID == folder.id)
            #expect(b.groupID == nil)
        } else {
            #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [a.id,b.id])
            #expect(a.groupID == folder.id && b.groupID == folder.id)
        }
    }

    @Test("The pointer's left or right half determines the order of a new sidebar split", arguments:[false,true])
    func splitSide(left:Bool) throws {
        let session = TestSession.make().0
        let incoming = page("Incoming",in:session), prefix = page("Prefix",in:session)
        let target = page("Target",in:session), tail = page("Tail",in:session)
        target.setKeepsInSidebar(true)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let board = try board(for:row("Incoming",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:left)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .move)
        let preview = try #require((table as? SidebarTableView)?.splitDropPreviewRect)
        let cell = try #require(table.view(atColumn:0,row:targetRow,makeIfNecessary:true) as? TabRowView)
        let pill = cell.convert(cell.pillRect,to:table)
        #expect(abs(preview.width-(pill.width/2-2)) < 0.01)
        #expect(abs(preview.minX-(left ? pill.minX+1 : pill.midX+1)) < 0.01)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        #expect((table as? SidebarTableView)?.splitDropPreviewRect == nil)
        let expected = left ? [incoming.id,target.id] : [target.id,incoming.id]
        #expect(session.activeSpace.splits.layout(containing:target.id)?.tabIDs == expected)
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [prefix.id]+expected+[tail.id])
        #expect(SidebarOrder.items(groups:[],tabs:session.activeSpace.sidebarVisibleTabs,parentID:nil).map(\.id) == expected+[prefix.id,tail.id])
        #expect(incoming.keepsInSidebar && target.keepsInSidebar)
        session.unsplit()
        #expect(session.activeSpace.sidebarVisibleTabs.map(\.id) == [prefix.id]+expected+[tail.id])
    }

    @Test("A drop on a compact split member lands beside that pane, retaining the group identity", arguments:[false,true])
    func splitMemberSide(left:Bool) throws {
        let session = TestSession.make().0
        let a = page("A",in:session), b = page("B",in:session), incoming = page("Incoming",in:session)
        session.splitTabs([a,b],grid:.stacked)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.7,0.3]))
        session.selectTab(b)
        let groupID = session.activeSpace.splits.identifier(containing:a.id)
        let sidebar = sidebar(session), table = sidebar.tabListTableView
        let targetRow = table.selectedRow
        let board = try board(for:row("Incoming",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        info.draggingLocation = try point(in:targetRow,of:sidebar,member:1,left:left)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        let layout = try #require(session.activeSpace.splits.layout(containing:b.id))
        #expect(layout.tabIDs == (left ? [a.id,incoming.id,b.id] : [a.id,b.id,incoming.id]))
        #expect(session.activeSpace.splits.identifier(containing:b.id) == groupID)
        #expect(session.activeTab === b)
        #expect(layout.unitFrames()[a.id] == CGRect(x:0,y:0,width:1,height:0.7))
        let bFrame = try #require(layout.unitFrames()[b.id])
        #expect(abs(bFrame.width-0.5) < 0.000001)
        #expect(abs(bFrame.minX-(left ? 0.5 : 0)) < 0.000001)
    }

    @Test("The split preview disappears on exit, ordinary insertion, invalid payloads and Space changes")
    func previewCleanup() throws {
        let session = TestSession.make().0
        _ = page("Incoming",in:session); _ = page("Target",in:session)
        let sidebar = sidebar(session), table = try #require(sidebar.tabListTableView as? SidebarTableView)
        let board = try board(for:row("Incoming",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:true)
        func preview() {
            #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .move)
            #expect(table.splitDropPreviewRect != nil)
        }
        preview(); table.draggingExited(nil)
        #expect(table.splitDropPreviewRect == nil)
        preview()
        _ = sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.above)
        #expect(table.splitDropPreviewRect == nil)
        preview(); info.draggingSourceOperationMask = []
        #expect(!sidebar.tableView(table,acceptDrop:info,row:targetRow,dropOperation:.on))
        #expect(table.splitDropPreviewRect == nil)
        info.draggingSourceOperationMask = .move
        preview(); _ = session.addSpace(named:"Other")
        #expect(table.splitDropPreviewRect == nil)
    }

    @Test("Owned light and dark sidebar renders show the preview in the chosen half", arguments:[false,true],[false,true])
    func renderSplitPreview(dark:Bool, left:Bool) throws {
        let session = TestSession.make().0
        _ = page("Incoming",in:session); _ = page("Target",in:session)
        session.activeSpace.look.appearance = dark ? .dark : .light
        let sidebar = sidebar(session), table = try #require(sidebar.tabListTableView as? SidebarTableView)
        table.backgroundColor = session.activeSpace.color.blended(withFraction:0.78,of:dark ? .black : .white)!
        let targetRow = try row("Target",in:sidebar)
        let board = try board(for:row("Incoming",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:left)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:targetRow,proposedDropOperation:.on) == .move)
        let preview = try #require(table.splitDropPreviewRect)
        let region = table.rect(ofRow:targetRow).insetBy(dx:0,dy:-4)
        #expect(region.contains(preview))
        let bitmap = try #require(table.bitmapImageRepForCachingDisplay(in:region))
        table.cacheDisplay(in:region,to:bitmap)
        if let directory = ProcessInfo.processInfo.environment["BARC_SPLIT_DROP_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath:directory).appending(path:"split-drop205-\(dark ? "dark" : "light")-\(left ? "left" : "right").png")
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        }
    }

    @Test("AppKit's table drag tracking updates the chosen half while the pointer remains on one row")
    func tableTracksSameRow() throws {
        let session = TestSession.make().0
        _ = page("Incoming",in:session); _ = page("Target",in:session)
        let sidebar = sidebar(session), table = try #require(sidebar.tabListTableView as? SidebarTableView)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:760),styleMask:[.borderless],backing:.buffered,defer:true)
        window.contentView = sidebar.view
        sidebar.view.layoutSubtreeIfNeeded()
        let board = try board(for:row("Incoming",in:sidebar),in:sidebar); defer { board.releaseGlobally() }
        let targetRow = try row("Target",in:sidebar)
        let info = SidebarDragInfoFixture(board:board,operations:.move)
        info.draggingDestinationWindow = window
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:true)
        #expect(table.draggingEntered(info) == .move)
        let left = try #require(table.splitDropPreviewRect)
        info.draggingLocation = try point(in:targetRow,of:sidebar,left:false)
        #expect(table.draggingUpdated(info) == .move)
        let right = try #require(table.splitDropPreviewRect)
        #expect(right.minX > left.minX && right.size == left.size)
        info.draggingSourceOperationMask = .copy
        #expect(table.draggingUpdated(info) == .copy)
        #expect(table.splitDropPreviewRect == nil)
        info.draggingSourceOperationMask = .move
        #expect(table.draggingUpdated(info) == .move)
        #expect(table.splitDropPreviewRect == right)
        table.draggingExited(info)
        #expect(table.splitDropPreviewRect == nil)
        window.contentView = nil
    }
}
