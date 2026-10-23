// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// Prepares a GitHub draft and lets the user review it before publishing.
@MainActor
final class FeedbackWindowController: NSWindowController {
    private let kindPopUp = NSPopUpButton()
    private let messageView = NSTextView()
    private let environmentLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton(title: "Open GitHub Draft", target: nil, action: nil)
    private let issuesButton = NSButton(title: "Open Issues", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var report: FeedbackSubmission.Report
    private var sending = false

    /// The send, replaceable so a test can answer without the network.
    var send: (FeedbackSubmission.Report) async -> FeedbackSubmission.Outcome = { report in
        await FeedbackSubmission.send(report)
    }

    init(kind: FeedbackSubmission.Kind) {
        report = FeedbackSubmission.Report(kind: kind, environment: SupportContact.currentEnvironment())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Report a Problem"
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("FeedbackWindowController is created in code only")
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let heading = NSTextField(labelWithString: "Tell us what happened")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString: "Review your report in a GitHub draft before publishing. Closing this window sends nothing.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        for kind in FeedbackSubmission.Kind.allCases {
            kindPopUp.addItem(withTitle: kind.title)
            kindPopUp.lastItem?.representedObject = kind.rawValue
        }
        kindPopUp.selectItem(at: FeedbackSubmission.Kind.allCases.firstIndex(of: report.kind) ?? 0)
        kindPopUp.target = self
        kindPopUp.action = #selector(kindChanged)

        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 13)
        messageView.delegate = self
        messageView.textContainerInset = NSSize(width: 6, height: 8)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true


        environmentLabel.stringValue = "Included in your draft:\n" + report.environment.report
        environmentLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        environmentLabel.textColor = .tertiaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true

        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        sendButton.isEnabled = false
        issuesButton.target = self
        issuesButton.action = #selector(issuesTapped)
        issuesButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [issuesButton, spinner, NSView(), cancelButton, sendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fill
        // The spacer takes the slack, so mail sits left and send sits right.
        buttons.views[3].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            heading, blurb, kindPopUp, messageScroll, environmentLabel, statusLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(18, after: blurb)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            messageScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)
        ])
        return container
    }

    // MARK: - Actions

    @objc private func kindChanged() {
        if let raw = kindPopUp.selectedItem?.representedObject as? String,
           let kind = FeedbackSubmission.Kind(rawValue: raw) {
            report.kind = kind
        }
    }

    @objc private func cancelTapped() {
        close()
    }

    /// Opens the issue list without publishing or submitting a report.
    @objc private func issuesTapped() {
        NSWorkspace.shared.open(SupportContact.issues)
        close()
    }

    @objc private func sendTapped() {
        guard !sending, report.isSendable else { return }
        sending = true
        setControlsEnabled(false)
        spinner.startAnimation(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Opening GitHub draft\u{2026}"
        let outgoing = report
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.send(outgoing)
            self.show(outcome)
        }
    }

    /// Puts the answer on the sheet. Shown here rather than in an alert so a
    /// failure leaves the typed report exactly where it was.
    func show(_ outcome: FeedbackSubmission.Outcome) {
        sending = false
        spinner.stopAnimation(nil)
        switch outcome {
        case .draftOpened:
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Draft opened on GitHub. Review it there before publishing."
            setControlsEnabled(false)
            sendButton.isEnabled = false
            // Long enough to read, short enough not to be in the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.close() }
        case .failed(let reason):
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = reason
            setControlsEnabled(true)
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        kindPopUp.isEnabled = enabled
        messageView.isEditable = enabled
        issuesButton.isEnabled = enabled
        cancelButton.isEnabled = enabled
        sendButton.isEnabled = enabled && report.isSendable
    }

    // MARK: - For tests

    var statusText: String { statusLabel.stringValue }
    var canSend: Bool { sendButton.isEnabled }
    var currentReport: FeedbackSubmission.Report { report }

    func setMessageForTesting(_ text: String) {
        messageView.string = text
        report.message = text
        sendButton.isEnabled = report.isSendable
    }
}

extension FeedbackWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        report.message = messageView.string
        sendButton.isEnabled = report.isSendable && !sending
    }

}
