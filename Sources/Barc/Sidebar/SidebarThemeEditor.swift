// Modified for Barc: Arc-style sidebar theme editor, 2026-10-24.
import AppKit

@MainActor
final class SidebarThemeEditor: NSViewController {
    private let session: BrowserSession
    private weak var space: Space?
    private(set) var style: SidebarThemeStyle
    private(set) var presetPage = 0
    private var selectedColor = 0
    private let canvas = ThemeColorCanvas()
    private var modeButtons: [NSButton] = []
    private var swatches: [NSButton] = []
    private let previous = NSButton()
    private let next = NSButton()
    private let add = NSButton()
    private let remove = NSButton()
    let intensity = ThemeValueControl(label: "Intensity")
    let grain = ThemeValueControl(label: "Graininess", dial: true)

    // Sampled from Arc's five visible preset pages; no artwork is embedded.
    static let presets = [
        ["#f2ebe5", "#e59fbb", "#9e749a", "#e1686f", "#ef8c62", "#f2d56d", "#73e59d", "#7fb8d6", "#666786"],
        ["#f0f1e9", "#e8bcaf", "#ab8793", "#e3ba82", "#f1e97c", "#c4ef83", "#87e5e4", "#9093da", "#8c7e97"],
        ["#fffbfa", "#fbeaf4", "#ecd2eb", "#f7cdd1", "#f9e1d5", "#fef9e6", "#e4fcec", "#e0f2fc", "#c5c6e2"],
        ["#4b3b58", "#633856", "#854344", "#a77049", "#d1b36a", "#cccca8", "#84a786", "#345f4b", "#2e4469"],
        ["#ffffff", "#e5e5e5", "#cccccc", "#b3b3b3", "#808080", "#666666", "#333333", "#191919", "#020202"]
    ]

    init(session: BrowserSession, space: Space) {
        self.session = session; self.space = space; style = SidebarThemeStyle(space: space)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 356, height: 508)
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func loadView() {
        let root = ThemeEditorSurface(frame: NSRect(origin: .zero, size: preferredContentSize))
        view = root
        canvas.frame = NSRect(x: 9, y: 8, width: 338, height: 338)
        root.addSubview(canvas)
        let symbols = ["sparkles", "sun.max.fill", "moon.stars.fill"]
        for (i, appearance) in AppearancePreference.allCases.enumerated() {
            let button = iconButton(symbols[i], label: appearance.title, action: #selector(chooseAppearance(_:)))
            button.tag = i; button.frame = NSRect(x: 113 + CGFloat(i) * 40, y: 23, width: 32, height: 32)
            button.wantsLayer = true; button.layer?.cornerRadius = 8
            canvas.addSubview(button); modeButtons.append(button)
        }
        configure(add, symbol: "plus", label: "Add", action: #selector(addColor))
        configure(remove, symbol: "minus", label: "Remove", action: #selector(removeColor))
        remove.frame = NSRect(x: 135, y: 294, width: 28, height: 28)
        add.frame = NSRect(x: 175, y: 294, width: 28, height: 28)
        canvas.addSubview(remove); canvas.addSubview(add)
        canvas.onSelect = { [weak self] index in self?.selectedColor = index }
        canvas.onMove = { [weak self] index, color in
            guard let self, style.colors.indices.contains(index) else { return }
            selectedColor = index; style.colors[index] = SidebarThemeStyle.color(color); commit()
        }
        configure(previous, symbol: "chevron.left", label: "Move to previous preset page.", action: #selector(previousPage))
        configure(next, symbol: "chevron.right", label: "Move to next preset page.", action: #selector(nextPage))
        previous.frame = NSRect(x: 12, y: 364, width: 22, height: 30)
        next.frame = NSRect(x: 322, y: 364, width: 22, height: 30)
        root.addSubview(previous); root.addSubview(next)
        for i in 0..<9 {
            let button = NSButton(); button.isBordered = false; button.imagePosition = .imageOnly
            button.tag = i; button.target = self; button.action = #selector(choosePreset(_:))
            button.frame = NSRect(x: 48 + CGFloat(i) * 29.5, y: 367, width: 24, height: 24)
            root.addSubview(button); swatches.append(button)
        }
        intensity.frame = NSRect(x: 12, y: 416, width: 232, height: 70)
        grain.frame = NSRect(x: 260, y: 413, width: 76, height: 76)
        root.addSubview(intensity); root.addSubview(grain)
        intensity.onChange = { [weak self] value in self?.style.intensity = value; self?.commit() }
        grain.onChange = { [weak self] value in self?.style.grain = value; self?.commit() }
        let cycle = NSButton(title: "", target: self, action: #selector(cycleTexture))
        cycle.isBordered = false; cycle.setAccessibilityLabel("Cycle noise texture"); cycle.toolTip = "Cycle noise texture"
        cycle.frame = NSRect(x: 278, y: 431, width: 40, height: 40)
        root.addSubview(cycle)
        sync()
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(); configure(button, symbol: symbol, label: label, action: action); return button
    }
    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false; button.title = ""; button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.target = self; button.action = action; button.setAccessibilityLabel(label); button.toolTip = label
    }
    private func commit() {
        guard let space, session.spaces.contains(where: { $0 === space }) else { return }
        session.setSidebarTheme(style, for: space); sync()
    }
    private func sync() {
        canvas.show(style.colors)
        (view as? ThemeEditorSurface)?.color = style.colors.first?.nsColor ?? .clear
        intensity.value = style.intensity; grain.value = style.grain; grain.showsGrain = style.hasGrain
        add.isEnabled = true
        remove.isEnabled = !style.colors.isEmpty
        for (i, button) in modeButtons.enumerated() {
            let selected = AppearancePreference.allCases[i] == session.browserAppearance
            button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(selected ? 0.1 : 0).cgColor
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        previous.isEnabled = presetPage > 0; next.isEnabled = presetPage < Self.presets.count - 1
        for (i, button) in swatches.enumerated() {
            let hex = Self.presets[presetPage][i]
            let color = NSColor(hexString: hex) ?? .gray
            button.image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
                color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.black.withAlphaComponent(0.09).setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); path.lineWidth = 2; path.stroke(); return true
            }
            button.setAccessibilityLabel("Set space color to \(hex)"); button.toolTip = hex
        }
    }
    @objc private func chooseAppearance(_ sender: NSButton) {
        guard AppearancePreference.allCases.indices.contains(sender.tag) else { return }
        session.setBrowserAppearance(AppearancePreference.allCases[sender.tag]); sync()
    }
    @objc private func choosePreset(_ sender: NSButton) {
        guard Self.presets[presetPage].indices.contains(sender.tag), let color = NSColor(hexString: Self.presets[presetPage][sender.tag]) else { return }
        if style.colors.isEmpty { style.colors.append(SidebarThemeStyle.color(color)); selectedColor = 0 }
        else { style.colors[min(selectedColor, style.colors.count - 1)] = SidebarThemeStyle.color(color) }
        commit()
    }
    @objc private func nextPage() { presetPage = min(Self.presets.count - 1, presetPage + 1); sync() }
    @objc private func previousPage() { presetPage = max(0, presetPage - 1); sync() }
    @objc private func addColor() {
        let hue = CGFloat(style.colors.count) * 0.23 + 0.52
        style.colors.append(SidebarThemeStyle.color(NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.95, alpha: 1)))
        selectedColor = style.colors.count - 1; commit()
    }
    @objc private func removeColor() {
        guard !style.colors.isEmpty else { return }
        style.colors.remove(at: min(selectedColor, style.colors.count - 1)); selectedColor = max(0, style.colors.count - 1); commit()
    }
    @objc private func cycleTexture() { style.hasGrain.toggle(); commit() }
}

@MainActor
private final class ThemeEditorSurface: NSView {
    override var isFlipped: Bool { true }
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill()
        bounds.fill()
        NSGradient(starting: color.withAlphaComponent(0.015), ending: color.withAlphaComponent(0.045))?.draw(in: bounds, angle: 90)
    }
}

@MainActor
final class ThemeColorCanvas: NSVisualEffectView {
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int, NSColor) -> Void)?
    private var handles: [ThemeColorHandle] = []
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover; blendingMode = .behindWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8; layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    func show(_ colors: [ImportedChrome.Color]) {
        while handles.count > colors.count { handles.removeLast().removeFromSuperview() }
        for (i, color) in colors.enumerated() {
            let handle: ThemeColorHandle
            let isNew = !handles.indices.contains(i)
            if handles.indices.contains(i) { handle = handles[i] }
            else { handle = ThemeColorHandle(); handles.append(handle); addSubview(handle, positioned: .below, relativeTo: subviews.first) }
            let colorChanged = handle.color != color.nsColor
            handle.color = color.nsColor
            handle.setAccessibilityLabel("Color \(i + 1)")
            handle.onSelect = { [weak self] in self?.onSelect?(i) }
            handle.onMove = { [weak self] point in
                guard let self else { return }
                let dx = point.x / bounds.width - 0.5, dy = point.y / bounds.height - 0.5
                var hue = atan2(dy, dx) / (2 * .pi); if hue < 0 { hue += 1 }
                let saturation = min(1, hypot(dx, dy) * 2)
                onMove?(i, NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1))
            }
            let rgb = color.nsColor.usingColorSpace(.sRGB) ?? .gray
            let angle = rgb.hueComponent * 2 * .pi
            let center = NSPoint(x: bounds.midX + cos(angle) * bounds.width * 0.25,
                                 y: bounds.midY + sin(angle) * bounds.height * 0.25)
            // Keep the active drag under the pointer; stationary colors use
            // their hue's position on the field.
            if !handle.isDragging && (isNew || colorChanged) { handle.frame = NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        for y in stride(from: CGFloat(3), to: bounds.height - 2, by: 4.25) {
            for x in stride(from: CGFloat(3), to: bounds.width - 2, by: 4.25) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 0.6, height: 0.6)).fill()
            }
        }
    }
}

@MainActor
private final class ThemeColorHandle: NSControl {
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    private(set) var isDragging = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }
    override func accessibilityValue() -> Any? { color.hexString }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); isDragging = true; onSelect?() }
    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: min(parent.bounds.maxX - 22, max(22, point.x)), y: min(parent.bounds.maxY - 22, max(22, point.y)))
        frame.origin = NSPoint(x: center.x - 22, y: center.y - 22); onMove?(center)
    }
    override func mouseUp(with event: NSEvent) { isDragging = false }
    override func keyDown(with event: NSEvent) {
        var point = NSPoint(x: frame.midX, y: frame.midY)
        switch event.keyCode {
        case 123: point.x -= 3
        case 124: point.x += 3
        case 125: point.y += 3
        case 126: point.y -= 3
        default: super.keyDown(with: event); return
        }
        if let parent = superview {
            point.x = min(parent.bounds.maxX - 22, max(22, point.x)); point.y = min(parent.bounds.maxY - 22, max(22, point.y))
        }
        frame.origin = NSPoint(x: point.x - 22, y: point.y - 22)
        isDragging = true; onSelect?(); onMove?(point); isDragging = false
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.1); shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        NSGraphicsContext.restoreGraphicsState()
        color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
    }
}
