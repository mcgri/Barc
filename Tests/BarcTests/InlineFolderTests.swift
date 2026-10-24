import AppKit
import Testing
@testable import Barc

@Suite("Inline sidebar folder naming", .serialized)
@MainActor
struct InlineFolderTests {
    private func host(_ session: BrowserSession) -> (SidebarViewController, NSWindow) {
        let sidebar = SidebarViewController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        window.contentView?.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    private func editor(_ sidebar: SidebarViewController) throws -> FolderNameEditor {
        try #require(UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? FolderNameEditor }.first)
    }

    private func type(_ name: String, into field: FolderNameEditor) {
        if let text = field.currentEditor() { text.string = name }
        else { field.stringValue = name }
    }

    @Test("New Folder appears directly above New Tab with its name selected, without a sheet")
    func newFolder() throws {
        let session = TestSession.make().0
        let (sidebar, window) = host(session); defer { window.close() }
        let tab = session.activeTab
        try perform("New Folder", in: sidebar.makeAddMenu())
        let field = try editor(sidebar)
        let folder = try #require(session.activeSpace.groups.last)
        #expect(folder.name == "Untitled")
        #expect(field.stringValue == "Untitled" && field.placeholderString == "Folder Title")
        #expect(field.accessibilityLabel() == "Folder name")
        #expect(window.attachedSheet == nil && (sidebar.presentedViewControllers?.isEmpty ?? true))
        let text = try #require(field.currentEditor() as? NSTextView)
        #expect(text.selectedRange() == NSRange(location: 0, length: "Untitled".utf16.count))
        #expect(session.activeTab === tab)
        #expect(field.superview === sidebar.tabListTableView)
        #expect(field.frame.width > 60 && field.frame.maxX <= sidebar.tabListTableView.bounds.maxX)
        let row = sidebar.tabListTableView.row(at: NSPoint(x: field.frame.midX, y: field.frame.midY))
        let next = sidebar.tabListTableView.view(atColumn: 0, row: row + 1, makeIfNecessary: true)
        #expect(next.map { UITestSupport.accessibilityLabels(in: $0).contains("New Tab") } == true)
        type("Client research", into: field)
        #expect(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(folder.name == "Client research")
        #expect(field.superview == nil)
    }

    @Test("Rename edits the row, Escape preserves its name and Return trims the new title")
    func renameAndCancel() throws {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let first = try editor(sidebar)
        type("Discard this", into: first)
        #expect(first.control(first, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(folder.name == "Original" && first.superview == nil)
        // The late field-editor end notification must not turn Escape into a save.
        first.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(folder.name == "Original")
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let second = try editor(sidebar)
        type("  Project notes  ", into: second)
        second.commit()
        #expect(folder.name == "Project notes")
        #expect(session.activeSpace.groups.count == 1)
    }

    @Test("Clicking elsewhere commits the name once and empty input keeps the old title")
    func blurAndEmptyName() throws {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let field = try editor(sidebar)
        type("Saved on blur", into: field)
        #expect(window.makeFirstResponder(sidebar.tabListTableView))
        #expect(folder.name == "Saved on blur")
        type("Late notification", into: field); field.commit()
        #expect(folder.name == "Saved on blur")
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let empty = try editor(sidebar); type("   ", into: empty); empty.commit()
        #expect(folder.name == "Saved on blur")
        #expect(empty.superview == nil)
    }

    @Test("Unrelated row rebuilds keep the same editor and the name being typed")
    func survivesRebuild() throws {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let field = try editor(sidebar)
        type("Still typing", into: field)
        _ = session.createGroup(named: "Another folder")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(try editor(sidebar) === field)
        #expect((field.currentEditor()?.string ?? field.stringValue) == "Still typing")
        field.commit()
        #expect(folder.name == "Still typing")
    }

    @Test("A nested folder opens its parent and editing never reparents existing tabs")
    func nestedFolder() throws {
        let session = TestSession.make().0
        let parent = session.createGroup(named: "Parent")
        session.toggleCollapsed(parent)
        let page = session.newTab(url: URL(string: "https://folder-fixture.invalid/")!)
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("New Nested Folder…", in: sidebar.makeGroupMenu(for: parent))
        let child = try #require(session.activeSpace.groups.last)
        #expect(child !== parent && child.parentID == parent.id)
        #expect(!parent.isCollapsed && page.groupID == nil)
        let field = try editor(sidebar)
        type("Nested", into: field); field.commit()
        #expect(child.name == "Nested")
    }

    @Test("A Space switch saves to the folder's owning Space, never the newly selected one")
    func switchSpace() throws {
        let session = TestSession.make().0
        let original = session.activeSpace
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let field = try editor(sidebar); type("Saved in original", into: field)
        let other = session.addSpace(named: "Other")
        #expect(folder.name == "Saved in original")
        #expect(original.groups.first === folder && other.groups.isEmpty)
        #expect(field.superview == nil)
    }

    @Test("A removed folder cannot be renamed by an outstanding editor callback")
    func removalDuringEdit() throws {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let field = try editor(sidebar); type("Must not return", into: field)
        session.removeGroup(folder)
        field.commit()
        #expect(session.activeSpace.groups.isEmpty && folder.name == "Original")
        #expect(field.superview == nil)
    }

    @Test("Creating a folder with selected tabs uses the same inline editor")
    func foldersWithTabs() throws {
        let session = TestSession.make().0
        let a = session.newTab(url: URL(string: "https://folder-fixture.invalid/a")!)
        let b = session.newTab(url: URL(string: "https://folder-fixture.invalid/b")!)
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("New Folder with Tab", in: sidebar.makeTabMenu(for: a))
        let first = try #require(a.groupID.flatMap { session.activeSpace.group(withID: $0) })
        let field = try editor(sidebar); type("First", into: field); field.commit()
        #expect(first.name == "First" && b.groupID == nil)
        try perform("New Folder with 2 Tabs", in: sidebar.makeMultiTabMenu(for: [a, b]))
        let second = try #require(b.groupID.flatMap { session.activeSpace.group(withID: $0) })
        #expect(second !== first && a.groupID == second.id)
        let other = try editor(sidebar); type("Together", into: other); other.commit()
        #expect(second.name == "Together" && window.attachedSheet == nil)
    }

    @Test("Folding an edited child's parent ends the edit instead of leaving a field over another row")
    func collapseDuringEdit() throws {
        let session = TestSession.make().0
        let parent = session.createGroup(named: "Parent")
        let child = session.createGroup(named: "Child", parent: parent)
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: child))
        let field = try editor(sidebar); type("Saved before folding", into: field)
        session.toggleCollapsed(parent)
        #expect(child.name == "Saved before folding" && field.superview == nil)
    }

    @Test("Opening the Library commits the edit and resizing keeps the field inside the row")
    func layoutAndLibrary() throws {
        let session = TestSession.make().0
        let folder = session.createGroup(named: "Original")
        let (sidebar, window) = host(session); defer { window.close() }
        try perform("Rename…", in: sidebar.makeGroupMenu(for: folder))
        let field = try editor(sidebar); type("Before Library", into: field)
        window.setContentSize(NSSize(width: 190, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(field.frame.width > 40 && field.frame.maxX <= sidebar.tabListTableView.bounds.maxX)
        sidebar.showLibrary(category: .spaces)
        #expect(folder.name == "Before Library" && field.superview == nil)
    }
}
