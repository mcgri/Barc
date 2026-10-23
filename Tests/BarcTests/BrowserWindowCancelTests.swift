// Modified for Barc: regression coverage for Escape after sidebar interactions, 2026-10-23.
import AppKit
import Testing
@testable import Barc

@Suite("Browser window cancellation", .serialized)
@MainActor
struct BrowserWindowCancelTests {
    @Test("Escape arriving from a web page leaves an ordinary browser window intact")
    func escapeWithoutAnOverlay() {
        _ = NSApplication.shared
        let (session, _) = TestSession.make()
        let controller = BrowserWindowController(session: session)
        let window = controller.window
        window?.isReleasedWhenClosed = false
        defer {
            window?.delegate = nil
            window?.close()
        }
        controller.cancelOperation(nil)
        #expect(controller.window === window)
        #expect(controller.session === session)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let root = window?.contentView,
           let dock = UITestSupport.descendants(of: root).first(where: { $0 is SpaceDockView }),
           let swipeRegion = controller.swipeRegion {
            #expect(!swipeRegion.intersects(dock.convert(dock.bounds, to: nil)))
        } else {
            Issue.record("The window must expose its Space dock and sidebar swipe region")
        }
    }
}
