// Modified for Barc: themed launcher selections and compact result arrows, 2026-10-24.
import AppKit

/// One row of the command bar's result list: symbol, primary label, secondary
/// label.
///
/// Hovering a row *moves the keyboard selection* onto it rather than drawing a
/// second highlight of its own. A launcher has exactly one "this is what Return
/// does" indicator, and two highlights competing to be it is how a list ends up
/// opening something the user was not pointing at.
@MainActor
final class CommandRowView: NSView {
    var onClick: (() -> Void)?
    /// Called when the pointer enters the row; the bar answers by selecting it.
    var onHover: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let labels = NSStackView()
    private let folderPathPlate = NSView()
    private let folderPathLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hasWebsiteIcon = false
    private var rowHeight: NSLayoutConstraint!
    private let arrowPlate = NSView()
    private let arrowImage = NSImageView()
    private let iconPlate = NSView()
    private var shortcutTrailing: NSLayoutConstraint!
    private var arrowTrailing: NSLayoutConstraint!
    private var labelsLeading: NSLayoutConstraint!
    private var compactLabelsTrailing: NSLayoutConstraint!
    private var showsSplitArrow = false
    private var usesIconPlate = false
    private var isFolder = false
    private static let normalText = NSColor(name: nil) { appearance in
        NSColor(srgbRed: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.9 : 0.2,
                green: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.9 : 0.2,
                blue: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.9 : 0.2, alpha: 1)
    }
    private static let hintText = NSColor(name: nil) { appearance in
        NSColor(srgbRed: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.6 : 0.65,
                green: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.6 : 0.65,
                blue: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.6 : 0.65, alpha: 1)
    }
    var selectionColor: NSColor = .selectedContentBackgroundColor {
        didSet { applySelectionColours(); needsDisplay = true }
    }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilitySelected(isSelected)
            applySelectionColours()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)

        titleLabel.font = Style.Fonts.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setAccessibilityElement(false)

        subtitleLabel.font = .systemFont(ofSize: CommandBarMetrics.subtitleFontSize)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.setAccessibilityElement(false)
        // The address is the row's caption, not its point: it gives way first.
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.cell?.usesSingleLineMode = true
        shortcutLabel.setAccessibilityElement(false)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        folderPathPlate.translatesAutoresizingMaskIntoConstraints = false
        folderPathPlate.wantsLayer = true
        folderPathPlate.layer?.cornerRadius = 3
        folderPathPlate.setAccessibilityElement(false)
        folderPathLabel.translatesAutoresizingMaskIntoConstraints = false
        folderPathLabel.font = .systemFont(ofSize:13,weight:.semibold)
        folderPathLabel.lineBreakMode = .byTruncatingTail
        folderPathLabel.cell?.usesSingleLineMode = true
        folderPathLabel.setAccessibilityElement(false)
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        folderPathPlate.addSubview(folderPathLabel)
        NSLayoutConstraint.activate([
            folderPathLabel.leadingAnchor.constraint(equalTo:folderPathPlate.leadingAnchor,constant:7),
            folderPathLabel.trailingAnchor.constraint(equalTo:folderPathPlate.trailingAnchor,constant:-7),
            folderPathLabel.centerYAnchor.constraint(equalTo:folderPathPlate.centerYAnchor),
            folderPathPlate.heightAnchor.constraint(equalToConstant:24)
        ])
        folderPathPlate.isHidden = true
        labels.setViews([titleLabel, subtitleLabel, folderPathPlate],in:.leading)
        labels.orientation = .horizontal
        labels.alignment = .lastBaseline
        labels.spacing = CommandBarMetrics.rowLabelSpacing
        labels.translatesAutoresizingMaskIntoConstraints = false

        for plate in [iconPlate, arrowPlate] {
            plate.translatesAutoresizingMaskIntoConstraints = false
            plate.wantsLayer = true
            plate.layer?.cornerRadius = 4
            plate.setAccessibilityElement(false)
            plate.isHidden = true
            addSubview(plate)
        }
        arrowImage.translatesAutoresizingMaskIntoConstraints = false
        arrowImage.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        arrowImage.imageScaling = .scaleProportionallyDown
        arrowImage.setAccessibilityElement(false)
        arrowPlate.addSubview(arrowImage)
        addSubview(iconView)
        addSubview(labels)
        addSubview(shortcutLabel)

        rowHeight = heightAnchor.constraint(equalToConstant: CommandBarMetrics.rowHeight)
        shortcutTrailing = shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CommandBarMetrics.rowInset)
        arrowTrailing = arrowPlate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CommandBarMetrics.rowInset)
        labelsLeading = labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Style.Metrics.rowContentSpacing)
        compactLabelsTrailing = labels.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,
            constant: -(CommandBarMetrics.rowInset + Style.Metrics.rowContentSpacing + CommandBarMetrics.compactResultActionSpace))
        NSLayoutConstraint.activate([
            rowHeight,
            iconPlate.widthAnchor.constraint(equalToConstant: 24), iconPlate.heightAnchor.constraint(equalToConstant: 24),
            iconPlate.centerXAnchor.constraint(equalTo: iconView.centerXAnchor), iconPlate.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            arrowPlate.widthAnchor.constraint(equalToConstant: 24), arrowPlate.heightAnchor.constraint(equalToConstant: 24),
            arrowTrailing,
            arrowPlate.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowImage.centerXAnchor.constraint(equalTo: arrowPlate.centerXAnchor), arrowImage.centerYAnchor.constraint(equalTo: arrowPlate.centerYAnchor),
            arrowImage.widthAnchor.constraint(equalToConstant: 16), arrowImage.heightAnchor.constraint(equalToConstant: 16),
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: CommandBarMetrics.rowInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: CommandBarMetrics.rowIconSide),
            iconView.heightAnchor.constraint(equalToConstant: CommandBarMetrics.rowIconSide),
            labelsLeading,
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutTrailing,
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: labels.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutLabel.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            )
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilitySelected(false)
        setAccessibilityChildren([])
        applySelectionColours()
    }

    required init?(coder: NSCoder) {
        fatalError("CommandRowView is created in code only")
    }

    func configure(_ result: CommandResult, image: NSImage? = nil, compact: Bool = false,
                   splitChoice: Bool = false, locationChoice: Bool = false) {
        let launcher = splitChoice || locationChoice
        let arcLayout = launcher || compact
        isFolder = result.kind == .folder
        folderPathPlate.isHidden = !isFolder
        folderPathLabel.stringValue = isFolder ? result.subtitle : ""
        labels.alignment = isFolder ? .centerY : .lastBaseline
        titleLabel.setContentCompressionResistancePriority(isFolder ? .required : .defaultHigh,for:.horizontal)
        compactLabelsTrailing.isActive = compact
        hasWebsiteIcon = image != nil
        let symbol = NSImage(systemSymbolName: result.symbolName, accessibilityDescription: nil)
        iconView.image = image ?? (isFolder ? symbol?.withSymbolConfiguration(.init(pointSize:16,weight:.regular)) : symbol)
        titleLabel.stringValue = isFolder ? "Open" : result.title
        subtitleLabel.stringValue = result.subtitle
        subtitleLabel.isHidden = isFolder || compact || splitChoice
        rowHeight.constant = arcLayout ? CommandBarMetrics.splitRowHeight : CommandBarMetrics.rowHeight
        labelsLeading.constant = arcLayout ? 12 : Style.Metrics.rowContentSpacing
        let titleFont = arcLayout ? NSFont.systemFont(ofSize:13,weight:.semibold) : Style.Fonts.body
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var titleAttributes: [NSAttributedString.Key:Any] = [.font:titleFont,.paragraphStyle:paragraph]
        if arcLayout { titleAttributes[.tracking] = 0.075 }
        titleLabel.attributedStringValue = NSAttributedString(string:isFolder ? "Open" : result.title,attributes:titleAttributes)
        subtitleLabel.font = .systemFont(ofSize: locationChoice ? 13 : CommandBarMetrics.subtitleFontSize, weight: .medium)
        subtitleLabel.setContentCompressionResistancePriority(locationChoice ? .init(751) : .defaultLow, for: .horizontal)
        usesIconPlate = arcLayout
        showsSplitArrow = launcher && !result.isCurrentPage && { if case .switchToTab = result.action { return true }; return false }()
        if showsSplitArrow { subtitleLabel.isHidden = true }
        arrowPlate.isHidden = !showsSplitArrow
        arrowTrailing.constant = showsSplitArrow ? -12 : -CommandBarMetrics.rowInset
        shortcutTrailing.constant = showsSplitArrow ? -44 : -CommandBarMetrics.rowInset
        shortcutLabel.font = launcher ? .systemFont(ofSize: 13, weight: .medium) : .monospacedSystemFont(ofSize: 11, weight: .medium)
        if isFolder {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            setAccessibilityLabel(result.title)
        } else if showsSplitArrow {
            shortcutLabel.stringValue = "Switch to Tab"
            shortcutLabel.isHidden = false
            setAccessibilityLabel("\(result.title), Switch to Tab")
        } else if let shortcut = result.shortcut, !shortcut.isEmpty {
            shortcutLabel.stringValue = shortcut
            shortcutLabel.isHidden = false
            setAccessibilityLabel("\(result.title), \(result.subtitle), shortcut \(shortcut)")
        } else {
            shortcutLabel.stringValue = ""
            shortcutLabel.isHidden = true
            setAccessibilityLabel("\(result.title), \(result.subtitle)")
        }
        applySelectionColours()
    }

    /// A selected row is filled with the system's selection colour, so its text
    /// has to move to the colour that is legible on it. Both are semantic, so
    /// this is also what makes the row correct in light and dark.
    private func applySelectionColours() {
        titleLabel.textColor = isSelected ? .white : Self.normalText
        subtitleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : Style.Colors.secondaryText
        shortcutLabel.textColor = isSelected ? .white : Self.hintText
        folderPathLabel.textColor = isSelected ? .white : Style.Colors.secondaryText
        iconView.contentTintColor = hasWebsiteIcon ? nil : (isSelected
            ? (usesIconPlate ? selectionColor : .alternateSelectedControlTextColor) : Style.Colors.secondaryText)
        iconPlate.isHidden = !usesIconPlate || (!isSelected && !isFolder)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconPlate.layer?.backgroundColor = (isSelected ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.05)).cgColor
            arrowPlate.layer?.backgroundColor = (isSelected ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.05)).cgColor
            folderPathPlate.layer?.backgroundColor = (isSelected
                ? NSColor.white.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.05)).cgColor
        }
        arrowImage.contentTintColor = isSelected ? selectionColor : Style.Colors.secondaryText
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        selectionColor.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: CommandBarMetrics.rowCornerRadius,
            yRadius: CommandBarMetrics.rowCornerRadius
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionColours()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// The squeeze the row gives under a click. See `SpringPress`.
    ///
    /// This row is one of the few that acts on `mouseUp`, so it can hold the
    /// squeeze for as long as the button is actually held rather than flicking
    /// on a fixed clock.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.down() }
        // This press belongs to the result. Forwarding it reaches the
        // launcher's outside-click handler and dismisses it before mouseUp.
    }

    override func mouseUp(with event: NSEvent) {
        press.up()
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
