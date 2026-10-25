// Modified for Barc: source-observed active/background split menu actions, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar split menu", .serialized)
@MainActor
struct SidebarSplitMenuTests {
    private func page(_ name:String,in session:BrowserSession) -> Tab {
        session.newTab(url:URL(string:"https://split-menu.invalid/\(name)")!)
    }
    private func fire(_ item:NSMenuItem) async throws {
        _ = NSApplication.shared
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action),to:item.target,from:item))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test("The sole active page can add an empty split without committing a tab")
    func solePage() async throws {
        let session = TestSession.make().0
        let placeholder = try #require(session.activeTab)
        let tab = page("sole",in:session)
        session.closeTab(placeholder)
        #expect(session.activeSpace.tabs.count == 1)
        let sidebar = SidebarViewController(session:session)
        var requests = 0
        sidebar.onChooseSplitPage = { requests += 1 }
        let before = session.snapshot()
        let item = try #require(sidebar.makeTabMenu(for:tab).items.first { ["Add Split View","Open in Split View"].contains($0.title) })
        #expect(item.title == "Add Split View" && item.isEnabled)
        guard item.isEnabled else { return }
        try await fire(item)
        #expect(requests == 1 && session.snapshot() == before)
    }

    @Test("A background page joins the active page instead of opening the blank chooser")
    func backgroundPage() async throws {
        let session = TestSession.make().0
        let a = page("a",in:session), b = page("b",in:session)
        session.selectTab(a)
        let sidebar = SidebarViewController(session:session)
        var requests = 0
        sidebar.onChooseSplitPage = { requests += 1 }
        let item = try #require(sidebar.makeTabMenu(for:b).items.first { $0.title == "Open in Split View" })
        try await fire(item)
        #expect(requests == 0 && session.activeSplit?.tabIDs == [a.id,b.id])
    }

    @Test("Menu availability plans complete groups against the four-pane limit")
    func capacity() throws {
        let session = TestSession.make().0
        let pages = (0..<6).map { page("\($0)",in:session) }
        session.splitTabs(Array(pages.prefix(4)),grid:.grid)
        session.selectTab(pages[0])
        let sidebar = SidebarViewController(session:session)
        func item(_ tab:Tab) throws -> NSMenuItem {
            let item = try #require(sidebar.makeTabMenu(for:tab).items.first { ["Add Split View","Open in Split View"].contains($0.title) })
            #expect(item.title == (session.activeTab === tab ? "Add Split View":"Open in Split View"))
            return item
        }
        #expect(try !item(pages[0]).isEnabled)
        #expect(try !item(pages[4]).isEnabled)
        session.unsplit()
        session.splitTabs(Array(pages.prefix(3)),grid:.sideBySide)
        session.splitTabs(Array(pages.suffix(2)),grid:.stacked)
        session.selectTab(pages[0])
        #expect(try item(pages[0]).isEnabled)
        #expect(try !item(pages[4]).isEnabled)
        #expect(try item(pages[3]).isEnabled)
    }

    @Test("An active-page menu retains its owning Space after switching elsewhere")
    func owner() async throws {
        let session = TestSession.make().0, original = session.activeSpace
        let tab = page("original",in:session)
        let sidebar = SidebarViewController(session:session)
        let item = try #require(sidebar.makeTabMenu(for:tab).items.first { $0.title == "Add Split View" })
        let other = session.addSpace(named:"Other")
        let untouched = page("other",in:session)
        var chosen:UUID?
        sidebar.onChooseSplitPage = { chosen = session.activeTab?.id }
        try await fire(item)
        #expect(session.activeSpace === original && chosen == tab.id)
        #expect(other.tabs.contains { $0 === untouched } && original.splits.layouts.isEmpty)
    }
}
