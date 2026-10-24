// Modified for Barc: frosted launcher backgrounds matching Arc's light and dark popups, 2026-10-24.
import AppKit

/// Blur the page and sidebar together, then damp their colours so the query
/// remains readable. The tint is above the effect, below the interactive rows.
@MainActor
final class CommandPanelView: NSVisualEffectView {
    private let tint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = CommandBarMetrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        addSubview(tint)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Created in code only") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            tint.layer?.backgroundColor = (dark
                ? NSColor(srgbRed: 20.0/255, green: 20.0/255, blue: 20.0/255, alpha: 0.8)
                : NSColor(srgbRed: 253.0/255, green: 252.0/255, blue: 252.0/255, alpha: 0.8)).cgColor
            layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.18).cgColor
        }
    }
}
