// Modified for Barc: a compact sidebar address with a transient URL editor, 2026-10-24.
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
    private var textLeading: NSLayoutConstraint!
    private var textTrailing: NSLayoutConstraint!
    private var highlight: RowHighlight?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                updateHighlight()
                copyButton.isHidden = !isHovered || currentURL == nil
                textTrailing.constant = isHovered && currentURL != nil ? -36 : -12
            }
        }
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
        field.title = "Search or Enter URL…"
        field.alignment = .left
        field.target = self
        field.action = #selector(openAddress)
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.contentTintColor = Style.Colors.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        textLeading = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        textTrailing = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        copyButton.isHidden = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            securityIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            securityIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 15),
            securityIcon.heightAnchor.constraint(equalToConstant: 15),
            textLeading,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            textTrailing,
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        show(display:"",url:nil)
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

    override func mouseEntered(with event: NSEvent) { if !currentDisplay.isEmpty { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { if !currentDisplay.isEmpty { onOpen?() } }
    @objc private func openAddress() { if !currentDisplay.isEmpty { onOpen?() } }

    private func updateHighlight() {
        highlight?.apply(
            isHovered ? .hover : .rest,
            appearance: effectiveAppearance
        )
    }

    /// The compact label follows the page; the popup owns its separate editing state.
    func show(display: String?, url: URL?) {
        currentDisplay = display ?? ""
        let empty = currentDisplay.isEmpty
        currentURL = empty ? nil : url
        if empty { isHovered = false }
        field.isEnabled = !empty
        field.toolTip = currentURL?.absoluteString
        copyButton.isHidden = !isHovered || currentURL == nil
        textTrailing.constant = isHovered && currentURL != nil ? -36 : -12
        showSecurity(of: currentURL, placeholder:empty)
        field.title = empty ? "Search or Enter URL…" : currentDisplay
        field.font = .systemFont(ofSize:empty ? 13 : 14,weight:empty ? .semibold : .regular)
        field.contentTintColor = empty ? Style.Colors.secondaryText : Style.Colors.primaryText
        field.attributedTitle = NSAttributedString(string:field.title,attributes:[
            .font:field.font!, .foregroundColor:field.contentTintColor!
        ])
    }

    /// A lock for HTTPS, a warning for plain HTTP, nothing for the schemes where
    /// "secure or not" is not the question (a new tab, a local file).
    private func showSecurity(of url: URL?, placeholder: Bool) {
        let symbol: (name: String, tint: NSColor, help: String)?
        switch placeholder ? "search" : url?.scheme?.lowercased() {
        case "search":
            symbol = ("magnifyingglass",Style.Colors.secondaryText,"Search")
        case "https":
            symbol = nil
        case "http":
            symbol = ("exclamationmark.triangle.fill", .systemOrange, "Connection is not secure (HTTP)")
        default:
            symbol = nil
        }
        guard let symbol else {
            securityIcon.isHidden = true
            textLeading.constant = 12
            return
        }
        textLeading.constant = 34
        securityIcon.isHidden = false
        let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.help)
        securityIcon.image = image
        securityIcon.symbolConfiguration = placeholder ? .init(pointSize:13,weight:.medium) : nil
        securityIcon.contentTintColor = symbol.tint
        securityIcon.toolTip = symbol.help
        securityIcon.setAccessibilityLabel(symbol.help)
        securityIcon.setAccessibilityElement(!placeholder)
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
