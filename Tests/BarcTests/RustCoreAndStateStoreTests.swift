import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("RustCore and out-of-line interaction state")
struct RustCoreAndStateStoreTests {
    @Test("InteractionStateStore compresses, roundtrips, and prunes state blobs")
    func roundtripsAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "barc-state-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InteractionStateStore(directory: dir)

        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        let key = try #require(store.store(payload, forKey: "tab-1"))
        #expect(key == "tab-1")

        let loaded = try #require(store.load(forKey: "tab-1"))
        #expect(loaded == payload)

        // File on disk should be dramatically smaller than raw 64 KB.
        let file = dir.appending(path: "tab-1.barcstate")
        let diskSize = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? Int.max
        #expect(diskSize < 2048)

        // Pruning drops unreferenced keys.
        store.prune(keeping: [])
        #expect(store.load(forKey: "tab-1") == nil)
    }

    @Test("Oversized interactionState blobs are dropped to prevent session bloat")
    func dropsOversizedBlobs() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "barc-state-cap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InteractionStateStore(directory: dir)

        let huge = Data(repeating: 0x11, count: InteractionStateStore.maxUncompressedBytes + 1)
        #expect(store.store(huge, forKey: "huge-tab") == nil)
        #expect(store.load(forKey: "huge-tab") == nil)
    }

    @Test("BrowserSession.suspend honours allowVisible for background active-tab sleep")
    @MainActor
    func suspendAllowVisible() {
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "barc-suspend-\(UUID()).json")))
        let tab = session.newTab(url: URL(string: "https://example.com")!)
        _ = tab.webView()
        #expect(tab.isLoaded)

        // Default suspend protects the visible tab.
        #expect(session.suspend([tab]) == 0)
        #expect(tab.isLoaded)

        // Background active-tab sleep explicitly allows unloading the visible tab.
        #expect(session.suspend([tab], allowVisible: true) == 1)
        #expect(!tab.isLoaded)
    }

    @Test("TabRehydrationStore compresses, roundtrips, and prunes page state snapshots on disk")
    func rehydrationStoreRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "barc-rehydrate-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TabRehydrationStore(directory: dir)

        let snap = TabRehydrationSnapshot(
            url: "https://app.clickup.com/t/12345",
            origin: "https://app.clickup.com",
            windowX: 0,
            windowY: 120,
            sessionStorage: ["activeView": "list", "filter": String(repeating: "abc", count: 500)],
            scrolls: [.init(selector: "#task-list", x: 0, y: 840)],
            forms: [
                .init(selector: "textarea[name=\"comment\"]", kind: "text", value: "Draft reply", checked: nil),
                .init(selector: "#show-closed", kind: "checkbox", value: nil, checked: true)
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(store.store(snap, forKey: "tab-clickup"))
        let loaded = try #require(store.load(forKey: "tab-clickup"))
        #expect(loaded == snap)

        // Disk file should be LZ4-compressed smaller than raw JSON.
        let file = dir.appending(path: "tab-clickup.pagestate")
        let diskSize = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? Int.max
        #expect(diskSize < 800)

        store.prune(keeping: [])
        #expect(store.load(forKey: "tab-clickup") == nil)
    }

    @Test("TabRehydrationStore captures and rehydrates sessionStorage, nested scroll, and non-sensitive forms while excluding passwords")
    @MainActor
    func rehydrationEndToEnd() async throws {
        // Serve a tiny local page over loopback so `origin` is http://127.0.0.1:<port>
        // (data: URLs have opaque null origin where sessionStorage is blocked).
        let html = """
        <!doctype html><html><head><script>
          window.__bootSessionVal = window.sessionStorage.getItem('barc_key') || '';
        </script><style>
          #scroller { height: 100px; overflow-y: auto; }
          #inner { height: 1000px; }
        </style></head><body>
          <div id="scroller"><div id="inner"></div></div>
          <textarea name="draft"></textarea>
          <input type="password" name="secret" />
        </body></html>
        """

        let server = try LocalLoopbackServer(html: html)
        defer { server.stop() }
        let pageURL = server.url

        let config1 = WKWebViewConfiguration()
        config1.websiteDataStore = .nonPersistent()
        let wv1 = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config1)
        wv1.load(URLRequest(url: pageURL))
        try await waitUntilLoaded(wv1)

        // Mutate live SPA state: sessionStorage, nested scroll, textarea, and password.
        _ = try await wv1.evaluateJavaScript("""
          window.sessionStorage.setItem('barc_key', 'persisted-across-kill');
          document.getElementById('scroller').scrollTop = 320;
          document.querySelector('textarea[name="draft"]').value = 'unsaved note';
          document.querySelector('input[name="secret"]').value = 'top-secret-password';
          true;
        """)

        let captured = try #require(await TabRehydrationStore.capture(from: wv1))
        let hasSessionKey = captured.sessionStorage["barc_key"] == "persisted-across-kill"
        let hasScroll = captured.scrolls.contains { $0.selector == "#scroller" && abs($0.y - 320) <= 2 }
        let hasDraft = captured.forms.contains { $0.selector.contains("draft") && $0.value == "unsaved note" }
        let hasSecret = captured.forms.contains { $0.value == "top-secret-password" || $0.selector.contains("secret") }
        #expect(hasSessionKey)
        #expect(hasScroll)
        #expect(hasDraft)
        // Passwords MUST NEVER be captured!
        #expect(!hasSecret)

        // Brand new WKWebView simulating rehydration after process kill/sleep.
        let config2 = WKWebViewConfiguration()
        config2.websiteDataStore = .nonPersistent()
        if let docStart = TabRehydrationStore.documentStartScript(for: captured) {
            config2.userContentController.addUserScript(docStart)
        }
        let wv2 = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config2)
        wv2.load(URLRequest(url: pageURL))
        try await waitUntilLoaded(wv2)
        TabRehydrationStore.restoreDOMState(captured, in: wv2)
        try await Task.sleep(for: .milliseconds(250))

        // Verify sessionStorage was already present BEFORE the page's <head><script> ran!
        let bootVal = try await wv2.evaluateJavaScript("window.__bootSessionVal") as? String
        let scrollTop = try await wv2.evaluateJavaScript("document.getElementById('scroller').scrollTop") as? Double
        let draftVal = try await wv2.evaluateJavaScript("document.querySelector('textarea[name=\"draft\"]').value") as? String
        let secretVal = try await wv2.evaluateJavaScript("document.querySelector('input[name=\"secret\"]').value") as? String

        #expect(bootVal == "persisted-across-kill")
        #expect((scrollTop ?? 0) >= 310)
        #expect(draftVal == "unsaved note")
        #expect(secretVal == "")
    }

    @Test("PageHibernationGuard protects code-editor proxy textareas and NSOpenPanel imports across SPA URL changes")
    @MainActor
    func protectsFlowAndCodeEditors() async throws {
        let html = """
        <!doctype html><html><body>
          <div class="monaco-editor"><textarea id="proxy" style="width:1px;height:1px;opacity:0"></textarea></div>
        </body></html>
        """
        let server = try LocalLoopbackServer(html: html)
        defer { server.stop() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        PageHibernationGuard.shared.attach(config.userContentController)
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        wv.load(URLRequest(url: server.url))
        try await waitUntilLoaded(wv)
        try await Task.sleep(for: .milliseconds(150))

        // Initially safe to hibernate.
        #expect(await PageHibernationGuard.shared.permitsHibernation(of: wv) == true)

        // Simulate Monaco/Flow typing into hidden proxy textarea and immediately clearing it.
        _ = try await wv.evaluateJavaScript("""
          const p = document.getElementById('proxy');
          p.value = '{"hello": "world"}';
          p.dispatchEvent(new Event('input', { bubbles: true }));
          p.value = '';
          true;
        """)
        #expect(await PageHibernationGuard.shared.permitsHibernation(of: wv) == false)

        // Fresh view: test native NSOpenPanel import survives SPA history.pushState query changes.
        let config2 = WKWebViewConfiguration()
        config2.websiteDataStore = .nonPersistent()
        PageHibernationGuard.shared.attach(config2.userContentController)
        let wv2 = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config2)
        wv2.load(URLRequest(url: server.url))
        try await waitUntilLoaded(wv2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await PageHibernationGuard.shared.permitsHibernation(of: wv2) == true)

        PageHibernationGuard.shared.markImportedFile(in: wv2)
        _ = try await wv2.evaluateJavaScript("history.pushState({}, '', '?mode=EDIT&step=2'); true;")
        #expect(await PageHibernationGuard.shared.permitsHibernation(of: wv2) == false)
    }
}

@MainActor
private func waitUntilLoaded(_ webView: WKWebView) async throws {
    for _ in 0..<100 {
        if !webView.isLoading, webView.url != nil,
           let ready = try? await webView.evaluateJavaScript("document.readyState") as? String,
           ready == "complete" {
            return
        }
        try await Task.sleep(for: .milliseconds(30))
    }
}

private final class LocalLoopbackServer: @unchecked Sendable {
    private let listenFD: Int32
    let url: URL
    private var running = true

    init(html: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        self.listenFD = fd
        self.url = URL(string: "http://127.0.0.1:\(port)/")!

        let body = Data(html.utf8)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.running == true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                var buf = [UInt8](repeating: 0, count: 2048)
                _ = read(client, &buf, buf.count)
                response.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(client, base, response.count)
                    }
                }
                close(client)
            }
        }
    }

    func stop() {
        running = false
        close(listenFD)
    }
}
