// Modified for Barc: measured empty Favorites hint against the saved sidebar reference, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Favorites hint reference", .serialized)
@MainActor
struct FavoritesHintReferenceTests {
    @Test("The empty Favorites card renders its title, explanation and dismiss action")
    func hint() throws {
        let host = NSView(frame:NSRect(x:0,y:0,width:228,height:116))
        host.appearance = NSAppearance(named:.darkAqua)
        host.wantsLayer = true
        host.layer!.backgroundColor = NSColor(deviceRed:118/255,green:100/255,blue:100/255,alpha:1).cgColor
        let pins = PinnedTilesView()
        pins.translatesAutoresizingMaskIntoConstraints = true
        pins.frame = NSRect(x:8,y:10,width:212,height:96)
        host.addSubview(pins)
        pins.show([])
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:456,pixelsHigh:232,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in:host.bounds,to:bitmap)
        // Frozen Source ink, relative to the card's top rather than its
        // unverified absolute window position. Measured at 2x backing scale.
        let captions:[(NSRect,NSRect)] = [
            (NSRect(x:70,y:87,width:320,height:40),NSRect(x:97,y:95,width:263,height:25)),
            (NSRect(x:70,y:127,width:320,height:65),NSRect(x:88,y:135,width:280,height:52)),
            (NSRect(x:200,y:37,width:56,height:50),NSRect(x:212,y:46,width:32,height:32)),
            (NSRect(x:390,y:32,width:37,height:35),NSRect(x:403,y:45,width:15,height:15))
        ]
        for (region,expected) in captions {
            let actual = ink(bitmap,in:region)
            #expect(actual == expected)
        }
        let fields = UITestSupport.textFields(in:pins)
        #expect(fields.map(\.stringValue).contains("Drag to add Favorites"))
        #expect(fields.map(\.stringValue).contains("Favorites keep your most used sites and apps close"))
        let dismiss = try #require(UITestSupport.buttons(in:pins).first { $0.accessibilityLabel() == "Dismiss Favorites Hint" })
        var dismissals = 0
        pins.onDismissHint = { dismissals += 1 }
        dismiss.performClick(nil)
        #expect(dismissals == 1)
        if let directory = ProcessInfo.processInfo.environment["BARC_HINT_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath:directory).appending(path:"hint.png")
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        }
        // Dynamic appearance must update the attributed wrapping label too.
        // Light text retains its prior effective opacity; only dark ink has
        // a measured Source reference.
        let detailRegion = NSRect(x:70,y:127,width:320,height:65)
        #expect(abs(contrast(bitmap,in:detailRegion,dark:true)-0.65) < 0.015)
        host.appearance = NSAppearance(named:.aqua)
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in:host.bounds,to:bitmap)
        #expect(abs(contrast(bitmap,in:detailRegion,dark:false)-0.80) < 0.015)
        host.appearance = NSAppearance(named:.darkAqua)
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in:host.bounds,to:bitmap)
        #expect(abs(contrast(bitmap,in:detailRegion,dark:true)-0.65) < 0.015)
        #expect(pins.intrinsicContentSize.height == 96)
    }

    private func ink(_ bitmap:NSBitmapImageRep,in region:NSRect) -> NSRect {
        var samples:[(x:Int,y:Int,value:CGFloat)] = []
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let c = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                samples.append((x,y,(c.redComponent+c.greenComponent+c.blueComponent)/3))
            }
        }
        let levels = samples.map(\.value).sorted(),background = levels[levels.count/2]
        let peak = levels.last!-background
        let points = samples.filter { $0.value-background > peak*0.45 }
        let x0 = points.map(\.x).min()!, x1 = points.map(\.x).max()!
        let y0 = points.map(\.y).min()!, y1 = points.map(\.y).max()!
        return NSRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1)
    }

    private func contrast(_ bitmap:NSBitmapImageRep,in region:NSRect,dark:Bool) -> CGFloat {
        var levels:[CGFloat] = []
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let c = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                levels.append((c.redComponent+c.greenComponent+c.blueComponent)/3)
            }
        }
        levels.sort()
        let background = levels[levels.count/2]
        return dark ? (levels.last!-background)/(1-background):(background-levels.first!)/background
    }
}
