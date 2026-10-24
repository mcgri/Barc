// Modified for Barc: transient New Tab recents and whole-window placement, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("New Tab launcher", .serialized)
@MainActor
struct NewTabLauncherTests {
    private func result(_ id: UUID = UUID()) -> CommandResult {
        .init(id: "tab:\(id)", kind: .openTab, title: "Research", subtitle: "example.invalid/research",
              symbolName: "globe", action: .switchToTab(id), score: 0)
    }

    @Test("New Tab centres over the whole window, keeps recent rows, and fits a narrow window")
    func placement() throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        let hostWidth = host.widthAnchor.constraint(equalToConstant: 1400)
        NSLayoutConstraint.activate([hostWidth, host.heightAnchor.constraint(equalToConstant: 900)])
        let page = NSView(frame: NSRect(x: 298, y: 0, width: 1102, height: 900))
        host.addSubview(page)
        let command = CommandBar(); command.install(in: host, centeredIn: page)
        let recent = (0..<7).map { _ in result() }
        for width: CGFloat in [1400, 780] {
            hostWidth.constant = width
            host.setFrameSize(NSSize(width: width, height: 900))
            page.setFrameSize(NSSize(width: width - 298, height: 900))
            command.openNewTab(recentResults: recent)
            host.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
            let panel = try #require(UITestSupport.descendants(of: command).compactMap { $0 as? CommandPanelView }.first)
            let rect = panel.convert(panel.bounds, to: host)
            #expect(abs(rect.midX - host.bounds.midX) < 0.5, "root \(host.frame), bar \(command.frame), page \(page.frame), panel \(rect)")
            #expect(abs(rect.midY - host.bounds.midY - 5) < 0.5)
            #expect(abs(rect.width - min(765, width - 96)) < 0.5)
            #expect(host.bounds.contains(rect))
            #expect(command.visibleResults == Array(recent.prefix(4)) && command.selectedIndex == 0)
            #expect(command.isNewTabMode && !command.isSplitMode && !command.isAddressMode)
            let rows = UITestSupport.descendants(of: command).compactMap { $0 as? CommandRowView }
            #expect(rows.count == 4 && rows.allSatisfy { abs($0.frame.height - 46) < 0.5 })
            #expect(rows.allSatisfy { $0.accessibilityLabel() == "Research, Switch to Tab" })
            command.close()
        }
    }

    @Test("Typing cannot run the stale recent selection, and clearing restores it immediately")
    func clearAndSubmit() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let command = CommandBar(); command.install(in: try #require(window.contentView))
        let recent = [result()]
        command.openNewTab(recentResults: recent)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("replacement.invalid/path", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(command.selectedIndex == nil && command.visibleResults.isEmpty)
        editor.selectAll(nil); editor.deleteBackward(nil)
        #expect(command.queryText.isEmpty && command.visibleResults == Array(recent.prefix(4)) && command.selectedIndex == 0)
        editor.insertText("replacement.invalid/path", replacementRange: NSRange(location: NSNotFound, length: 0))
        var action: CommandAction?, newTab = false
        command.onRun = { action = $0; newTab = $1 }
        command.submit()
        #expect(action == .openURL(URL(string: "https://replacement.invalid/path")!) && newTab)
        #expect(!command.isOpen)
    }

    @Test("Opening and cancelling never adds a tab; choosing a recent page reuses it")
    func sessionContract() throws {
        _ = NSApplication.shared
        let oldSetting = Settings.shared.openCommandBarOnNewTab
        let oldSources = Settings.shared.suggestionSources
        Settings.shared.openCommandBarOnNewTab = true
        var sources = oldSources; sources.openTabs = true
        Settings.shared.suggestionSources = sources
        defer {
            Settings.shared.openCommandBarOnNewTab = oldSetting
            Settings.shared.suggestionSources = oldSources
        }
        let session = TestSession.make().0
        let originalSpace = session.activeSpace
        let a = session.newTab(url: URL(string: "https://launcher-fixture.invalid/a")!)
        session.addSpace(named: "Other work")
        let other = session.newTab(url: URL(string: "https://launcher-fixture.invalid/other")!)
        session.selectSpace(originalSpace)
        let b = session.newTab(url: URL(string: "https://launcher-fixture.invalid/b")!)
        let controller = BrowserWindowController(session: session)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let command = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? CommandBar }.first)
        let before = session.allTabs.map(\.id), layout = session.activeSplit
        controller.newTab(nil)
        #expect(command.isOpen && command.selectedIndex == 0)
        #expect(command.results.contains { $0.action == .switchToTab(a.id) })
        #expect(!command.results.contains { $0.action == .switchToTab(b.id) })
        #expect(command.results.contains { $0.action == .switchToTab(other.id) })
        command.cancelOperation(nil)
        #expect(session.allTabs.map(\.id) == before && session.activeTab === b && session.activeSplit == layout)
        controller.newTab(nil)
        command.select(try #require(command.visibleResults.firstIndex { $0.action == .switchToTab(other.id) }))
        command.submit()
        #expect(session.activeTab === other && session.allTabs.map(\.id) == before && session.activeSplit == layout)
        sources.openTabs = false; Settings.shared.suggestionSources = sources
        controller.newTab(nil)
        #expect(command.results.isEmpty && command.selectedIndex == nil)
        command.cancelOperation(nil)
        #expect(session.activeTab === other && session.allTabs.map(\.id) == before)
    }
}
