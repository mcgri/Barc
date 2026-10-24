// Modified for Barc: transient split selection, cancellation and profile isolation, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Split pane chooser", .serialized)
@MainActor
struct SplitChooserTests {
    private func url(_ path: String) -> URL { URL(string: "https://split-fixture.invalid/\(path)")! }
    private func bar(_ controller: BrowserWindowController) throws -> CommandBar {
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        return try #require(UITestSupport.descendants(of: root).compactMap { $0 as? CommandBar }.first)
    }
    private func empty(_ controller: BrowserWindowController) -> NSView? {
        guard let root = controller.window?.contentView else { return nil }
        return UITestSupport.descendants(of: root).first { $0.accessibilityLabel() == "Empty split pane" }
    }
    private func cleanup(_ controller: BrowserWindowController) {
        controller.window?.delegate = nil; controller.window?.close()
    }

    @Test("Opening and Escape show then remove an empty pane without adding a tab or saved layout")
    func previewAndCancel() throws {
        _ = NSApplication.shared
        let (session, store) = TestSession.make()
        let source = session.newTab(url: url("source"))
        let partner = session.newTab(url: url("partner"), select: false)
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        let count = session.allTabs.count
        controller.splitSideBySide(nil)
        let command = try bar(controller)
        #expect(command.isOpen && command.isSplitMode && command.isNewTabMode)
        #expect(empty(controller) != nil && session.activeSplit == nil && !session.canUndoSplit)
        let emptyPane = try #require(empty(controller)?.superview as? SplitPaneView)
        #expect(!emptyPane.isFocused)
        #expect(NSColor(cgColor:try #require(emptyPane.layer?.borderColor))?.alphaComponent == 0)
        #expect(session.allTabs.count == count && session.activeTab === source)
        #expect(command.results.contains { $0.action == .switchToTab(partner.id) })
        #expect(!command.results.contains { $0.action == .switchToTab(source.id) })
        let root = try #require(controller.window?.contentView)
        let panel = try #require(UITestSupport.descendants(of: command).compactMap { $0 as? CommandPanelView }.first)
        let panelFrame = panel.convert(panel.bounds, to: root)
        #expect(panelFrame.midX > root.bounds.midX, "panel \(panelFrame), empty \(empty(controller)?.convert(empty(controller)!.bounds, to: root) ?? .zero), root \(root.bounds)")
        #expect(panelFrame.maxX <= root.bounds.maxX - 79)
        #expect(abs(panelFrame.midY - root.bounds.midY - 10) < 0.5)
        session.saveNow()
        #expect(try store.load()?.spaces[0].tabs.count == count)
        command.cancelOperation(nil)
        #expect(!command.isOpen && empty(controller) == nil)
        #expect(session.activeSplit == nil && session.activeTab === source && session.allTabs.count == count)
        #expect(source.url == url("source") && partner.url == url("partner"))
    }

    @Test("The chooser can reuse an existing tab without changing either URL or creating a duplicate")
    func chooseExisting() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let source = session.newTab(url: url("source"))
        let partner = session.newTab(url: url("partner"), select: false)
        let count = session.allTabs.count
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        controller.splitSideBySide(nil)
        let command = try bar(controller)
        command.setResults([CommandResult(id: "partner", kind: .openTab, title: "Partner", subtitle: "Switch to Tab",
            symbolName: "globe", action: .switchToTab(partner.id), score: 0)])
        command.select(0); command.submit()
        #expect(!command.isOpen && empty(controller) == nil)
        #expect(session.activeSplit?.tabIDs == [source.id, partner.id] && session.activeTab === partner)
        #expect(session.allTabs.count == count && source.url == url("source") && partner.url == url("partner"))
    }

    @Test("A typed URL creates only the chosen page in the source profile and arrangement")
    func chooseNewPage() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let owner = session.addSpace(named: "Work")
        let source = session.newTab(url: url("source"))
        let count = session.allTabs.count
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        controller.splitStacked(nil)
        let command = try bar(controller)
        let root = try #require(controller.window?.contentView)
        let panel = try #require(UITestSupport.descendants(of:command).compactMap { $0 as? CommandPanelView }.first)
        let pane = try #require(empty(controller)?.superview)
        let panelRect = panel.convert(panel.bounds,to:root), paneRect = pane.convert(pane.bounds,to:root)
        #expect(abs(panelRect.midY - paneRect.midY - 10) < 0.5)
        let field = try #require(UITestSupport.descendants(of: command).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        command.setResults([])
        field.stringValue = url("chosen").absoluteString
        command.submit()
        let chosen = try #require(session.activeTab)
        #expect(chosen !== source && chosen.url == url("chosen") && chosen.identity == owner.identity)
        #expect(session.activeSplit?.grid == .stacked && session.activeSplit?.tabIDs == [source.id, chosen.id])
        #expect(session.allTabs.count == count + 1 && source.url == url("source"))
        #expect(!chosen.isSidebarRetained && chosen.pinnedSiteID == nil && empty(controller) == nil)
    }

    @Test("Command-W cancels the unfinished pane instead of closing the source")
    func closePreview() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let source = session.activeTab
        let count = session.allTabs.count
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        controller.splitSideBySide(nil)
        #expect(try bar(controller).isOpen)
        controller.closeTab(nil)
        #expect(try !bar(controller).isOpen)
        #expect(session.allTabs.count == count && session.activeTab === source && session.activeSplit == nil)
        #expect(session.recentClosedTabs.isEmpty && empty(controller) == nil)
    }

    @Test("An existing split stays unchanged on cancellation; the pane limit disables another chooser")
    func existingAndLimit() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let a = session.newTab(url: url("a")), b = session.newTab(url: url("b"))
        #expect(session.splitTabs([a,b], grid: .sideBySide))
        let original = session.activeSplit
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        controller.splitSideBySide(nil)
        let command = try bar(controller)
        #expect(command.isOpen && empty(controller) != nil)
        #expect(session.activeSplit == original, "Before: \(String(describing: original)); after preview: \(String(describing: session.activeSplit))")
        let selected = session.activeTab
        let other = selected === a ? b : a
        let root = try #require(controller.window?.contentView)
        let container = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? SplitContainerView }.first)
        container.onFocusPane?(other.id)
        #expect(session.activeTab === selected && command.isOpen, "The chooser owns clicks over the underlying pages")
        command.cancelOperation(nil)
        #expect(session.activeSplit == original, "After cancel: \(String(describing: session.activeSplit))")
        #expect(empty(controller) == nil)
        container.onFocusPane?(other.id)
        #expect(session.activeTab === other)
        let c = session.newTab(url: url("c")), d = session.newTab(url: url("d"))
        session.splitTabs([a,b,c,d])
        let menu = NSMenuItem(title: "Split", action: #selector(BrowserWindowController.splitSideBySide(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(menu))
        controller.splitSideBySide(nil)
        #expect(!command.isOpen && session.activeSplit?.tabIDs.count == 4)
    }

    @Test("Changing Space or starting an ordinary New Tab dismisses a stale preview")
    func changeContext() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        session.newTab(url: url("source"))
        let controller = BrowserWindowController(session: session)
        defer { cleanup(controller) }
        controller.splitSideBySide(nil)
        let command = try bar(controller)
        let other = session.addSpace(named: "Personal")
        #expect(!command.isOpen && empty(controller) == nil && session.activeSpace === other)
        controller.splitSideBySide(nil)
        #expect(command.isOpen)
        controller.newTab(nil)
        #expect(command.isOpen && !command.isSplitMode && empty(controller) == nil)
        command.cancelOperation(nil)
        #expect(session.activeSplit == nil)
    }
}
