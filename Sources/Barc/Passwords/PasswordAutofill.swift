// Modified for Barc: responsive password lookup without blocking sidebar input, 2026-10-24.
import AppKit
import WebKit
import LocalAuthentication

/// Fills saved logins into pages and offers to save new ones, backed by the
/// macOS Keychain. A small script in each page watches a login form's
/// fields and, when the user interacts with one, asks native for a credential; on
/// submit it hands the typed login back to be saved.
///
/// The site a request is for is read from the frame's real URL, never from the
/// page, so a page can only ever reach the logins saved for its own origin --
/// the one boundary that makes exposing this to page JavaScript safe.
@MainActor
final class PasswordAutofill: NSObject {
    static let shared = PasswordAutofill()
    typealias CredentialReader = @Sendable (String, Space.Identity, String, Int) -> [PasswordCredential]
    private let settings: Settings
    private let readCredentials: CredentialReader
    private static let messageName = "barcPasswords"

    init(settings: Settings = .shared, readCredentials: @escaping CredentialReader = {
        KeychainPasswordStore.credentials(host: $0, identity: $1, scheme: $2, port: $3)
    }) {
        self.settings = settings
        self.readCredentials = readCredentials
        super.init()
    }

    func attach(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    // MARK: - Backing the script

    func credential(for host: String, identity: Space.Identity, scheme: String, port: Int) async -> PasswordCredential? {
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill,
              !identity.isPrivate, !host.isEmpty else { return nil }
        let found = await credentials(host: host, identity: identity, scheme: scheme, port: port)
        // A system approval may take time. Respect a preference changed while
        // waiting instead of filling after the user switched the feature off.
        guard settings.passwordProvider == .keychain, settings.passwordOfferAutofill else { return nil }
        return found.first
    }

    private func credentials(host: String, identity: Space.Identity, scheme: String, port: Int) async -> [PasswordCredential] {
        let read = readCredentials
        return await Task.detached(priority: .userInitiated) { read(host, identity, scheme, port) }.value
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
        let existing = await credentials(host: host, identity: identity, scheme: scheme, port: port)
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
        guard let webView = message.webView,
              let identity = WebEnvironment.shared.identity(for: webView.configuration.websiteDataStore), !identity.isPrivate,
              let frameURL = message.frameInfo.request.url ?? webView.url,
              let host = frameURL.host(), let scheme = frameURL.scheme, ["http", "https"].contains(scheme) else { return (nil, nil) }
        let port = KeychainPasswordStore.port(for: frameURL)
        switch action {
        case "lookup":
            guard let credential = await credential(for: host, identity: identity, scheme: scheme, port: port), await authorize(),
                  settings.passwordProvider == .keychain, settings.passwordOfferAutofill else { return (nil, nil) }
            return ([
                "username": credential.username,
                "password": credential.password,
                "submit": settings.passwordSubmitAutomatically
            ], nil)
        case "save":
            // Show the prompt on the next tick rather than blocking the reply
            // handler with a modal while the page is navigating away on submit.
            let username = body["username"] as? String ?? ""
            let password = body["password"] as? String ?? ""
            Task { await self.offerToSave(host: host, username: username, password: password, identity: identity, scheme: scheme, port: port) }
            return (nil, nil)
        default:
            return (nil, nil)
        }
    }
}

private extension PasswordAutofill {
    /// Runs in the page: wires a login form's fields so a click fills the saved
    /// login, and reports the typed login on submit so it can be saved. It asks
    /// native only during an actual user interaction. Page scripts routinely
    /// focus login fields on load; that must not start a keychain approval.
    static let script = """
    (function() {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.barcPasswords;
      if (!handler) return;
      let filled = false;
      let filling = false;

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

      async function fillInto(pw) {
        if (filled || filling) return;
        filling = true;
        try {
          const creds = await handler.postMessage({ action: 'lookup' });
          if (!creds) return;
          filled = true;
          const user = usernameNear(pw);
          if (user && creds.username) setValue(user, creds.username);
          if (creds.password) setValue(pw, creds.password);
          if (creds.submit && pw.form && pw.form.requestSubmit) pw.form.requestSubmit();
        } catch (e) {} finally { filling = false; }
      }

      function wire() {
        const pw = document.querySelector('input[type="password"]');
        if (!pw || pw.dataset.barcWired) return;
        pw.dataset.barcWired = '1';
        const trigger = function(event) {
          if (!event.isTrusted || !navigator.userActivation || !navigator.userActivation.isActive) return;
          fillInto(pw);
        };
        pw.addEventListener('focus', trigger);
        pw.addEventListener('click', trigger);
        const user = usernameNear(pw);
        if (user) {
          user.addEventListener('focus', trigger);
          user.addEventListener('click', trigger);
        }
      }

      document.addEventListener('submit', function(e) {
        const form = e.target;
        if (!form || !form.querySelectorAll) return;
        const pw = form.querySelector('input[type="password"]');
        if (!pw || !pw.value) return;
        const user = usernameNear(pw, form);
        handler.postMessage({ action: 'save', username: user ? user.value : '', password: pw.value });
      }, true);

      wire();
      new MutationObserver(function() { wire(); }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}
