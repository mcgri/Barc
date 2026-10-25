// Modified for Barc: keyboard traversal skips the collapsed Pinned section, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Collapsed Pinned keyboard traversal", .serialized)
@MainActor
struct CollapsedPinnedNavigationTests {
    private func session() -> BrowserSession {
        let session = TestSession.make().0
        if let empty = session.activeTab { session.closeTab(empty) }
        return session
    }
    private func page(_ name:String,in session:BrowserSession) -> Tab {
        TestSession.appendTab(in:session,url:URL(string:"https://collapsed-navigation.invalid/\(name)")!)
    }

    @Test("Next and previous wrap through Today while root pins and folder pages stay skipped")
    func collapsedWrap() {
        let session = session(),space = session.activeSpace
        let pin = page("pin",in:session),child = page("child",in:session)
        pin.setKeepsInSidebar(true)
        _ = session.createGroup(named:"Folder",containing:[child])
        let a = page("a",in:session),b = page("b",in:session)
        space.look.pinnedSectionCollapsed = true
        session.selectTab(b);session.selectTab(offsetBy:1)
        #expect(session.activeTab === a)
        session.selectTab(offsetBy:-1)
        #expect(session.activeTab === b)
        #expect(space.look.pinnedSectionCollapsed && pin.keepsInSidebar && child.groupID != nil)
    }

    @Test("A selected hidden pin can leave the section in either direction")
    func hiddenSelection() {
        let session = session(),space = session.activeSpace
        let a = page("a",in:session),pin = page("pin",in:session),b = page("b",in:session)
        pin.setKeepsInSidebar(true);space.look.pinnedSectionCollapsed = true
        session.selectTab(pin);session.selectTab(offsetBy:1)
        #expect(session.activeTab === a)
        session.selectTab(pin);session.selectTab(offsetBy:-1)
        #expect(session.activeTab === b)
        session.selectTab(pin);session.selectTab(offsetBy:2)
        #expect(session.activeTab === b)
        session.selectTab(pin);session.selectTab(offsetBy:-2)
        #expect(session.activeTab === a)
    }

    @Test("Hidden sticky splits remain intact when traversal selects a Today tab")
    func hiddenSticky() {
        let session = session(),space = session.activeSpace
        let a = page("pin-a",in:session),b = page("pin-b",in:session)
        session.splitTabs([a,b]);session.setSidebarPin(true,for:a)
        let today = page("today",in:session)
        session.selectTab(b);session.toggleStickPane(a.id)
        let before = space.splits
        space.look.pinnedSectionCollapsed = true
        session.selectTab(offsetBy:1)
        #expect(session.activeTab === today)
        #expect(space.splits == before && !today.isSidebarRetained)
    }

    @Test("Visible Favorite tiles remain in the cycle and expanding Pinned restores its entries")
    func favoritesAndExpanded() {
        let session = session(),space = session.activeSpace
        let pin = page("pin",in:session);pin.setKeepsInSidebar(true)
        let favorite = page("favorite",in:session);session.pin(favorite)
        let today = page("today",in:session)
        space.look.pinnedSectionCollapsed = true
        session.selectTab(today);session.selectTab(offsetBy:1)
        #expect(session.activeTab === favorite)
        session.selectTab(offsetBy:1)
        #expect(session.activeTab === today)
        space.look.pinnedSectionCollapsed = false
        session.selectTab(favorite);session.selectTab(offsetBy:1)
        #expect(session.activeTab === pin)
    }

    @Test("Zero and extreme offsets are safe and an entirely hidden list does not change selection")
    func boundaries() {
        let session = session(),space = session.activeSpace
        let pin = page("pin",in:session);pin.setKeepsInSidebar(true)
        let a = page("a",in:session),b = page("b",in:session)
        space.look.pinnedSectionCollapsed = true
        session.selectTab(pin);session.selectTab(offsetBy:0)
        #expect(session.activeTab === pin)
        session.selectTab(a);session.selectTab(offsetBy:Int.max)
        #expect(session.activeTab === b)
        session.selectTab(a);session.selectTab(offsetBy:Int.min)
        #expect(session.activeTab === a)
        a.setKeepsInSidebar(true);b.setKeepsInSidebar(true)
        session.selectTab(pin);session.selectTab(offsetBy:1)
        #expect(session.activeTab === pin)
    }

    @Test("Native actions skip the hidden section and disable when no other eligible tab exists")
    func nativeActions() throws {
        _ = NSApplication.shared
        let session = session(),space = session.activeSpace
        let pin = page("pin",in:session);pin.setKeepsInSidebar(true)
        let today = page("today",in:session)
        space.look.pinnedSectionCollapsed = true;session.selectTab(pin)
        let controller = BrowserWindowController(session:session)
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.delegate = nil;window.close() }
        let next = NSMenuItem(title:"Next Tab",action:#selector(BrowserWindowController.selectNextTab(_:)),keyEquivalent:"")
        let previous = NSMenuItem(title:"Previous Tab",action:#selector(BrowserWindowController.selectPreviousTab(_:)),keyEquivalent:"")
        #expect(controller.validateMenuItem(next) && controller.validateMenuItem(previous))
        controller.selectNextTab(nil)
        #expect(session.activeTab === today)
        #expect(!controller.validateMenuItem(next) && !controller.validateMenuItem(previous))
        session.selectTab(pin);controller.selectPreviousTab(nil)
        #expect(session.activeTab === today && space.look.pinnedSectionCollapsed)
        today.setKeepsInSidebar(true)
        #expect(!controller.validateMenuItem(next) && !controller.validateMenuItem(previous))
    }
}
