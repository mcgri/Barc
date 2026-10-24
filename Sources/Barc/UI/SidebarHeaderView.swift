// Modified for Barc: Arc-style shared traffic-light and navigation row, 2026-10-24.
import AppKit

/// Window controls and navigation share the top band. The Space label is hosted below Favorites.
@MainActor
final class SidebarHeaderView: NSView {
    let spaceButton = MenuLabelButton()
    private var navigation: NSView?
    private var navigationLeading: NSLayoutConstraint?
    private var navigationTop: NSLayoutConstraint?
    private var headerHeight: NSLayoutConstraint!
    private struct LightOrigin {
        weak var host: NSView?
        let frame: NSRect
        let translates: Bool
        let autoresizing: NSView.AutoresizingMask
    }
    private var lightOrigins: [ObjectIdentifier: LightOrigin] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        headerHeight = heightAnchor.constraint(equalToConstant: Style.Metrics.titlebarHeight)
        headerHeight.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeTrafficLights()
        needsLayout = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { returnTrafficLights() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeTrafficLights()
    }

    var hostsTrafficLights = true {
        didSet {
            guard hostsTrafficLights != oldValue else { return }
            if !hostsTrafficLights { returnTrafficLights() }
            needsLayout = true
        }
    }

    func installNavigation(_ view: NSView) {
        navigation?.removeFromSuperview()
        navigation = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        navigationLeading = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.trafficLightWidth)
        navigationTop = view.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        NSLayoutConstraint.activate([navigationLeading!, navigationTop!,
            view.trailingAnchor.constraint(equalTo: trailingAnchor)])
        needsLayout = true
    }

    override func layout() {
        let compact = hostsTrafficLights && navigation != nil && navigation?.isHidden != true && bounds.width < 214
        navigationLeading?.constant = hostsTrafficLights && !compact ? Style.Metrics.trafficLightWidth : Style.Metrics.sidebarInset
        navigationTop?.constant = compact ? Style.Metrics.titlebarHeight : 12
        headerHeight.constant = compact ? Style.Metrics.titlebarHeight + (navigation?.frame.height ?? 24) : Style.Metrics.titlebarHeight
        super.layout()
        placeTrafficLights()
    }

    private func placeTrafficLights() {
        guard hostsTrafficLights, let window else { return }
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            if button.superview !== self {
                lightOrigins[ObjectIdentifier(button)] = LightOrigin(host: button.superview, frame: button.frame,
                    translates: button.translatesAutoresizingMaskIntoConstraints, autoresizing: button.autoresizingMask)
                button.removeFromSuperview()
                button.translatesAutoresizingMaskIntoConstraints = true
                addSubview(button)
                button.autoresizingMask = [.maxXMargin]
            }
            button.frame.origin = NSPoint(x: 13 + CGFloat(index) * 22,
                                          y: bounds.height - 24 - button.frame.height / 2)
        }
    }

    private func returnTrafficLights() {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.superview === self,
                  let origin = lightOrigins.removeValue(forKey: ObjectIdentifier(button)) else { continue }
            button.removeFromSuperview()
            (origin.host ?? window.contentView?.superview)?.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = origin.translates
            button.autoresizingMask = origin.autoresizing
            button.frame = origin.frame
        }
    }

}

/// A text button that pops up a menu under itself.
///
/// `NSPopUpButton` in pull-down mode would do this, but it insists on a bezel,
/// a chevron and a first item used as the title -- three things that have to be
/// fought rather than configured. Drawing the label and calling
/// `NSMenu.popUp(positioning:)` is shorter than the fight.
@MainActor
final class MenuLabelButton: NSView, NSTextFieldDelegate {
    /// The menu shown on click. `nil` makes the button inert but still legible,
    /// which is right for a build that has no spaces to choose between.
    var menuProvider: (() -> NSMenu?)?
    var onPress: (() -> Void)?
    var isSectionCollapsed = false { didSet { refreshIcon() } }
    private var restingIcon: NSImage?
    var onRenameStateChange: ((Bool) -> Void)?
    private(set) var isRenaming = false
    private var originalName = ""
    private var representedID: UUID?
    private var rename: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    /// The space's mark, before its name. Hidden for a space wearing nothing,
    /// so a header that never had an icon looks exactly as it did.
    private let icon = NSImageView()
    /// The name's leading edge: against the button's own edge when there is no
    /// icon, against the icon when there is. Two constraints rather than a
    /// stack view, because the label's width priorities are load-bearing here
    /// -- see below -- and a stack view would have its own opinion about them.
    private var labelLeadingToEdge: NSLayoutConstraint?
    private var labelLeadingToIcon: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            highlight?.apply(
                isHovered && (menuProvider != nil || onPress != nil) ? .hover : .rest,
                appearance: effectiveAppearance
            )
            refreshIcon()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

        label.font = Style.Fonts.title
        label.delegate = self
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        // The name yields before the sidebar does.
        //
        // It truncates, but truncating is not the same as being willing to:
        // at the default resistance the label still *asks* for its full width,
        // and that ask travels up to the split view, which widens the sidebar
        // to grant it. Switching to a space with a longer name therefore shoved
        // the divider out -- "Read Later BF9059" wanted 240 points where
        // "Studio" wanted 216 -- and switching away left it there. Walking
        // through eleven spaces, the sidebar visibly grew at two of them.
        //
        // Lowered on both: the label is what has the intrinsic width, and this
        // view is what passes it on.
        //
        // Below `.defaultLow`, not at it. The split view holds the sidebar at
        // `.defaultLow` too, so leaving the name there left the two asks tied
        // at 250 and the solver free to satisfy either -- the same tie as the
        // Settings pane's gutter. It happened to come out right while the Now
        // Playing card was quietly holding the sidebar at 169 whatever the
        // name said; with the card no longer doing that, a long name took the
        // width again. One step above nothing, so the name always yields.
        for view in [label, self] as [NSView] {
            view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            view.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        addSubview(label)

        icon.imageScaling = .scaleProportionallyDown
        icon.isHidden = true
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        // The mark keeps its size while the name gives way: an icon that
        // shrank with the sidebar would be a smudge long before the name it
        // belongs to ran out of room.
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)

        labelLeadingToEdge = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        labelLeadingToIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
        labelLeadingToEdge?.isActive = true

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])

        setAccessibilityRole(.popUpButton)
        // A role alone does not make an `NSView` an element; without this the
        // button, and so the whole space menu, is invisible to VoiceOver.
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("MenuLabelButton is created in code only")
    }

    /// The mark before the name: a touch under the cap height of the title, so
    /// it sits in the line rather than towering over it.
    static let iconSide: CGFloat = 16

    /// - Parameter icon: the space's emoji, symbol or picture, or nil for a
    ///   space wearing nothing -- which leaves the header as a name alone,
    ///   exactly as it was before spaces could be marked.
    func show(title: String, icon image: NSImage?, accessibilityLabel: String, tooltip: String?, identity: UUID? = nil) {
        if isRenaming, identity != representedID { finishRenaming(commit: false) }
        representedID = identity
        if !isRenaming { label.stringValue = title }
        restingIcon = image
        refreshIcon()
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(title)
        toolTip = tooltip
    }

    private func refreshIcon() {
        let disclosure = onPress != nil && !isRenaming && (isSectionCollapsed || isHovered)
        let image = disclosure
            ? NSImage(systemSymbolName: isSectionCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            : restingIcon
        icon.image = image
        icon.contentTintColor = disclosure ? Style.Colors.secondaryText : nil
        icon.isHidden = image == nil
        labelLeadingToEdge?.isActive = image == nil
        labelLeadingToIcon?.isActive = image != nil
    }

    /// The field occupies exactly the name's resting position. Return and a
    /// click outside commit once; Escape restores the original name.
    func beginRenaming(_ commit: @escaping (String) -> Void) {
        guard !isRenaming else { return }
        originalName = label.stringValue
        rename = commit
        isRenaming = true
        label.isEditable = true
        label.isSelectable = true
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.textField)
        label.setAccessibilityLabel("Space name")
        label.formatter = LimitedLengthFormatter(limit: Space.maximumNameLength)
        onRenameStateChange?(true)
        refreshIcon()
        // selectText installs and selects the field editor itself. Asking the
        // window first ends that editor when selectText installs it again.
        label.selectText(nil)
    }

    func finishRenaming(commit: Bool) {
        guard isRenaming else { return }
        let name = Space.clampName(label.stringValue)
        let action = rename
        rename = nil
        isRenaming = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        label.setAccessibilityRole(.staticText)
        label.formatter = nil
        if !commit || name.isEmpty { label.stringValue = originalName }
        onRenameStateChange?(false)
        refreshIcon()
        if commit, !name.isEmpty { action?(name) }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRenaming(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRenaming(commit: false)
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRenaming(commit: true)
        } else { return false }
        window?.makeFirstResponder(nil)
        return true
    }

    override func layout() {
        super.layout()
        highlight?.layout(bounds, in: bounds.height, flipped: isFlipped, radius: 7, scale: highlightScale)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The squeeze the header gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { super.mouseDown(with: event); return }
        // Flicked before the menu opens rather than held through it: a menu
        // runs its own event loop, so a held press would stay squeezed for as
        // long as the menu is on screen.
        if acceptsSpringPress { press.flick() }
        if let onPress { onPress() } else { presentMenu() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func accessibilityPerformPress() -> Bool {
        if let onPress { onPress() } else { presentMenu() }
        return true
    }

    private func presentMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}
