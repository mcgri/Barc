// Modified for Barc: continuous theme intensity and grain controls, 2026-10-24.
import AppKit

@MainActor
final class ThemeValueControl: NSControl {
    let isDial: Bool
    var onChange: ((Double) -> Void)?
    var value: Double = 0 { didSet { needsDisplay = true } }
    var showsGrain = true { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(label: String, dial: Bool = false) {
        isDial = dial
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(label)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
        toolTip = label
    }
    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func accessibilityValue() -> Any? { value }
    override func setAccessibilityValue(_ value: Any?) { if let number = value as? NSNumber { choose(number.doubleValue) } }
    override func accessibilityPerformIncrement() -> Bool { choose(value + 0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { choose(value - 0.05); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: choose(value - 0.02)
        case 124, 126: choose(value + 0.02)
        case 115: choose(0)
        case 119: choose(1)
        default: super.keyDown(with: event)
        }
    }
    private func track(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDial {
            var angle = atan2(point.y - bounds.midY, point.x - bounds.midX) + .pi / 2
            if angle < 0 { angle += 2 * .pi }
            choose(Double(angle / (2 * .pi)))
        } else { choose(Double((point.x - 12) / max(1, bounds.width - 24))) }
    }
    private func choose(_ proposed: Double) {
        guard proposed.isFinite else { return }
        let next = min(1, max(0, proposed))
        guard next != value else { return }
        value = next; onChange?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        let gray = NSColor.labelColor.withAlphaComponent(0.42)
        if isDial {
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - 5
            for tick in 0..<20 {
                let angle = CGFloat(tick) / 20 * 2 * .pi - .pi / 2
                NSColor.labelColor.withAlphaComponent(Double(tick) / 20 <= value ? 0.42 : 0.14).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x + cos(angle) * radius - 2.5,
                    y: center.y + sin(angle) * radius - 2.5, width: 5, height: 5)).fill()
            }
            let disc = NSRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)
            NSColor.gray.withAlphaComponent(0.4).setFill(); NSBezierPath(ovalIn: disc).fill()
            if showsGrain {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: disc).addClip()
                var seed: UInt32 = 417
                for y in stride(from: disc.minY, to: disc.maxY, by: 0.75) {
                    for x in stride(from: disc.minX, to: disc.maxX, by: 0.75) {
                        seed = seed &* 1664525 &+ 1013904223
                        NSColor(white: CGFloat(seed & 255) / 255, alpha: 0.2).setFill()
                        NSRect(x: x, y: y, width: 0.75, height: 0.75).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            let angle = CGFloat(value) * 2 * .pi - .pi / 2
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x + cos(angle) * radius, yBy: center.y + sin(angle) * radius)
            transform.rotate(byRadians: angle); transform.concat()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: -8, y: -3.5, width: 16, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let track = NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.midY - 8, width: bounds.width - 16, height: 16), xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); track.fill()
            let wave = NSBezierPath()
            for step in 0...180 {
                let x = 12 + CGFloat(step) / 180 * (bounds.width - 24)
                let y = bounds.midY - sin(CGFloat(step) / 180 * .pi * 11) * 12
                if step == 0 { wave.move(to: NSPoint(x: x, y: y)) } else { wave.line(to: NSPoint(x: x, y: y)) }
            }
            wave.lineWidth = 4; wave.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.12).setStroke(); wave.stroke()
            let x = 12 + CGFloat(value) * (bounds.width - 24)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: 0, width: x, height: bounds.height).clip()
            gray.setStroke(); wave.stroke(); NSGraphicsContext.restoreGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.06)
            shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 11, y: bounds.midY - 28, width: 22, height: 56), xRadius: 11, yRadius: 11).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
