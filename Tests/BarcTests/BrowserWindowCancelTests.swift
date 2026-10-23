// Modified for Barc: regression coverage for Escape after sidebar interactions, 2026-10-23.
import AppKit
import Testing
@testable import Barc

@Suite("Browser window cancellation", .serialized)
@MainActor
struct BrowserWindowCancelTests {
    @Test("Sidebar click and Cmd-L open the same full-URL popup without creating tabs")
    func sidebarAddressOpensPopup() throws {
        _ = NSApplication.shared
        let (session, _) = TestSession.make()
        let url = URL(string: "https://example.com/path?query=value#section")!
        let active = session.newTab(url: url)
        session.newTab(url: URL(string: "https://other.example/")!, select: false)
        let controller = BrowserWindowController(session: session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; window.close() }
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let address = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? AddressField }.first)
        let bar = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? CommandBar }.first)
        let count = session.activeSpace.tabs.count
        address.onOpen?()
        root.layoutSubtreeIfNeeded()
        #expect(bar.isOpen && bar.isAddressMode)
        #expect(bar.queryText == url.absoluteString)
        #expect(bar.fieldHasFocus)
        #expect(bar.results.first?.action == .switchToTab(active.id))
        #expect(session.activeSpace.tabs.count == count)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        controller.openLocation(nil)
        #expect(bar.isOpen)
        #expect(editor.selectedRange().length == (url.absoluteString as NSString).length)
        bar.cancelOperation(nil)
        #expect(!bar.isOpen)
        #expect(session.activeTab === active)
        #expect(session.activeTab?.url == url)
        #expect(session.activeSpace.tabs.count == count)
    }

    @Test("Escape arriving from a web page leaves an ordinary browser window intact")
    func escapeWithoutAnOverlay() {
        _ = NSApplication.shared
        let (session, _) = TestSession.make()
        let controller = BrowserWindowController(session: session)
        let window = controller.window
        window?.isReleasedWhenClosed = false
        defer {
            window?.delegate = nil
            window?.close()
        }
        controller.cancelOperation(nil)
        #expect(controller.window === window)
        #expect(controller.session === session)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let root = window?.contentView,
           let dock = UITestSupport.descendants(of: root).first(where: { $0 is SpaceDockView }),
           let swipeRegion = controller.swipeRegion {
            #expect(!swipeRegion.intersects(dock.convert(dock.bounds, to: nil)))
        } else {
            Issue.record("The window must expose its Space dock and sidebar swipe region")
        }
    }
}
