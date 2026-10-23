// Modified for Barc: Space dock selection, customization and magnification coverage, 2026-10-23.
import AppKit
import Testing
@testable import Barc

@Suite("Space icon dock")
@MainActor
struct SpaceDockTests {
    private func items(_ count: Int) -> [SpaceDockItem] {
        (0..<count).map { SpaceDockItem(id: UUID(), name: "Space \($0)", icon: .automatic, color: .systemBlue) }
    }

    @Test("The icon under the pointer grows most, nearby icons grow less, and distant icons stay small")
    func fisheyeFalloff() {
        let rest = SpaceDockLayout.plan(count: 8, availableWidth: 221, pointerX: nil, reduceMotion: false)
        let pointer = rest.frames[3].midX
        let hover = SpaceDockLayout.plan(count: 8, availableWidth: 221, pointerX: pointer, reduceMotion: false)
        #expect(hover.iconSizes[3] == SpaceDockLayout.enlargedSide)
        #expect(hover.iconSizes[2] > SpaceDockLayout.iconSide)
        #expect(hover.iconSizes[2] < hover.iconSizes[3])
        #expect(hover.iconSizes[0] == SpaceDockLayout.iconSide)
        #expect(hover.width <= 221)
        for pair in zip(hover.frames, hover.frames.dropFirst()) { #expect(pair.0.maxX <= pair.1.minX + 0.01) }
    }

    @Test("Leaving restores icon sizes and Reduce Motion disables magnification")
    func resetAndReducedMotion() {
        for pointer: CGFloat? in [nil, 80] {
            let plan = SpaceDockLayout.plan(count: 8, availableWidth: 221, pointerX: pointer, reduceMotion: true)
            #expect(plan.iconSizes.allSatisfy { $0 == SpaceDockLayout.iconSide })
        }
        let before = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = before }
        let dock = SpaceDockView()
        let values = items(8)
        dock.show(values, selectedID: values[0].id)
        _ = UITestSupport.host(dock, width: 221, height: SpaceDockLayout.height)
        let rest = dock.buttons.map(\.iconSize)
        dock.setPointer(dock.buttons[3].frame.midX)
        #expect(dock.buttons[3].iconSize > rest[3])
        dock.setPointer(nil)
        #expect(dock.buttons.map(\.iconSize) == rest)
    }

    @Test("Every Space is a named button; clicking selects its stable identity")
    func selectionAndIdentity() {
        let dock = SpaceDockView()
        let values = items(8)
        dock.show(values, selectedID: values[2].id)
        #expect(dock.buttons.count == 8)
        #expect(dock.buttons[2].isSelectedSpace)
        #expect(dock.buttons[2].accessibilityValue() as? String == "Selected")
        var selected: UUID?
        dock.onSelect = { selected = $0 }
        let button = dock.buttons[6]
        if let target = button.target, let action = button.action { _ = target.perform(action, with: button) }
        #expect(selected == values[6].id)
        dock.show(values.reversed(), selectedID: values[6].id)
        #expect(dock.buttons.first { $0.id == button.id } === button)
    }

    @Test("A right-click menu changes the clicked Space's icon without switching Spaces")
    func customization() throws {
        let (session, _) = TestSession.make()
        let first = session.activeSpace
        let second = session.addSpace(named: "Work")
        session.selectSpace(first)
        let sidebar = SidebarViewController(session: session)
        _ = sidebar.view
        let dock = try #require(UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? SpaceDockView }.first)
        let button = try #require(dock.buttons.first { $0.id == second.id })
        let menu = button.customizationMenu()
        #expect(menu.items.contains { $0.title == "Choose Emoji…" })
        #expect(menu.items.contains { $0.title == "Choose Image…" })
        let symbols = try #require(menu.items.first { $0.title == "Symbol" }?.submenu)
        let choice = try #require(symbols.items.first { $0.title == "Briefcase" })
        _ = choice.target?.perform(choice.action!, with: choice)
        #expect(second.icon == .symbol("briefcase.fill"))
        #expect(session.activeSpace === first)
        #expect(dock.buttons.first { $0.id == second.id } === button)
        let reset = try #require(button.customizationMenu().items.first { $0.title == "Use Default Icon" })
        _ = reset.target?.perform(reset.action!, with: reset)
        #expect(second.icon == .automatic)
    }

    @Test("A narrow dock scrolls instead of dropping Spaces and reveals the selected one")
    func overflowKeepsEverySpace() {
        let dock = SpaceDockView()
        let host = UITestSupport.host(dock, width: 95, height: SpaceDockLayout.height)
        let values = items(24)
        dock.show(values, selectedID: values.last!.id)
        host.layoutSubtreeIfNeeded()
        #expect(dock.buttons.count == 24)
        #expect(dock.buttons.last!.visibleRect.width > 10)
        #expect(dock.buttons.last!.frame.maxX > dock.bounds.width)
    }

    @Test("A single Space remains configurable")
    func singleSpace() {
        let dock = SpaceDockView()
        let values = items(1)
        dock.show(values, selectedID: values[0].id)
        #expect(!dock.isHidden)
        #expect(dock.buttons.count == 1)
        #expect(!dock.buttons[0].customizationMenu().items.isEmpty)
    }
}
