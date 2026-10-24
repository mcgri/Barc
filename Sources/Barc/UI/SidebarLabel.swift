// Modified for Barc: single-pass sidebar caption ink with native editing, 2026-10-25.
import AppKit

/// Draw the native cell once, preserving its glyph layout, truncation and
/// insets. Selectable and editable text retains the native field editor.
@MainActor
final class SidebarLabel: NSTextField {
    override func draw(_ dirtyRect:NSRect) {
        guard !isEditable, !isSelectable else { super.draw(dirtyRect); return }
        cell?.drawInterior(withFrame:bounds,in:self)
    }
}
