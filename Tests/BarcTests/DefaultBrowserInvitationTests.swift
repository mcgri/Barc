// Added for Barc: one-time invitation and web-link defaults, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("First-launch default browser")
@MainActor
struct DefaultBrowserInvitationTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "barc.tests.\(UUID())")!)
    }

    @Test("A fresh install asks once, even when the user declines")
    func freshInstall() {
        let settings = settings()
        #expect(DefaultBrowserInvitation.takeInvitation(settings: settings, isDefault: false))
        #expect(settings.defaultBrowserInvitationHandled)
        #expect(!DefaultBrowserInvitation.takeInvitation(settings: settings, isDefault: false))
    }

    @Test("The answer survives a new Settings instance, relaunches and updates")
    func persists() {
        let defaults = UserDefaults(suiteName: "barc.tests.\(UUID())")!
        let first = Settings(defaults: defaults)
        #expect(DefaultBrowserInvitation.takeInvitation(settings: first, isDefault: false))
        let relaunched = Settings(defaults: defaults)
        relaunched.lastLaunchedVersion = "0.0.3"
        #expect(!DefaultBrowserInvitation.takeInvitation(settings: relaunched, isDefault: false))
    }

    @Test("An existing installation is not prompted after an update")
    func existingInstall() {
        let settings = settings()
        settings.lastLaunchedVersion = "0.0.2"
        #expect(!DefaultBrowserInvitation.takeInvitation(settings: settings, isDefault: false))
        #expect(settings.defaultBrowserInvitationHandled)
    }

    @Test("Already default does not prompt, even if the default changes later")
    func alreadyDefault() {
        let settings = settings()
        #expect(!DefaultBrowserInvitation.takeInvitation(settings: settings, isDefault: true))
        #expect(!DefaultBrowserInvitation.takeInvitation(settings: settings, isDefault: false))
    }

    @Test("A missing window does not consume the invitation")
    func missingWindow() {
        let settings = settings()
        DefaultBrowserInvitation.presentIfNeeded(on: nil, settings: settings)
        #expect(!settings.defaultBrowserInvitationHandled)
    }

    @Test("The invitation offers a choice and names the setting")
    func alertChoices() {
        let alert = DefaultBrowserInvitation.makeAlert()
        #expect(alert.buttons.map(\.title) == ["Make Default", "Not Now"])
        #expect(alert.informativeText.contains("Settings > General"))
    }

    @Test("HTTP and HTTPS must both belong to this installation")
    func bothSchemes() {
        let barc = URL(fileURLWithPath: "/Applications/Barc.app")
        let other = URL(fileURLWithPath: "/Applications/Other.app")
        #expect(DefaultBrowser.isDefault(applicationURL: barc) { _ in barc })
        #expect(!DefaultBrowser.isDefault(applicationURL: barc) { $0 == "https" ? barc : other })
        #expect(!DefaultBrowser.isDefault(applicationURL: barc) { $0 == "http" ? barc : other })
        #expect(!DefaultBrowser.isDefault(applicationURL: barc) { _ in nil })
        #expect(!DefaultBrowser.isDefault(applicationURL: barc) { _ in
            URL(fileURLWithPath: "/tmp/Barc.app")
        })
    }
}
