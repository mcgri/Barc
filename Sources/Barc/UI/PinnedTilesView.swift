// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import AppKit

/// One pinned shortcut: a site, and the name it is announced by.
///
/// The tile carries the site's address rather than a picture of it, because
/// the picture is a favicon and Barc already has one place that turns an
/// address into a favicon. `url` is optional only so that a pin with an
/// address nothing can be fetched from still renders -- as the globe
/// `FaviconImageView` shows, never as a guess at the site's branding.
struct PinnedTile {
    let id: String
    let title: String
    let url: URL?
    /// Whether this shortcut is the page currently on screen. Only the active
    /// tile wears its brand colours; the rest stay neutral, so a strip of
    /// shortcuts reads as one thing with a current item rather than as a row of
    /// competing logos.
    let isActive: Bool
    let favicon: PageFavicon?

    init(id: String, title: String, url: URL? = nil, isActive: Bool = false, favicon: PageFavicon? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
        self.favicon = favicon
    }
}

/// The row of shortcut tiles below the traffic lights.
///
/// An empty strip explains how to add Favorites. The hint can be dismissed;
/// it temporarily returns as a drop target while a sidebar tab is dragged.
@MainActor
final class PinnedTilesView: NSView {
    var onDismissHint: (() -> Void)?
    var canDropTab: ((UUID) -> Bool)?
    var onDropTab: ((UUID) -> Bool)?
    /// A tile was clicked, identified by `PinnedTile.id`.
    var onSelect: ((String) -> Void)?
    /// A tile asked to be unpinned, identified by `PinnedTile.id`.
    var onRemove: ((String) -> Void)?

    private var tileViews: [PinnedTileView] = []
    private let emptyHint = EmptyFavoritesHint()
    private var showsEmptyHint = true
    private var tabDragInProgress = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        emptyHint.onDismiss = { [weak self] in self?.onDismissHint?() }
        addSubview(emptyHint)
        registerForDraggedTypes([SidebarTabDrag.type])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Pinned shortcuts")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedTilesView is created in code only")
    }

    /// Number of tiles currently shown, not counting the hint. Exists
    /// for the layout tests, which otherwise have no way to see inside.
    private(set) var tileCount = 0

    /// - Parameter isPrivate: whether the space the pins belong to is private. It
    ///   reaches the favicon layer, which writes nothing to disk for a private
    ///   one. The default is the private answer rather than the common one: a
    ///   caller that has not said which kind of space this is must not have its pins
    ///   recorded on disk on the strength of a convenient default.
    func show(_ tiles: [PinnedTile], isPrivate: Bool = true, showsEmptyHint: Bool = true) {
        self.showsEmptyHint = showsEmptyHint
        for view in tileViews { view.removeFromSuperview() }
        tileViews = tiles.map { tile in
            let view = PinnedTileView(tile: tile, isPrivate: isPrivate)
            view.onClick = { [weak self] in self?.onSelect?(tile.id) }
            view.onRemove = { [weak self] in self?.onRemove?(tile.id) }
            return view
        }
        for view in tileViews { addSubview(view, positioned: .below, relativeTo: emptyHint) }
        tileCount = tiles.count
        refreshEmptyHint()
    }

    func setTabDragInProgress(_ dragging: Bool) {
        tabDragInProgress = dragging
        refreshEmptyHint()
    }

    private func refreshEmptyHint() {
        emptyHint.isHidden = !tileViews.isEmpty || (!showsEmptyHint && !tabDragInProgress)
        isHidden = tileViews.isEmpty && emptyHint.isHidden
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func canAcceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let id = SidebarTabDrag.id(in: pasteboard) else { return false }
        return canDropTab?(id) == true
    }

    @discardableResult
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard canAcceptDrop(from: pasteboard), let id = SidebarTabDrag.id(in: pasteboard) else { return false }
        return onDropTab?(id) == true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = canAcceptDrop(from: sender.draggingPasteboard)
        emptyHint.isDropTarget = accepts
        return accepts ? .move : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { emptyHint.isDropTarget = false }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { canAcceptDrop(from: sender.draggingPasteboard) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { emptyHint.isDropTarget = false }
        return acceptDrop(from: sender.draggingPasteboard)
    }

    // MARK: - Layout

    /// Rows are numbered from the top, so the strip has to be too. Without
    /// this the first row is drawn at the bottom and the tiles read backwards.
    override var isFlipped: Bool { true }

    /// Laid out by hand rather than by a stack view, because the strip has to
    /// wrap: a stack is one line, and the tiles need to reflow into as many
    /// rows as the sidebar's width needs. Every tile in a row is the same
    /// width and the row fills the strip, so dragging the sidebar resizes them
    /// rather than leaving a ragged gap.
    override func layout() {
        super.layout()
        if tileViews.isEmpty {
            emptyHint.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.emptyHintHeight)
            return
        }
        let items = tileViews
        let plan = TileGrid.plan(itemCount: items.count, availableWidth: bounds.width)

        // The number of rows is only knowable once the width is, and the width
        // is only known here. Asking for a new intrinsic height when the two
        // disagree is what lets the strip grow a second row; the comparison is
        // what stops it asking on every pass.
        if abs(plan.height - bounds.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }

        for (index, view) in items.enumerated() {
            let column = index % plan.columns
            let row = index / plan.columns
            let x = CGFloat(column) * (plan.tileWidth + Style.Metrics.tileSpacing)
            let y = CGFloat(row) * (Style.Metrics.tileHeight + Style.Metrics.tileSpacing)
            view.frame = NSRect(
                x: x,
                y: y,
                width: plan.tileWidth,
                height: Style.Metrics.tileHeight
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        if tileViews.isEmpty { return NSSize(width: NSView.noIntrinsicMetric, height: emptyHint.isHidden ? 0 : Self.emptyHintHeight) }
        let plan = TileGrid.plan(itemCount: tileViews.count, availableWidth: bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: plan.height)
    }

    static let emptyHintHeight: CGFloat = 96

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // A narrower strip may need another row, and the height it reports has
        // to change with it or the row below overlaps.
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// How many columns fit, how wide each is, and how tall the result is.
///
/// Separated from the view so the wrapping rule is a test rather than something
/// only a screenshot can confirm.
enum TileGrid {
    struct Plan: Equatable {
        var columns: Int
        var tileWidth: CGFloat
        var rows: Int
        var height: CGFloat
    }

    /// Below this a tile is too narrow to read as one, so the strip wraps
    /// instead of shrinking further.
    static let minimumTileWidth: CGFloat = 64

    /// And above this a tile stops being a tile.
    ///
    /// Without a ceiling the strip divided its whole width between however
    /// many shortcuts there were, so two pinned sites became two lozenges half
    /// a sidebar wide each: the same layout that looks right with six looked
    /// absurd with two, and the tiles changed size every time one was added.
    /// A shortcut is a fixed-size thing that there happen to be some number
    /// of, so the row fills up from the left and stops.

    static func plan(itemCount: Int, availableWidth: CGFloat) -> Plan {
        let spacing = Style.Metrics.tileSpacing
        let count = max(itemCount, 1)
        guard availableWidth > 0 else {
            return Plan(columns: 1, tileWidth: minimumTileWidth, rows: count,
                        height: CGFloat(count) * Style.Metrics.tileHeight
                            + CGFloat(count - 1) * spacing)
        }

        let fitting = Int((availableWidth + spacing) / (minimumTileWidth + spacing))
        // Never more columns than there are tiles, or the last row stretches a
        // single tile across the whole strip.
        let columns = max(1, min(count, fitting))
        let even = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let width = even
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * Style.Metrics.tileHeight
            + CGFloat(rows - 1) * spacing
        return Plan(columns: columns, tileWidth: width, rows: rows, height: height)
    }
}

// MARK: - Tiles

/// A single filled tile. Private because nothing outside the strip should be
/// able to place one on its own and get the spacing wrong.
@MainActor
private final class PinnedTileView: NSView {
    var onClick: (() -> Void)?
    /// A right-click on the tile asks to unpin it.
    var onRemove: (() -> Void)?

    /// The same view the sidebar rows use, which is the whole point: a pinned
    /// site has no web view to ask for its declared icons, and that is a case
    /// `FaviconImageView` and the service behind it already handle by falling
    /// back to the `/favicon.ico` convention. Re-deriving the cache-hit,
    /// fetch and placeholder handling here would be a second fetcher for the
    /// sake of a tile.
    private let icon = FaviconImageView()
    /// The brand ring. A conic gradient masked to the tile's outline, so the
    /// colours run around the edge rather than across it.
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var highlight: RowHighlight?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }

    private let isActive: Bool

    init(tile: PinnedTile, isPrivate: Bool) {
        self.isActive = tile.isActive
        super.init(frame: .zero)
        // The strip sets this view's frame directly, so it is laid out by
        // frame rather than by constraints.
        translatesAutoresizingMaskIntoConstraints = true

        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer) }
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = Self.ringWidth
        ring.mask = ringMask
        layer?.addSublayer(ring)
        applyRing(for: nil)

        addSubview(icon)
        // The icon arrives asynchronously, so the ring is coloured when it does
        // rather than once at build time.
        icon.onImageChanged = { [weak self] image in self?.applyRing(for: image) }
        updateHighlight()
        if let url = tile.url {
            icon.show(for: url, in: nil, isPrivate: isPrivate, restored: tile.favicon)
        }

        toolTip = tile.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(tile.title)
        setAccessibilityElement(true)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PinnedTileView is created in code only")
    }

    /// Thin enough to read as an outline rather than a frame, at the tile size
    /// the strip draws.
    private static let ringWidth: CGFloat = 2

    /// The brand ring, and only on the tile whose page is in front.
    ///
    /// Every tile used to carry one -- the inactive ones in a neutral grey at
    /// 0.45 -- on the reasoning that a shared shape makes a strip read as one
    /// thing. In practice it did the opposite: six grey outlines around six
    /// grey boxes is six competing rectangles, and the one tile that mattered
    /// was distinguished only by the hue of its outline. A ring nobody else
    /// has is a far stronger signal than a ring everybody has in a different
    /// colour, and the strip reads as a row of icons rather than a row of
    /// frames.
    private func applyRing(for image: NSImage?) {
        // Arc distinguishes the active Favorite with the plate, without a brand-colored outline.
        ring.isHidden = true
    }

    private func updateHighlight() {
        highlight?.apply(
            isActive ? .selected : (isHovered ? .hover : .rest),
            appearance: effectiveAppearance
        )
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: Style.Metrics.tileCornerRadius, scale: highlightScale
        )
        // No implicit animation: the tiles are re-laid out on every sidebar
        // drag, and a ring that eases into place on each frame smears.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ringMask.frame = bounds
        ringMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: Self.ringWidth / 2, dy: Self.ringWidth / 2),
            cornerWidth: Style.Metrics.tileCornerRadius,
            cornerHeight: Style.Metrics.tileCornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// The resting fill, under the highlight. Drawn rather than layered so the
    /// tile always has a body even before it is hovered or made active.
    override func draw(_ dirtyRect: NSRect) {
        Style.Colors.tileFill.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Style.Metrics.tileCornerRadius,
            yRadius: Style.Metrics.tileCornerRadius
        ).fill()
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
    /// The squeeze the tile gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if acceptsSpringPress { press.flick() }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// A tile is pinned from a tab's menu but has nowhere else to be unpinned
    /// (the tab left the list when it became a tile), so a right-click on the
    /// tile is the way back off it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let unpin = NSMenuItem(title: "Unpin", action: #selector(removeFromMenu), keyEquivalent: "")
        unpin.target = self
        unpin.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        menu.addItem(unpin)
        return menu
    }

    @objc private func removeFromMenu() { onRemove?() }
}

/// A full-width, dismissible explanation instead of an empty Favorite tile.
@MainActor
private final class EmptyFavoritesHint: NSView {
    var onDismiss: (() -> Void)?
    var isDropTarget = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Drag to add Favorites")
    private let detail = NSTextField(wrappingLabelWithString: "Favorites keep your most used sites and apps close")
    private let dismiss = IconButton(symbolName: "xmark", label: "Dismiss Favorites Hint", side: 22, symbolSize: 11)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
        icon.image = NSImage(systemSymbolName: "star.circle.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .labelColor.withAlphaComponent(0.70)
        icon.imageScaling = .scaleProportionallyDown
        icon.isEnabled = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor.withAlphaComponent(0.70)
        title.alignment = .center
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .labelColor.withAlphaComponent(0.55)
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        dismiss.contentTintColor = .labelColor.withAlphaComponent(0.45)
        dismiss.setClickHandler { [weak self] in self?.onDismiss?() }
        for view in [icon, title, detail, dismiss] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: topAnchor, constant: 54),
            dismiss.topAnchor.constraint(equalTo: topAnchor, constant: 4), dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Empty Favorites")
    }
    required init?(coder: NSCoder) { fatalError("EmptyFavoritesHint is created in code only") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isDropTarget ? 0.22 : 0.12).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        path.fill()
        path.lineWidth = 1
        path.setLineDash([5, 5], count: 2, phase: 0)
        NSColor.labelColor.withAlphaComponent(isDropTarget ? 0.65 : 0.30).setStroke()
        path.stroke()
    }
}
