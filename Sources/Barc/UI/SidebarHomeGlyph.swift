// Modified for Barc: a compact open keepsake box for the sidebar Library control, 2026-10-24.
import AppKit

@MainActor
enum SidebarHomeGlyph {
    static func image() -> NSImage {
        let image = NSImage(size:NSSize(width:18,height:20),flipped:false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect:NSRect(x:3,y:2,width:12,height:9),xRadius:2,yRadius:2).fill()
            let lid = NSBezierPath()
            lid.move(to:NSPoint(x:2.7,y:12.5))
            lid.line(to:NSPoint(x:8.9,y:12.5))
            lid.curve(to:NSPoint(x:11,y:14.8),controlPoint1:NSPoint(x:10.3,y:12.5),controlPoint2:NSPoint(x:10.9,y:13.8))
            lid.line(to:NSPoint(x:7.2,y:14.5))
            lid.line(to:NSPoint(x:6.7,y:16.7))
            lid.curve(to:NSPoint(x:5.4,y:17.2),controlPoint1:NSPoint(x:6.4,y:17.6),controlPoint2:NSPoint(x:5.7,y:17.7))
            lid.line(to:NSPoint(x:4.6,y:15))
            lid.line(to:NSPoint(x:2.5,y:14.7))
            lid.curve(to:NSPoint(x:2.7,y:12.5),controlPoint1:NSPoint(x:1.7,y:14.5),controlPoint2:NSPoint(x:1.8,y:13))
            lid.close();lid.fill()
            NSBezierPath(ovalIn:NSRect(x:10,y:16.5,width:2,height:2)).fill()
            let mark = NSBezierPath()
            mark.move(to:NSPoint(x:13.3,y:15.4))
            mark.curve(to:NSPoint(x:15.4,y:13.3),controlPoint1:NSPoint(x:13.8,y:15.1),controlPoint2:NSPoint(x:15.3,y:13.9))
            mark.curve(to:NSPoint(x:12.9,y:12.6),controlPoint1:NSPoint(x:15.6,y:12.8),controlPoint2:NSPoint(x:13.5,y:12.6))
            mark.curve(to:NSPoint(x:13.3,y:15.4),controlPoint1:NSPoint(x:12.5,y:12.7),controlPoint2:NSPoint(x:12.8,y:15.2))
            mark.close();mark.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSBezierPath(roundedRect:NSRect(x:7,y:8,width:4,height:2),xRadius:1,yRadius:1).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Home"
        return image
    }
}
