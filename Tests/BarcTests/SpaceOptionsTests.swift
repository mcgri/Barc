import AppKit
import Testing
@testable import Barc

@Suite("Space menu targets and inline names")
@MainActor
struct SpaceOptionsTests {
    private func field(in button: MenuLabelButton) throws -> NSTextField {
        try #require(UITestSupport.descendants(of: button).compactMap { $0 as? NSTextField }.first)
    }

    private func header(_ title: String = "Work", id: UUID = UUID()) -> MenuLabelButton {
        let button = MenuLabelButton()
        button.show(title: title, icon: nil, accessibilityLabel: "Space", tooltip: nil, identity: id)
        return button
    }

    @Test("Return commits a trimmed name once even when AppKit subsequently ends field editing")
    func returnCommitsOnce() throws {
        let button = header()
        var names: [String] = []
        button.beginRenaming { names.append($0) }
        let editor = try field(in: button)
        editor.stringValue = "  Studio  "
        #expect(editor.isEditable)
        #expect(button.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        button.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(names == ["Studio"])
        #expect(!button.isRenaming)
        #expect(!editor.isEditable)
    }

    @Test("Escape restores the original name and never commits the discarded edit")
    func escapeCancels() throws {
        let button = header()
        var names: [String] = []
        button.beginRenaming { names.append($0) }
        let editor = try field(in: button)
        editor.stringValue = "Discard this"
        #expect(button.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        button.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(names.isEmpty)
        #expect(editor.stringValue == "Work")
        #expect(!button.isRenaming)
    }

    @Test("Clicking elsewhere commits; an empty name restores the old one")
    func endingAndEmpty() throws {
        for raw in ["New name", "  "] {
            let button = header()
            var names: [String] = []
            button.beginRenaming { names.append($0) }
            let editor = try field(in: button)
            editor.stringValue = raw
            button.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            #expect(names == (raw == "New name" ? [raw] : []))
            #expect(editor.stringValue == (raw == "New name" ? raw : "Work"))
        }
    }

    @Test("A reload keeps a pending edit, but a switch to another Space cancels it")
    func identityNotDisplayName() throws {
        let first = UUID(), second = UUID()
        let button = header(id: first)
        var names: [String] = []
        button.beginRenaming { names.append($0) }
        let editor = try field(in: button)
        editor.stringValue = "Unfinished"
        button.show(title: "Work", icon: nil, accessibilityLabel: "Space", tooltip: nil, identity: first)
        #expect(editor.stringValue == "Unfinished")
        button.show(title: "Work", icon: nil, accessibilityLabel: "Space", tooltip: nil, identity: second)
        #expect(!button.isRenaming)
        #expect(names.isEmpty, "Even equal display names must not transfer an edit between identities")
        #expect(editor.stringValue == "Work")
    }

    @Test("The Done control remains reachable without moving the name or widening the sidebar")
    func stableHeaderWhileEditing() throws {
        let name = header("A long Space title here")
        let identity = SidebarSpaceIdentityView(nameButton: name)
        let host = UITestSupport.host(identity, width: 228, height: 32)
        host.layoutSubtreeIfNeeded()
        let frame = name.frame
        let width = host.fittingSize.width
        #expect(identity.moreButton.alphaValue == 0)
        name.beginRenaming { _ in }
        try field(in: name).stringValue = "Another long Space name"
        host.layoutSubtreeIfNeeded()
        #expect(identity.moreButton.alphaValue == 1)
        #expect(identity.moreButton.accessibilityLabel() == "Done")
        #expect(name.frame == frame)
        #expect(host.fittingSize.width <= width + 0.5)
        identity.moreButton.performClick(nil)
        #expect(!name.isRenaming)
        #expect(identity.moreButton.accessibilityLabel() == "Space Options")
    }

    @Test("Menu targets survive after construction and dispatch the actual selected action")
    func retainedMenuActions() throws {
        _ = NSApplication.shared
        var actions: [SpaceOptionsMenu.Action] = []
        let menu = SpaceOptionsMenu.make(canDelete: false, hasGitHubFolder: false) { actions.append($0) }
        let rename = try #require(menu.items.first { $0.title == "Rename Space…" })
        #expect(NSApp.sendAction(try #require(rename.action), to: rename.target, from: rename))
        #expect(actions == [.rename])
        #expect(menu.items.first { $0.title == "Delete Space" }?.isEnabled == false)
    }

    @Test("A dock menu for an inactive Space edits that Space, never the current one")
    func inactiveSpaceTarget() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let first = session.activeSpace
        let other = session.addSpace(named: "Other")
        session.selectSpace(first)
        let sidebar = SidebarViewController(session: session)
        _ = sidebar.view
        let menu = sidebar.makeSpaceOptionsMenu(for: other, anchor: sidebar.view)
        let rename = try #require(menu.items.first { $0.title == "Rename Space…" })
        #expect(NSApp.sendAction(try #require(rename.action), to: rename.target, from: rename))
        #expect(session.activeSpace === other)
        #expect(first.name != "Other")
    }
}
