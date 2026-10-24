// Modified for Barc: compact split units in the sidebar, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Combined sidebar split rows", .serialized)
@MainActor
struct SidebarSplitRowTests {
    private func fixture() -> (BrowserSession, SidebarViewController, [Tab]) {
        let session = TestSession.make().0
        let tabs = (0..<4).map { index in
            let tab = session.newTab(url: URL(string: "https://sidebar-split.invalid/page-\(index)")!)
            session.rename(tab,to:"Page \(index)")
            return tab
        }
        session.splitTabs(Array(tabs.prefix(2)),grid:.sideBySide)
        session.splitTabs(Array(tabs.suffix(2)),grid:.stacked)
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        return (session,sidebar,tabs)
    }

    @Test("Two splits occupy two compact rows, while the selected row represents all its members")
    func oneRowPerGroup() {
        let (session,sidebar,tabs) = fixture()
        #expect(sidebar.tabListTableView.numberOfRows == 3)
        #expect(sidebar.selectedTabs.map(\.id) == [tabs[2].id,tabs[3].id])
        let selected = sidebar.tabListTableView.selectedRow
        session.selectTab(tabs[3])
        #expect(sidebar.tabListTableView.selectedRow == selected)
        #expect(sidebar.selectedTabs.map(\.id) == [tabs[2].id,tabs[3].id])
        session.selectTab(tabs[0])
        #expect(sidebar.tabListTableView.selectedRow != selected)
        #expect(sidebar.selectedTabs.map(\.id) == [tabs[0].id,tabs[1].id])
    }

    @Test("Dissolving one group restores its member rows without disturbing the other compact group")
    func dissolveRows() {
        let (session,sidebar,tabs) = fixture()
        session.unsplit()
        #expect(sidebar.tabListTableView.numberOfRows == 4)
        session.selectTab(tabs[0])
        #expect(sidebar.selectedTabs.map(\.id) == [tabs[0].id,tabs[1].id])
        session.unsplit()
        #expect(sidebar.tabListTableView.numberOfRows == 5)
    }

    @Test("Clicking and accessibility activation choose a pane without changing the selected row")
    func memberActivation() throws {
        let (session,sidebar,tabs) = fixture()
        session.selectTab(tabs[0])
        let table = sidebar.tabListTableView
        let row = table.selectedRow
        let cell = try #require(table.view(atColumn:0,row:row,makeIfNecessary:true) as? SplitRowView)
        cell.layoutSubtreeIfNeeded()
        let plate = cell.convert(cell.pillRect,to:sidebar.view)
        #expect(abs(plate.minX-8) < 0.5)
        #expect(abs(plate.maxX-(sidebar.view.bounds.width-8)) < 0.5)
        let second = cell.members[1].frame
        #expect(cell.activate(at:NSPoint(x:second.midX,y:second.midY)))
        #expect(session.activeTab === tabs[1])
        #expect(table.selectedRow == row && cell.focusedIndex == 1)
        #expect(cell.members[0].accessibilityPerformPress())
        #expect(session.activeTab === tabs[0] && table.selectedRow == row)
        #expect(!cell.activate(at:NSPoint(x:-1,y:-1)))
    }

    @Test("Keyboard row selection returns to the pane last focused in that group")
    func rememberedSelection() {
        let (session,sidebar,tabs) = fixture()
        session.selectTab(tabs[1])
        let rememberedRow = sidebar.tabListTableView.selectedRow
        session.selectTab(tabs[3])
        sidebar.tabListTableView.selectRowIndexes([rememberedRow],byExtendingSelection:false)
        #expect(session.activeTab === tabs[1])
    }

    @Test("A stale compact cell cannot activate or close tabs after its group is dissolved")
    func staleCallbacks() throws {
        let (session,sidebar,tabs) = fixture()
        let cell = try #require(sidebar.tabListTableView.view(atColumn:0,row:sidebar.tabListTableView.selectedRow,makeIfNecessary:true) as? SplitRowView)
        let select = try #require(cell.onSelectMember)
        let close = try #require(cell.onCloseMember)
        let originalIDs = session.activeSpace.tabs.map(\.id)
        session.unsplit()
        session.selectTab(tabs[0])
        select(1); close(0)
        #expect(session.activeTab === tabs[0])
        #expect(session.activeSpace.tabs.map(\.id) == originalIDs)
    }

    @Test("Compact cells fit two through four panes at narrow and wide sidebar widths")
    func memberGeometry() {
        for width:CGFloat in [180,228,360] {
            for count in 2...4 {
                let cell = SplitRowView(frame:NSRect(x:0,y:0,width:width,height:Style.Metrics.rowHeight))
                cell.configure((0..<count).map { TabRowContent(title:"Page \($0) with a long title") },focusedIndex:0)
                cell.isSelected = true
                cell.layoutSubtreeIfNeeded()
                for (index,member) in cell.members.enumerated() {
                    #expect(cell.pillRect.contains(member.frame))
                    #expect(member.bounds.contains(member.title.frame))
                    #expect(member.bounds.contains(member.favicon.frame))
                    if index > 0 { #expect(cell.members[index-1].frame.maxX + 4 == member.frame.minX) }
                    #expect(cell.hitTest(NSPoint(x:member.frame.midX,y:member.frame.midY)) === cell)
                }
            }
        }
    }

    @Test("Recycling a split row clears callbacks, selection, labels and pane views")
    func reuse() {
        let cell = SplitRowView(frame:NSRect(x:0,y:0,width:228,height:Style.Metrics.rowHeight))
        cell.configure([TabRowContent(title:"Old page"),TabRowContent(title:"Other page")],focusedIndex:1)
        cell.isSelected = true
        cell.onSelectMember = { _ in Issue.record("Stale callback") }
        cell.prepareForReuse()
        #expect(cell.members.isEmpty && cell.focusedIndex == nil && !cell.isSelected)
        #expect(cell.onSelectMember == nil && cell.onCloseMember == nil && cell.onResetMember == nil)
        cell.configure([TabRowContent(title:"New page"),TabRowContent(title:"Next page")],focusedIndex:0)
        #expect(cell.members.map { $0.title.stringValue } == ["New page","Next page"])
    }

    @Test("Dragging a split row moves every member into the same folder and keeps pane focus")
    func moveWholeUnit() throws {
        let (session,sidebar,tabs) = fixture()
        let group = session.createGroup(named:"Destination")
        session.selectTab(tabs[1])
        let id = session.activeSpace.splits.identifier(containing:tabs[0].id)
        #expect(session.moveSidebarTab(tabs[0],to:session.activeSpace.tabs.count,group:group,before:nil,retained:true))
        #expect(tabs[0].groupID == group.id && tabs[1].groupID == group.id)
        #expect(tabs[2].groupID == nil && tabs[3].groupID == nil)
        #expect(session.activeSpace.splits.identifier(containing:tabs[0].id) == id)
        #expect(session.activeSpace.splits.preferredTab(containing:tabs[0].id) == tabs[1].id)
        #expect(session.activeSpace.tabs.suffix(2).map(\.id) == [tabs[0].id,tabs[1].id])
        #expect(sidebar.selectedTabs.map(\.id) == [tabs[0].id,tabs[1].id])
        #expect(session.moveSidebarTab(tabs[0],to:0,group:nil,before:.tab(tabs[2]),retained:false))
        #expect(tabs[0].groupID == nil && tabs[1].groupID == nil)
        #expect(!tabs[0].keepsInSidebar && !tabs[1].keepsInSidebar)
        let ordered = SidebarOrder.items(groups:session.activeSpace.groups,tabs:session.activeSpace.sidebarVisibleTabs)
        #expect(ordered.map(\.id) == [group.id,tabs[0].id,tabs[1].id,tabs[2].id,tabs[3].id])
    }

    @Test("Dropping onto a member of the same unit is a no-op, and foreign destinations are refused")
    func invalidUnitMoves() {
        let (session,_,tabs) = fixture()
        let before = session.snapshot()
        #expect(session.moveSidebarTab(tabs[0],to:4,group:nil,before:.tab(tabs[1]),retained:true))
        #expect(!session.moveSidebarTab(tabs[0],to:4,group:TabGroup(name:"Foreign"),before:nil,retained:true))
        #expect(session.snapshot() == before)
    }

    @Test("The shared selection plate and individual pane labels render at the reference width")
    func renderedRow() throws {
        let host = NSView(frame:NSRect(x:0,y:0,width:228,height:66))
        host.appearance = NSAppearance(named:.aqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(srgbRed:0.89,green:0.57,blue:0.45,alpha:1).cgColor
        let row = SplitRowView(frame:NSRect(x:0,y:12,width:220,height:Style.Metrics.rowHeight))
        host.addSubview(row)
        row.configure([TabRowContent(title:"mcgri/Barc",sidebarSymbolName:"globe"),TabRowContent(title:"github.com",sidebarSymbolName:"globe")],focusedIndex:0)
        row.isSelected = true
        host.layoutSubtreeIfNeeded()
        #expect(row.pillRect.height == 35)
        #expect(row.members.allSatisfy { !$0.title.isHidden && $0.title.frame.width > 40 })
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        #expect(bitmap.pixelsWide >= 228 && bitmap.pixelsHigh >= 66)
        if let path = ProcessInfo.processInfo.environment["BARC_SPLIT_ROW_CAPTURE"] {
            let png = try #require(bitmap.representation(using:.png,properties:[:]))
            try png.write(to:URL(fileURLWithPath:path))
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
        }
    }
}
