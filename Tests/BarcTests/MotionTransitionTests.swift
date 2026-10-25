// Modified for Barc: interrupted sidebar motion and display-preference changes, 2026-10-25.
import AppKit
import QuartzCore
import Testing
@testable import Barc

@Suite("Sidebar reduced-motion transitions", .serialized)
@MainActor
struct MotionTransitionTests {
    private func drainDisplayNotification() {
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }

    @Test("Display observation delivers on the main thread and ends with its owner")
    func observationLifetime() {
        var count = 0
        var observation:DisplayOptionsObservation? = DisplayOptionsObservation { count += 1 }
        weak var reference = observation
        drainDisplayNotification()
        #expect(count == 1 && reference != nil)
        observation = nil
        drainDisplayNotification()
        #expect(count == 1 && reference == nil)
    }

    @Test("A reduced presence operation clears an earlier journey and leaves the requested final state", arguments:["appear","slide","disappear"])
    func interruptedPresence(operation:String) throws {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let view = NSView(frame:NSRect(x:0,y:0,width:200,height:40))
        SpringPresence.slideIn(view,from:CGVector(dx:-28,dy:10))
        let layer = try #require(view.layer)
        #expect(layer.animation(forKey:"barc.springPresence") != nil)
        layer.transform = CATransform3DMakeTranslation(-28,10,0)
        Style.Motion.reduceMotionOverride = true
        var completions = 0
        switch operation {
        case "appear":SpringPresence.appear(view,rising:12) { completions += 1 }
        case "slide":SpringPresence.slideIn(view,from:CGVector(dx:28,dy:10),fading:true)
        default:SpringPresence.disappear(view,falling:12) { completions += 1 }
        }
        #expect(layer.animation(forKey:"barc.springPresence") == nil)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(view.alphaValue == (operation == "disappear" ? 0:1))
        #expect(completions == (operation == "slide" ? 0:1))
    }

    private func dock() -> SpaceDockView {
        let dock = SpaceDockView()
        let items = (0..<6).map { SpaceDockItem(id:UUID(),name:"Space \($0)",icon:.automatic,color:.systemBlue) }
        dock.show(items,selectedID:items[2].id)
        _ = UITestSupport.host(dock,width:180,height:SpaceDockLayout.height)
        return dock
    }

    @Test("A running dock interpolation discards its old enlarged target immediately when reduced")
    func dockMidInterpolation() {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let dock = dock(),frames = dock.buttons.map(\.frame)
        dock.setPointer(frames[2].midX);dock.advanceMagnification(by:1.0/60)
        #expect(dock.buttons[2].iconSize > SpaceDockLayout.iconSide)
        Style.Motion.reduceMotionOverride = true
        dock.advanceMagnification(by:1.0/60)
        #expect(dock.buttons.allSatisfy { $0.iconSize == SpaceDockLayout.iconSide })
        #expect(dock.buttons.map(\.frame) == frames && dock.buttons[2].isSelectedSpace)
    }

    @Test("A display-preference notification settles a stationary hovered dock and preserves its targets")
    func stationaryDock() {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let dock = dock(),frames = dock.buttons.map(\.frame)
        dock.setPointer(frames[2].midX)
        for _ in 0..<30 { dock.advanceMagnification(by:1.0/60) }
        #expect(dock.buttons[2].iconSize == SpaceDockLayout.enlargedSide)
        Style.Motion.reduceMotionOverride = true
        drainDisplayNotification()
        #expect(dock.buttons.allSatisfy { $0.iconSize == SpaceDockLayout.iconSide })
        #expect(dock.buttons.map(\.frame) == frames && dock.buttons[2].isSelectedSpace)
        Style.Motion.reduceMotionOverride = false
        drainDisplayNotification()
        #expect(dock.buttons[2].iconSize == SpaceDockLayout.enlargedSide)
        #expect(dock.buttons.map(\.frame) == frames)
    }

    private func sidebar() -> (BrowserSession,SidebarViewController) {
        let session = TestSession.make().0
        let first = session.activeSpace
        _ = session.addSpace(named:"Work",profile:first.profile)
        session.selectSpace(first)
        let sidebar = SidebarViewController(session:session)
        sidebar.view.frame = NSRect(x:0,y:0,width:228,height:700)
        sidebar.view.layoutSubtreeIfNeeded()
        return (session,sidebar)
    }
    private func stills(_ sidebar:SidebarViewController) -> [NSView] {
        UITestSupport.descendants(of:sidebar.view).filter { String(describing:type(of:$0)).contains("SpaceStill") }
    }
    private func assertAtRest(_ sidebar:SidebarViewController) {
        #expect(stills(sidebar).isEmpty)
        #expect(!sidebar.isSwitchInFlight)
        for view in UITestSupport.descendants(of:sidebar.view) {
            #expect(view.layer?.animation(forKey:"barc.slide") == nil)
            #expect(view.layer?.affineTransform().tx ?? 0 == 0)
        }
    }

    @Test("Changing the setting during a drag restores the sidebar on cancel or another drag event",arguments:[false,true])
    func swipeStops(onCancel:Bool) {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let (session,sidebar) = sidebar(),selected = session.activeSpace
        sidebar.applySwipe(translation:-40,crossfade:0.2)
        #expect(!stills(sidebar).isEmpty)
        #expect(UITestSupport.descendants(of:sidebar.view).contains { $0.layer?.affineTransform().tx == -40 })
        Style.Motion.reduceMotionOverride = true
        if onCancel { sidebar.cancelSwipe() } else { sidebar.applySwipe(translation:-60,crossfade:0.3) }
        assertAtRest(sidebar)
        #expect(session.activeSpace === selected)
    }

    @Test("A display-preference notification finishes an in-flight Space switch without changing its destination")
    func switchNotification() {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let (session,sidebar) = sidebar(),target = session.spaces[1]
        sidebar.animateSwitch(offset:1) { session.selectSpace(target) }
        #expect(sidebar.isSwitchInFlight && !stills(sidebar).isEmpty)
        Style.Motion.reduceMotionOverride = true
        drainDisplayNotification()
        assertAtRest(sidebar)
        #expect(session.activeSpace === target)
    }

    @Test("A preference-only redraw preserves the scrolled viewport, multiple selection and active page")
    func preferenceRedrawPreservesContext() throws {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = old }
        let session = TestSession.make().0
        for index in 0..<30 { _ = session.newTab(url:URL(string:"https://fixture.invalid/\(index)")!,select:false) }
        let sidebar = SidebarViewController(session:session)
        sidebar.view.frame = NSRect(x:0,y:0,width:228,height:700)
        sidebar.view.layoutSubtreeIfNeeded()
        let table = sidebar.tabListTableView
        table.selectRowIndexes(IndexSet([2,3]),byExtendingSelection:false)
        let active = session.activeTab
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to:NSPoint(x:0,y:250));scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin,selection = table.selectedRowIndexes
        #expect(origin.y > 0 && selection.count == 2)
        Style.Motion.reduceMotionOverride = true
        drainDisplayNotification()
        #expect(scroll.contentView.bounds.origin == origin)
        #expect(table.selectedRowIndexes == selection)
        #expect(session.activeTab === active)
    }

    @Test("Reduced-motion row insertion and removal preserve selection and settle every cell")
    func tableChanges() throws {
        let old = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = true
        defer { Style.Motion.reduceMotionOverride = old }
        let (session,sidebar) = sidebar()
        let table = sidebar.tabListTableView,before = table.numberOfRows
        let originalTabs = session.activeSpace.tabs.map(\.id)
        let page = session.newTab(url:URL(string:"https://fixture.invalid/motion")!)
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == before+1 && session.activeTab === page)
        let selected = table.selectedRow
        let row = try #require(table.rowView(atRow:selected,makeIfNecessary:true))
        #expect(row.frame == table.rect(ofRow:selected))
        for view in UITestSupport.descendants(of:row) {
            #expect(view.layer?.animation(forKey:"barc.springPresence") == nil)
            if let transform = view.layer?.transform { #expect(CATransform3DIsIdentity(transform)) }
        }
        session.closeTab(page)
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == before && session.activeSpace.tabs.map(\.id) == originalTabs)
    }
}
