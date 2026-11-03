import AppKit
import Testing
import WebKit
@testable import Barc

/// Saving an image from a page, the three ways pages and people do it.
@Suite("Downloading images from a page", .serialized)
@MainActor
struct ImageDownloadTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    /// A tab in a window whose downloads land in a directory of its own.
    @MainActor
    private struct Fixture {
        let tab: Tab
        let view: WKWebView
        let window: NSWindow
        let directory: URL
        let before: Int

        var saved: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }

        func waitForDownload() async throws {
            for _ in 0..<300 {
                try await Task.sleep(for: .milliseconds(10))
                if DownloadManager.shared.downloads.count > before, DownloadManager.shared.downloads.first?.state != .running { return }
            }
        }

        func click(_ type: NSEvent.EventType) throws {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .rightMouseDown: view.rightMouseDown(with: event)
            default: view.rightMouseUp(with: event)
            }
        }
    }

    private func withPage(_ body: String, _ run: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-image-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = TestSession.make().0
        let space = session.activeSpace
        space.downloadsDirectoryPath = directory.path
        let previous = DownloadManager.shared.spaceResolver
        DownloadManager.shared.spaceResolver = { _ in space }
        defer { DownloadManager.shared.spaceResolver = previous }

        let tab = session.newTab(url: URL(string: "about:blank")!)
        defer { tab.unload() }
        let view = tab.webView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        view.loadHTMLString("<!doctype html>\(body)<i id='ready'></i>", baseURL: URL(string: "http://127.0.0.1/fixture/"))
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('ready') && Array.from(document.images).every(i => i.complete)")) as? Bool == true { break }
        }
        let before = DownloadManager.shared.downloads.count
        defer {
            for row in DownloadManager.shared.downloads.prefix(max(0, DownloadManager.shared.downloads.count - before)) {
                DownloadManager.shared.remove(row)
            }
        }
        try await run(Fixture(tab: tab, view: view, window: window, directory: directory, before: before))
    }

    @Test("Download Image on the context menu saves the image")
    func contextMenu() async throws {
        try await withPage("<img style='position:fixed;inset:0;width:100%;height:100%' src='data:image/png;base64,\(Self.png)'>") { page in
            var offered = false
            GlanceWebView.testMenuWillOpen = { menu in
                if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadImage" }) {
                    offered = true
                    menu.performActionForItem(at: index)
                }
                RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTrackingWithoutAnimation() }
            }
            defer { GlanceWebView.testMenuWillOpen = nil }
            try page.click(.rightMouseDown)
            try page.click(.rightMouseUp)
            try await page.waitForDownload()
            #expect(offered)
            #expect(page.saved.count == 1, "WebKit hands the download to a delegate method Barc did not answer, and dropped it")
        }
    }

    @Test("A download button whose link carries the image itself saves it under the page's name")
    func dataLink() async throws {
        try await withPage("<a style='position:fixed;inset:0' download='chart.png' href='data:image/png;base64,\(Self.png)'>Download</a>") { page in
            try page.click(.leftMouseDown)
            try page.click(.leftMouseUp)
            try await page.waitForDownload()
            #expect(page.saved == ["chart.png"], "WebKit will not load a data: link as a page, so the click used to do nothing")
        }
    }

    @Test("A download button built from a blob saves it, even when the page revokes the link at once")
    func blobLink() async throws {
        try await withPage("<p>Generated image</p>") { page in
            _ = try await page.view.evaluateJavaScript("""
                fetch('data:image/png;base64,\(Self.png)').then(r => r.blob()).then(blob => {
                  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'generated.png';
                  a.click(); URL.revokeObjectURL(a.href);
                }); true
                """)
            try await page.waitForDownload()
            #expect(page.saved == ["generated.png"])
        }
    }

    @Test("Glance, Little Arc and web-app pages take context-menu downloads too")
    func coordinatorAnswers() {
        #expect(PageWebCoordinator().responds(to: Selector(("_webView:contextMenuDidCreateDownload:"))))
    }
}
