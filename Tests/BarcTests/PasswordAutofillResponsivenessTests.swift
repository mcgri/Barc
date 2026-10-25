import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Password lookup keeps the browser responsive", .serialized)
@MainActor
struct PasswordAutofillResponsivenessTests {
    @Test("A waiting password reader leaves the window thread free to respond")
    func keychainWait() async throws {
        let suite = "barc.autofill-response.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.passwordOfferAutofill = true
        settings.passwordProvider = .keychain
        let expected = PasswordCredential(host: "fixture.invalid", username: "fixture", password: "fictional-password")
        let scope = Space.Identity.makeIsolated()
        let autofill = PasswordAutofill(settings: settings, readCredentials: { host, identity, scheme, port in
            #expect(!Thread.isMainThread)
            #expect(host == "fixture.invalid" && identity == scope && scheme == "https" && port == 8443)
            let response = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { response.signal() }
            #expect(response.wait(timeout: .now() + 90) == .success)
            return [expected]
        })
        let actual = await autofill.credential(for: "fixture.invalid", identity: scope, scheme: "https", port: 8443)
        #expect(actual == expected)
    }

    @Test("A login field needs user interaction, including username-only sign-in pages", arguments: [false, true])
    func programmaticFocus(usernameOnly: Bool) async throws {
        let controller = WKUserContentController()
        let autofill = PasswordAutofill()
        autofill.attach(controller)
        controller.removeScriptMessageHandler(forName: "barcPasswords", contentWorld: PasswordAutofill.contentWorld)
        let probe = AutofillMessageProbe()
        controller.addScriptMessageHandler(probe, contentWorld: .page, name: "barcPasswords")
        controller.addScriptMessageHandler(probe, contentWorld: PasswordAutofill.contentWorld, name: "barcPasswords")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        defer { window.close() }
        let load = AutofillFixtureLoader()
        web.navigationDelegate = load
        try await load.load(web, usernameOnly: usernameOnly)
        // WebKit treats callAsyncJavaScript as a user gesture. Let the page's
        // own load handler focus the field, as a real login page does.
        for _ in 0..<100 where !probe.actions.contains("probe") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(probe.focusCount == 1, "The fixture really delivered a focus event")
        #expect(probe.userActivation == false, "The focus came from the page, without a user gesture")
        #expect(probe.actions.contains("probe"), "The actual installed page script has a working native bridge")
        #expect(!probe.actions.contains("lookup"))

        // WebKit grants this native evaluation user activation. Use it as a
        // positive control: the same installed focus handler must still work
        // once the browser is handling an active interaction.
        _ = try await web.callAsyncJavaScript("""
            const user = document.getElementById('username');
            user.blur(); user.focus();
            await window.webkit.messageHandlers.barcPasswords.postMessage({ action: 'activatedProbe' });
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(probe.actions.contains("lookup"))
    }

    @Test("Turning autofill off during a lookup discards its eventual result")
    func changedPreferenceWhileWaiting() async throws {
        let suite = "barc.autofill-preference.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.passwordOfferAutofill = true
        settings.passwordProvider = .keychain
        let autofill = PasswordAutofill(settings: settings, readCredentials: { _, _, _, _ in
            let response = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { settings.passwordOfferAutofill = false; response.signal() }
            #expect(response.wait(timeout: .now() + 90) == .success)
            return [.init(host: "fixture.invalid", username: "fixture", password: "fictional-password")]
        })
        #expect(await autofill.credential(for: "fixture.invalid", identity: .standard, scheme: "https", port: 0) == nil)
    }

    @Test("Private browsing and disabled autofill never ask the reader for a credential")
    func privateAndDisabled() async throws {
        let suite = "barc.autofill-disabled.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.passwordOfferAutofill = true
        settings.passwordProvider = .keychain
        let autofill = PasswordAutofill(settings: settings, readCredentials: { _, _, _, _ in
            Issue.record("An excluded page must not reach the password reader")
            return []
        })
        #expect(await autofill.credential(for: "fixture.invalid", identity: .makeEphemeral(), scheme: "https", port: 0) == nil)
        settings.passwordOfferAutofill = false
        #expect(await autofill.credential(for: "fixture.invalid", identity: .standard, scheme: "https", port: 0) == nil)
    }
}

@MainActor
private final class AutofillMessageProbe: NSObject, WKScriptMessageHandlerWithReply {
    var actions: [String] = []
    var focusCount: Int?
    var userActivation: Bool?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        if let body = message.body as? [String: Any], let action = body["action"] as? String {
            actions.append(action)
            if action == "probe" {
                focusCount = body["focused"] as? Int
                userActivation = body["activation"] as? Bool
            }
        }
        return (nil, nil)
    }
}

@MainActor
private final class AutofillFixtureLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, usernameOnly: Bool = false) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            web.loadHTMLString("""
                <input id='username' type='email'>\(usernameOnly ? "" : "<input type='password'>")
                <script>
                window.addEventListener('load', () => setTimeout(() => {
                  const user = document.getElementById('username');
                  user.blur();
                  let focused = 0;
                  user.addEventListener('focus', () => focused++);
                  user.focus();
                  window.webkit.messageHandlers.barcPasswords.postMessage({
                    action: 'probe', focused, activation: navigator.userActivation.isActive
                  });
                }, 100));
                </script>
                """, baseURL: URL(string: "https://autofill-fixture.invalid/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.finish(.failure(NSError(domain: "AutofillFixture", code: 1)))
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
