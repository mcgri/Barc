// Modified for Barc: center the sidebar Add mark without SF Symbol baseline insets, 2026-10-24.
import AppKit

@MainActor
enum SidebarAddGlyph {
    static func image() -> NSImage {
        let image = NSImage(size:NSSize(width:20,height:20),flipped:false) { _ in
            NSColor.black.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.75
            mark.lineCapStyle = .round
            mark.move(to:NSPoint(x:4,y:10));mark.line(to:NSPoint(x:16,y:10))
            mark.move(to:NSPoint(x:10,y:4));mark.line(to:NSPoint(x:10,y:16))
            mark.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Add"
        return image
    }
}
