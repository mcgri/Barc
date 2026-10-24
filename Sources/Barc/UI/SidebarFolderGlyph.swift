// Modified for Barc: source-sized sidebar folders with contrasting outlines and imported badges, 2026-10-24.
import AppKit

@MainActor
enum SidebarFolderGlyph {
    static func image(tint: NSColor, badge: Data? = nil, strokeColor: NSColor? = nil) -> NSImage {
        let mark = badge.flatMap { try? FaviconDecoder.normalize($0) }.flatMap(NSImage.init(data:))
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let stroke = strokeColor ?? tint.blended(withFraction: 0.45, of: Style.Colors.primaryText) ?? tint
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 4, y: 1.75))
            folder.line(to: NSPoint(x: 17, y: 1.75))
            folder.curve(to: NSPoint(x: 19.25, y: 4), controlPoint1: NSPoint(x: 18.35, y: 1.75), controlPoint2: NSPoint(x: 19.25, y: 2.65))
            folder.line(to: NSPoint(x: 19.25, y: 14.8))
            folder.curve(to: NSPoint(x: 17, y: 17.05), controlPoint1: NSPoint(x: 19.25, y: 16.15), controlPoint2: NSPoint(x: 18.35, y: 17.05))
            folder.line(to: NSPoint(x: 11.5, y: 17.05))
            folder.line(to: NSPoint(x: 8.5, y: 19.2))
            folder.line(to: NSPoint(x: 5.5, y: 19.2))
            folder.curve(to: NSPoint(x: 1.75, y: 16), controlPoint1: NSPoint(x: 3.25, y: 19.2), controlPoint2: NSPoint(x: 1.75, y: 17.75))
            folder.line(to: NSPoint(x: 1.75, y: 4))
            folder.curve(to: NSPoint(x: 4, y: 1.75), controlPoint1: NSPoint(x: 1.75, y: 2.65), controlPoint2: NSPoint(x: 2.65, y: 1.75))
            folder.close()
            NSColor.white.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 17.5, height: 13.5), xRadius: 2.25, yRadius: 2.25).fill()
            stroke.setStroke()
            folder.lineWidth = 1.5
            folder.stroke()
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 2.2, y: 15.1))
            seam.line(to: NSPoint(x: 18.7, y: 15.1))
            seam.lineWidth = 1.5
            seam.stroke()
            if let mark {
                let rect = NSRect(x: 5.75, y: 4, width: 9, height: 9)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                mark.draw(in: rect)
                stroke.setFill()
                rect.fill(using: .sourceAtop)
                NSGraphicsContext.current?.cgContext.endTransparencyLayer()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
