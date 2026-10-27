// Modified for Barc: profile-scoped account suggestions for two-step sign-in, 2026-10-25.
// Modified for Barc: responsive password lookup without blocking sidebar input, 2026-10-24.
import AppKit
import WebKit
import LocalAuthentication

/// Fills saved logins into pages and offers to save new ones, backed by the
/// macOS Keychain. An isolated script watches login fields, including the
/// username-only first step, and asks native to offer saved accounts; on
/// submit it hands the typed login back to be saved.
///
/// The site a request is for is read from the frame's real URL, never from the
/// page, so a page can only ever reach the logins saved for its own origin --
/// the one boundary that makes exposing this to page JavaScript safe.
@MainActor
final class PasswordAutofill: NSObject {
    static let shared = PasswordAutofill()
    typealias CredentialReader = @Sendable (String, Space.Identity, String, Int) throws -> [PasswordCredential]
    typealias CredentialChooser = @MainActor ([PasswordCredential], WKWebView, NSRect) async -> PasswordCredential?
    static let contentWorld = WKContentWorld.world(name: "BarcPasswordAutofill")
    typealias IdentityProvider = @MainActor (WKWebsiteDataStore) -> Space.Identity?
    private let identityProvider: IdentityProvider
    private let chooseCredential: CredentialChooser
    private struct LoginScope: Hashable {
        let identity: Space.Identity
        let host: String
        let scheme: String
        let port: Int
    }
    private var selectedUsernames: [LoginScope: String] = [:]
    private let lookupRequests = NSMapTable<WKWebView, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let settings: Settings
    private let readCredentials: CredentialReader
    private static let messageName = "barcPasswords"

    init(settings: Settings = .shared, readCredentials: @escaping CredentialReader = {
        // Keep a blocked Keychain approval off the window thread, including retries.
        KeychainPasswordStore.prepareForAccess()
        return try KeychainPasswordStore.lookupCredentials(host: $0, identity: $1, scheme: $2, port: $3)
    }, chooseCredential: CredentialChooser? = nil,
       identityProvider: @escaping IdentityProvider = { WebEnvironment.shared.identity(for: $0) }) {
        self.settings = settings
        self.readCredentials = readCredentials
        self.identityProvider = identityProvider
        self.chooseCredential = chooseCredential ?? { credentials, webView, rect in
            await PasswordSuggestionMenu.choose(credentials, in: webView, field: rect)
        }
        super.init()
    }

    func attach(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: Self.contentWorld, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.contentWorld))
    }

    // MARK: - Backing the script

    func credential(for host: String, identity: Space.Identity, scheme: String, port: Int) async -> PasswordCredential? {
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill,
              !identity.isPrivate, !host.isEmpty else { return nil }
        guard let found = try? await credentials(host: host, identity: identity, scheme: scheme, port: port) else { return nil }
        // A system approval may take time. Respect a preference changed while
        // waiting instead of filling after the user switched the feature off.
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill else { return nil }
        return found.first
    }

    private func credentials(host: String, identity: Space.Identity, scheme: String, port: Int) async throws -> [PasswordCredential] {
        let read = readCredentials
        return try await Task.detached(priority: .userInitiated) { try read(host, identity, scheme, port) }.value
    }

    func selectedCredential(for host: String, identity: Space.Identity, scheme: String, port: Int,
                            in webView: WKWebView, field: NSRect, validatesContext: () -> Bool = { true }) async throws -> PasswordCredential? {
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill,
              !identity.isPrivate, !host.isEmpty else { return nil }
        let found = try await credentials(host: host, identity: identity, scheme: scheme, port: port)
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill, validatesContext() else { return nil }
        guard !found.isEmpty else { return nil }
        let selected = await chooseCredential(found, webView, field)
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill,
              validatesContext(), let selected, found.contains(selected) else { return nil }
        return selected
    }

    static func reply(for credential: PasswordCredential, usernameOnly: Bool, submit: Bool) -> [String: Any] {
        if usernameOnly { return ["username": credential.username] }
        return ["username": credential.username, "password": credential.password, "submit": submit]
    }

    /// Touch ID (or the login password) before a saved password is revealed to a
    /// page, when the setting asks for it. A machine with no biometrics falls
    /// through so autofill still works.
    private func authorize() async -> Bool {
        guard settings.passwordUsesTouchID else { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill your saved password") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func offerToSave(host: String, username: String, password: String, identity: Space.Identity, scheme: String, port: Int) async {
        guard settings.passwordProvider == .keychain, settings.passwordOfferSave, !identity.isPrivate, !host.isEmpty, !password.isEmpty else { return }
        guard let existing = try? await credentials(host: host, identity: identity, scheme: scheme, port: port) else { return }
        guard settings.passwordProvider == .keychain, settings.passwordOfferSave else { return }
        // Nothing to do if this exact login is already stored.
        if existing.contains(where: { $0.username == username && $0.password == password }) { return }
        let updating = existing.contains { $0.username == username }
        let alert = NSAlert()
        alert.messageText = updating ? "Update the password for \(host)?" : "Save this password for \(host)?"
        alert.informativeText = username.isEmpty ? "Barc can fill it in for you next time." : "Username: \(username)"
        alert.addButton(withTitle: updating ? "Update" : "Save Password")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            let path = existing.first { $0.username == username }?.storagePath
            _ = await Task.detached(priority: .userInitiated) {
                KeychainPasswordStore.save(host: host, username: username, password: password, identity: identity, scheme: scheme, port: port,
                                           storagePath: path)
            }.value
        }
    }
}

extension PasswordAutofill: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return (nil, nil) }
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let identity = identityProvider(webView.configuration.websiteDataStore), !identity.isPrivate,
              let frameURL = message.frameInfo.request.url ?? webView.url,
              let host = frameURL.host(), let scheme = frameURL.scheme, ["http", "https"].contains(scheme) else { return (nil, nil) }
        let port = KeychainPasswordStore.port(for: frameURL)
        switch action {
        case "dismiss":
            guard let request = body["request"] as? String,
                  lookupRequests.object(forKey: webView) as String? == request else { return (nil, nil) }
            lookupRequests.removeObject(forKey: webView)
            PasswordSuggestionMenu.dismiss(in: webView)
            return (nil, nil)
        case "lookup":
            guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill,
                  let rect = PasswordSuggestionMenu.fieldRect(body["rect"]),
                  let request = body["request"] as? String, request.utf8.count <= 128 else { return (nil, nil) }
            PasswordSuggestionMenu.dismiss(in: webView)
            lookupRequests.setObject(request as NSString, forKey: webView)
            defer {
                if lookupRequests.object(forKey: webView) as String? == request { lookupRequests.removeObject(forKey: webView) }
            }
            let usernameOnly = body["field"] as? String == "username"
            let scope = LoginScope(identity: identity, host: host, scheme: scheme, port: port)
            do {
                guard let credential = try await selectedCredential(for: host, identity: identity, scheme: scheme, port: port,
                        in: webView, field: rect, validatesContext: {
                            webView.url == frameURL && identityProvider(webView.configuration.websiteDataStore) == identity
                                && lookupRequests.object(forKey: webView) as String? == request
                        }) else { return (nil, nil) }
                if !usernameOnly, !(await authorize()) { return (nil, nil) }
                guard webView.url == frameURL,
                      lookupRequests.object(forKey: webView) as String? == request,
                      identityProvider(webView.configuration.websiteDataStore) == identity,
                      settings.passwordProvider == .keychain, settings.passwordOfferAutofill else { return (nil, nil) }
                selectedUsernames[scope] = credential.username
                return (Self.reply(for: credential, usernameOnly: usernameOnly, submit: settings.passwordSubmitAutomatically), nil)
            } catch {
                if webView.url == frameURL, lookupRequests.object(forKey: webView) as String? == request,
                   identityProvider(webView.configuration.websiteDataStore) == identity,
                   settings.passwordProvider == .keychain, settings.passwordOfferAutofill {
                    PasswordSuggestionMenu.showUnavailable(in: webView, field: rect)
                }
                return (nil, nil)
            }
        case "save":
            // Show the prompt on the next tick rather than blocking the reply
            // handler with a modal while the page is navigating away on submit.
            let suppliedUsername = body["username"] as? String ?? ""
            let scope = LoginScope(identity: identity, host: host, scheme: scheme, port: port)
            let username = suppliedUsername.isEmpty ? (selectedUsernames[scope] ?? "") : suppliedUsername
            let password = body["password"] as? String ?? ""
            Task { await self.offerToSave(host: host, username: username, password: password, identity: identity, scheme: scheme, port: port) }
            return (nil, nil)
        default:
            return (nil, nil)
        }
    }
}

private extension PasswordAutofill {
    /// Watches login fields in an isolated world so a click offers saved
    /// accounts, and reports typed logins on submit so they can be saved. It asks
    /// native only during an actual user interaction. Page scripts routinely
    /// focus login fields on load; that must not start a keychain approval.
    static let script = """
    (function() {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.barcPasswords;
      if (!handler) return;
      let pending = null;
      let requestSequence = 0;
      const documentToken = Date.now().toString(36) + Math.random().toString(36).slice(2);

      function setValue(el, value) {
        try {
          const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, value);
        } catch (e) { el.value = value; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      function usernameNear(pw, root) {
        const inputs = Array.prototype.slice.call((root || document).querySelectorAll('input'));
        const i = inputs.indexOf(pw);
        for (let j = i - 1; j >= 0; j--) {
          const t = (inputs[j].type || 'text').toLowerCase();
          if (t === 'text' || t === 'email' || t === 'tel') return inputs[j];
        }
        return null;
      }

      function loginField(el) {
        if (!(el instanceof HTMLInputElement) || el.disabled || el.readOnly || !el.getClientRects().length) return null;
        const type = (el.type || 'text').toLowerCase();
        const autocomplete = (el.autocomplete || '').toLowerCase().split(/\\s+/);
        if (autocomplete.includes('new-password') || autocomplete.includes('one-time-code')) return null;
        if (type === 'password') return 'password';
        if (type === 'email' || autocomplete.includes('username')) return 'username';
        if (type === 'text' || type === 'tel') {
          const hint = [el.id, el.name].join(' ').toLowerCase();
          if (/user|login|email|identifier/.test(hint)) return 'username';
          const pw = (el.form || document).querySelector('input[type="password"]');
          if (pw && usernameNear(pw, el.form) === el) return 'username';
        }
        return null;
      }

      async function fillInto(field, kind) {
        if (pending) return;
        const lookup = { field, value: field.value, request: documentToken + ':' + (++requestSequence) };
        pending = lookup;
        const originalURL = location.href;
        try {
          const rect = field.getBoundingClientRect();
          const creds = await handler.postMessage({ action: 'lookup', field: kind, request: lookup.request,
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } });
          if (!creds || pending !== lookup || !field.isConnected || location.href !== originalURL ||
              document.activeElement !== field || field.value !== lookup.value) return;
          pending = null;
          if (kind === 'username') {
            if (creds.username) setValue(field, creds.username);
            return;
          }
          const user = usernameNear(field, field.form);
          if (user && creds.username) setValue(user, creds.username);
          if (creds.password) setValue(field, creds.password);
          if (creds.submit && field.form && field.form.requestSubmit) field.form.requestSubmit();
        } catch (e) {} finally { if (pending === lookup) pending = null; }
      }

      function dismiss() {
        if (!pending) return;
        const lookup = pending;
        pending = null;
        handler.postMessage({ action: 'dismiss', request: lookup.request }).catch(() => {});
      }

      document.addEventListener('input', event => { if (pending && event.target === pending.field) dismiss(); }, true);
      document.addEventListener('focusout', event => { if (pending && event.target === pending.field) dismiss(); }, true);
      document.addEventListener('pointerdown', event => { if (pending && event.target !== pending.field) dismiss(); }, true);
      window.addEventListener('pagehide', dismiss, true);
      window.addEventListener('blur', dismiss, true);

      function trigger(event) {
        if (!event.isTrusted || !navigator.userActivation || !navigator.userActivation.isActive) return;
        if (event.type === 'keydown' && event.key !== 'ArrowDown') { dismiss(); return; }
        const field = event.target;
        const kind = loginField(field);
        if (kind) fillInto(field, kind);
      }
      document.addEventListener('focusin', trigger, true);
      document.addEventListener('click', trigger, true);
      document.addEventListener('keydown', trigger, true);

      document.addEventListener('submit', function(e) {
        const form = e.target;
        if (!form || !form.querySelectorAll) return;
        const pw = form.querySelector('input[type="password"]');
        if (!pw || !pw.value) return;
        const user = usernameNear(pw, form);
        handler.postMessage({ action: 'save', username: user ? user.value : '', password: pw.value });
      }, true);

    })();
    """
}
