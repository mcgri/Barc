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

    @Test("A field with no saved logins never opens a keyboard-blocking menu")
    func noMatchesLeaveFieldUsable() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        defer { window.close() }
        let tracking = PasswordMenuTrackingProbe()
        NotificationCenter.default.addObserver(tracking, selector: #selector(tracking.menuTrackingStarted(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(tracking) }
        let service = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in [] })
        let selected = try await service.selectedCredential(for: first.host, identity: .standard, scheme: "https", port: 0,
            in: web, field: NSRect(x: 10, y: 10, width: 200, height: 30))
        tracking.stop()
        #expect(selected == nil)
        #expect(!tracking.didTrack, "Clicking an empty login field must leave keystrokes with the page")
    }

    @Test("Saved-account suggestions keep field focus and pass the first typed character through")
    func typingWithSavedAccounts() async throws {
        let (web, window) = try await inputWindow()
        defer { PasswordSuggestionMenu.dismiss(in: web); window.close() }
        let responder = window.firstResponder
        let selection = Task { await PasswordSuggestionMenu.choose([first, second], in: web,
            field: NSRect(x: 10, y: 10, width: 240, height: 30)) }
        let panel = try await suggestionPanel(in: window)
        #expect(!panel.canBecomeKey && !panel.isKeyWindow)
        #expect(window.firstResponder === responder)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        NSApp.sendEvent(event)
        #expect(await selection.value == nil)
        #expect(!panel.isVisible)
        #expect(try await web.evaluateJavaScript("document.getElementById('email').value") as? String == "x")
    }

    @Test("Clicking a saved account explicitly selects it without taking field focus")
    func nonactivatingSelection() async throws {
        let (web, window) = try await inputWindow()
        defer { PasswordSuggestionMenu.dismiss(in: web); window.close() }
        let responder = window.firstResponder
        let selection = Task { await PasswordSuggestionMenu.choose([first, second], in: web,
            field: NSRect(x: 10, y: 10, width: 240, height: 30)) }
        let panel = try await suggestionPanel(in: window)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let button = try #require(panel.contentView.flatMap { buttons(in: $0).first { $0.title == second.username } })
        #expect(!button.acceptsFirstResponder && !button.needsPanelToBecomeKey)
        #expect(button.convert(button.bounds, to: nil).intersects(NSRect(origin: .zero, size: panel.frame.size)))
        if let path = ProcessInfo.processInfo.environment["BARC_LOGIN_SUGGESTION_PREVIEW"] {
            let view = try #require(panel.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        button.performClick(nil)
        #expect(await selection.value == second)
        #expect(window.firstResponder === responder && !panel.isVisible)
    }

    @Test("Return submits normally until an account has been explicitly highlighted", arguments: [false, true])
    func explicitKeyboardSelection(highlight: Bool) async throws {
        let (web, window) = try await inputWindow()
        defer { PasswordSuggestionMenu.dismiss(in: web); window.close() }
        let selection = Task { await PasswordSuggestionMenu.choose([first, second], in: web,
            field: NSRect(x: 10, y: 10, width: 240, height: 30)) }
        _ = try await suggestionPanel(in: window)
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        if highlight { try key(125, "\u{f701}") }
        try key(36, "\r")
        #expect(await selection.value == (highlight ? first : nil))
        #expect(try await web.evaluateJavaScript("window.submissions || 0") as? Int == (highlight ? 0 : 1))
    }

    @Test("Closing the owner or cancelling the lookup removes suggestions and resumes its reply", arguments: [false, true])
    func dismissPresentation(cancelTask: Bool) async throws {
        let (web, window) = try await inputWindow()
        defer { PasswordSuggestionMenu.dismiss(in: web); window.close() }
        let selection = Task { await PasswordSuggestionMenu.choose([first], in: web,
            field: NSRect(x: 10, y: 10, width: 240, height: 30)) }
        let panel = try await suggestionPanel(in: window)
        if cancelTask { selection.cancel() } else { window.close() }
        #expect(await selection.value == nil)
        #expect(!panel.isVisible)
    }

    @Test("Editing or leaving a field cancels lookup and discards a delayed saved-login reply", arguments: ["input", "field", "window"])
    func delayedReplyDoesNotOverwriteField(change: String) async throws {
        let controller = WKUserContentController()
        PasswordAutofill(settings: settings()).attach(controller)
        controller.removeScriptMessageHandler(forName: "barcPasswords", contentWorld: PasswordAutofill.contentWorld)
        let probe = DelayedPasswordReplyProbe(credential: first)
        controller.addScriptMessageHandler(probe, contentWorld: PasswordAutofill.contentWorld, name: "barcPasswords")
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { probe.finish(); window.close() }
        web.loadHTMLString("<input id='email' type='email'><input id='other'>", baseURL: URL(string: "https://accounts.example.invalid/"))
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await web.callAsyncJavaScript("document.getElementById('email').focus()", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<200 where !probe.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.isWaiting)
        _ = try await web.callAsyncJavaScript("""
            const field = document.getElementById('email');
            if (change === 'window') window.dispatchEvent(new Event('blur'));
            else if (change === 'field') document.getElementById('other').focus();
            else { field.value = 'manual@example.invalid'; field.dispatchEvent(new Event('input', {bubbles: true})); }
            """, arguments: ["change": change], in: nil, contentWorld: .page)
        for _ in 0..<200 where probe.dismissals == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.dismissals == 1)
        // A subsequent evaluation runs after the resolved message's page microtasks.
        #expect(try await web.evaluateJavaScript("document.getElementById('email').value") as? String == (change == "input" ? "manual@example.invalid" : ""))
    }

    @Test("Typing during a real vault lookup prevents its eventual suggestions from appearing")
    func delayedReaderDoesNotOpenPicker() async throws {
        let gate = DispatchSemaphore(value: 0), credential = first
        defer { gate.signal() }
        var chooserCalls = 0
        let service = PasswordAutofill(settings: settings(), readCredentials: { _, _, _, _ in
            _ = gate.wait(timeout: .now() + 10)
            return [credential]
        }, chooseCredential: { _, _, _ in chooserCalls += 1; return credential }, identityProvider: { _ in .standard })
        let controller = WKUserContentController(); service.attach(controller)
        controller.removeScriptMessageHandler(forName: "barcPasswords", contentWorld: PasswordAutofill.contentWorld)
        let probe = ForwardingPasswordProbe(service: service)
        controller.addScriptMessageHandler(probe, contentWorld: PasswordAutofill.contentWorld, name: "barcPasswords")
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        web.loadHTMLString("<input id='email' type='email'>", baseURL: URL(string: "https://accounts.example.invalid/"))
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await web.callAsyncJavaScript("document.getElementById('email').focus()", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<200 where !probe.started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.started)
        _ = try await web.evaluateJavaScript("const field = document.getElementById('email'); field.value = 'manual@example.invalid'; field.dispatchEvent(new Event('input', {bubbles:true}));")
        for _ in 0..<200 where !probe.dismissed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.dismissed)
        gate.signal()
        for _ in 0..<200 where !probe.finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.finished && chooserCalls == 0)
        #expect(try await web.evaluateJavaScript("document.getElementById('email').value") as? String == "manual@example.invalid")
    }

    private func inputWindow() async throws -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        web.loadHTMLString("""
            <form onsubmit='event.preventDefault(); window.submissions = (window.submissions || 0) + 1'>
              <input id='email' type='text'><button type='submit'>Continue</button>
            </form>
            """, baseURL: URL(string: "https://accounts.example.invalid/"))
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await web.evaluateJavaScript("document.getElementById('email').focus()")
        return (web, window)
    }

    private func suggestionPanel(in window: NSWindow) async throws -> NSWindow {
        for _ in 0..<200 where window.childWindows?.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(window.childWindows?.first { $0.identifier?.rawValue == "BarcSavedLoginSuggestions" })
    }

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

@MainActor
private final class PasswordMenuTrackingProbe: NSObject {
    var didTrack = false
    private weak var menu: NSMenu?
    private var cancellation: Timer?
    @objc func menuTrackingStarted(_ note: Notification) {
        didTrack = true
        menu = note.object as? NSMenu
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(cancelTrackedMenu), userInfo: nil, repeats: true)
        cancellation = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
    }
    @objc private func cancelTrackedMenu() { menu?.cancelTrackingWithoutAnimation() }
    func stop() { cancellation?.invalidate(); cancellation = nil }
}

@MainActor
private final class DelayedPasswordReplyProbe: NSObject, WKScriptMessageHandlerWithReply {
    let credential: PasswordCredential
    private var waiting: CheckedContinuation<(Any?, String?), Never>?
    var isWaiting: Bool { waiting != nil }
    var dismissals = 0
    init(credential: PasswordCredential) { self.credential = credential }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let body = message.body as? [String: Any]
        if body?["action"] as? String == "lookup" {
            return await withCheckedContinuation { waiting = $0 }
        }
        if body?["action"] as? String == "dismiss" { dismissals += 1; finish() }
        return (nil, nil)
    }
    func finish() {
        let reply = waiting; waiting = nil
        reply?.resume(returning: (["username": credential.username], nil))
    }
}

@MainActor
private final class ForwardingPasswordProbe: NSObject, WKScriptMessageHandlerWithReply {
    let service: PasswordAutofill
    var started = false
    var finished = false
    var dismissed = false
    init(service: PasswordAutofill) { self.service = service }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let action = (message.body as? [String: Any])?["action"] as? String
        if action == "lookup" { started = true }
        let reply = await service.userContentController(controller, didReceive: message)
        if action == "lookup" { finished = true }
        if action == "dismiss" { dismissed = true }
        return reply
    }
}
