// Modified for Barc: Arc's inline tab rename commit, cancel and ownership rules, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Inline sidebar tab naming", .serialized)
@MainActor
struct InlineTabNamingTests {
    private func host(_ session: BrowserSession) -> (SidebarViewController, NSWindow) {
        _ = NSApplication.shared
        let sidebar = SidebarViewController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = UITestSupport.host(sidebar.view, width: 228, height: 800)
        sidebar.view.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        window.contentView = content
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        return (sidebar, window)
    }
    private func rename(_ tab: Tab, in sidebar: SidebarViewController) async throws -> FolderNameEditor {
        let item = try #require(sidebar.makeTabMenu(for: tab).items.first { $0.title == "Rename…" })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        return try #require(UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? FolderNameEditor }.first)
    }
    private func type(_ value: String, into field: FolderNameEditor) {
        if let text = field.currentEditor() { text.string = value }
        else { field.stringValue = value }
    }
    @Test("Rename edits and selects the current title in its row; Escape cancels and Return saves")
    func commitAndCancel() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "https://tab-fixture.invalid/title")!)
        session.rename(tab, to: "Current name")
        let (sidebar, window) = host(session); defer { window.close() }
        let field = try await rename(tab, in: sidebar)
        #expect(field.accessibilityLabel() == "Tab name" && field.stringValue == "Current name")
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        #expect(field.frame.width > 50 && field.frame.maxX <= sidebar.view.bounds.maxX)
        #expect(window.attachedSheet == nil)
        let text = try #require(field.currentEditor() as? NSTextView)
        #expect(text.selectedRange() == NSRange(location: 0, length: "Current name".utf16.count))
        type("Discard", into: field)
        field.cancel()
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(tab.customName == "Current name" && field.superview == nil)
        let second = try await rename(tab, in: sidebar)
        type("  Saved name  ", into: second)
        second.commit()
        #expect(tab.customName == "Saved name" && second.superview == nil)
        let clearing = try await rename(tab, in: sidebar)
        type("", into: clearing); clearing.commit()
        #expect(tab.customName == nil)
    }
    @Test("Leaving a Space commits its tab's editor and removing the tab rejects a late save")
    func ownerAndRemoval() async throws {
        let session = TestSession.make().0
        let owner = session.activeSpace
        let tab = session.newTab(url: URL(string: "https://tab-fixture.invalid/owner")!)
        let (sidebar, window) = host(session); defer { window.close() }
        let field = try await rename(tab, in: sidebar)
        type("Original Space title", into: field)
        let other = session.addSpace(named: "Other")
        #expect(tab.customName == "Original Space title" && field.superview == nil)
        #expect(owner.tabs.contains { $0 === tab } && !other.tabs.contains { $0 === tab })
        session.selectSpace(owner)
        let late = try await rename(tab, in: sidebar)
        type("Must not revive", into: late)
        session.closeTab(tab)
        late.commit()
        #expect(late.superview == nil && !owner.tabs.contains { $0 === tab })
    }
}
