// Modified for Barc: opaque launcher surfaces matching Arc's light and dark panels, 2026-10-24.
import AppKit

/// The launcher is a readable surface over a page, independent of that page's
/// colours. A solid backing also avoids a live blur of the page while typing.
@MainActor
final class CommandPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = CommandBarMetrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
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
            layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
                : NSColor(srgbRed: 249.0/255, green: 248.0/255, blue: 246.0/255, alpha: 1)).cgColor
            layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.18).cgColor
        }
    }
}
