// Modified for Barc: caption opacity and native title layout, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Single-pass sidebar labels", .serialized)
@MainActor
struct SidebarLabelTests {
    private func bitmap(_ label:NSTextField, dark:Bool) throws -> NSBitmapImageRep {
        let host = NSView(frame:NSRect(x:0,y:0,width:120,height:40))
        host.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        host.wantsLayer = true
        host.layer!.backgroundColor = NSColor(white:dark ? 0.15 : 1,alpha:1).cgColor
        label.frame = NSRect(x:20,y:11,width:68,height:18)
        host.addSubview(label)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:80,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        image.size = host.bounds.size
        host.cacheDisplay(in:host.bounds,to:image)
        return image
    }
    private func luminance(_ image:NSBitmapImageRep, x:Int, y:Int) -> Double {
        let color = image.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        return Double(color.redComponent+color.greenComponent+color.blueComponent)/3
    }
    private func ink(_ image:NSBitmapImageRep, dark:Bool) -> (bounds:NSRect,alpha:Double) {
        let background = luminance(image,x:0,y:0)
        var values: [(x:Int,y:Int,contrast:Double)] = []
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                values.append((x,y,abs(luminance(image,x:x,y:y)-background)))
            }
        }
        let peak = values.map(\.contrast).max()!
        let pixels = values.filter { $0.contrast > peak*0.45 }
        let left = pixels.map(\.x).min()!, right = pixels.map(\.x).max()!
        let top = pixels.map(\.y).min()!, bottom = pixels.map(\.y).max()!
        return (NSRect(x:left,y:top,width:right-left+1,height:bottom-top+1),peak/(dark ? 1-background : background))
    }
    private func configure(_ label:NSTextField, text:String, dark:Bool, alpha:CGFloat) {
        label.stringValue = text
        label.font = .systemFont(ofSize:14)
        label.textColor = NSColor(white:dark ? 1 : 0,alpha:alpha)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
    }

    @Test("A requested translucent caption draws once in light and dark appearances", arguments:[false,true])
    func opacity(dark:Bool) throws {
        let label = SidebarLabel(labelWithString:"")
        configure(label,text:"Messaging Terms",dark:dark,alpha:0.6)
        let result = ink(try bitmap(label,dark:dark),dark:dark)
        #expect(abs(result.alpha-0.6) < 0.01)
    }

    @Test("Native glyph layout and ellipsis positions survive the single-pass rendering path")
    func nativeTruncation() throws {
        let text = "mocky/Browser: This is a sample browser"
        let native = NSTextField(labelWithString:""), label = SidebarLabel(labelWithString:"")
        configure(native,text:text,dark:false,alpha:0.6)
        configure(label,text:text,dark:false,alpha:0.6)
        let nativeImage = try bitmap(native,dark:false), image = try bitmap(label,dark:false)
        let expected = ink(nativeImage,dark:false), actual = ink(image,dark:false)
        #expect(actual.bounds == expected.bounds)
        #expect(actual.bounds == NSRect(x:46,y:29,width:110,height:26))
        #expect(abs(actual.alpha-0.6) < 0.01)
        #expect(label.stringValue == text)
        #expect(label.accessibilityValue() as? String == text)
        if let directory = ProcessInfo.processInfo.environment["BARC_LABEL_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath:directory).appending(path:"truncated-caption.png")
            try #require(image.representation(using:.png,properties:[:])).write(to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        }
    }

    @Test("Retained-caption alignment resets on reuse and stays inside every density")
    func retainedReuse() throws {
        let previous = Settings.shared.sidebarDensity
        defer { Settings.shared.sidebarDensity = previous }
        for density in SidebarDensity.allCases {
            Settings.shared.sidebarDensity = density
            let row = TabRowView(frame:NSRect(x:0,y:0,width:228,height:density.rowHeight))
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant:density.rowHeight).isActive = true
            let host = UITestSupport.host(row,width:228,height:density.rowHeight)
            row.configure(TabRowContent(title:"Caption"));host.layoutSubtreeIfNeeded()
            let ordinary = row.nameEditorFrame(in:host)
            row.configure(TabRowContent(title:"Retained",keepsInSidebar:true));host.layoutSubtreeIfNeeded()
            let retained = row.nameEditorFrame(in:host)
            #expect(abs(retained.midY-ordinary.midY) == 1)
            #expect(host.bounds.contains(retained))
            row.prepareForReuse()
            row.configure(TabRowContent(title:"Ordinary again"));host.layoutSubtreeIfNeeded()
            #expect(row.nameEditorFrame(in:host) == ordinary)
        }
    }
}
