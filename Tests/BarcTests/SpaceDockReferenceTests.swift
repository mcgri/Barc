// Modified for Barc: footer artwork against frozen light-reference measurements, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Space dock reference artwork", .serialized)
@MainActor
struct SpaceDockReferenceTests {
    private let emojis = ["😆","🫠","🐮","😇","🫡"]

    private func fixture(dark:Bool, selectedIndex:Int = 0) -> (NSView,SpaceDockView) {
        let footer = SidebarFooterView()
        let icons:[SpaceIcon] = [.symbol("ionicon.planet")] + emojis.map(SpaceIcon.emoji)
        let items = icons.enumerated().map { index,icon in
            SpaceDockItem(id:UUID(),name:"Space \(index)",icon:icon,color:NSColor(srgbRed:0.65,green:0.2,blue:0.04,alpha:1))
        }
        footer.showSpaces(items,selectedID:items[selectedIndex].id)
        let host = NSView(frame:NSRect(x:0,y:0,width:228,height:57))
        host.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        host.wantsLayer = true
        host.layer!.backgroundColor = NSColor(srgbRed:216/255,green:152/255,blue:125/255,alpha:1).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(footer)
        NSLayoutConstraint.activate([footer.leadingAnchor.constraint(equalTo:host.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo:host.trailingAnchor),footer.bottomAnchor.constraint(equalTo:host.bottomAnchor)])
        host.layoutSubtreeIfNeeded()
        return (host,UITestSupport.descendants(of:host).compactMap { $0 as? SpaceDockView }.first!)
    }

    private func bitmap(_ host:NSView) throws -> NSBitmapImageRep {
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:456,pixelsHigh:114,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        image.size = host.bounds.size
        host.cacheDisplay(in:host.bounds,to:image)
        return image
    }

    private func save(_ image:NSBitmapImageRep, name:String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BARC_DOCK_REFERENCE_DIR"] else { return }
        let output = URL(fileURLWithPath:directory).appending(path:name+".png")
        try #require(image.representation(using:.png,properties:[:])).write(to:output)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
    }

    private func inkBounds(_ image:NSBitmapImageRep, center:Int, opacity:Double) -> [Int] {
        func chroma(_ x:Int, _ y:Int) -> Double {
            let color = image.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            return Double(color.redComponent-color.blueComponent)
        }
        let background = chroma(0,0)
        let left = center-20, top = 28, width = 40, height = 66
        let alpha = (0..<height).map { y in (0..<width).map { x in
            min(1,max(0,(1-chroma(left+x,top+y)/background)/opacity))
        } }
        var points:[(x:Int,y:Int)] = []
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let samples = ((y-1)...(y+1)).flatMap { row in ((x-1)...(x+1)).map { alpha[row][$0] } }.sorted()
                if samples[4]>0.45 { points.append((left+x,top+y)) }
            }
        }
        return [points.map(\.x).min()!,points.map(\.y).min()!,points.map(\.x).max()!,points.map(\.y).max()!]
    }

    @Test("Light inactive emoji preserve half the background chroma; the dark muting is retained", arguments:[false,true])
    func inactiveInk(dark:Bool) throws {
        let (host,dock) = fixture(dark:dark)
        let image = try bitmap(host)
        try save(image,name:dark ? "dark" : "light")
        let expected:CGFloat = dark ? 0.35 : 0.5
        for button in dock.buttons.dropFirst() {
            let glyph = try #require(UITestSupport.descendants(of:button).compactMap { $0 as? NSImageView }.first)
            #expect(glyph.alphaValue == expected)
        }
        // An opaque gray emoji cancels the background's red/blue separation
        // in proportion to its alpha, independent of its shade or baseline.
        let bg = image.colorAt(x:0,y:0)!.usingColorSpace(.deviceRGB)!
        let background = bg.redComponent-bg.blueComponent
        for center in [156,204,252,300,348] {
            var peak:CGFloat = 0
            for y in 34..<90 { for x in (center-18)..<(center+18) {
                let color = image.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                peak = max(peak,1-(color.redComponent-color.blueComponent)/background)
            } }
            #expect(abs(peak-expected)<0.012)
        }
    }

    @Test("All five resting emoji silhouettes match the frozen light reference within one physical pixel")
    func referenceBounds() throws {
        let (host,_) = fixture(dark:false), image = try bitmap(host)
        let expected = [[143,48,169,75],[190,48,217,75],[240,51,265,74],[287,48,313,75],[335,48,363,75]]
        var error = 0
        for (index,center) in [156,204,252,300,348].enumerated() {
            let actual = inkBounds(image,center:center,opacity:0.5)
            for (a,b) in zip(actual,expected[index]) {
                #expect(abs(a-b)<=1)
                error += abs(a-b)
            }
        }
        #expect(error<=4)
    }

    @Test("Native-size emoji really enlarge while their button targets remain fixed")
    func magnifiedInk() throws {
        let previous = Style.Motion.reduceMotionOverride
        Style.Motion.reduceMotionOverride = false
        defer { Style.Motion.reduceMotionOverride = previous }
        let (host,dock) = fixture(dark:false), frames = dock.buttons.map(\.frame)
        let resting = inkBounds(try bitmap(host),center:156,opacity:0.5)
        dock.setPointer(dock.buttons[1].frame.midX)
        for _ in 0..<30 { dock.advanceMagnification(by:1/60) }
        let enlarged = inkBounds(try bitmap(host),center:156,opacity:0.5)
        #expect(dock.buttons.map(\.frame) == frames)
        #expect(enlarged[2]-enlarged[0]>resting[2]-resting[0])
        #expect(enlarged[3]-enlarged[1]>resting[3]-resting[1])
        try save(try bitmap(host),name:"hover")
    }

    @Test("An existing dock refreshes light/dark inactive symbol ink without changing selection")
    func appearanceRefresh() throws {
        let (host,dock) = fixture(dark:true,selectedIndex:1)
        let symbol = try #require(UITestSupport.descendants(of:dock.buttons[0]).compactMap { $0 as? NSImageView }.first)
        #expect(symbol.alphaValue == 0.175)
        host.appearance = NSAppearance(named:.aqua)
        host.layoutSubtreeIfNeeded()
        #expect(symbol.alphaValue == 0.25)
        #expect(dock.buttons[1].isSelectedSpace)
        let selected = try #require(UITestSupport.descendants(of:dock.buttons[1]).compactMap { $0 as? NSImageView }.first)
        #expect(selected.alphaValue == 1)
        let colorImage = try #require(selected.image?.cgImage(forProposedRect:nil,context:nil,hints:nil))
        let pixels = NSBitmapImageRep(cgImage:colorImage)
        var hasColor = false
        for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
            let color = pixels.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            if color.alphaComponent>0.9, abs(color.redComponent-color.blueComponent)>0.2 { hasColor = true }
        } }
        #expect(hasColor)
    }
}
