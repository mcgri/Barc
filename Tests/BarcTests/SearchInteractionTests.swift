// Modified for Barc: combined search interaction regressions, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@MainActor
private final class SidebarClickProbe:NSView {
    var received:[NSEvent.EventType] = []
    override func mouseDown(with event:NSEvent) { received.append(event.type) }
    override func rightMouseDown(with event:NSEvent) { received.append(event.type) }
    override func otherMouseDown(with event:NSEvent) { received.append(event.type) }
}

@Suite("Search sidebar pointer interaction", .serialized)
@MainActor
struct SearchInteractionTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;return window
    }
    private func event(_ type:NSEvent.EventType,at point:NSPoint,window:NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    @Test("A sidebar press dismisses before hit testing and preserves its original mouse event",arguments:[NSEvent.EventType.leftMouseDown,.rightMouseDown,.otherMouseDown])
    func sidebarPress(type:NSEvent.EventType) throws {
        let window = window();defer { window.close() }
        let root = try #require(window.contentView)
        let sidebar = NSView(frame:NSRect(x:0,y:0,width:250,height:700));root.addSubview(sidebar)
        let target = SidebarClickProbe(frame:NSRect(x:20,y:100,width:200,height:40));sidebar.addSubview(target)
        let bar = CommandBar();bar.sidebarInteractionView = sidebar;bar.install(in:root)
        bar.openNewTab(recentResults:[]);root.layoutSubtreeIfNeeded()
        let point = target.convert(NSPoint(x:40,y:20),to:nil)
        let original = try event(type,at:point,window:window)
        #expect(root.hitTest(root.convert(point,from:nil)) === bar)
        bar.prepareSidebarInteraction(original)
        #expect(!bar.isOpen)
        let hit = try #require(root.hitTest(root.convert(point,from:nil)))
        #expect(hit === target)
        switch type {
        case .rightMouseDown:hit.rightMouseDown(with:original)
        case .otherMouseDown:hit.otherMouseDown(with:original)
        default:hit.mouseDown(with:original)
        }
        #expect(target.received == [type])
    }
    @Test("A compact sidebar keeps its native click target in place when search closes")
    func compactHandoff() throws {
        let settings = Settings.shared
        let oldMode = settings.sidebarMode,oldCompact = settings.compactModeEnabled
        let oldConfiguration = settings.compactModeConfiguration,oldCommand = settings.openCommandBarOnNewTab
        defer {
            settings.sidebarMode = oldMode;settings.compactModeEnabled = oldCompact
            settings.compactModeConfiguration = oldConfiguration;settings.openCommandBarOnNewTab = oldCommand
        }
        settings.openCommandBarOnNewTab = true
        let session = TestSession.make().0
        _ = session.newTab(url:URL(string:"https://fixture.invalid")!)
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        controller.setSidebarMode(.compact);controller.newTab(nil)
        let window = try #require(controller.window),root = try #require(window.contentView)
        let bar = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? CommandBar }.first)
        let sidebar = try #require(bar.sidebarInteractionView)
        root.layoutSubtreeIfNeeded();root.layoutSubtreeIfNeeded()
        let row = try #require(UITestSupport.descendants(of:sidebar).compactMap { $0 as? ActionRowView }.first)
        let before = row.convert(row.bounds,to:root)
        let point = row.convert(NSPoint(x:row.bounds.midX,y:row.bounds.midY),to:nil)
        bar.prepareSidebarInteraction(try event(.leftMouseDown,at:point,window:window))
        #expect(!bar.isOpen && row.convert(row.bounds,to:root) == before)
        let hit = try #require(root.hitTest(root.convert(point,from:nil)))
        #expect(hit === row || hit.isDescendant(of:row))
        hit.mouseDown(with:try event(.leftMouseDown,at:point,window:window))
        #expect(bar.isOpen && bar.queryText.isEmpty)
        bar.close()
    }

    @Test("Panel overlap, hidden sidebars, hover, foreign windows and page presses do not pass through")
    func boundaries() throws {
        let window = window(),other = self.window();defer { window.close();other.close() }
        let root = try #require(window.contentView)
        let sidebar = NSView(frame:root.bounds);root.addSubview(sidebar)
        let anchor = NSView(frame:NSRect(x:20,y:500,width:220,height:30));sidebar.addSubview(anchor)
        let bar = CommandBar();bar.sidebarInteractionView = sidebar;bar.install(in:root)
        bar.openAddress(text:"example.com",anchor:anchor);root.layoutSubtreeIfNeeded()
        let panel = try #require(bar.subviews.first)
        let panelPoint = panel.convert(NSPoint(x:40,y:panel.bounds.midY),to:nil)
        bar.prepareSidebarInteraction(try event(.leftMouseDown,at:panelPoint,window:window))
        #expect(bar.isOpen)
        let outside = NSPoint(x:50,y:50)
        bar.prepareSidebarInteraction(try event(.leftMouseDown,at:outside,window:other));#expect(bar.isOpen)
        bar.prepareSidebarInteraction(try event(.mouseMoved,at:outside,window:window));#expect(bar.isOpen)
        sidebar.isHidden = true
        bar.prepareSidebarInteraction(try event(.leftMouseDown,at:outside,window:window));#expect(bar.isOpen)
        sidebar.isHidden = false;sidebar.setFrameSize(NSSize(width:250,height:700))
        #expect(!sidebar.bounds.contains(sidebar.convert(NSPoint(x:900,y:50),from:nil)))
        bar.prepareSidebarInteraction(try event(.leftMouseDown,at:NSPoint(x:900,y:50),window:window));#expect(bar.isOpen)
        bar.close()
    }
}
