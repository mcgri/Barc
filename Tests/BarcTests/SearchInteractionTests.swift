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
