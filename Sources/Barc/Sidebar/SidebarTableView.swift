// Modified for Barc: context menus use the sidebar's own row appearance, 2026-10-24.
import AppKit

@MainActor
final class SidebarTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu)?
    private let splitDropIndicator = SplitDropIndicator()
    private(set) var splitDropPreviewRect: NSRect?

    func showSplitDropPreview(_ rect: NSRect?, color: NSColor = .clear) {
        splitDropPreviewRect = rect
        guard let rect else { splitDropIndicator.isHidden = true; return }
        if splitDropIndicator.superview == nil {
            addSubview(splitDropIndicator,positioned:.above,relativeTo:nil)
        }
        splitDropIndicator.frame = rect
        splitDropIndicator.color = color
        splitDropIndicator.isHidden = false
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        showSplitDropPreview(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        showSplitDropPreview(nil)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        showSplitDropPreview(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuForRow else { return super.menu(for: event) }
        // NSTableView's implementation adds a rectangular contextual highlight
        // around the clicked row. The sidebar cells already draw their hover
        // and selection, so ask for the menu without that additional outline.
        let point = convert(event.locationInWindow, from: nil)
        return menuForRow(row(at: point))
    }

    private final class SplitDropIndicator: NSView {
        var color: NSColor = .clear { didSet { needsDisplay = true } }
        override init(frame:NSRect) {
            super.init(frame:frame)
            wantsLayer = true
            layer?.zPosition = 100
            setAccessibilityElement(false)
            isHidden = true
        }
        required init?(coder:NSCoder) { fatalError("SplitDropIndicator is created in code only") }
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect:NSRect) {
            let rect = bounds.insetBy(dx:0.5,dy:0.5)
            let path = NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6)
            color.withAlphaComponent(0.24).setFill(); path.fill()
            (color.blended(withFraction:0.45,of:.labelColor) ?? color).withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1; path.stroke()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); needsDisplay = true
        }
    }
}
