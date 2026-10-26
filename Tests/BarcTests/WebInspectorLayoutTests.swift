import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Web Inspector page geometry", .serialized)
@MainActor
struct WebInspectorLayoutTests {
    enum Host: CaseIterable { case single, split }

    @Test("A docked console keeps a stable page frame and restores full height on close", .timeLimit(.minutes(3)), arguments: Host.allCases)
    func dockedConsole(kind: Host) async throws {
        let session = TestSession.make().0
        // Keep layout tests independent of concurrently exercised global site
        // and enterprise policies. This is still the real native inspector and
        // production page view, with its required developer preference enabled.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let page = WebEnvironment.shared.makeWebView(configuration: configuration)
        try await MemoryTestPage.load(page, html: "<p>Inspector layout fixture</p>")
        let tab = session.adoptGlancedTab(page, after: session.activeTab)
        let host: NSView
        switch kind {
        case .single:
            let single = WebContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
            single.show(page, failure: nil, url: page.url, onRetry: nil)
            host = single
        case .split:
            let split = SplitPaneView(tabID: tab.id)
            split.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
            split.adopt(page)
            host = split
        }
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let inspector = try #require(page.value(forKey: "_inspector") as? NSObject)
        let close = #selector(NSWindow.close)
        defer {
            if inspector.responds(to: close) { inspector.perform(close) }
            tab.unload()
            window.orderOut(nil)
            window.close()
        }
        let showConsole = Selector(("showConsole"))
        try #require(inspector.responds(to: showConsole))
        inspector.perform(showConsole)
        for _ in 0..<300 {
            if inspector.value(forKey: "isVisible") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(inspector.value(forKey: "isVisible") as? Bool == true, "The real inspector must finish opening before docking")
        let attach = Selector(("attach"))
        try #require(inspector.responds(to: attach))
        inspector.perform(attach)
        for _ in 0..<200 {
            if inspector.value(forKey: "isVisible") as? Bool == true,
               host.subviews.contains(where: { $0 !== page && $0 is WKWebView }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let console = try #require(host.subviews.first { $0 !== page && $0 is WKWebView }, "The native console must actually be docked in the page host")
        for size in [NSSize(width: 1000, height: 800), NSSize(width: 1100, height: 860), NSSize(width: 950, height: 720)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(50))
            var heights: [CGFloat] = []
            for _ in 0..<12 {
                heights.append(page.frame.height)
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                heights.append(page.frame.height)
                #expect(page.frame.intersection(console.frame).height <= 1,
                    "The page and console must not compete for the same vertical space")
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 1,
                "The page height must not oscillate while the window is unchanged")
        }
        try #require(inspector.responds(to: close))
        inspector.perform(close)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(abs(page.frame.height - host.bounds.height) <= 1)
    }

    @Test("Resizing and repeated sleep/wake cycles keep the visible page filling its card")
    func restoredPageFillsCard() async throws {
        let session = TestSession.make().0
        let original = session.activeSpace
        let tab = try #require(session.activeTab)
        let content = WebContentViewController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.orderFront(nil)
        defer { tab.unload(); window.orderOut(nil); window.close() }
        let elsewhere = session.addSpace(named: "Elsewhere")
        session.selectSpace(original)
        for _ in 0..<6 {
            let page = tab.webView()
            try await MemoryTestPage.load(page, html: "<p>Wake layout fixture</p>")
            for size in [NSSize(width: 1100, height: 850), NSSize(width: 900, height: 650)] {
                window.setContentSize(size)
                content.view.layoutSubtreeIfNeeded()
                let host = try #require(page.superview as? WebContainerView)
                #expect(page.frame == host.bounds)
            }
            session.selectSpace(elsewhere)
            session.suspend([tab])
            #expect(tab.isAsleep)
            session.selectSpace(original)
            content.view.layoutSubtreeIfNeeded()
            let restored = try #require(tab.currentWebView)
            let host = try #require(restored.superview as? WebContainerView)
            #expect(restored !== page)
            #expect(restored.frame == host.bounds)
        }
    }
}
