// Modified for Barc: regression coverage for Escape after sidebar interactions, 2026-10-23.
import AppKit
import Testing
@testable import Barc

@Suite("Browser window cancellation", .serialized)
@MainActor
struct BrowserWindowCancelTests {
    @Test("Window controls share navigation; Space identity follows Favorites; New Tab precedes ordinary tabs")
    func compactArcSidebarStructure() throws {
        _ = NSApplication.shared
        let (session, _) = TestSession.make()
        let ordinary = session.newTab(url: URL(string: "https://ordinary.example/")!)
        let kept = session.newTab(url: URL(string: "https://kept.example/")!)
        kept.setKeepsInSidebar(true)
        session.selectTab(ordinary)
        // Measured without the performance gauge, which pushes navigation to
        // its own row at the default width.
        let showsGauge = Settings.shared.showsTaskManagerInSidebar
        Settings.shared.showsTaskManagerInSidebar = false
        defer { Settings.shared.showsTaskManagerInSidebar = showsGauge }
        let controller = BrowserWindowController(session: session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; window.close() }
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let descendants = UITestSupport.descendants(of: root)
        let bar = try #require(descendants.compactMap { $0 as? ContentTopBar }.first)
        let header = try #require(descendants.compactMap { $0 as? SidebarHeaderView }.first)
        let pins = try #require(descendants.compactMap { $0 as? PinnedTilesView }.first)
        let light = try #require(window.standardWindowButton(.closeButton))
        let lightFrame = light.convert(light.bounds, to: root)
        let navFrame = bar.backButton.convert(bar.backButton.bounds, to: root)
        #expect(abs(lightFrame.midY - navFrame.midY) < 1, "Root \(root.frame), header \(header.frame), light \(lightFrame), nav \(navFrame)")
        #expect(lightFrame.maxX < navFrame.minX, "Header \(header.frame), nav host \(String(describing: bar.backButton.superview?.frame))")
        #expect(bar.utilitiesButton.superview === bar.backButton.superview)
        let pinFrame = pins.convert(pins.bounds, to: root)
        let identity = header.spaceButton.convert(header.spaceButton.bounds, to: root)
        let address = bar.addressField.convert(bar.addressField.bounds, to: root)
        #expect(identity.maxY < pinFrame.minY)
        #expect(pinFrame.maxY < address.minY)
        let list = try #require(descendants.compactMap { $0 as? NSTableView }.first)
        func index(containing text: String) -> Int? {
            (0..<list.numberOfRows).first { row in
                guard let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) else { return false }
                return UITestSupport.descendants(of: cell).contains { ($0.accessibilityLabel() ?? "").contains(text) }
            }
        }
        let newTab = try #require(index(containing: "New Tab"))
        let keptRow = try #require(index(containing: "kept.example"))
        let ordinaryRow = try #require(index(containing: "ordinary.example"))
        #expect(keptRow < newTab)
        #expect(newTab < ordinaryRow)
        #expect(session.activeTab === ordinary)
        let footer = try #require(descendants.compactMap { $0 as? SidebarFooterView }.first)
        let addMenu = try #require(footer.addMenuProvider?())
        for title in ["New Tab", "New Boost", "New Split"] {
            let item = try #require(addMenu.items.first { $0.title == title })
            #expect(item.target === controller)
        }
    }

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
