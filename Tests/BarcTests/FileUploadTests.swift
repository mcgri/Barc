import AppKit
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import Barc

@Suite("Choosing files to upload", .serialized)
@MainActor
struct FileUploadTests {
    private let picker = #selector(WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:))

    @Test("Tabs and glance, Little Arc and web-app pages all answer the file picker")
    func delegatesAnswer() async throws {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "about:blank")!)
        defer { tab.unload() }
        #expect(tab.webView().uiDelegate?.responds(to: picker) == true, "Without it WebKit ignores every upload button")
        #expect(PageWebCoordinator().responds(to: picker))
    }

    @Test("Clicking an upload area opens the picker and the chosen file reaches the page")
    func uploadArea() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "barc-upload-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var offered: (multiple: Bool, directories: Bool, types: [UTType])?
        FileUploadPanel.testChooser = { panel in
            offered = (panel.allowsMultipleSelection, panel.canChooseDirectories, panel.allowedContentTypes)
            return [file]
        }
        defer { FileUploadPanel.testChooser = nil }

        let coordinator = PageWebCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = try await MemoryTestPage.make(html: """
            <div id='zone' style='position:fixed;inset:0' onclick='chooser.click()'>Drop files here or click to upload</div>
            <input id='chooser' type='file' accept='image/*' multiple hidden>
            """)
        view.uiDelegate = coordinator
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }

        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }

        var chosen: String?
        for _ in 0..<200 {
            chosen = try await view.evaluateJavaScript("chooser.files.length ? chooser.files[0].name : ''") as? String
            if chosen?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(offered?.multiple == true)
        #expect(offered?.directories == false)
        #expect(offered?.types == [.image], "accept='image/*' shows images only, as Safari does")
        #expect(chosen == file.lastPathComponent)
    }

    @Test("The accept attribute narrows the picker only when every type is known", arguments: [
        (["image/*"], [], [UTType.image]),
        (["image/png"], [".csv"], [UTType.png, .commaSeparatedText]),
        ([], [".pdf"], [UTType.pdf]),
        (["video/*", "audio/*"], [], [UTType.movie, .audio]),
        ([], [], nil),
        (["application/x-barc-made-up"], [], nil),
        (["image/*"], [".barcmadeup"], nil)
    ] as [([String], [String], [UTType]?)])
    func acceptFilter(mimeTypes: [String], fileExtensions: [String], expected: [UTType]?) {
        #expect(FileUploadPanel.contentTypes(mimeTypes: mimeTypes, fileExtensions: fileExtensions) == expected)
    }
}
