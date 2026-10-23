// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// Barc identity, upstream attribution, license notices and update status.
@MainActor
final class AboutSettingsViewController: NSViewController {
    /// The copy, in one place, so it can be edited without touching layout.
    enum Copy {
        static let tagline = "A lightweight native browser for the Mac."
        static let browser = """
            Barc is a native macOS browser built with Swift, AppKit and the system \
            WebKit engine. Spaces keep separate website identities in one window.
            """
        static let aboutUs = """
            Barc is an independent fork of Kylmora, distributed under Apache \
            License 2.0. The original authors' copyright and attribution notices \
            are preserved. Barc is not an official Kylmora release.
            """
        static let logo = """
            The Barc mark is a B made from overlapping coral, blue and violet \
            ribbons, inspired by Arc's visual style. Barc is independent of Arc \
            and The Browser Company.
            """
        static let contact = """
            Reports and feature requests open an editable draft in Barc's GitHub \
            repository. Review it there before publishing. No report is sent \
            to Kylmora's support service.
            """
        static let copyright = "Original browser © 2026 Kylmora. Barc modifications © 2026 Barc contributors."

    }

    private let autoCheckCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let autoDownloadCheckbox = NSButton(checkboxWithTitle: "Automatically download updates", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check for Updates\u{2026}", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Update Now", target: nil, action: nil)
    private let reportButton = NSButton(title: "Report a Problem\u{2026}", target: nil, action: nil)
    private let featureButton = NSButton(title: "Suggest a Feature\u{2026}", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private var checking = false
    private var downloadURL: URL?

    /// The check, replaceable so a test can answer without the network.
    var check: (String) async -> UpdateCheck.Outcome = { current in
        await UpdateCheck.run(current: current)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AboutSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = SettingsScrollingPane(form: form)
        buildLayout(in: form)
    }

    private func buildLayout(in form: SettingsForm) {
        form.addHero(makeHero())
        form.addSeparator()

        form.addRow("Browser", Self.paragraph(Copy.browser), alignment: .top)
        form.addRow("Engine", Self.value("WebKit, the system's own, shared with Safari (security patches arrive with macOS updates)"))
        form.addRow("Built with", Self.value("Swift 6 and AppKit; derived from Kylmora"))
        form.addRow("Project", Self.link("github.com/mcgri/Barc", url: AppInfo.website))
        form.addRow("Original browser", Self.link("Kylmora", url: AppInfo.upstreamWebsite))
        form.addRow("License", Self.link("Apache License 2.0", url: AppInfo.licenseURL))
        form.addRow("Notices", Self.link("Copyright and attribution", url: AppInfo.noticeURL))

        form.addSeparator()
        form.addRow("About us", Self.paragraph(Copy.aboutUs), alignment: .top)
        form.addRow("The logo", Self.paragraph(Copy.logo), alignment: .top)

        form.addSeparator()
        addContactRows(to: form)

        form.addSeparator()
        autoCheckCheckbox.state = Settings.shared.automaticallyCheckForUpdates ? .on : .off
        autoCheckCheckbox.target = self
        autoCheckCheckbox.action = #selector(autoCheckToggled(_:))
        if EnterprisePolicyManager.shared.isAutoUpdateForced {
            autoCheckCheckbox.state = .on
            autoCheckCheckbox.isEnabled = false
            autoCheckCheckbox.toolTip = "Mandatory automatic updates are enforced by your organization"
        }
        if UpdateCheck.feedURL == nil {
            autoCheckCheckbox.state = .off
            autoCheckCheckbox.isEnabled = false
        }
        form.addRow("Updates", autoCheckCheckbox)

        autoDownloadCheckbox.state = Settings.shared.automaticallyDownloadUpdates ? .on : .off
        autoDownloadCheckbox.target = self
        autoDownloadCheckbox.action = #selector(autoDownloadToggled(_:))
        if UpdateCheck.feedURL == nil {
            autoDownloadCheckbox.state = .off
            autoDownloadCheckbox.isEnabled = false
        }
        form.addRow("", autoDownloadCheckbox)

        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(download)
        downloadButton.bezelStyle = .rounded
        downloadButton.isHidden = true
        form.addRow("", [checkButton, downloadButton])
        updateStatus.stringValue = "Barc has no automatic update feed yet. Get builds from the project repository. WebKit security patches arrive with macOS updates."
        form.addNote(updateStatus)

        form.addSeparator()
        form.addRow("", Self.value(Copy.copyright, secondary: true))
    }

    // MARK: - Contact

    /// The card that says how to reach us, and opens a draft that is already
    /// most of the way written.
    private func addContactRows(to form: SettingsForm) {
        form.addRow("Contact", Self.paragraph(Copy.contact), alignment: .top)

        reportButton.target = self
        reportButton.action = #selector(reportProblem)
        reportButton.bezelStyle = .rounded
        featureButton.target = self
        featureButton.action = #selector(suggestFeature)
        featureButton.bezelStyle = .rounded
        form.addRow("", [reportButton, featureButton])

        form.addRow("Issues and ideas", Self.link("github.com/mcgri/Barc", url: SupportContact.issues))
        form.addRow("Security", Self.link("Private vulnerability report", url: SupportContact.securityAdvisory))
        form.addNote("Use private reporting if enabled for this repository. Do not disclose vulnerabilities in public issues. See SECURITY.md.")
    }

    @objc private func reportProblem() {
        (NSApp.delegate as? AppDelegate)?.showFeedback(kind: .bug)
    }

    @objc private func suggestFeature() {
        (NSApp.delegate as? AppDelegate)?.showFeedback(kind: .feature)
    }

    /// The icon, the name, the tagline and the version, centred.
    private func makeHero() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112)
        ])

        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .systemFont(ofSize: 26, weight: .semibold)
        name.alignment = .center

        let tagline = NSTextField(labelWithString: Copy.tagline)
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center

        let version = NSTextField(labelWithString: "Version \(AppInfo.version) (\(AppInfo.build))")
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.alignment = .center

        let stack = NSStackView(views: [icon, name, tagline, version])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(10, after: tagline)
        return stack
    }

    private static func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        // No width of its own. A paragraph goes under its heading and runs the
        // width of the card; pinning it to the control column left two thirds
        // of the card empty beside every line.
        return field
    }

    private static func value(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    private static func link(_ text: String, url: URL) -> NSTextField {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .link: url, .foregroundColor: NSColor.linkColor
        ])
        let field = NSTextField(labelWithAttributedString: attributed)
        field.allowsEditingTextAttributes = true
        field.isSelectable = true
        return field
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        guard !checking else { return }
        checking = true
        checkButton.isEnabled = false
        downloadButton.isHidden = true
        downloadURL = nil
        release = nil
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = "Checking for Barc updates\u{2026}"
        let current = AppInfo.version
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.check(current)
            self.show(outcome)
        }
    }

    /// Puts the answer on the pane.
    func show(_ outcome: UpdateCheck.Outcome) {
        checking = false
        checkButton.isEnabled = true
        switch outcome {
        case .upToDate(let current):
            updateStatus.textColor = .secondaryLabelColor
            updateStatus.stringValue = "You\u{2019}re on the latest version. Barc \(current) is the newest there is."
        case .available(let found):
            updateStatus.textColor = .labelColor
            var text = "Barc \(found.version) is available; you have \(AppInfo.version)."
            if let notes = found.notes, !notes.isEmpty { text += " \(notes)" }
            updateStatus.stringValue = text
            let url = found.url
            downloadURL = url
            release = found
            // Only when there is something to fetch. A release the feed named
            // but gave no address for cannot be installed or downloaded, and a
            // button that would do neither is worse than no button.
            downloadButton.isHidden = url == nil
        case .unreachable(let reason):
            updateStatus.textColor = .secondaryLabelColor
            updateStatus.stringValue = reason
        }
        view.window?.windowController.flatMap { $0 as? SettingsWindowController }?.paneDidResize()
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        Settings.shared.automaticallyCheckForUpdates = (sender.state == .on)
    }

    @objc private func autoDownloadToggled(_ sender: NSButton) {
        Settings.shared.automaticallyDownloadUpdates = (sender.state == .on)
    }

    /// Hands the update to the installer rather than to a web page.
    ///
    /// This button used to open the download in a browser and leave the rest
    /// to the user: find the disk image, open it, drag the app over the old
    /// one, agree to replace it. `UpdateController` does the whole thing --
    /// download, verify, swap, reopen -- so all this has to do is start it and
    /// let the update window take over from here.
    @objc private func download() {
        guard let release else {
            // No release in hand: fall back to the page, which is better than
            // a button that does nothing.
            if let downloadURL { NSWorkspace.shared.open(downloadURL) }
            return
        }
        UpdateController.shared.presentUpdateWindow(for: release)
    }

    /// The release the check found, which the Update Now button installs.
    private var release: UpdateCheck.Release?

    /// What the status line says right now; for tests.
    var updateStatusText: String { updateStatus.stringValue }
    var showsDownloadButton: Bool { !downloadButton.isHidden }
    var isAutoCheckEnabled: Bool { autoCheckCheckbox.state == .on }
    var isAutoDownloadEnabled: Bool { autoDownloadCheckbox.state == .on }
}
