import AppKit
import WebKit

/// Printing a page, and saving it as a PDF, through WebKit's own layout.
@MainActor
enum PagePrinting {
    /// Tests stand in for the print panel; the job is ready to run.
    static var testWillRun: ((NSPrintOperation) -> Void)?

    /// How long after a page's print job ends another request from it is
    /// ignored. `print()` in a loop would otherwise reopen the panel the
    /// moment it closes, and a sheet leaves no way to close the tab.
    private static let pageRepeatInterval: TimeInterval = 1
    private static var lastPagePrint: (page: ObjectIdentifier, ended: Date)?

    /// The print operation for what `tab` shows, or nil when that has nothing
    /// to print. A PDF is drawn over the web view and never loaded into it, so
    /// the web view holds the page before it, or nothing at all: printing it
    /// gives the wrong page or a blank sheet.
    static func operation(for tab: Tab, info: NSPrintInfo = .shared) -> NSPrintOperation? {
        if tab.document != nil {
            guard let operation = tab.documentView?.printOperation(info: info) else { return nil }
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.jobTitle = jobTitle(title: tab.displayTitle, url: tab.displayURL)
            return operation
        }
        guard !tab.showsStartPage, let webView = tab.currentWebView else { return nil }
        return operation(for: webView, info: info)
    }

    /// The print operation for `webView`, or for one `frame` of it, ready to
    /// run with the standard panel, or nil while the page has nothing WebKit
    /// can print yet (no document loaded, or a web view that is not on screen).
    ///
    /// WebKit hands back an operation whose print view has no size, and an
    /// unsized view prints as blank pages; giving it the web view's bounds is
    /// the documented way to make it paginate the page.
    static func operation(for webView: WKWebView, frame: AnyObject? = nil, info: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard webView.window != nil, webView.url != nil || webView.title?.isEmpty == false else { return nil }
        let printInfo = (info.copy() as? NSPrintInfo) ?? info
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = false
        let operation = frameOperation(in: webView, frame: frame, info: printInfo) ?? webView.printOperation(with: printInfo)
        guard let view = operation.view else { return nil }
        view.frame = NSRect(origin: .zero, size: webView.bounds.size)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = jobTitle(title: webView.title, url: webView.url)
        return operation
    }

    /// WebKit's public call prints the main frame only, which for a site
    /// printing an embedded document is the page around it.
    private static func frameOperation(in webView: WKWebView, frame: AnyObject?, info: NSPrintInfo) -> NSPrintOperation? {
        let selector = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        guard let frame, webView.responds(to: selector) else { return nil }
        return webView.perform(selector, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation
    }

    /// Runs `operation` as a sheet on `window`.
    static func run(_ operation: NSPrintOperation, in window: NSWindow, completion: @escaping @MainActor () -> Void = {}) {
        testWillRun?(operation)
        let finished = PrintFinished(completion)
        operation.runModal(for: window, delegate: finished,
                           didRun: #selector(PrintFinished.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(finished).toOpaque())
    }

    /// `window.print()`, which is what a site's own Print button calls. WebKit
    /// does nothing with it unless the UI delegate answers, and holds the page
    /// until `completion` runs. `frame` is WebKit's handle for the frame that
    /// asked. A page out of sight is answered at once, like its dialogs.
    static func printFromPage(_ webView: WKWebView, frame: AnyObject, completion: @escaping @MainActor () -> Void) {
        let page = ObjectIdentifier(webView)
        if let last = lastPagePrint, last.page == page, Date().timeIntervalSince(last.ended) < pageRepeatInterval {
            completion()
            return
        }
        guard let window = webView.window, let operation = operation(for: webView, frame: frame) else {
            completion()
            return
        }
        run(operation, in: window) {
            lastPagePrint = (page, Date())
            completion()
        }
    }

    /// The page rendered as a PDF by WebKit, whole and unpaginated.
    static func pdfData(of webView: WKWebView) async throws -> Data {
        try await webView.pdf()
    }

    /// What `tab` shows as a PDF: the file itself for a document, otherwise
    /// the page rendered by WebKit. Nil when it has nothing to save yet.
    static func pdfData(of tab: Tab) async throws -> Data? {
        if let document = tab.document {
            guard case .ready(let file, _) = document.state else { return nil }
            return try Data(contentsOf: file)
        }
        guard !tab.showsStartPage, let webView = tab.currentWebView else { return nil }
        return try await pdfData(of: webView)
    }

    /// The name the print system and the Save panel show: the page title,
    /// then the host, then "Page".
    static func jobTitle(title: String?, url: URL?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if let host = url?.host(), !host.isEmpty { return host }
        return "Page"
    }

    /// A file name for the PDF: the job title with anything a file system
    /// dislikes replaced, kept to a sane length.
    static func suggestedPDFName(title: String?, url: URL?) -> String {
        var name = jobTitle(title: title, url: url)
        let disallowed = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        name = String(String.UnicodeScalarView(name.unicodeScalars.map { disallowed.contains($0) ? "-" : $0 }))
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.count > 80 { name = String(name.prefix(80)) }
        if name.isEmpty { name = "Page" }
        return name + ".pdf"
    }
}

/// Hears a print job end. AppKit may report it from the thread the job ran on.
private final class PrintFinished: NSObject, @unchecked Sendable {
    private let completion: @MainActor () -> Void

    init(_ completion: @escaping @MainActor () -> Void) {
        self.completion = completion
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintFinished>.fromOpaque(contextInfo).release() }
        Task { @MainActor in completion() }
    }
}
