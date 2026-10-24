// Modified for Barc: inactive Space artwork retains its shape with a neutral palette, 2026-10-24.
import AppKit

@MainActor
enum SpaceDockArtwork {
    static func monochrome(_ image: NSImage) -> NSImage {
        let side = 120
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
