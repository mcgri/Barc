// Modified for Barc: selected-account autofill and username-only reply isolation, 2026-10-25.
import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Saved login suggestions", .serialized)
@MainActor
struct PasswordSuggestionTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "barc.password-suggestions.\(UUID())")!)
    }
    private let first = PasswordCredential(host: "accounts.example.invalid", username: "first@example.invalid", password: "fictional-first")
    private let second = PasswordCredential(host: "accounts.example.invalid", username: "second@example.invalid", password: "fictional-second")

    @Test("The account chooser receives only the requested profile and origin and can select a second login")
    func selectedAccount() async throws {
        let identity = Space.Identity.makeIsolated(), a = first, b = second
        let service = PasswordAutofill(settings: settings(), readCredentials: { host, scope, scheme, port in
            #expect(host == "accounts.example.invalid" && scope == identity && scheme == "https" && port == 0)
            return [a, b]
        }, chooseCredential: { choices, _, _ in
            #expect(choices == [a, b]); return choices[1]
        })
        let chosen = try await service.selectedCredential(for: a.host, identity: identity, scheme: "https", port: 0,
            in: WKWebView(), field: NSRect(x: 10, y: 10, width: 200, height: 30))
        #expect(chosen == b)
    }

    @Test("Username-only pages receive no password or automatic-submit instruction")
    func usernameReply() {
        let reply = PasswordAutofill.reply(for: second, usernameOnly: true, submit: true)
        #expect(reply["username"] as? String == second.username)
        #expect(reply["password"] == nil && reply["submit"] == nil)
        let password = PasswordAutofill.reply(for: second, usernameOnly: false, submit: false)
        #expect(password["password"] as? String == second.password)
        #expect(password["submit"] as? Bool == false)
    }

    @Test("Cancellation, changed pages, and a chooser returning a foreign credential never fill")
    func cancelledOrStale() async throws {
        let a = first, b = second, identity = Space.Identity.makeIsolated()
        let web = WKWebView(), rect = NSRect(x: 0, y: 0, width: 100, height: 20)
        let stale = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in [a] }, chooseCredential: { _, _, _ in
            Issue.record("A page that moved on must not show its old login choices"); return a
        })
        #expect(try await stale.selectedCredential(for: a.host, identity: identity, scheme: "https", port: 0,
            in: web, field: rect, validatesContext: { false }) == nil)
        let foreign = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in [a] }, chooseCredential: { _, _, _ in b })
        #expect(try await foreign.selectedCredential(for: a.host, identity: identity, scheme: "https", port: 0, in: web, field: rect) == nil)
        let cancelled = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in [a] }, chooseCredential: { _, _, _ in nil })
        #expect(try await cancelled.selectedCredential(for: a.host, identity: identity, scheme: "https", port: 0, in: web, field: rect) == nil)
    }

    @Test("The real bridge fills a chosen account on an email-only step and a dynamically added password step")
    func twoStepPage() async throws {
        let a = first, b = second, identity = Space.Identity.makeIsolated()
        let settings = settings(); settings.passwordUsesTouchID = false
        var choices = 0
        let service = PasswordAutofill(settings: settings, readCredentials: { host, scope, scheme, port in
            #expect(!Thread.isMainThread)
            #expect(host == a.host && scope == identity && scheme == "https" && port == 0)
            return [a, b]
        }, chooseCredential: { credentials, _, _ in
            choices += 1; #expect(credentials == [a, b]); return credentials[1]
        }, identityProvider: { _ in identity })
        let controller = WKUserContentController(); service.attach(controller)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        web.loadHTMLString("<input id='identifierId' type='email' autocomplete='username'>", baseURL: URL(string: "https://accounts.example.invalid/"))
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        func focusAndRead(_ id: String) async throws -> String? {
            try await web.callAsyncJavaScript("""
                const el = document.getElementById(id);
                return await new Promise(resolve => {
                  const timer = setTimeout(() => resolve('timed out'), 5000);
                  el.addEventListener('change', () => { clearTimeout(timer); resolve(el.value); }, {once:true});
                  el.blur(); el.focus();
                });
                """, arguments: ["id": id], in: nil, contentWorld: .page) as? String
        }
        #expect(try await focusAndRead("identifierId") == b.username)
        #expect(choices == 1)
        _ = try await web.evaluateJavaScript("document.body.innerHTML = '<input id=pass type=password autocomplete=current-password>';")
        #expect(try await focusAndRead("pass") == b.password)
        #expect(choices == 2)
    }

    @Test("A vault failure stays an error instead of becoming an empty account list")
    func lockedVault() async {
        let service = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in
            throw WebsitePasswordVault.Failure.missingKey
        }, chooseCredential: { _, _, _ in Issue.record("A locked vault must not claim there are no saved accounts"); return nil })
        do {
            _ = try await service.selectedCredential(for: first.host, identity: .standard, scheme: "https", port: 0,
                in: WKWebView(), field: NSRect(x: 0, y: 0, width: 100, height: 20))
            Issue.record("Expected the vault error")
        } catch { #expect(error as? WebsitePasswordVault.Failure == .missingKey) }
    }

    @Test("The password bridge exists only in the browser's isolated script world")
    func isolatedBridge() async throws {
        let controller = WKUserContentController()
        PasswordAutofill(settings: settings()).attach(controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts[0].isForMainFrameOnly)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        web.loadHTMLString("<html><body>Bridge isolation fixture</body></html>", baseURL: URL(string: "https://fixture.invalid/"))
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let probe = "return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.barcPasswords);"
        let page = try await web.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .page) as? Bool
        let isolated = try await web.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: PasswordAutofill.contentWorld) as? Bool
        #expect(page == false && isolated == true)
    }
}
