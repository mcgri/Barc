// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Testing
import AppKit
import WebKit
@testable import Barc

@Suite("Screenshots and Page Capture (F-18)")
@MainActor
struct ScreenshotTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var completion: CheckedContinuation<Void, Error>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?.resume(); completion = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion?.resume(throwing: error); completion = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion?.resume(throwing: error); completion = nil }
    }

    @Test("Filename generation sanitizes page titles and generates clean names")
    func testFilenameGeneration() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let name = ScreenshotService.generateFilename(title: "My Site / Documentation: Guide?", timestamp: fixedDate)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("?"))
        #expect(name.hasSuffix(".png"))
        #expect(name.contains("My Site Documentation Guide"))

        // Nil / empty title fallback
        let fallback = ScreenshotService.generateFilename(title: "", timestamp: fixedDate)
        #expect(fallback.hasPrefix("Screenshot "))
        #expect(fallback.hasSuffix(".png"))
    }

    @Test("Filename sanitization strips illegal filesystem characters and collapses whitespace")
    func testSanitization() {
        let raw = "Test  \\ / : * ? \" < > | # % &  Page Name "
        let sanitized = ScreenshotService.sanitizeFilename(raw)
        #expect(sanitized == "Test Page Name")
    }

    @Test("PNG data conversion produces valid PNG format bytes")
    func testPNGConversion() {
        let image = NSImage(size: NSSize(width: 50, height: 50))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 50, height: 50).fill()
        image.unlockFocus()

        let pngData = ScreenshotService.pngData(from: image)
        #expect(pngData != nil)
        #expect((pngData?.count ?? 0) > 8)

        // Standard PNG 8-byte header: 137 80 78 71 13 10 26 10
        if let data = pngData {
            let header = [UInt8](data.prefix(8))
            #expect(header == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }

    @Test("Copying a screenshot sets image and PNG data on an isolated destination pasteboard")
    func testClipboardCopy() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()

        let pboard = NSPasteboard(name: .init("barc.screenshot-test.\(UUID())"))
        defer { pboard.releaseGlobally() }
        ScreenshotService.copyImageToClipboard(image: image, pasteboard: pboard)
        let types = pboard.types ?? []
        #expect(types.contains(.png) || types.contains(.tiff))
    }

    @Test("Saving screenshot to disk creates file and avoids filename collisions")
    func testSaveImageToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        image.unlockFocus()

        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let file1 = try ScreenshotService.saveImageToDownloads(
            image: image,
            tabTitle: "CollisionTest",
            url: nil,
            customDirectory: tempDir,
            timestamp: timestamp
        )
        #expect(FileManager.default.fileExists(atPath: file1.path))
        #expect(((try? Data(contentsOf: file1))?.count ?? 0) > 0)

        // Force the same base name regardless of whether the wall clock ticks.
        let file2 = try ScreenshotService.saveImageToDownloads(
            image: image,
            tabTitle: "CollisionTest",
            url: nil,
            customDirectory: tempDir,
            timestamp: timestamp
        )
        #expect(file1 != file2)
        #expect(FileManager.default.fileExists(atPath: file2.path))
        #expect(file2.lastPathComponent.contains("(1)"))
    }

    @Test("CommandCatalog includes screenshot candidates")
    func testCommandCatalogCandidates() {
        let ids = CommandCatalog.all.map(\.id)
        #expect(ids.contains("capture-visible-area"))
        #expect(ids.contains("copy-visible-area"))
        #expect(ids.contains("capture-full-page"))
        #expect(ids.contains("copy-full-page"))
    }

    @Test("ShortcutManager defines configurable shortcuts for screenshot actions")
    func testShortcutManagerDefinitions() {
        let manager = ShortcutManager.shared
        #expect(manager.definition(for: "capture-visible-area") != nil)
        #expect(manager.definition(for: "copy-visible-area") != nil)
        #expect(manager.definition(for: "capture-full-page") != nil)
        #expect(manager.definition(for: "copy-full-page") != nil)
    }

    @Test("MainMenu contains Capture Screenshot submenu under File menu")
    func testMainMenuSubmenu() {
        let mock = MenuDelegateStub()
        let menu = MainMenu.build(
            bookmarks: mock,
            history: mock,
            tabs: mock,
            pinnedSites: mock,
            spaces: mock
        )
        let fileMenu = menu.items.first(where: { $0.title == "File" })
        let screenshotItem = fileMenu?.submenu?.items.first(where: { $0.title == "Capture Screenshot" })
        #expect(screenshotItem != nil)
        let subItems = screenshotItem?.submenu?.items.map(\.title) ?? []
        #expect(subItems.contains("Capture Visible Area"))
        #expect(subItems.contains("Copy Visible Area to Clipboard"))
        #expect(subItems.contains("Capture Full Page"))
        #expect(subItems.contains("Copy Full Page to Clipboard"))
    }

    @Test("GlanceWebView adds Capture Screenshot submenu to context menu")
    func testGlanceWebViewContextMenu() {
        let webView = GlanceWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let menu = NSMenu()
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        webView.willOpenMenu(menu, with: event)
        let screenshotItem = menu.items.first(where: { $0.title == "Capture Screenshot" })
        #expect(screenshotItem != nil)
        let titles = screenshotItem?.submenu?.items.map(\.title) ?? []
        #expect(titles.contains("Capture Visible Area"))
        #expect(titles.contains("Copy Visible Area to Clipboard"))
        #expect(titles.contains("Capture Full Page"))
        #expect(titles.contains("Copy Full Page to Clipboard"))
    }

    @Test("Capturing visible area snapshot on a loaded web view yields valid image")
    func testLiveWebViewSnapshot() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let html = "<html><body style='background-color: blue;'><h1>Barc</h1></body></html>"
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        // Wait for the page, rather than assuming a loaded WebKit process
        // after a fixed delay while the rest of the UI suite is running.
        try await withCheckedThrowingContinuation { continuation in
            waiter.completion = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        let image = try await ScreenshotService.capture(webView: webView, scope: .visible)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("Full-page capture includes the footer below the viewport and copies its full PNG", arguments: [1.0, 1.5])
    func fullPageClipboard(zoom: Double) async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { window.close() }
        web.pageZoom = zoom
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.completion = continuation
            web.loadHTMLString("<html><head><style>@media print { body { opacity:0 } }</style></head><body style='margin:0'><div style='height:600px;background:#ff0000'></div><div style='height:600px;background:#00ff00'></div><div style='height:600px;background:#0000ff'></div></body></html>", baseURL: nil)
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 300)")
        let image = try await ScreenshotService.capture(webView: web, scope: .fullPage)
        #expect(image.size.height >= 1800 * zoom - 1)
        let png = try #require(ScreenshotService.pngData(from: image))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        let first = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 10)?.usingColorSpace(.deviceRGB))
        let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let last = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 10)?.usingColorSpace(.deviceRGB))
        #expect(first.redComponent > 0.9 && first.blueComponent < 0.1)
        #expect(middle.greenComponent > 0.9 && middle.redComponent < 0.1)
        #expect(last.blueComponent > 0.9 && last.redComponent < 0.1)
        #expect(try await web.evaluateJavaScript("window.scrollY") as? Double == 300)
        #expect(web.bounds.size == NSSize(width: 300, height: 200))
        let clipboard = NSPasteboard(name: .init("barc.full-page-test.\(UUID())"))
        defer { clipboard.releaseGlobally() }
        ScreenshotService.copyImageToClipboard(image: image, pasteboard: clipboard)
        let copied = try #require(clipboard.data(forType: .png))
        #expect(NSBitmapImageRep(data: copied)?.pixelsHigh == bitmap.pixelsHigh)
    }


    @Test("The sidebar utility menu exposes full-page clipboard capture")
    func sidebarCaptureAction() throws {
        let controller = BrowserWindowController(session: TestSession.make().0)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? ContentTopBar }.first)
        let menu = bar.makeUtilitiesMenu()
        let action = try #require(menu.items.first { $0.title == "Copy Full Page to Clipboard" })
        #expect(action.target != nil && action.action != nil)
        #expect(ToolbarLayout.catalog.contains { $0.label == action.title })
    }


    @Test("A page taller than the old capture limit retains its footer within the bitmap budget")
    func longPageKeepsFooter() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
        defer { window.close() }
        let waiter = LoadWaiter(); web.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.completion = continuation
            web.loadHTMLString("<body style='margin:0'><div style='height:29000px;background:red'></div><div style='height:1000px;background:blue'></div></body>", baseURL: nil)
        }
        let image = try await ScreenshotService.capture(webView: web, scope: .fullPage)
        let png = try #require(ScreenshotService.pngData(from: image))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsHigh <= Int(ScreenshotService.maxFullPageHeight))
        #expect(Double(bitmap.pixelsHigh * bitmap.pixelsWide) <= ScreenshotService.maxFullPagePixels)
        let footer = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 10)?.usingColorSpace(.deviceRGB))
        #expect(footer.blueComponent > 0.9 && footer.redComponent < 0.1)
    }

}
