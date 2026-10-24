// Modified for Barc: a flat sidebar divider without native separator outsets, 2026-10-25.
import AppKit

@MainActor
final class SidebarSectionDivider: NSView {
    override init(frame:NSRect) {
        super.init(frame:frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }
    required init?(coder:NSCoder) { fatalError("SidebarSectionDivider is created in code only") }
    override func draw(_ dirtyRect:NSRect) {
        Style.Colors.sidebarSectionDivider.setFill()
        NSBezierPath(rect:bounds).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
