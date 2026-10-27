import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Viewport restoration yields to page use", .serialized)
@MainActor
struct PageViewportRestorationTests {
    enum Activity: CaseIterable { case none, input, navigation, noPaint }

    @Test("A deferred scroll respects input/navigation and restores the history policy", arguments: Activity.allCases)
    func deferredRestore(activity: Activity) async throws {
        let page = try await MemoryTestPage.make(html: "<div style='height:12000px'>Scroll fixture</div>")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFront(nil)
        defer { page.removeFromSuperview(); window.orderOut(nil); window.close() }
        // Control paint delivery without changing the production restore path.
        _ = try await page.callAsyncJavaScript("window.fixturePaints=[]; window.requestAnimationFrame=callback=>fixturePaints.push(callback); return true;",
                                              arguments: [:], in: nil, contentWorld: .defaultClient)
        let url = try #require(page.url)
        PageViewport(url: url, x: 0, y: 900).restore(in: page)
        if activity == .noPaint { try await Task.sleep(for: .milliseconds(1600)) }
        let action: String
        switch activity {
        case .none: action = ""
        case .input: action = "document.dispatchEvent(new WheelEvent('wheel',{bubbles:true})); window.scrollTo(0,125);"
        case .navigation: action = "history.pushState({}, '', '/another-page'); window.scrollTo(0,125);"
        case .noPaint: action = "window.scrollTo(0,125);"
        }
        let result = try #require(try await page.callAsyncJavaScript("""
            \(action)
            while (fixturePaints.length) fixturePaints.shift()();
            return {y:scrollY, policy:history.scrollRestoration};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any])
        #expect(result["y"] as? Double == (activity == .none ? 900 : 125))
        #expect(result["policy"] as? String == "auto")
    }
}
