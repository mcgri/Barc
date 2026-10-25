// Modified for Barc: the compact tab menu opens the selected website's Boost editor, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar Customize Page", .serialized)
@MainActor
struct SidebarCustomizePageTests {
    private func url(_ name:String) -> URL { URL(string:"https://\(name).customize-fixture.invalid/page")! }
    private func controllers(_ root:NSViewController) -> [NSViewController] {
        [root] + root.children.flatMap(controllers) + (root.presentedViewControllers ?? []).flatMap(controllers)
    }
    private func fire(_ menu:NSMenu) async throws {
        let item = try #require(menu.items.first { $0.title == "Customize Page…" })
        #expect(item.isEnabled && !item.isAlternate && item.image == nil)
        #expect(NSApp.sendAction(try #require(item.action),to:item.target,from:item))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test("The captured active webpage menu places Customize Page after Mute; background and non-web pages omit it")
    func shapeAndEligibility() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let background = session.newTab(url:url("background")),active = session.newTab(url:url("active"))
        let sidebar = SidebarViewController(session:session)
        let visible = sidebar.makeTabMenu(for:active).items.filter { !$0.isAlternate }
            .map { $0.isSeparatorItem ? "-":$0.title }
        #expect(visible == ["Copy Link","-","Change Icon…","Rename…","Mute","Customize Page…","-",
            "Add Split View","Duplicate","Move to","-","Archive Tab","Archive Tabs Below"])
        let copy = try #require(sidebar.makeTabMenu(for:active).items.first { $0.title == "Copy Link" })
        #expect(copy.keyEquivalent == "c" && copy.keyEquivalentModifierMask == [.command,.shift])
        #expect(sidebar.makeTabMenu(for:active).items.filter(\.isAlternate).map(\.title)
            == ["Archive Other Tabs","Archive Tabs Above"])
        #expect(!sidebar.makeTabMenu(for:background).items.contains { $0.title == "Customize Page…" })
        let local = session.newTab(url:URL(fileURLWithPath:"/tmp/customize-page-fixture.html"))
        #expect(!sidebar.makeTabMenu(for:local).items.contains { $0.title == "Customize Page…" })
        let empty = session.newTab(url:URL(string:"about:blank")!)
        #expect(!sidebar.makeTabMenu(for:empty).items.contains { $0.title == "Customize Page…" })
    }

    @Test("The real menu action presents the site editor without changing pages or saving a Boost")
    func nativeEditor() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0,owner = session.activeSpace
        let tab = session.newTab(url:url("selected"))
        let controller = BrowserWindowController(session:session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil;window.close() }
        let root = try #require(window.contentViewController)
        let sidebar = try #require(controllers(root).compactMap { $0 as? SidebarViewController }.first)
        let before = session.allTabs.map(\.id),webView = tab.currentWebView
        let boosts = BoostStore.shared.boosts
        let host = SiteSettings.normalise(tab.displayURL.host()!)
        let expectedHost = BoostStore.shared.boost(forHost:host)?.host ?? host
        try await fire(sidebar.makeTabMenu(for:tab))
        let editor = try #require(controllers(root).compactMap { $0 as? BoostEditorViewController }.first)
        #expect(UITestSupport.descendants(of:editor.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "Boost for \(expectedHost)" })
        #expect(session.activeSpace === owner && session.activeTab === tab && tab.currentWebView === webView)
        #expect(session.allTabs.map(\.id) == before && tab.url == url("selected"))
        let unchanged = BoostStore.shared.boosts == boosts
        #expect(unchanged)
        editor.presentingViewController?.dismiss(editor)
    }

    @Test("An old Customize menu cannot edit a replacement page, another Space or a removed tab",arguments:[0,1,2])
    func staleTarget(change:Int) async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let tab = session.newTab(url:url("original"))
        let controller = BrowserWindowController(session:session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil;window.close() }
        let root = try #require(window.contentViewController)
        let sidebar = try #require(controllers(root).compactMap { $0 as? SidebarViewController }.first)
        let menu = sidebar.makeTabMenu(for:tab)
        switch change {
        case 0: tab.load(url("replacement"))
        case 1: _ = session.addSpace(named:"Elsewhere");_ = session.newTab(url:url("elsewhere"))
        default: session.closeTab(tab)
        }
        let selected = session.activeTab
        try await fire(menu)
        #expect(!controllers(root).contains { $0 is BoostEditorViewController })
        #expect(session.activeTab === selected)
    }
}
