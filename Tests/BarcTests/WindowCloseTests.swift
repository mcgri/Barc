import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Window close and OAuth popups")
@MainActor
struct WindowCloseTests {
    @Test("Closing a script-opened child tab returns selection to its opener")
    func closingChildReturnsToOpener() {
        let session = TestSession.make().0
        let opener = session.newTab(url: URL(string: "https://soundon.example/login")!)
        let unrelated = session.newTab(url: URL(string: "https://other.example")!)
        session.selectTab(opener)

        let config = WebEnvironment.shared.makeConfiguration(for: session.activeSpace.identity)
        let popup = session.adoptChildTab(of: opener, configuration: config)
        #expect(session.activeTab === popup)
        #expect(popup.openerTabID == opener.id)

        // The popup sits at the top of Today, above `unrelated`, not adjacent to `opener`.
        session.tabDidRequestClose(popup)
        #expect(!session.activeSpace.tabs.contains { $0 === popup })
        #expect(session.activeTab === opener)
        #expect(session.activeSpace.tabs.contains { $0 === unrelated })
    }

    @Test("Closing a script-opened child falls back to its neighbour when the opener is gone")
    func closingChildFallsBackWhenOpenerClosed() {
        let session = TestSession.make().0
        let opener = session.newTab(url: URL(string: "https://soundon.example/login")!)
        let unrelated = session.newTab(url: URL(string: "https://other.example")!)
        session.selectTab(opener)

        let config = WebEnvironment.shared.makeConfiguration(for: session.activeSpace.identity)
        let popup = session.adoptChildTab(of: opener, configuration: config)
        session.closeTab(opener)
        #expect(session.activeTab === popup)

        session.tabDidRequestClose(popup)
        #expect(!session.activeSpace.tabs.contains { $0 === popup })
        #expect(session.activeTab === unrelated)
    }

    @Test("Page-initiated close respects a locked tab")
    func pageCloseRespectsLockedTab() {
        let session = TestSession.make().0
        let tab = session.newTab(url: URL(string: "https://example.com")!)
        tab.setLocked(true)

        session.tabDidRequestClose(tab)
        #expect(session.activeSpace.tabs.contains { $0 === tab })
    }

    @Test("PageWebCoordinator forwards webViewDidClose to onClose")
    func pageCoordinatorForwardsClose() {
        var closed = false
        let coordinator = PageWebCoordinator(onClose: { closed = true })
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.webViewDidClose(wv)
        #expect(closed)
    }

    @Test("Live OAuth popup closes itself via window.close and returns focus to opener")
    func liveOAuthPopupClosesAndReturnsToOpener() async throws {
        let server = try OAuthLoopbackServer()
        defer { server.stop() }

        let session = TestSession.make().0
        let opener = session.newTab(url: server.loginURL)
        _ = session.newTab(url: URL(string: "https://other.example")!)
        session.selectTab(opener)

        let openerView = opener.webView()
        // Allow headless test script to trigger `window.open` without a synthetic click;
        // once opened, `window.close()` exercises the real WebKit popup close path.
        openerView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        for _ in 0..<100 {
            if !openerView.isLoading, openerView.url != nil,
               let ready = try? await openerView.evaluateJavaScript("document.readyState") as? String,
               ready == "complete" {
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }

        _ = try await openerView.evaluateJavaScript("window.startOAuth(); true;")

        // Wait for the popup tab to open, broadcast its token, and close itself.
        var receivedToken: String?
        for _ in 0..<150 {
            if let token = try? await openerView.evaluateJavaScript("window.__oauthToken || ''") as? String,
               !token.isEmpty,
               session.activeTab === opener,
               session.activeSpace.tabs.count == 3 {
                receivedToken = token
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }

        #expect(receivedToken == "ok-token")
        #expect(session.activeTab === opener)
        // Initial placeholder + opener + unrelated; the OAuth popup tab is gone.
        #expect(session.activeSpace.tabs.count == 3)
    }
}

private final class OAuthLoopbackServer: @unchecked Sendable {
    private let listenFD: Int32
    let loginURL: URL
    private var running = true

    init() throws {
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
        listen(fd, 16)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        self.listenFD = fd
        self.loginURL = URL(string: "http://127.0.0.1:\(port)/login")!

        let loginHTML = """
        <!doctype html><html><body><script>
        window.startOAuth = function() {
          const ch = new BroadcastChannel('oauth_test_channel');
          ch.onmessage = function(e) { window.__oauthToken = e.data; };
          window.open('/login/oauth/middle?lang=en', 'Google Auth', 'popup=1,width=400,height=700');
        };
        </script></body></html>
        """
        let callbackHTML = """
        <!doctype html><html><body><script>
        history.replaceState(history.state, '', '/login/oauth/middle?lang=en');
        new BroadcastChannel('oauth_test_channel').postMessage('ok-token');
        try {
          window.opener = null;
          window.open('', '_self');
          window.close();
        } catch (e) {}
        </script></body></html>
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.running == true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                var buf = [UInt8](repeating: 0, count: 2048)
                let count = read(client, &buf, buf.count)
                let req = count > 0 ? String(decoding: buf[0..<count], as: UTF8.self) : ""
                let html = req.contains("/login/oauth/middle") ? callbackHTML : loginHTML
                let body = Data(html.utf8)
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
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
