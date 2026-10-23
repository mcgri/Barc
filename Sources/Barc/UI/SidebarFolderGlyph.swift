// Modified for Barc: filled sidebar folders with imported website badges, 2026-10-24.
import AppKit

@MainActor
enum SidebarFolderGlyph {
    static func image(tint: NSColor, badge: Data? = nil) -> NSImage {
        let mark = badge.flatMap { try? FaviconDecoder.normalize($0) }.flatMap(NSImage.init(data:))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let stroke = tint.blended(withFraction: 0.45, of: Style.Colors.primaryText) ?? tint
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 3, y: 1))
            folder.line(to: NSPoint(x: 15.5, y: 1))
            folder.curve(to: NSPoint(x: 17.5, y: 3), controlPoint1: NSPoint(x: 16.7, y: 1), controlPoint2: NSPoint(x: 17.5, y: 1.8))
            folder.line(to: NSPoint(x: 17.5, y: 12))
            folder.curve(to: NSPoint(x: 15.5, y: 14), controlPoint1: NSPoint(x: 17.5, y: 13.2), controlPoint2: NSPoint(x: 16.7, y: 14))
            folder.line(to: NSPoint(x: 8, y: 14))
            folder.line(to: NSPoint(x: 6.5, y: 16))
            folder.line(to: NSPoint(x: 3, y: 16))
            folder.curve(to: NSPoint(x: 1, y: 14), controlPoint1: NSPoint(x: 1.8, y: 16), controlPoint2: NSPoint(x: 1, y: 15.2))
            folder.line(to: NSPoint(x: 1, y: 3))
            folder.curve(to: NSPoint(x: 3, y: 1), controlPoint1: NSPoint(x: 1, y: 1.8), controlPoint2: NSPoint(x: 1.8, y: 1))
            folder.close()
            NSColor.white.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16.5, height: 13), xRadius: 2, yRadius: 2).fill()
            stroke.setStroke()
            folder.lineWidth = 1.2
            folder.stroke()
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 1.6, y: 14))
            seam.line(to: NSPoint(x: 15.5, y: 14))
            seam.lineWidth = 1
            seam.stroke()
            if let mark {
                let rect = NSRect(x: 4, y: 2, width: 10, height: 10)
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
