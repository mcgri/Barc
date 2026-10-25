// Modified for Barc: native-size Space emoji and neutral inactive artwork, 2026-10-25.
import AppKit

@MainActor
enum SpaceDockArtwork {
    /// Draw at the resting well's native size, retaining small-glyph hinting.
    /// The ink offset aligns emoji with the frozen footer reference, while
    /// the button's well and pointer target remain fixed.
    static func emoji(_ text: String, title: String) -> NSImage {
        let image = NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:12)]
            let value = text as NSString, size = value.size(withAttributes:attributes)
            value.draw(at:NSPoint(x:rect.midX-size.width/2+0.25,y:rect.midY-size.height/2+1),withAttributes:attributes)
            return true
        }
        image.accessibilityDescription = title
        return image
    }

    static func monochrome(_ image: NSImage) -> NSImage {
        let extent = max(image.size.width,image.size.height)
        guard extent.isFinite, extent>0 else { return image }
        let side = max(1,Int(ceil(min(60,extent)*2)))
        guard let rgb = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
            let context = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*2,
            space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:rgb,flipped:false)
        image.draw(in:NSRect(x:0,y:0,width:side,height:side))
        NSGraphicsContext.restoreGraphicsState()
        guard let color = rgb.makeImage() else { return image }
        context.draw(color,in:CGRect(x:0,y:0,width:side,height:side))
        guard let gray = context.makeImage() else { return image }
        return NSImage(cgImage:gray,size:image.size)
    }
}
