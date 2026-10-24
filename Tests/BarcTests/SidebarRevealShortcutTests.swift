// Modified for Barc: Arc's dock/edge-reveal transition and lock button behavior, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar dock and edge reveal", .serialized)
@MainActor
struct SidebarRevealShortcutTests {
    @Test("Hide uses edge reveal and the floating lock button restores the same docked width")
    func hideRevealAndLock() throws {
        _ = NSApplication.shared
        let settings = Settings.shared
        let originalMode = settings.sidebarMode
        let originalPosition = settings.sidebarPosition
        let originalConfig = settings.compactModeConfiguration
        defer {
            settings.compactModeConfiguration = originalConfig
            settings.sidebarPosition = originalPosition
            settings.sidebarMode = originalMode
        }
        settings.sidebarPosition = .leading
        settings.sidebarMode = .expanded
        let session = TestSession.make().0
        let tab = session.activeTab
        let count = session.activeSpace.tabs.count
        let controller = BrowserWindowController(session: session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil; window.close() }
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        let width = controller.restingSidebarWidth
        let bar = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? ContentTopBar }.first)
        let addressParent = bar.addressField.superview
        #expect(bar.sidebarToggle.accessibilityLabel() == "Hide sidebar")
        let menuItem = NSMenuItem(title: "Hide Sidebar", action: #selector(BrowserWindowController.toggleBarcSidebar(_:)), keyEquivalent: "s")
        controller.toggleBarcSidebar(nil)
        root.layoutSubtreeIfNeeded()
        #expect(settings.sidebarMode == .compact && settings.compactModeEnabled)
        let overlay = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? CompactSidebarOverlay }.first)
        #expect(!overlay.isHidden)
        #expect(controller.validateMenuItem(menuItem) && menuItem.title == "Show Sidebar")
        #expect(bar.sidebarToggle.accessibilityLabel() == "Lock sidebar")
        #expect(bar.addressField.superview === addressParent, "Navigation remains in the sidebar")
        // Reveal it explicitly, then use the button a hovering user sees.
        controller.toggleCompactSidebarPin(nil)
        root.layoutSubtreeIfNeeded()
        bar.sidebarToggle.performClick(nil)
        root.layoutSubtreeIfNeeded()
        #expect(settings.sidebarMode == .expanded && !settings.compactModeEnabled)
        #expect(overlay.isHidden)
        #expect(abs(controller.restingSidebarWidth - width) < 1)
        #expect(controller.validateMenuItem(menuItem) && menuItem.title == "Hide Sidebar")
        #expect(bar.sidebarToggle.accessibilityLabel() == "Hide sidebar")
        #expect(session.activeTab === tab && session.activeSpace.tabs.count == count)
        #expect(session.archivedTabs.isEmpty)
    }
}

@Suite("First edge hover", .serialized)
@MainActor
struct FirstSidebarEdgeHoverTests {
    private final class Slot: CompactSidebarSlot {
        let restingSidebarWidth: CGFloat = 298
        var pointerIsOnSidebarRevealEdge = false
        let sidebar = NSViewController()
        init() { sidebar.view = NSView(frame: NSRect(x: 0, y: 0, width: 298, height: 700)) }
        func detachSidebar() -> NSViewController { sidebar }
        func reattachSidebar(_ controller: NSViewController) {}
    }
    private func chrome(_ slot: Slot) -> (CompactChrome, NSView) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        return (CompactChrome(slot: slot, contentView: content, toolbarView: nil,
                              toolbarTopConstraint: nil, window: nil), content)
    }
    @Test("Command-S from the page leaves the first genuine edge entry available")
    func firstHoverFromPage() {
        let slot = Slot()
        let (chrome, content) = chrome(slot)
        withExtendedLifetime(content) {
            chrome.setEnabled(true, animated: false)
            #expect(!chrome.controller.state.sidebarIsRevealed)
            chrome.controller.hoverBegan(on: .sidebar)
            #expect(chrome.controller.state.sidebarIsRevealed)
        }
    }
    @Test("A pointer already on the edge suppresses the synthetic enter, then reveals on reentry")
    func syntheticEnter() {
        let slot = Slot(); slot.pointerIsOnSidebarRevealEdge = true
        let (chrome, content) = chrome(slot)
        withExtendedLifetime(content) {
            chrome.setEnabled(true, animated: false)
            chrome.controller.hoverBegan(on: .sidebar)
            #expect(!chrome.controller.state.sidebarIsRevealed)
            chrome.controller.hoverEnded(on: .sidebar)
            chrome.controller.hoverBegan(on: .sidebar)
            #expect(chrome.controller.state.sidebarIsRevealed)
        }
    }
    @Test("A drag entering a hidden sidebar is never discarded as a synthetic mouse enter")
    func firstDrag() {
        let slot = Slot(); slot.pointerIsOnSidebarRevealEdge = true
        let (chrome, content) = chrome(slot)
        withExtendedLifetime(content) {
            chrome.setEnabled(true, animated: false)
            chrome.controller.hoverBegan(on: .sidebar, isDrag: true)
            #expect(chrome.controller.state.sidebarIsRevealed)
            #expect(chrome.controller.state.sidebarReasons.contains(.dragHover))
        }
    }
}
