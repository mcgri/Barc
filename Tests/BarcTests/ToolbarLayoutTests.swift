// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Toolbar layout")
@MainActor
struct ToolbarLayoutTests {
    private let names = ["Shield", "Translate Page", "Reader Mode", "Share", "Page Menu"]

    @Test("The default layout keeps every button in its default order")
    func defaults() {
        let layout = ToolbarLayout.default
        #expect(layout.isDefault)
        #expect(layout.arrange(names, label: { $0 }) == names)
        #expect(layout.fullOrder() == ToolbarLayout.catalog.map(\.label))
    }

    @Test("Hidden buttons go, ordered ones lead, unknown ones keep their place")
    func arranging() {
        var layout = ToolbarLayout(order: ["Share", "Shield", "Long Gone"], hidden: ["Reader Mode", "Never Seen"])
        #expect(layout.arrange(names, label: { $0 }) == ["Share", "Shield", "Translate Page", "Page Menu"])
        layout.move("Page Menu", by: -1)
        #expect(layout.fullOrder().firstIndex(of: "Page Menu")! < layout.fullOrder().firstIndex(of: "Add Bookmark")!)
        layout.move("Shield", by: -5)
        #expect(layout.fullOrder().first == "Share", "moving past the start does nothing")
        layout.setHidden("Reader Mode", false)
        #expect(!layout.hidden.contains("Reader Mode"))
    }

    @Test("A layout persists, announces changes, and the default clears the stored value")
    func persistence() {
        let settings = Settings.shared
        let before = settings.toolbarLayout
        defer { settings.toolbarLayout = before }
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .toolbarLayoutDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        var layout = ToolbarLayout()
        layout.setHidden("Share", true)
        layout.move("Page Menu", by: -1)
        settings.toolbarLayout = layout
        #expect(settings.toolbarLayout == layout)
        settings.toolbarLayout = layout
        #expect(notified == 1, "the same layout again is not a change")
        settings.toolbarLayout = .default
        #expect(settings.toolbarLayout.isDefault)
        #expect(notified == 2)
    }

    @Test("Every catalog symbol exists")
    func symbols() {
        for entry in ToolbarLayout.catalog {
            #expect(NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil) != nil, "\(entry.label)")
        }
    }

    @Test("The top bar shows only what the layout allows")
    func topBar() {
        let bar = ContentTopBar()
        let actions = names.map { TopBarAction(symbolName: "circle", label: $0) {} }
        bar.setActions(ToolbarLayout(order: ["Share"], hidden: ["Shield"]).arrange(actions, label: \.label))
        #expect(bar.actionButton(labelled: "Share") != nil)
        #expect(bar.actionButton(labelled: "Shield") == nil)
        #expect(bar.actionButton(labelled: "Reader Mode") != nil)
    }

    @Test("Utilities live in one menu beside navigation, with working actions and visible popup anchors")
    func utilitiesMenu() throws {
        let bar = ContentTopBar()
        var selected: String?
        bar.setActions(names.map { name in
            TopBarAction(symbolName: "circle", label: name) { selected = name }
        })
        let host = UITestSupport.host(bar, width: 237, height: 200)
        host.layoutSubtreeIfNeeded()
        let controls = [bar.backButton, bar.forwardButton, bar.reloadButton, bar.utilitiesButton]
        let frames = controls.map { $0.convert($0.bounds, to: bar) }
        #expect(frames.allSatisfy { abs($0.midY - frames[0].midY) < 1 })
        #expect(bar.frame.height <= 70)
        let visibleLabels = UITestSupport.buttons(in: bar).compactMap { $0.accessibilityLabel() }
        #expect(visibleLabels.contains("Page Utilities"))
        #expect(!visibleLabels.contains(where: names.contains))
        #expect(names.allSatisfy { bar.actionAnchor(labelled: $0) === bar.utilitiesButton })

        let reader = try #require(bar.actionButton(labelled: "Reader Mode") as? IconButton)
        reader.isEnabled = false
        let shield = try #require(bar.actionButton(labelled: "Shield") as? IconButton)
        shield.isActive = true
        shield.setSymbol("checkmark.shield.fill", label: "Shield Enabled")
        let menu = bar.makeUtilitiesMenu()
        #expect(menu.items.map(\.title) == ["Shield Enabled", "Translate Page", "Reader Mode", "Share", "Page Menu"])
        #expect(menu.items[0].state == .on)
        #expect(!menu.items[2].isEnabled)
        #expect(menu.items.allSatisfy { $0.image != nil })
        let share = menu.items[3]
        _ = share.target?.perform(try #require(share.action), with: share)
        #expect(selected == "Share")
        #expect(bar.utilitiesButton.accessibilityLabel() == "Page Utilities")
    }

    @Test("Sidebar navigation follows the Arc reference while keeping utilities in the same row", arguments: [190.0, 214.0, 228.0, 300.0])
    func sidebarNavigation(width: Double) throws {
        let bar = ContentTopBar()
        // The Arc reference has no performance gauge beside the window controls.
        let settings = Settings(defaults: UserDefaults(suiteName: "toolbar-layout.\(UUID())")!)
        settings.showsTaskManagerInSidebar = false
        let sidebar = SidebarViewController(session: TestSession.make().0, settings: settings)
        sidebar.installBrowserControls([bar])
        let host = UITestSupport.host(sidebar.view, width: width, height: 800)
        host.layoutSubtreeIfNeeded()
        let controls = [bar.sidebarToggle, bar.utilitiesButton, bar.backButton, bar.forwardButton, bar.reloadButton]
        let frames = controls.map { $0.convert($0.bounds, to: sidebar.view) }
        #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width && abs($0.midY - frames[0].midY) < 0.5 })
        for pair in zip(frames, frames.dropFirst()) { #expect(pair.0.maxX <= pair.1.minX) }
        if width == 228 {
            // Artwork positions, separate from their larger hit targets.
            // SidebarHeaderReferenceTests also checks the painted pixels.
            for (button,center) in zip([bar.sidebarToggle,bar.backButton,bar.forwardButton,bar.reloadButton],[92.5,137,171,205]) {
                let glyph = try #require(UITestSupport.imageViews(in:button).first)
                #expect(abs(glyph.convert(glyph.bounds,to:sidebar.view).midX-center) <= 0.25)
            }
        }
    }

    @Test("Dragging a button several places takes it there, keeping the rest in order")
    func moveToAnAbsolutePlace() {
        // A swap would have been enough while the arrows were the only way to
        // reorder, because a swap and a move are the same thing one step at a
        // time. They are not the same over three: swapping the first with the
        // fourth puts the fourth one first and leaves the two between them
        // where they were, which is not what a drag showed you it would do.
        var layout = ToolbarLayout()
        let before = layout.fullOrder()
        let first = before[0]
        layout.move(first, to: 3)
        let after = layout.fullOrder()

        #expect(after[3] == first)
        #expect(after[0] == before[1])
        #expect(after[1] == before[2])
        #expect(after[2] == before[3])
        #expect(Set(after) == Set(before), "nothing is lost or invented")
        #expect(after.count == before.count)
    }

    @Test("Dragging a button back up is the same move in reverse")
    func moveUpwards() {
        var layout = ToolbarLayout()
        let before = layout.fullOrder()
        let fourth = before[3]
        layout.move(fourth, to: 0)
        let after = layout.fullOrder()
        #expect(after[0] == fourth)
        #expect(after[1] == before[0])
        #expect(after[3] == before[2])
    }

    @Test("A move of one place is exactly what the arrows always did")
    func oneStepIsUnchanged() {
        var moved = ToolbarLayout()
        var swapped = ToolbarLayout()
        let names = moved.fullOrder()
        moved.move(names[2], to: 3)
        swapped.move(names[2], by: 1)
        #expect(moved.fullOrder() == swapped.fullOrder())
    }

    @Test("A move to nowhere leaves the order alone")
    func moveOutOfRange() {
        var layout = ToolbarLayout()
        let before = layout.fullOrder()
        layout.move(before[0], to: -1)
        layout.move(before[0], to: before.count)
        layout.move("Not a button", to: 2)
        layout.move(before[0], to: 0)
        #expect(layout.fullOrder() == before)
    }
}
