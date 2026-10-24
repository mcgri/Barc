import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Empty sidebar and Favorite drops")
@MainActor
struct SidebarEmptyStateTests {
    @Test("Tab text and icons pass pointer gestures to the row while its close button stays clickable")
    func tabRowPointerFaces() throws {
        let row = TabRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Style.Metrics.rowHeight).isActive = true
        var closed = false
        row.onClose = { closed = true }
        row.configure(TabRowContent(title: "Drag this tab"))
        row.isSelected = true
        let host = UITestSupport.host(row, width: 228, height: Style.Metrics.rowHeight)
        host.layoutSubtreeIfNeeded()
        let parent = try #require(row.superview)
        let title = try #require(UITestSupport.textFields(in: row).first { $0.stringValue == "Drag this tab" })
        for face in [title as NSView, row.favicon] {
            let point = face.convert(NSPoint(x: face.bounds.midX, y: face.bounds.midY), to: parent)
            #expect(row.hitTest(point) === row, "The table needs the pointer sequence to start a drag")
        }
        let close = try #require(UITestSupport.buttons(in: row).first { !$0.isHiddenOrHasHiddenAncestor })
        let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: parent)
        #expect(row.hitTest(point) === close)
        close.performClick(nil)
        #expect(closed)
    }

    private func pins(in sidebar: SidebarViewController) throws -> PinnedTilesView {
        try #require(UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? PinnedTilesView }.first)
    }
    private func pasteboard(id: UUID) -> NSPasteboard {
        let board = NSPasteboard(name: .init("barc.favorite-test.\(UUID())"))
        board.setString(id.uuidString, forType: SidebarTabDrag.type)
        return board
    }

    @Test("An empty Space has one New Tab action and keeps its saved content owner")
    func oneNewTabRow() throws {
        let session = TestSession.make().0
        let placeholder = try #require(session.activeTab)
        let sidebar = SidebarViewController(session: session)
        _ = sidebar.view
        #expect(placeholder.isSidebarPlaceholder)
        #expect(sidebar.tabListTableView.numberOfRows == 1)
        let before = session.activeSpace.tabs.map(\.id)
        var requests = 0
        sidebar.onNewTab = { requests += 1 }
        let cell = try #require(sidebar.tabListTableView.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let action = try #require(UITestSupport.descendants(of: cell).compactMap { $0 as? ActionRowView }.first)
        #expect(action.accessibilityPerformPress())
        #expect(requests == 1)
        #expect(session.activeSpace.tabs.map(\.id) == before)
        #expect(session.activeTab === placeholder)
        #expect(UITestSupport.descendants(of: cell).compactMap { $0 as? NSBox }.allSatisfy { $0.isHidden })
        let restored = try #require(BrowserSession.spaces(from: session.snapshot())?.first)
        #expect(restored.tabs.count == 1)
        #expect(restored.activeTab?.url == StartPage.url)
        #expect(restored.sidebarVisibleTabs.isEmpty)
    }

    @Test("A start page that was named, retained, grouped or annotated stays visible")
    func meaningfulStartPagesStayVisible() {
        let identity = TestSession.make().0.activeSpace.identity
        let named = Tab(url: StartPage.url, identity: identity)
        _ = TabNameStore.shared.rename(named.id, to: "Research")
        defer { _ = TabNameStore.shared.rename(named.id, to: "") }
        let retained = Tab(url: StartPage.url, identity: identity); retained.setKeepsInSidebar(true)
        let grouped = Tab(url: StartPage.url, identity: identity); grouped.setGroupID(UUID())
        let annotated = Tab(url: StartPage.url, identity: identity); annotated.setNote("Keep these notes")
        for tab in [named, retained, grouped, annotated] { #expect(!tab.isSidebarPlaceholder) }
    }

    @Test("Dismissing the empty hint persists, leaves real Favorites alone, and does not dismiss another Space")
    func dismissHint() throws {
        let session = TestSession.make().0
        let original = session.activeSpace
        let sidebar = SidebarViewController(session: session)
        let strip = try pins(in: sidebar)
        let dismiss = try #require(UITestSupport.buttons(in: strip).first { $0.accessibilityLabel() == "Dismiss Favorites Hint" })
        dismiss.performClick(nil)
        #expect(original.look.favoritesHintDismissed)
        #expect(strip.isHidden)
        let tab = session.newTab(url: URL(string: "https://favorite.invalid/")!, select: false)
        session.pin(tab)
        #expect(!strip.isHidden && strip.tileCount == 1)
        session.unpin(tab)
        #expect(strip.isHidden)
        let other = session.addSpace(named: "Other")
        #expect(!other.look.favoritesHintDismissed)
        #expect(!strip.isHidden)
        session.selectSpace(original)
        #expect(strip.isHidden)
        let restored = try #require(BrowserSession.spaces(from: session.snapshot())?.first { $0.id == original.id })
        #expect(restored.look.favoritesHintDismissed)
        #expect(try JSONDecoder().decode(SpaceLook.self, from: Data("{}".utf8)).favoritesHintDismissed == false)
    }

    @Test("Dragging a tab brings back an empty drop target without resetting the dismissed hint")
    func transientDropTarget() {
        let strip = PinnedTilesView()
        strip.show([], showsEmptyHint: false)
        #expect(strip.isHidden)
        strip.setTabDragInProgress(true)
        #expect(!strip.isHidden)
        #expect(strip.intrinsicContentSize.height > 0)
        strip.setTabDragInProgress(false)
        #expect(strip.isHidden)
        #expect(strip.intrinsicContentSize.height == 0)
    }

    @Test("The empty card is one registered drop target while its dismiss button stays clickable")
    func hintPointerFaces() throws {
        let strip = PinnedTilesView()
        strip.show([])
        let host = UITestSupport.host(strip, width: 212, height: 100)
        host.layoutSubtreeIfNeeded()
        let parent = try #require(strip.superview)
        for field in UITestSupport.textFields(in: strip) {
            let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: parent)
            #expect(strip.hitTest(point) === strip)
        }
        let dismiss = try #require(UITestSupport.buttons(in: strip).first)
        let point = dismiss.convert(NSPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), to: parent)
        var hit = strip.hitTest(point)
        while hit != nil && !(hit is NSButton) { hit = hit?.superview }
        #expect(hit === dismiss)
    }

    @Test("A real sidebar drag Favorites the same tab after its row index changes")
    func dragUsesStableTabID() throws {
        let session = TestSession.make().0
        let a = session.newTab(url: URL(string: "https://a.invalid/")!, select: false)
        let b = session.newTab(url: URL(string: "https://b.invalid/")!, select: false)
        let sidebar = SidebarViewController(session: session)
        let strip = try pins(in: sidebar)
        let table = sidebar.tabListTableView
        let row = try #require((0..<table.numberOfRows).first { row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return false }
            return cell.accessibilityLabel()?.contains("b.invalid") == true
                || UITestSupport.accessibilityLabels(in: cell).contains { $0.contains("b.invalid") }
        })
        let writer = try #require(sidebar.tableView(table, pasteboardWriterForRow: row))
        let board = NSPasteboard(name: .init("barc.favorite-writer.\(UUID())")); defer { board.releaseGlobally() }
        #expect(board.writeObjects([writer]))
        #expect(SidebarTabDrag.id(in: board) == b.id)
        session.moveTab(from: try #require(session.activeSpace.index(of: b)), to: 0)
        let before = Set(session.activeSpace.tabs.map(\.id))
        #expect(strip.canAcceptDrop(from: board))
        #expect(strip.acceptDrop(from: board))
        #expect(b.pinnedSiteID != nil && a.pinnedSiteID == nil)
        #expect(session.activeSpace.pinnedSites.count == 1)
        #expect(Set(session.activeSpace.tabs.map(\.id)) == before)
        #expect(b.currentWebView == nil)
        #expect(!strip.acceptDrop(from: board), "Dropping the same tab twice cannot duplicate it")
    }

    @Test("A stale tab, empty page or another profile cannot be Favorited through a drop")
    func rejectsUnrelatedDrops() throws {
        let session = TestSession.make().0
        let original = session.activeSpace
        let empty = try #require(session.activeTab)
        let tab = session.newTab(url: URL(string: "https://first.invalid/")!, select: false)
        _ = session.addSpace(named: "Separate")
        let sidebar = SidebarViewController(session: session)
        let strip = try pins(in: sidebar)
        for id in [tab.id, UUID()] {
            let board = pasteboard(id: id); defer { board.releaseGlobally() }
            #expect(!strip.canAcceptDrop(from: board))
            #expect(!strip.acceptDrop(from: board))
        }
        session.selectSpace(original)
        let board = pasteboard(id: empty.id); defer { board.releaseGlobally() }
        #expect(!strip.acceptDrop(from: board))
        #expect(original.pinnedSites.isEmpty)
        #expect(session.spaces.allSatisfy { $0.pinnedSites.isEmpty })
    }

    @Test("Favorites stop at twelve without removing or duplicating any tabs")
    func twelveFavorites() throws {
        let session = TestSession.make().0
        let tabs = (0..<13).map { session.newTab(url: URL(string: "https://site\($0).invalid/")!, select: false) }
        for tab in tabs.prefix(12) { session.pin(tab) }
        let sidebar = SidebarViewController(session: session)
        let strip = try pins(in: sidebar)
        let board = pasteboard(id: tabs[12].id); defer { board.releaseGlobally() }
        #expect(!strip.acceptDrop(from: board))
        session.pin(tabs[12])
        #expect(session.activeSpace.pinnedSites.count == 12)
        #expect(tabs[12].pinnedSiteID == nil)
        #expect(session.activeSpace.tabs.count == 14)
    }
}
