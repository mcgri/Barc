// Modified for Barc: the sidebar address opens a transient URL editor, 2026-10-23.
import AppKit

/// A compact page address. Editing happens in the sidebar's floating URL popup.
@MainActor
final class AddressField: NSView {
    var onOpen: (() -> Void)?

    private let field = NSButton()
    private let securityIcon = NSImageView()
    private let copyButton = IconButton(symbolName: "doc.on.doc", label: "Copy Address")
    /// The page's compact address while idle.
    private var currentDisplay = ""
    /// The full URL, for the tooltip and the copy button.
    private var currentURL: URL?
    private var highlight: RowHighlight?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }

    /// The field's corner. A touch rounder than a toolbar button's, because
    /// the shape is long: the same radius reads as sharper the wider it gets.
    private static let cornerRadius: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.setButtonType(.momentaryChange)
        field.title = "Search or enter address"
        field.alignment = .left
        field.target = self
        field.action = #selector(openAddress)
        field.focusRingType = .none
        field.font = Style.Fonts.body
        field.contentTintColor = Style.Colors.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Address")

        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.setContentHuggingPriority(.required, for: .horizontal)
        securityIcon.setAccessibilityRole(.image)

        addSubview(securityIcon)
        addSubview(field)

        copyButton.setClickHandler { [weak self] in self?.copyAddress() }
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.iconButtonSide),
            securityIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            securityIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 15),
            securityIcon.heightAnchor.constraint(equalToConstant: 15),
            field.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("AddressField is created in code only") }

    // MARK: - The plate

    /// The resting plate, under the highlight. Drawn rather than layered so the
    /// field has a shape even when nothing is hovering or editing it.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Style.Metrics.hairline / 2, dy: Style.Metrics.hairline / 2),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        Style.Colors.fieldFill.setFill()
        shape.fill()
        shape.lineWidth = Style.Metrics.hairline
        Style.Colors.fieldStroke.setStroke()
        shape.stroke()
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: Self.cornerRadius, scale: highlightScale
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onOpen?() }
    @objc private func openAddress() { onOpen?() }

    private func updateHighlight() {
        highlight?.apply(
            isHovered ? .hover : .rest,
            appearance: effectiveAppearance
        )
    }

    /// The compact label follows the page; the popup owns its separate editing state.
    func show(display: String?, url: URL?) {
        currentDisplay = display ?? ""
        currentURL = url
        field.toolTip = url?.absoluteString
        copyButton.isHidden = (url == nil)
        showSecurity(of: url)
        field.title = currentDisplay.isEmpty ? "Search or enter address" : currentDisplay
    }

    /// A lock for HTTPS, a warning for plain HTTP, nothing for the schemes where
    /// "secure or not" is not the question (a new tab, a local file).
    private func showSecurity(of url: URL?) {
        let symbol: (name: String, tint: NSColor, help: String)?
        switch url?.scheme?.lowercased() {
        case "https":
            symbol = ("lock.fill", Style.Colors.secondaryText, "Connection is secure (HTTPS)")
        case "http":
            symbol = ("exclamationmark.triangle.fill", .systemOrange, "Connection is not secure (HTTP)")
        default:
            symbol = nil
        }
        guard let symbol else {
            securityIcon.isHidden = true
            return
        }
        securityIcon.isHidden = false
        let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.help)
        securityIcon.image = image
        securityIcon.contentTintColor = symbol.tint
        securityIcon.toolTip = symbol.help
        securityIcon.setAccessibilityLabel(symbol.help)
    }

    private func copyAddress() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        // A one-second checkmark, so a silent copy still says it happened.
        copyButton.setSymbol("checkmark", label: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.copyButton.setSymbol("doc.on.doc", label: "Copy Address")
        }
    }

}
