// Modified for Barc: decorative button artwork never intercepts pointer events, 2026-10-24.
import AppKit

final class ButtonGlyphView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
