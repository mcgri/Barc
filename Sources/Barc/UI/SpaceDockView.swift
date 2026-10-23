// Modified for Barc: configurable Space icons with pointer magnification, 2026-10-23.
import AppKit

struct SpaceDockItem {
    let id: UUID
    let name: String
    let icon: SpaceIcon
    let color: NSColor
}

/// Fixed cells keep pointer tracking, click targets and scrolling independent of magnification.
enum SpaceDockLayout {
    static let iconSide: CGFloat = 13
    static let enlargedSide: CGFloat = 20
    static let inset: CGFloat = 2
    static let height: CGFloat = 40

    struct Plan {
        var frames: [NSRect]
        var iconSizes: [CGFloat]
        var width: CGFloat
    }

    static func plan(count: Int, availableWidth: CGFloat, pointerX: CGFloat?, reduceMotion: Bool) -> Plan {
        guard count > 0 else { return Plan(frames: [], iconSizes: [], width: max(0, availableWidth)) }
        let rowWidth = CGFloat(count) * enlargedSide + inset * 2
        let width = max(availableWidth, rowWidth)
        let start = (width - rowWidth) / 2 + inset
        let frames = (0..<count).map { index in
            NSRect(x: start + CGFloat(index) * enlargedSide, y: 0, width: enlargedSide, height: height)
        }
        let sizes = (0..<count).map { index -> CGFloat in
            guard !reduceMotion, let pointerX, pointerX.isFinite else { return iconSide }
            let center = frames[index].midX
            let distance = abs(pointerX - center)
            let influence = distance < 50 ? (1 + cos(.pi * distance / 50)) / 2 : 0
            return iconSide + (enlargedSide - iconSide) * influence
        }
        return Plan(frames: frames, iconSizes: sizes, width: width)
    }
}

@MainActor
final class SpaceDockView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onChangeIcon: ((UUID, IconMenu.Choice) -> Void)?
    private let scroll = SpaceDockScrollView()
    private let document = SpaceDockDocumentView()
    private(set) var buttons: [SpaceDockButton] = []
    private var selectedID: UUID?
    private var pointerX: CGFloat?
    private var lastViewportWidth: CGFloat = -1
    private nonisolated(unsafe) var pointerMonitor: Any?
    private nonisolated(unsafe) var animationTimer: Timer?
    private var lastAnimationTime: TimeInterval = 0
    private var targetIconSizes: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .automatic
        scroll.documentView = document
        scroll.onScroll = { [weak self] in self?.setPointer(nil) }
        document.onPointer = { [weak self] point in self?.setPointer(point?.x) }
        addSubview(scroll)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SpaceDockLayout.height),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spaces")
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    deinit {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        animationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        guard window != nil else {
            stopAnimation()
            pointerX = nil
            arrange(animated: false)
            return
        }
        // Buttons may track the mouse themselves. Observe the window's pointer
        // stream too, so magnification follows across them and during a drag.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackPointer(event) }
            return event
        }
    }

    func trackPointer(_ event: NSEvent) {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { setPointer(nil); return }
        let point = document.convert(event.locationInWindow, from: nil)
        setPointer(document.visibleRect.contains(point) ? point.x : nil)
    }

    func show(_ items: [SpaceDockItem], selectedID: UUID?) {
        let selectionChanged = self.selectedID != selectedID
        self.selectedID = selectedID
        let previous = Dictionary(uniqueKeysWithValues: buttons.map { ($0.id, $0) })
        for button in buttons where !items.contains(where: { $0.id == button.id }) { button.removeFromSuperview() }
        buttons = items.map { item in
            let button = previous[item.id] ?? SpaceDockButton(id: item.id)
            button.configure(item, selected: item.id == selectedID)
            button.onSelect = { [weak self] in self?.onSelect?(item.id) }
            button.onChangeIcon = { [weak self] choice in self?.onChangeIcon?(item.id, choice) }
            if button.superview !== document { document.addSubview(button) }
            return button
        }
        setAccessibilityValue(items.first { $0.id == selectedID }?.name)
        arrange(animated: false)
        if selectionChanged { revealSelection() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        arrange(animated: false)
        if lastViewportWidth != scroll.contentSize.width {
            lastViewportWidth = scroll.contentSize.width
            revealSelection()
        }
    }

    /// Also used by the geometry tests; mouse movement reaches this same path.
    func setPointer(_ x: CGFloat?) {
        guard pointerX != x else { return }
        pointerX = x
        arrange(animated: true)
    }

    private func arrange(animated: Bool) {
        let plan = SpaceDockLayout.plan(count: buttons.count, availableWidth: scroll.contentSize.width,
                                       pointerX: pointerX, reduceMotion: Style.Motion.isReduced)
        let size = NSSize(width: plan.width, height: SpaceDockLayout.height)
        if document.frame.size != size { document.setFrameSize(size) }
        targetIconSizes = plan.iconSizes
        let shouldAnimate = (animated || animationTimer != nil) && !Style.Motion.isReduced
        for (index, button) in buttons.enumerated() {
            button.apply(frame: plan.frames[index], iconSize: shouldAnimate ? button.iconSize : targetIconSizes[index])
        }
        if shouldAnimate { startAnimation() } else { stopAnimation() }
    }

    private func startAnimation() {
        guard animationTimer == nil, zip(buttons, targetIconSizes).contains(where: { abs($0.0.iconSize - $0.1) > 0.01 }) else { return }
        lastAnimationTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.advanceMagnification(by: now - self.lastAnimationTime)
                self.lastAnimationTime = now
            }
        }
        timer.tolerance = 1.0 / 600
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One non-spring animation follows the latest target without restarting on every mouse event.
    /// Passing elapsed time also lets tests replay rapid pointer movement deterministically.
    func advanceMagnification(by elapsed: TimeInterval) {
        let blend: CGFloat = Style.Motion.isReduced ? 1 : 1 - exp(-max(0, elapsed) / 0.045)
        var settled = true
        for (button, target) in zip(buttons, targetIconSizes) {
            var size = button.iconSize + (target - button.iconSize) * blend
            if abs(size - target) < 0.01 { size = target } else { settled = false }
            button.apply(frame: button.frame, iconSize: size)
        }
        if settled { stopAnimation() }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func revealSelection() {
        if let button = buttons.first(where: { $0.id == selectedID }) { button.scrollToVisible(button.bounds) }
    }

}

@MainActor
private final class SpaceDockScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?()
        guard abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY), let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let limit = max(0, documentView.bounds.width - contentView.bounds.width)
        let x = min(max(0, contentView.bounds.origin.x - event.scrollingDeltaY), limit)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class SpaceDockDocumentView: NSView {
    var onPointer: ((NSPoint?) -> Void)?
    private var pointerTracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.inVisibleRect, .activeAlways, .enabledDuringMouseDrag, .mouseEnteredAndExited, .mouseMoved],
                                 owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }
}

@MainActor
final class SpaceDockButton: NSButton {
    override var isFlipped: Bool { false }
    let id: UUID
    var onSelect: (() -> Void)?
    var onChangeIcon: ((IconMenu.Choice) -> Void)?
    private let glyph = NSImageView()
    private var item: SpaceDockItem?
    private(set) var iconSize = SpaceDockLayout.iconSide
    private(set) var isSelectedSpace = false

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        target = self
        action = #selector(selectSpace)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.isEnabled = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Change Icon") { [weak self] in
                guard let self else { return false }
                customizationMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
                return true
            }
        ])
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    func configure(_ item: SpaceDockItem, selected: Bool) {
        self.item = item
        isSelectedSpace = selected
        setAccessibilityLabel(item.name)
        setAccessibilityValue(selected ? "Selected" : "")
        toolTip = "\(item.name)\nClick to switch. Right-click to change icon."
        glyph.image = item.icon == .automatic ? Self.initialImage(item) : item.icon.image(color: item.color, title: item.name, side: 60)
        needsDisplay = true
    }

    func apply(frame: NSRect, iconSize: CGFloat) {
        self.iconSize = iconSize
        let imageFrame = NSRect(x: (frame.width - iconSize) / 2, y: 13.5, width: iconSize, height: iconSize)
        glyph.alphaValue = isSelectedSpace || iconSize > SpaceDockLayout.iconSide + 0.2 ? 1 : 0.58
        if self.frame != frame { self.frame = frame }
        if glyph.frame != imageFrame { glyph.frame = imageFrame }
    }

    @objc private func selectSpace() { onSelect?() }

    override func menu(for event: NSEvent) -> NSMenu? { customizationMenu() }

    func customizationMenu() -> NSMenu {
        guard let item else { return NSMenu() }
        let menu = IconMenu.menu(current: item.icon.asMenuChoice, color: item.color, anchor: self) { [weak self] choice in
            self?.onChangeIcon?(choice)
        }
        menu.items.first { $0.title == "Remove Icon" }?.title = "Use Default Icon"
        return menu
    }

    private static func initialImage(_ item: SpaceDockItem) -> NSImage {
        let side: CGFloat = 60
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            item.color.withAlphaComponent(1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16).fill()
            let initial = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased() as NSString
            let rgb = item.color.usingColorSpace(.sRGB) ?? .systemBlue
            let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
            let ink: NSColor = brightness > 0.6 ? .black : .white
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: ink]
            let size = initial.size(withAttributes: attributes)
            initial.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
            return true
        }
    }
}
