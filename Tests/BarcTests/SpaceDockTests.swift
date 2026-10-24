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

    private func settle(_ dock: SpaceDockView) {
        for _ in 0..<30 { dock.advanceMagnification(by: 1.0 / 60) }
    }

    @Test("At Arc's 228-point width the full footer places six Space targets 24 points apart")
    func sourceFooterGeometry() throws {
        let session = TestSession.make().0
        for index in 1..<6 { session.addSpace(named:"Space \(index+1)") }
        session.selectSpace(session.spaces[0])
        let sidebar = SidebarViewController(session:session),root = sidebar.view
        let host = UITestSupport.host(root,width:228,height:1027)
        host.layoutSubtreeIfNeeded()
        let footer = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? SidebarFooterView }.first)
        let dock = try #require(UITestSupport.descendants(of:footer).compactMap { $0 as? SpaceDockView }.first)
        let bounds = footer.convert(footer.bounds,to:root)
        let home = footer.homeButton.convert(footer.homeButton.bounds,to:root)
        let add = footer.addButton.convert(footer.addButton.bounds,to:root)
        #expect(bounds.width == 228 && bounds.height == 50)
        #expect(abs(home.midX-24)<0.1 && abs(add.midX-204)<0.1)
        #expect(abs(home.midY-25)<0.1 && abs(add.midY-25)<0.1)
        let centers = dock.buttons.map { $0.convert($0.bounds,to:root).midX }
        #expect(centers == [54,78,102,126,150,174])
        #expect(dock.buttons.allSatisfy { $0.frame.width == 24 && $0.iconSize == 18 })
        let ids = dock.buttons.map(\.id),frames = dock.buttons.map(\.frame)
        dock.setPointer(frames[2].midX);settle(dock)
        #expect(dock.buttons.map(\.frame) == frames && dock.buttons.map(\.id) == ids)
        sidebar.showLibrary(category:.spaces);host.layoutSubtreeIfNeeded()
        #expect(!footer.isDescendant(of:root))
        sidebar.hideLibrary();host.layoutSubtreeIfNeeded()
        #expect(footer.isDescendant(of:root))
        #expect(footer.convert(footer.bounds,to:root) == bounds)
        #expect(dock.buttons.map { $0.convert($0.bounds,to:root).midX } == centers)
    }

    @Test("Moving the pointer never shifts click targets or changes the scrollable width")
    func hoverKeepsRowStationary() {
        for (count, width) in [(8, CGFloat(221)), (24, CGFloat(95))] {
            let rest = SpaceDockLayout.plan(count: count, availableWidth: width, pointerX: nil, reduceMotion: false)
            for x in stride(from: CGFloat(0), through: rest.width, by: 7) {
                let hover = SpaceDockLayout.plan(count: count, availableWidth: width, pointerX: x, reduceMotion: false)
                #expect(hover.frames == rest.frames)
                #expect(hover.width == rest.width)
            }
        }
    }

    @Test("Rapid hover reversals preserve positions and ease sizes without jumps or overshoot")
    func rapidPointerMovementStaysSolid() throws {
        let before = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = before }
        let dock = SpaceDockView()
        let values = items(8)
        dock.show(values, selectedID: values[3].id)
        let host = UITestSupport.host(dock, width: 221, height: SpaceDockLayout.height)
        let frames = dock.buttons.map(\.frame)
        let document = try #require(dock.buttons.first?.superview)
        let documentFrame = document.frame
        for index in [0, 7, 2, 6, 3, 4, 0, 7, 3] {
            let previousSizes = dock.buttons.map(\.iconSize)
            dock.setPointer(frames[index].midX)
            #expect(dock.buttons.map(\.iconSize) == previousSizes)
            dock.advanceMagnification(by: 1.0 / 60)
            for (button, previous) in zip(dock.buttons, previousSizes) {
                #expect(abs(button.iconSize - previous) < 3)
                #expect(button.iconSize >= SpaceDockLayout.iconSide)
                #expect(button.iconSize <= SpaceDockLayout.enlargedSide)
            }
            host.layoutSubtreeIfNeeded()
            #expect(dock.buttons.map(\.frame) == frames)
            #expect(document.frame == documentFrame)
        }
        settle(dock)
        #expect(dock.buttons[3].iconSize == SpaceDockLayout.enlargedSide)
        #expect(dock.buttons[3].isSelectedSpace)
        dock.setPointer(nil)
        var previous = dock.buttons.map(\.iconSize)
        for _ in 0..<30 {
            dock.advanceMagnification(by: 1.0 / 60)
            for (button, size) in zip(dock.buttons, previous) { #expect(button.iconSize <= size) }
            previous = dock.buttons.map(\.iconSize)
        }
        #expect(dock.buttons.allSatisfy { $0.iconSize == SpaceDockLayout.iconSide })
        #expect(dock.buttons.map(\.frame) == frames)
    }

    @Test("AppKit pointer events reach the dock and magnify the icon under the mouse")
    func pointerEventsReachIcons() throws {
        _ = NSApplication.shared
        let before = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = before }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 221, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let dock = SpaceDockView()
        let host = UITestSupport.host(dock, width: 221, height: 100)
        window.contentView = host
        let values = items(8)
        dock.show(values, selectedID: values[0].id)
        host.layoutSubtreeIfNeeded()
        #expect(window.acceptsMouseMovedEvents)
        let document = try #require(dock.buttons[3].superview)
        document.updateTrackingAreas()
        #expect(document.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.activeAlways) })
        let point = document.convert(NSPoint(x: dock.buttons[3].frame.midX, y: 22), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 0, pressure: 0))
        document.mouseMoved(with: event)
        settle(dock)
        #expect(dock.buttons[3].iconSize > SpaceDockLayout.iconSide)
        document.mouseExited(with: event)
        settle(dock)
        #expect(dock.buttons.allSatisfy { $0.iconSize == SpaceDockLayout.iconSide })
        dock.trackPointer(event)
        settle(dock)
        #expect(dock.buttons[3].iconSize > SpaceDockLayout.iconSide)
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
        settle(dock)
        #expect(dock.buttons[3].iconSize > rest[3])
        dock.setPointer(nil)
        settle(dock)
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
