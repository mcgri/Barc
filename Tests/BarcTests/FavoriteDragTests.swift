// Modified for Barc: complete Favorite drag and profile-bound transfer verification, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@MainActor
private final class FavoriteDragInfo:NSObject,NSDraggingInfo {
    let draggingPasteboard:NSPasteboard
    var draggingSourceOperationMask:NSDragOperation
    var draggingLocation:NSPoint = .zero
    var draggingDestinationWindow:NSWindow?
    var draggingSource:Any? { nil }
    var draggingSequenceNumber:Int { 1 }
    var draggedImageLocation:NSPoint { .zero }
    nonisolated var draggedImage:NSImage? { nil }
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight:NSSpringLoadingHighlight { .none }
    init(_ board:NSPasteboard,_ mask:NSDragOperation) { draggingPasteboard = board;draggingSourceOperationMask = mask }
    func slideDraggedImage(to screenPoint:NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination destination:URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Suite("Favorite native drag and complete transfers", .serialized)
@MainActor
struct FavoriteDragTests {
    private func page(_ name:String,in session:BrowserSession) -> Tab {
        let page = session.newTab(url:URL(string:"https://favorite-drag.invalid/\(name)")!)
        session.rename(page,to:name);return page
    }
    private func favorite(_ session:BrowserSession) throws -> (Space,[Tab],PinnedSite) {
        let owner = session.activeSpace,a = page("A",in:session),b = page("B",in:session)
        session.splitTabs([a,b]);session.selectTab(b)
        _ = session.renameSplit(containing:a.id,in:owner,to:"Named pair")
        _ = session.setSplitIcon(.emoji("📚"),containing:a.id,in:owner)
        session.pin(a)
        return (owner,[a,b],try #require(owner.pinnedSites.first))
    }
    private func board(_ site:PinnedSite,in owner:Space) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName(),item = NSPasteboardItem()
        item.setString(site.id.uuidString,forType:SidebarTabDrag.favoriteType)
        item.setString(owner.id.uuidString,forType:SidebarTabDrag.ownerType)
        item.setString(site.url.absoluteString,forType:.URL)
        board.writeObjects([item]);return board
    }
    private func workspaceBoard(_ tabs:[Tab],in owner:Space) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.writeObjects(tabs.map { tab in
            let item = NSPasteboardItem();item.setString(tab.id.uuidString,forType:SidebarTabDrag.type)
            item.setString(owner.id.uuidString,forType:SidebarTabDrag.ownerType);return item
        });return board
    }
    private func sidebar(_ session:BrowserSession) -> SidebarViewController {
        let controller = SidebarViewController(session:session)
        _ = UITestSupport.host(controller.view,width:228,height:800);return controller
    }
    private func strip(_ sidebar:SidebarViewController) throws -> PinnedTilesView {
        try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? PinnedTilesView }.first)
    }
    private func row(_ title:String,in sidebar:SidebarViewController) throws -> Int {
        let table = sidebar.tabListTableView
        return try #require((0..<table.numberOfRows).first { index in
            table.view(atColumn:0,row:index,makeIfNecessary:true).map { cell in UITestSupport.textFields(in:cell).contains { $0.stringValue == title } } == true
        })
    }

    @Test("A shared Favorite moves as the same live pages into the chosen workspace and leaves every profile tile")
    func sharedMove() throws {
        let session = TestSession.make().0
        let (source,pages,site) = try favorite(session)
        let target = session.addSpace(named:"Destination",profile:source.profile)
        let expected = source.splits.layout(containing:pages[0].id)
        let moved = session.receiveFavorite(site.id,from:source,into:target,copy:false)
        #expect(moved.map(\.id) == pages.map(\.id) && moved.allSatisfy { $0.pinnedSiteID == nil && $0.pinnedMemberID == nil })
        #expect(source.pinnedSites.isEmpty && target.pinnedSites.isEmpty && source.profile.favoriteTabs.isEmpty)
        #expect(!source.tabs.contains { $0 === pages[0] } && target.workspaceTabs.contains { $0 === pages[0] })
        #expect(target.splits.layout(containing:pages[0].id) == expected)
        #expect(target.splits.name(containing:pages[0].id) == "Named pair" && target.splits.icon(containing:pages[0].id) == .emoji("📚"))
        #expect(target.splits.preferredTab(containing:pages[0].id) == pages[1].id && session.activeSpace === target)
    }

    @Test("Copying preserves the source Favorite and arrangement while creating an independent complete unit")
    func sharedCopy() throws {
        let session = TestSession.make().0
        let (source,pages,site) = try favorite(session)
        let before = source.splits
        let target = session.addSpace(named:"Destination",profile:source.profile)
        let copied = session.receiveFavorite(site.id,from:source,into:target,copy:true)
        #expect(copied.count == 2 && Set(copied.map(\.id)).isDisjoint(with:pages.map(\.id)))
        #expect(source.pinnedSites == [site] && source.splits == before && source.profile.favoriteTabs.count == 2)
        #expect(copied.allSatisfy { $0.pinnedSiteID == nil && $0.pinnedMemberID == nil && $0.identity == target.identity })
        #expect(target.splits.layout(containing:copied[0].id)?.tabIDs == copied.map(\.id))
        #expect(target.splits.preferredTab(containing:copied[0].id) == copied[1].id && target.splits.name(containing:copied[0].id) == "Named pair")
    }

    @Test("Divergent older Favorite records remain reachable when the canonical unit moves",arguments:[false,true])
    func legacyMembers(copy:Bool) throws {
        let session = TestSession.make().0
        let (source,pages,site) = try favorite(session)
        let extra = Tab(url:URL(string:"https://favorite-drag.invalid/legacy")!,identity:source.identity)
        extra.setPinnedSiteID(site.id);extra.setPinnedMemberID(UUID())
        _ = TabNameStore.shared.rename(extra.id,to:"Legacy page")
        source.insert(extra,at:0)
        #expect(extra.pinnedSiteID == nil && source.workspaceTabs.contains { $0 === extra })
        let target = session.addSpace(named:"Destination",profile:source.profile)
        let moved = session.receiveFavorite(site.id,from:source,into:target,copy:copy)
        #expect(moved.count == 2 && moved.allSatisfy { $0 !== extra })
        #expect(session.allTabs.contains { $0 === extra } && extra.customName == "Legacy page")
        if copy {
            #expect(source.profile.favoriteTabs.count == 2 && source.workspaceTabs.contains { $0 === extra })
            #expect(extra.pinnedSiteID == nil && source.pinnedSites == [site])
        } else {
            #expect(source.profile.favoriteTabs.isEmpty && source.workspaceTabs.contains { $0 === extra })
            #expect(extra.pinnedSiteID == nil && extra.pinnedMemberID == nil)
            #expect(pages.allSatisfy { page in target.workspaceTabs.contains { $0 === page } })
        }
    }

    @Test("An unopened Favorite split can cross profiles without carrying opaque page state",arguments:[false,true])
    func isolatedTransfer(copy:Bool) throws {
        let session = TestSession.make().0,source = session.activeSpace
        let a = page("SavedA",in:session),b = page("SavedB",in:session)
        session.splitTabs([a,b]);let layout = try #require(source.splits.layout(containing:a.id))
        let opaque = Data([1,2,3,4])
        let members = [a,b].map { page -> FavoriteSplit.Member in
            var saved = page.snapshot();saved.interactionState = opaque
            return .init(id:page.id,page:saved)
        }
        let saved = FavoriteSplit(id:UUID(),members:members,layout:layout,focusedMemberID:b.id,stickyMemberID:nil,customName:"Saved pair")
        let site = PinnedSite(url:a.url,title:"Saved pair",split:saved,icon:.symbol("book"));source.addPinnedSite(site)
        let before = source.splits
        let profile = try #require(session.addProfile(named:"Other profile"))
        let target = session.addSpace(named:"Other",profile:profile)
        let moved = session.receiveFavorite(site.id,from:source,into:target,copy:copy)
        #expect(moved.count == 2 && moved.allSatisfy { $0.identity == target.identity && $0.identity != source.identity && $0.snapshot().interactionState == nil })
        #expect(target.splits.name(containing:moved[0].id) == "Saved pair")
        if copy {
            #expect(source.pinnedSites == [site] && source.splits == before)
            #expect(source.profile.favoriteTabs.allSatisfy { $0.snapshot().interactionState == opaque })
        } else { #expect(source.pinnedSites.isEmpty && source.profile.favoriteTabs.isEmpty) }
    }

    @Test("An unopened single tile retains its name and icon when converted to a workspace page")
    func unopenedSingle() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let site = PinnedSite(url:URL(string:"https://favorite-drag.invalid/unopened")!,title:"My tool",icon:.emoji("🧰"));owner.addPinnedSite(site)
        let pages = session.receiveFavorite(site.id,from:owner,into:owner,copy:false)
        let page = try #require(pages.first)
        #expect(page.customName == "My tool" && page.sidebarIcon == .emoji("🧰") && page.currentWebView == nil)
        #expect(owner.pinnedSites.isEmpty && owner.workspaceTabs.contains { $0 === page })
    }

    @Test("Stale and protected Favorite moves are rejected before any profile or layout changes")
    func invalidMoves() throws {
        let session = TestSession.make().0
        let (source,pages,site) = try favorite(session)
        pages[0].setLocked(true)
        let before = source.splits,sites = source.pinnedSites,ids = source.tabs.map(\.id)
        #expect(session.receiveFavorite(site.id,from:source,into:source,copy:false).isEmpty)
        #expect(session.receiveFavorite(UUID(),from:source,into:source,copy:true).isEmpty)
        #expect(source.splits == before && source.pinnedSites == sites && source.tabs.map(\.id) == ids)
    }

    @Test("Native sidebar Favorite drops respect Pinned and Today placement",arguments:[false,true])
    func sidebarPlacement(retained:Bool) throws {
        let session = TestSession.make().0,source = session.activeSpace
        let site = PinnedSite(url:URL(string:"https://favorite-drag.invalid/tool")!,title:"Tool");source.addPinnedSite(site)
        _ = page("Existing",in:session)
        let sidebar = sidebar(session),table = sidebar.tabListTableView,board = board(site,in:source)
        defer { board.releaseGlobally() }
        let index = retained ? try row("New Tab",in:sidebar):table.numberOfRows
        let info = FavoriteDragInfo(board,.move)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:index,proposedDropOperation:.above) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:index,dropOperation:.above))
        let received = try #require(source.workspaceTabs.first { $0.customName == "Tool" })
        #expect(received.keepsInSidebar == retained && source.pinnedSites.isEmpty)
    }

    @Test("Copy-only native Favorite drops preserve the tile and return a complete unowned unit")
    func nativeCopy() throws {
        let session = TestSession.make().0
        let (owner,pages,site) = try favorite(session)
        let sidebar = sidebar(session),table = sidebar.tabListTableView,board = board(site,in:owner)
        defer { board.releaseGlobally() }
        let before = owner.splits.layout(containing:pages[0].id)
        let info = FavoriteDragInfo(board,.copy),index = table.numberOfRows
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:index,proposedDropOperation:.above) == .copy)
        #expect(sidebar.tableView(table,acceptDrop:info,row:index,dropOperation:.above))
        let copied = owner.workspaceTabs.filter { !$0.isSidebarPlaceholder }
        #expect(copied.count == 2 && copied.allSatisfy { $0.pinnedSiteID == nil && !$0.keepsInSidebar })
        #expect(owner.pinnedSites == [site] && owner.splits.layout(containing:pages[0].id) == before)
        #expect(owner.splits.name(containing:copied[0].id) == "Named pair")
    }

    @Test("Native strip accepts all selected rows as complete units and honors copy versus move",arguments:[false,true])
    func multiRowStrip(copy:Bool) throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let a = page("A",in:session),b = page("B",in:session),c = page("C",in:session)
        session.splitTabs([a,b]);_ = session.renameSplit(containing:a.id,in:owner,to:"Pair")
        let sidebar = sidebar(session),strip = try strip(sidebar),board = workspaceBoard([a,c],in:owner)
        defer { board.releaseGlobally() }
        let info = FavoriteDragInfo(board,copy ? .copy:.move)
        #expect(strip.draggingEntered(info) == (copy ? .copy:.move))
        #expect(strip.performDragOperation(info))
        #expect(owner.pinnedSites.count == 2 && owner.profile.favoriteTabs.count == 3)
        #expect(owner.pinnedSites.contains { $0.title == "Pair" && $0.split?.members.count == 2 })
        #expect([a,b,c].allSatisfy { original in owner.workspaceTabs.contains { $0 === original } } == copy)
    }

    @Test("A full Favorites strip refuses a multi-unit drop without moving a source page")
    func capacity() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        for index in 0..<11 { owner.addPinnedSite(.init(url:URL(string:"https://favorite-drag.invalid/pin\(index)")!,title:"Pin \(index)")) }
        let a = page("A",in:session),b = page("B",in:session)
        let before = owner.workspaceTabs.map(\.id)
        #expect(!session.favoriteSidebarTabs([a,b],from:owner,into:owner,copy:false,at:0))
        #expect(owner.workspaceTabs.map(\.id) == before && owner.pinnedSites.count == 11)
    }

    @Test("Native strip reordering moves the existing Favorite identity rather than creating another")
    func reorder() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let sites = (0..<3).map { PinnedSite(url:URL(string:"https://favorite-drag.invalid/tool\($0)")!,title:"Tool \($0)") }
        sites.forEach(owner.addPinnedSite)
        let sidebar = sidebar(session),strip = try strip(sidebar),board = board(sites[0],in:owner)
        defer { board.releaseGlobally() }
        strip.layoutSubtreeIfNeeded()
        let info = FavoriteDragInfo(board,.move);info.draggingLocation = strip.convert(NSPoint(x:10000,y:10000),to:nil)
        #expect(strip.draggingEntered(info) == .move && strip.performDragOperation(info))
        #expect(owner.pinnedSites.map(\.id) == [sites[1].id,sites[2].id,sites[0].id])
        #expect(owner.profile.favoriteTabs.isEmpty)
    }

    @Test("A Favorite files into a folder through the same native landing path as ordinary rows")
    func folderPlacement() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let site = PinnedSite(url:URL(string:"https://favorite-drag.invalid/filed")!,title:"Filed tool");owner.addPinnedSite(site)
        let existing = page("Existing",in:session),folder = try #require(session.createGroup(named:"Folder",containing:[existing]))
        let sidebar = sidebar(session),table = sidebar.tabListTableView,board = board(site,in:owner)
        defer { board.releaseGlobally() }
        let index = try row("Existing",in:sidebar),info = FavoriteDragInfo(board,.move)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:index,proposedDropOperation:.above) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:index,dropOperation:.above))
        #expect(owner.workspaceTabs.first { $0.customName == "Filed tool" }?.groupID == folder.id && owner.pinnedSites.isEmpty)
    }

    @Test("Dropping a Favorite unit onto a workspace tab combines every pane")
    func favoriteSplitLanding() throws {
        let session = TestSession.make().0
        let (owner,pages,site) = try favorite(session)
        let target = page("Target",in:session),sidebar = sidebar(session),table = sidebar.tabListTableView
        let index = try row("Target",in:sidebar)
        let cell = try #require(table.view(atColumn:0,row:index,makeIfNecessary:true) as? TabRowView)
        cell.layoutSubtreeIfNeeded();let rect = cell.pillRect
        let board = board(site,in:owner);defer { board.releaseGlobally() }
        let info = FavoriteDragInfo(board,.move);info.draggingLocation = cell.convert(NSPoint(x:rect.maxX-8,y:rect.midY),to:nil)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:index,proposedDropOperation:.on) == .move)
        #expect(sidebar.tableView(table,acceptDrop:info,row:index,dropOperation:.on))
        #expect(Set(owner.splits.layout(containing:target.id)?.tabIDs ?? []) == Set((pages+[target]).map(\.id)))
        #expect(owner.pinnedSites.isEmpty && owner.profile.favoriteTabs.isEmpty)
    }

    @Test("A Favorite dropped onto its own mixed split pane is refused before the tile is removed")
    func ownSplitPane() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let a = page("SelfFavorite",in:session);session.pin(a)
        let site = try #require(owner.pinnedSites.first),b = page("Workspace",in:session)
        session.splitTabs([a,b])
        let sidebar = sidebar(session),table = sidebar.tabListTableView,index = try row("Workspace",in:sidebar)
        let split = try #require(table.view(atColumn:0,row:index,makeIfNecessary:true) as? SplitRowView)
        split.layoutSubtreeIfNeeded()
        let pane = try #require(split.members.first { UITestSupport.textFields(in:$0).contains { $0.stringValue == "SelfFavorite" } })
        let board = board(site,in:owner);defer { board.releaseGlobally() }
        let info = FavoriteDragInfo(board,.move)
        info.draggingLocation = pane.convert(NSPoint(x:pane.bounds.midX,y:pane.bounds.midY),to:nil)
        let before = owner.splits,ids = owner.tabs.map(\.id)
        #expect(!sidebar.tableView(table,acceptDrop:info,row:index,dropOperation:.on))
        #expect(owner.pinnedSites == [site] && owner.splits == before && owner.tabs.map(\.id) == ids)
        #expect(a.pinnedSiteID == site.id)
    }

    @Test("Malformed and stale native payloads never fall back to their URL or move a partial selection")
    func stalePayloads() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let site = PinnedSite(url:URL(string:"https://favorite-drag.invalid/stale")!,title:"Stale tool");owner.addPinnedSite(site)
        let a = page("A",in:session),sidebar = sidebar(session),table = sidebar.tabListTableView,strip = try strip(sidebar)
        let board = NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        let item = NSPasteboardItem();item.setString(site.id.uuidString,forType:SidebarTabDrag.favoriteType)
        item.setString(UUID().uuidString,forType:SidebarTabDrag.ownerType);item.setString(site.url.absoluteString,forType:.URL)
        board.writeObjects([item]);let info = FavoriteDragInfo(board,.move),before = owner.tabs.map(\.id)
        #expect(sidebar.tableView(table,validateDrop:info,proposedRow:table.numberOfRows,proposedDropOperation:.above).isEmpty)
        let valid = NSPasteboardItem(),invalid = NSPasteboardItem()
        for (item,id) in [(valid,a.id),(invalid,UUID())] { item.setString(id.uuidString,forType:SidebarTabDrag.type);item.setString(owner.id.uuidString,forType:SidebarTabDrag.ownerType) }
        board.clearContents();board.writeObjects([valid,invalid])
        #expect(strip.draggingEntered(info).isEmpty && !strip.performDragOperation(info))
        #expect(owner.tabs.map(\.id) == before && owner.pinnedSites == [site])
    }

    @Test("A tile supplies a stable owner-scoped payload and waits for mouse-up before clicking")
    func nativeSource() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let site = PinnedSite(url:URL(string:"https://favorite-drag.invalid/source")!,title:"Source tool");owner.addPinnedSite(site)
        let sidebar = sidebar(session),strip = try strip(sidebar)
        sidebar.view.layoutSubtreeIfNeeded()
        let tile = try #require(UITestSupport.descendants(of:strip).first { $0.accessibilityLabel() == "Source tool" })
        let id = "\(owner.id)/\(owner.profile.id)/\(site.id)"
        let writer = try #require(strip.dragItemProvider?(id))
        #expect(writer.string(forType:SidebarTabDrag.favoriteType) == site.id.uuidString)
        #expect(writer.string(forType:SidebarTabDrag.ownerType) == owner.id.uuidString)
        var clicks = 0;strip.onSelect = { _ in clicks += 1 }
        let point = tile.convert(NSPoint(x:tile.bounds.midX,y:tile.bounds.midY),to:nil)
        let down = try #require(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        let up = try #require(NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:2,clickCount:1,pressure:0))
        tile.mouseDown(with:down);#expect(clicks == 0)
        tile.mouseUp(with:up);#expect(clicks == 1)
    }

    @Test("A Favorite dropped on a Space icon crosses profiles as one named unit")
    func dockTransfer() throws {
        let session = TestSession.make().0
        let (source,pages,site) = try favorite(session)
        let profile = try #require(session.addProfile(named:"Other")),target = session.addSpace(named:"Other",profile:profile)
        session.selectSpace(source)
        let sidebar = sidebar(session),board = board(site,in:source)
        defer { board.releaseGlobally() }
        let button = try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? SpaceDockButton }.first { $0.id == target.id })
        let info = FavoriteDragInfo(board,.move)
        #expect(button.draggingEntered(info) == .move && button.performDragOperation(info))
        #expect(session.activeSpace === target && target.splits.layouts.first?.paneCount == 2)
        #expect(target.splits.name(containing:try #require(session.activeTab?.id)) == "Named pair")
        #expect(source.pinnedSites.isEmpty && target.pinnedSites.isEmpty && pages.allSatisfy { page in !source.tabs.contains { $0 === page } })
    }
}
