// Added for Barc: one-time default-browser invitation, 2026-10-25.
import AppKit

@MainActor
enum DefaultBrowserInvitation {
    /// Called before WhatsNew records this launch. Existing installations do
    /// not get a new prompt just because they installed this update.
    static func takeInvitation(settings: Settings, isDefault: Bool) -> Bool {
        guard !settings.defaultBrowserInvitationHandled else { return false }
        settings.defaultBrowserInvitationHandled = true
        let hasLaunchedBefore = !(settings.lastLaunchedVersion ?? "").isEmpty
        return !hasLaunchedBefore && !isDefault
    }

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Make Barc your default browser?"
        alert.informativeText = "Open web links from other apps in Barc. You can change this later in Barc Settings > General."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    static func presentIfNeeded(on window: NSWindow?, settings: Settings = .shared) {
        guard let window, takeInvitation(settings: settings, isDefault: DefaultBrowser.isBarc) else { return }
        // Record the invitation before presenting. Declining, cancelling a
        // system confirmation or quitting must not cause another prompt.
        makeAlert().beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak window] in
                guard case .failure(let message) = await DefaultBrowser.makeBarcDefault(),
                      let window else { return }
                let failure = NSAlert()
                failure.messageText = "Default browser unchanged"
                failure.informativeText = message + " Open Barc Settings > General to try again."
                failure.addButton(withTitle: "OK")
                _ = await failure.beginSheetModal(for: window)
            }
        }
    }
}
