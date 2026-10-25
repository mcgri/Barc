// Modified for Barc: double-clicking a tab title enters its existing inline editor, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Double-click tab naming", .serialized)
@MainActor
struct DoubleClickTabNamingTests {
    private final class ResponderProbe:NSResponder {
        var presses = 0
        override func mouseDown(with event:NSEvent) { presses += 1 }
    }
    private func host(_ session:BrowserSession) -> (SidebarViewController,NSWindow) {
        _ = NSApplication.shared
        let sidebar = SidebarViewController(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let content = UITestSupport.host(sidebar.view,width:228,height:800)
        sidebar.view.bottomAnchor.constraint(equalTo:content.bottomAnchor).isActive = true
        window.contentView = content;content.layoutSubtreeIfNeeded();sidebar.viewDidLayout()
        return (sidebar,window)
    }
    private func cell(_ tab:Tab,in sidebar:SidebarViewController) throws -> TabRowView {
        try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? TabRowView }
            .first { $0.textField?.stringValue == tab.displayTitle })
    }
    private func send(_ count:Int,to row:TabRowView,at point:NSPoint? = nil,
                      modifiers:NSEvent.ModifierFlags = [],type:NSEvent.EventType = .leftMouseDown,fallback:NSResponder? = nil) throws {
        let rect = row.nameEditorFrame(in:row)
        let location = row.convert(point ?? NSPoint(x:rect.midX,y:rect.midY),to:nil)
        let window = try #require(row.window)
        let content = try #require(window.contentView)
        let receiver = try #require(content.hitTest(content.convert(location,from:nil)))
        #expect(receiver === row, "The native hierarchy must route this point to its configured tab cell")
        let event = try #require(NSEvent.mouseEvent(with:type,location:location,modifierFlags:modifiers,
            timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:1))
        // Keep the fallback from entering NSTableView's mouse-tracking loop.
        // The actual configured cell receives its native event and retains its
        // real window, model callbacks, geometry and editor host.
        let responder = row.nextResponder;row.nextResponder = fallback
        defer { row.nextResponder = responder }
        receiver.mouseDown(with:event)
    }
    private func editor(in sidebar:SidebarViewController) -> FolderNameEditor? {
        UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? FolderNameEditor }.first
    }

    @Test("Double-clicking a Today or Pinned title opens the inline editor",arguments:[false,true])
    func titleGesture(retained:Bool) async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url:URL(string:"https://double-name.invalid/page")!)
        tab.setKeepsInSidebar(retained);session.rename(tab,to:"Current name")
        let (sidebar,window) = host(session);defer { window.close() }
        let row = try cell(tab,in:sidebar)
        let pages = session.activeSpace.tabs.map(\.id),url = tab.url
        try send(2,to:row)
        let field = try #require(editor(in:sidebar))
        #expect(field.stringValue == "Current name" && field.accessibilityLabel() == "Tab name")
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        let text = try #require(field.currentEditor() as? NSTextView)
        #expect(text.selectedRange() == NSRange(location:0,length:"Current name".utf16.count))
        text.string = "  Saved by double-click  ";field.commit()
        #expect(tab.customName == "Saved by double-click" && field.superview == nil)
        #expect(session.activeSpace.tabs.map(\.id) == pages && tab.url == url)
        #expect(window.attachedSheet == nil && tab.currentWebView == nil)
    }

    @Test("Single, triple and modified title presses keep their normal responder path",
          arguments:[0,1,2,3,4,5,6])
    func otherPresses(_ variant:Int) throws {
        let session = TestSession.make().0
        let tab = session.newTab(url:URL(string:"https://double-name.invalid/other")!)
        let (sidebar,window) = host(session);defer { window.close() }
        let row = try cell(tab,in:sidebar),probe = ResponderProbe()
        let flags:[NSEvent.ModifierFlags] = [[],[],.command,.option,.shift,.control,[]]
        let count = variant == 0 ? 1:(variant == 1 ? 3:2)
        let type:NSEvent.EventType = variant == 6 ? .rightMouseDown:.leftMouseDown
        try send(count,to:row,modifiers:flags[variant],type:type,fallback:probe)
        #expect(editor(in:sidebar) == nil && probe.presses == 1)
    }

    @Test("The favicon and the outer gutter do not start a title edit",arguments:[false,true])
    func outsideTitle(favicon:Bool) throws {
        let session = TestSession.make().0
        let tab = session.newTab(url:URL(string:"https://double-name.invalid/icon")!)
        tab.setKeepsInSidebar(true)
        let (sidebar,window) = host(session);defer { window.close() }
        let row = try cell(tab,in:sidebar),probe = ResponderProbe()
        let point = favicon ? NSPoint(x:row.favicon.frame.midX,y:row.favicon.frame.midY):NSPoint(x:1,y:row.bounds.midY)
        try send(2,to:row,at:point,fallback:probe)
        #expect(editor(in:sidebar) == nil && probe.presses == 1 && tab.customName == nil)
    }

    @Test("Nested title editing uses the same field geometry and Escape cancels")
    func nestedTitle() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url:URL(string:"https://double-name.invalid/nested")!)
        session.rename(tab,to:"Nested name")
        let parent = session.createGroup(named:"Parent")
        _ = session.createGroup(named:"Child",containing:[tab],parent:parent)
        let (sidebar,window) = host(session);defer { window.close() }
        let row = try cell(tab,in:sidebar)
        let rect = row.nameEditorFrame(in:sidebar.view)
        try send(2,to:row,modifiers:.capsLock)
        let field = try #require(editor(in:sidebar))
        #expect(abs(field.frame.minX-rect.minX)<0.01 && abs(field.frame.minY-rect.minY)<0.01)
        #expect(field.frame.width>20 && field.frame.maxX<=sidebar.view.bounds.maxX)
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        if let text = field.currentEditor() { text.string = "Discard" } else { field.stringValue = "Discard" }
        field.cancel()
        #expect(tab.customName == "Nested name" && field.superview == nil)
    }

    @Test("A stale row cannot switch Spaces or rename a removed page")
    func staleOwnership() throws {
        let session = TestSession.make().0,owner = session.activeSpace
        let tab = session.newTab(url:URL(string:"https://double-name.invalid/stale")!)
        let (sidebar,window) = host(session);defer { window.close() }
        let row = try cell(tab,in:sidebar)
        let action = try #require(row.onRename)
        let other = session.addSpace(named:"Other")
        action()
        #expect(session.activeSpace === other && editor(in:sidebar) == nil)
        session.selectSpace(owner);session.closeTab(tab);action()
        #expect(editor(in:sidebar) == nil && tab.customName == nil)
    }

    @Test("Recycling the row drops its previous name action and editing state")
    func recycled() {
        let row = TabRowView()
        row.onRename = { };row.isEditingName = true
        row.prepareForReuse()
        #expect(row.onRename == nil && !row.isEditingName)
    }
}
