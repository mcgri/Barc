import AppKit
import Testing
@testable import Barc

@Suite("Cleaning up tabs unused for a week", .serialized)
@MainActor
struct TabCleanUpTests {
    private let day: TimeInterval = 86_400

    private func tab(_ session: BrowserSession, _ name: String, unusedFor days: Double) -> Tab {
        let tab = session.newTab(url: URL(string: "https://\(name).example/")!, select: false)
        tab.backdateLastActive(by: days * day)
        return tab
    }

    @Test("Archives tabs unused for 7 days and keeps recent, locked, pinned and on-screen ones")
    func archivesOnlyStaleTabs() {
        let session = TestSession.make().0
        var toasts: [Toast] = []
        session.showToast = { toasts.append($0) }
        let onScreen = session.newTab(url: URL(string: "https://on-screen.example/")!)
        onScreen.backdateLastActive(by: 30 * day)
        let stale = tab(session, "stale", unusedFor: 8)
        let older = tab(session, "older", unusedFor: 40)
        let recent = tab(session, "recent", unusedFor: 6.9)
        let kept = tab(session, "kept", unusedFor: 30)
        kept.setKeepsInSidebar(true)
        let pinned = tab(session, "pinned", unusedFor: 30)
        session.pin(pinned)

        #expect(session.cleanUpUnusedTabs() == 2)
        let remaining = session.allTabs.map(\.id)
        for tab in [onScreen, recent, kept, pinned] { #expect(remaining.contains(tab.id), "\(tab.url) must stay") }
        for tab in [stale, older] { #expect(!remaining.contains(tab.id), "\(tab.url) must go") }
        #expect(Set(session.archivedTabs.map(\.snapshot.url)) == [stale.url, older.url], "Archived, not lost")
        #expect(toasts.last?.message == "Archived 2 tabs unused for 7 days")

        toasts.last?.action?.handler()
        #expect(Set(session.allTabs.map(\.url)).isSuperset(of: [stale.url, older.url]), "Undo puts them back")
        #expect(session.archivedTabs.isEmpty)
    }

    @Test("A tab still holding a page stays, however old: it may be an unsent draft")
    func awakeTabStays() async throws {
        let session = TestSession.make().0
        let awake = tab(session, "draft", unusedFor: 30)
        _ = awake.webView()
        #expect(!awake.isAsleep)
        defer { awake.unload() }
        #expect(session.cleanUpUnusedTabs() == 0)
        #expect(session.allTabs.contains { $0 === awake })
    }

    @Test("With nothing old enough it says so instead of doing nothing visible")
    func nothingToCleanUp() {
        let session = TestSession.make().0
        var toasts: [Toast] = []
        session.showToast = { toasts.append($0) }
        _ = tab(session, "fresh", unusedFor: 1)
        #expect(session.cleanUpUnusedTabs() == 0)
        #expect(toasts.last?.message == "No tabs unused for 7 days")
        #expect(session.archivedTabs.isEmpty)
    }

    @Test("The button beside New Tab runs it")
    func sidebarButton() throws {
        let session = TestSession.make().0
        let stale = tab(session, "stale", unusedFor: 10)
        let sidebar = SidebarViewController(session: session)
        _ = UITestSupport.host(sidebar.view, width: 228, height: 760)
        func buttons(in view: NSView) -> [IconButton] {
            ((view as? IconButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
        }
        let table = sidebar.tabListTableView
        let rows = (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
        let button = try #require((rows + [sidebar.view]).flatMap(buttons).first { $0.accessibilityLabel() == "Clean Up Tabs Unused for 7 Days" })
        button.performClick(nil)
        #expect(!session.allTabs.contains { $0 === stale })
        #expect(session.archivedTabs.map(\.snapshot.url) == [stale.url])
    }
}
