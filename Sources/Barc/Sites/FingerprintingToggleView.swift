import AppKit

/// The floating capsule over the bottom-trailing corner of a page on a site
/// known to refuse anti-fingerprinting: a switch for the protection on this
/// site, and a close button.
///
/// Bottom-trailing because the find bar takes the top-trailing corner and
/// toasts the bottom-leading one. It floats rather than pushing the page,
/// like the find bar, so a sign-in form does not move under the cursor.
final class FingerprintingToggleView: NSVisualEffectView {
    /// The person flipped the switch: true to protect, false to stop.
    var onToggle: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Anti-Fingerprinting")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let closeButton = NSButton(image: NSImage(), target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Anti-Fingerprinting for This Site")

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        self.shadow = shadow

        buildLayout()
        applyBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("FingerprintingToggleView is created in code only")
    }

    private func buildLayout() {
        icon.image = NSImage(systemSymbolName: SiteSettingCategory.antiFingerprinting.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Anti-Fingerprinting")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.toolTip = "Hide for This Site"
        closeButton.setAccessibilityLabel("Hide for This Site")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, labels, toggle, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(4, after: toggle)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            labels.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Mirrors the site's setting. Nothing here decides anything.
    func update(host: String, isProtected: Bool) {
        toggle.state = isProtected ? .on : .off
        icon.contentTintColor = isProtected ? .systemGreen : .secondaryLabelColor
        detailLabel.stringValue = isProtected
            ? "This site may block sign-in while it is on"
            : "Off for \(host)"
        toolTip = "\(host) checks the readouts anti-fingerprinting masks, and can refuse Barc for them."
    }

    var isProtected: Bool { toggle.state == .on }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}
