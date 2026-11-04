import AppKit
import PDFKit
import Testing
import WebKit
@testable import Barc

/// What actually comes out of a print job, read back from the file it wrote.
@Suite("Printing a PDF", .serialized)
@MainActor
struct PDFPrintingTests {
    private static let phrase = "Quarterly apples invoice"

    /// A window on a live session, whose print jobs land in `output`.
    @MainActor
    private struct Fixture {
        let session: BrowserSession
        let controller: BrowserWindowController
        let window: NSWindow
        let base: URL
        let output: URL
        var toasts: Toasts

        final class Toasts { var messages: [String] = [] }

        /// Puts `tab`'s page in the window, as the content area does.
        func show(_ tab: Tab) -> WKWebView {
            let view = tab.webView()
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            return view
        }

        func printed() async throws -> PDFDocument? {
            for _ in 0..<400 {
                if let document = PDFDocument(url: output), document.pageCount > 0 { return document }
                try await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }

        func wait(_ done: () -> Bool) async throws {
            for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(25)) }
        }

        /// A page from the fixture, with its first paint done.
        func openPage(_ html: String = "<p>The page under the PDF</p>") async throws -> (Tab, WKWebView) {
            let tab = session.newTab(url: URL(string: "about:blank")!)
            let view = show(tab)
            view.loadHTMLString("<!doctype html><title>Fixture</title>\(html)<i id='ready'></i>", baseURL: base)
            for _ in 0..<300 {
                try await Task.sleep(for: .milliseconds(10))
                if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('ready')")) as? Bool == true { break }
            }
            return (tab, view)
        }

        /// The tab a page opened, once its PDF has arrived.
        func openedTab(before: Int) async throws -> Tab {
            try await wait { session.allTabs.count > before && session.activeTab?.document?.isReady == true }
            let tab = try #require(session.activeTab)
            #expect(tab.document?.isReady == true)
            return tab
        }
    }

    private func withWindow(_ body: (Fixture) async throws -> Void) async throws {
        let bytes = try await MemoryTestPage.make(html: "<h1>\(Self.phrase)</h1>").pdf()
        let server = try MemoryHTTPFixture(pdf: bytes); defer { server.stop() }
        let base = try await server.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "barc-pdf-print-\(UUID().uuidString)")
        // Left for the system to clear: a job that loses the folder it is
        // saving to goes to the real printer instead.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appending(path: "printed.pdf")

        let session = TestSession.make().0
        let toasts = Fixture.Toasts()
        let controller = BrowserWindowController(session: session)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        session.showToast = { toasts.messages.append($0.message) }
        defer { window.orderOut(nil); for tab in session.allTabs { tab.unload() } }

        PagePrinting.testWillRun = { operation in
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.printInfo.jobDisposition = .save
            operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        }
        defer { PagePrinting.testWillRun = nil }
        try await body(Fixture(session: session, controller: controller, window: window, base: base, output: output, toasts: toasts))
    }

    /// For a test where nothing should print: a job that starts anyway is
    /// cancelled and fails the test, and never reaches a printer.
    private func refusingPrintJobs() {
        PagePrinting.testWillRun = { operation in
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.printInfo.jobDisposition = .cancel
            Issue.record("Nothing should have been printed")
        }
    }

    /// Dark pixels on the page: a blank sheet has none.
    private func inkedPixels(on page: PDFPage) throws -> Int {
        let (top, bottom) = try inkedHalves(of: page)
        return top + bottom
    }

    private func inkedHalves(of page: PDFPage) throws -> (top: Int, bottom: Int) {
        let image = page.thumbnail(of: NSSize(width: 400, height: 520), for: .mediaBox)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var top = 0, bottom = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.brightnessComponent < 0.5 else { continue }
                if y < rep.pixelsHigh / 2 { top += 1 } else { bottom += 1 }
            }
        }
        return (top, bottom)
    }

    @Test("Print on a PDF reached by a link prints the PDF, not the page underneath")
    func sameTab() async throws {
        try await withWindow { fixture in
            let (tab, _) = try await fixture.openPage()
            tab.load(fixture.base.appending(path: "report.pdf"))
            try await fixture.wait { tab.document?.isReady == true }

            fixture.controller.printPage(nil)
            let printed = try #require(try await fixture.printed())
            #expect(printed.pageCount == 1)
            #expect(printed.string?.contains(Self.phrase) == true)
            #expect(printed.string?.contains("under the PDF") == false)
            #expect(try inkedPixels(on: try #require(printed.page(at: 0))) > 0, "A blank sheet is the bug")
        }
    }

    @Test("Print on a PDF a page opened in a new tab prints the PDF")
    func newTab() async throws {
        try await withWindow { fixture in
            let (_, view) = try await fixture.openPage()
            let before = fixture.session.allTabs.count
            _ = try await view.evaluateJavaScript("window.open('/report.pdf?print=true'); true")
            _ = try await fixture.openedTab(before: before)

            fixture.controller.printPage(nil)
            let printed = try #require(try await fixture.printed())
            #expect(printed.string?.contains(Self.phrase) == true)
            #expect(fixture.toasts.messages.isEmpty, "It is on screen, so there is something to print")
        }
    }

    @Test("Print on a PDF that loaded into a blank pop-up prints the PDF")
    func blankPopup() async throws {
        try await withWindow { fixture in
            let (_, view) = try await fixture.openPage()
            let before = fixture.session.allTabs.count
            _ = try await view.evaluateJavaScript("const w = window.open('about:blank'); w.location.href = '/report.pdf?print=true'; true")
            let tab = try await fixture.openedTab(before: before)
            _ = fixture.show(tab)

            fixture.controller.printPage(nil)
            let printed = try #require(try await fixture.printed())
            #expect(printed.string?.contains(Self.phrase) == true)
        }
    }

    @Test("Print on a PDF in WebKit's own viewer, for a site set to use it, prints the PDF")
    func webKitViewer() async throws {
        try await withWindow { fixture in
            SiteSettings.shared.update { $0.set("webkit", for: "127.0.0.1", in: .pdfDocuments) }
            defer { SiteSettings.shared.update { $0.remove("127.0.0.1", from: .pdfDocuments) } }
            let (tab, view) = try await fixture.openPage()
            tab.load(fixture.base.appending(path: "report.pdf"))
            try await fixture.wait { view.url?.path == "/report.pdf" && !view.isLoading }
            try await Task.sleep(for: .milliseconds(500))
            #expect(tab.document == nil)

            fixture.controller.printPage(nil)
            let printed = try #require(try await fixture.printed())
            #expect(printed.string?.contains(Self.phrase) == true)
        }
    }

    @Test("A portrait page prints upright on a portrait sheet")
    func portraitStaysUpright() async throws {
        try await withWindow { fixture in
            let folder = fixture.output.deletingLastPathComponent()
            let file = folder.appending(path: "portrait.pdf")
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.setFillColor(.black)
            context.fill(CGRect(x: 0, y: 742, width: 595, height: 100)) // A bar across the top.
            context.endPDFPage()
            context.closePDF()

            let (tab, _) = try await fixture.openPage()
            let address = fixture.base.appending(path: "portrait.pdf")
            tab.beginDocument(at: address)
            tab.documentArrived(at: file, from: address)
            fixture.controller.printPage(nil)
            let printed = try #require(try await fixture.printed())
            let page = try #require(printed.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            #expect(bounds.height > bounds.width, "A portrait sheet")
            let (top, bottom) = try inkedHalves(of: page)
            #expect(top > 0)
            #expect(bottom == 0, "Turned sideways, the bar would run down the page into its lower half")
        }
    }

    @Test("A PDF still loading says there is nothing to print yet")
    func stillLoading() async throws {
        try await withWindow { fixture in
            refusingPrintJobs()
            let (tab, _) = try await fixture.openPage()
            tab.beginDocument(at: fixture.base.appending(path: "slow.pdf"))
            fixture.controller.printPage(nil)
            #expect(fixture.toasts.messages == ["Nothing to print yet"])
            #expect(try await PagePrinting.pdfData(of: tab) == nil, "Export has nothing to save either")
        }
    }

    @Test("A PDF that forbids printing says so")
    func forbidden() async throws {
        try await withWindow { fixture in
            refusingPrintJobs()
            let folder = fixture.output.deletingLastPathComponent()
            let file = folder.appending(path: "locked.pdf")
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            let info: [CFString: Any] = [kCGPDFContextOwnerPassword: "owner", kCGPDFContextAllowsPrinting: false]
            let context = try #require(CGContext(file as CFURL, mediaBox: &box, info as CFDictionary))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()

            let (tab, _) = try await fixture.openPage()
            let address = fixture.base.appending(path: "locked.pdf")
            tab.beginDocument(at: address)
            tab.documentArrived(at: file, from: address)
            #expect(tab.documentView?.document?.allowsPrinting == false)
            fixture.controller.printPage(nil)
            #expect(fixture.toasts.messages == ["This PDF does not allow printing"])
        }
    }

    @Test("Export as PDF on a PDF saves that PDF, not the page underneath")
    func export() async throws {
        try await withWindow { fixture in
            let (tab, _) = try await fixture.openPage()
            tab.load(fixture.base.appending(path: "report.pdf"))
            try await fixture.wait { tab.document?.isReady == true }
            let data = try #require(try await PagePrinting.pdfData(of: tab))
            #expect(PDFDocument(data: data)?.string?.contains(Self.phrase) == true)
        }
    }

    @Test("A tab on the start page has nothing to print, rather than a blank sheet")
    func startPage() async throws {
        try await withWindow { fixture in
            let tab = fixture.session.newTab(url: URL(string: "about:blank")!)
            _ = fixture.show(tab)
            tab.load(StartPage.url)
            #expect(tab.showsStartPage)
            #expect(PagePrinting.operation(for: tab) == nil)
        }
    }

    @Test("A page's own Print button prints the page")
    func windowPrint() async throws {
        try await withWindow { fixture in
            let (_, view) = try await fixture.openPage("<p>Printed by the page itself</p>")
            _ = try await view.evaluateJavaScript("print(); true")
            let printed = try #require(try await fixture.printed())
            #expect(printed.string?.contains("Printed by the page itself") == true)
        }
    }

    @Test("Printing an embedded PDF from its frame prints the PDF, not the page around it")
    func framePrint() async throws {
        try await withWindow { fixture in
            let (_, view) = try await fixture.openPage("<p>The page around the frame</p><iframe id='doc' src='/report.pdf' width='600' height='400'></iframe>")
            try await Task.sleep(for: .milliseconds(800))
            _ = try await view.evaluateJavaScript("document.getElementById('doc').contentWindow.print(); true")
            let printed = try #require(try await fixture.printed())
            #expect(printed.string?.contains(Self.phrase) == true)
            #expect(printed.string?.contains("around the frame") == false)
        }
    }

    @Test("A page out of sight cannot open a print panel, and is not left waiting")
    func hiddenPage() async throws {
        try await withWindow { fixture in
            let (_, view) = try await fixture.openPage()
            view.removeFromSuperview()
            #expect(try await view.evaluateJavaScript("print(); 'carried on'") as? String == "carried on")
            try await Task.sleep(for: .milliseconds(200))
            #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    @Test("A page that asks again straight after a print cannot trap the window in print panels")
    func repeatedPrint() async throws {
        try await withWindow { fixture in
            var runs = 0
            let saving = PagePrinting.testWillRun
            PagePrinting.testWillRun = { runs += 1; saving?($0) }
            let (_, view) = try await fixture.openPage("<p>Again and again</p>")
            _ = try await view.evaluateJavaScript("print(); true")
            _ = try await fixture.printed()
            #expect(runs == 1)
            _ = try await view.evaluateJavaScript("print(); print(); print(); true")
            #expect(runs == 1)
        }
    }

    @Test("Tabs, and glance, Little Arc and web-app pages, all answer window.print()")
    func delegatesAnswer() async throws {
        let selector = NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "about:blank")!)
        defer { tab.unload() }
        #expect(tab.webView().uiDelegate?.responds(to: selector) == true)
        #expect(PageWebCoordinator().responds(to: selector))
    }
}
