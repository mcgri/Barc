import AppKit
import Combine

/// Floats the anti-fingerprinting switch over pages on sites known to refuse
/// the protection (`FingerprintingCompatibility`).
///
/// The switch writes the site's own setting, the same one the Websites pane
/// and the page's Site Settings show, and reloads the tab: the protection is
/// decided as the page's scripts load, so a page already open keeps what it
/// loaded with.
@MainActor
final class FingerprintingToggleController {
    private let session: BrowserSession
    private let sites: SiteSettings
    private let settings: Settings
    private let bar = FingerprintingToggleView()
    /// Hosts the person closed the switch on. Until Barc quits: a closed
    /// switch is "not now", and the setting itself stays in Site Settings.
    private var dismissed: Set<String> = []
    private var sessionCancellable: AnyCancellable?

    init(session: BrowserSession, sites: SiteSettings = .shared, settings: Settings = .shared) {
        self.session = session
        self.sites = sites
        self.settings = settings
    }

    func install(in host: NSView) {
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12)
        ])
        bar.onToggle = { [weak self] protect in self?.setProtection(protect) }
        bar.onDismiss = { [weak self] in self?.dismiss() }

        sessionCancellable = session.changes
            .sink { [weak self] change in
                switch change {
                case .activeTab, .spaces, .tabs, .structure:
                    self?.refresh()
                case .tab(let tab):
                    guard let self, tab.id == self.session.activeTab?.id else { return }
                    self.refresh()
                case .bookmarks:
                    break
                }
            }
        sites.addChangeObserver { [weak self] in self?.refresh() }
        refresh()
    }

    /// The active tab's address, when it is a web page.
    private var activeURL: URL? {
        guard let tab = session.activeTab, !tab.showsStartPage else { return nil }
        return tab.displayURL
    }

    private func refresh() {
        let url = activeURL
        guard let host = FingerprintingCompatibility.toggleHost(
            for: url, protectionEnabled: settings.antiFingerprintingEnabled, dismissed: dismissed
        ) else {
            setVisible(false)
            return
        }
        bar.update(host: host, isProtected: sites.usesAntiFingerprinting(for: url))
        setVisible(true)
    }

    private func setProtection(_ protect: Bool) {
        guard let tab = session.activeTab, let host = activeURL?.host()?.lowercased() else { return }
        sites.update { $0.set(protect ? "on" : "off", for: host, in: .antiFingerprinting) }
        tab.reload()
    }

    private func dismiss() {
        if let host = activeURL?.host()?.lowercased() { dismissed.insert(host) }
        refresh()
    }

    private func setVisible(_ visible: Bool) {
        guard bar.isHidden == visible else { return }
        if !visible {
            bar.isHidden = true
            return
        }
        bar.alphaValue = 0
        bar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            bar.animator().alphaValue = 1
        }
    }
}
