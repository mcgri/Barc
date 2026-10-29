// Modified for Barc: measured header and navigation artwork, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar header reference", .serialized)
@MainActor
struct SidebarHeaderReferenceTests {
    private func luminance(_ bitmap:NSBitmapImageRep, x:Int, y:Int) -> Double {
        let color = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        return Double(color.redComponent+color.greenComponent+color.blueComponent)*255/3
    }

    private func ink(_ bitmap:NSBitmapImageRep, in region:NSRect) -> (bounds:NSRect,alpha:Double) {
        var samples: [(x:Int,y:Int,value:Double)] = []
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) { samples.append((x,y,luminance(bitmap,x:x,y:y))) }
        }
        let sorted = samples.map(\.value).sorted()
        let background = sorted[sorted.count/2]
        let peak = samples.map { background-$0.value }.max()!
        let pixels = samples.filter { background-$0.value > max(8,peak*0.45) }
        let left = pixels.map(\.x).min()!, right = pixels.map(\.x).max()!
        let top = pixels.map(\.y).min()!, bottom = pixels.map(\.y).max()!
        return (NSRect(x:left,y:top,width:right-left+1,height:bottom-top+1),peak/background)
    }

    @Test("The complete header renders with real window controls and browser navigation")
    func renderedHeader() throws {
        // The measured reference has no performance gauge beside the lights.
        let settings = Settings(defaults:UserDefaults(suiteName:"header-reference.\(UUID())")!)
        settings.showsTaskManagerInSidebar = false
        let session = TestSession.make().0
        session.activeSpace.look.appearance = .light
        let sidebar = SidebarViewController(session:session,settings:settings)
        let bar = ContentTopBar()
        sidebar.installBrowserControls([bar])
        bar.addressField.show(display:"mail.google.com",url:URL(string:"https://mail.google.com/"))
        bar.update(canGoBack:true,canGoForward:false,isLoading:false,hasPage:true)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:800),
            styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = sidebar.view
        sidebar.view.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let root = sidebar.view
        let region = NSRect(x:0,y:root.bounds.maxY-90,width:228,height:90)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:456,pixelsHigh:180,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = region.size
        root.cacheDisplay(in:region,to:bitmap)
        #expect(bitmap.pixelsWide == 456)
        // Painted 2x pixel bounds from the original image. Its window begins
        // at y=17; the owned render begins at the sidebar's content origin.
        let references: [(NSRect,NSRect,Double)] = [
            (NSRect(x:155,y:23,width:56,height:50),NSRect(x:166,y:34,width:37,height:29),0.57),
            (NSRect(x:246,y:26,width:55,height:47),NSRect(x:259,y:37,width:29,height:24),0.57),
            (NSRect(x:315,y:26,width:57,height:47),NSRect(x:327,y:37,width:29,height:24),0.22),
            (NSRect(x:385,y:23,width:51,height:50),NSRect(x:396,y:31,width:28,height:34),0.57),
            (NSRect(x:30,y:109,width:270,height:42),NSRect(x:42,y:119,width:195,height:25),0.6)
        ]
        for (region,expected,alpha) in references {
            let measured = ink(bitmap,in:region)
            #expect(measured.bounds == expected)
            #expect(abs(measured.alpha-alpha) < 0.015)
        }
        let plate = bar.addressField.convert(bar.addressField.bounds,to:root)
        #expect(plate.minX == 7 && plate.width == 212 && plate.height == 36)
        #expect(root.bounds.maxY-plate.maxY == 46.5)
        for (x,expected) in [(15,109),(20,101),(25,97),(30,94),(35,93),(420,94),(435,106)] {
            let background = luminance(bitmap,x:x,y:90)
            let full = luminance(bitmap,x:x,y:128)
            let top = try #require((92..<120).first { background-luminance(bitmap,x:x,y:$0) > (background-full)/2 })
            #expect(abs(top-expected) <= 1)
        }
        var records: [[String:Any]] = []
        func record(_ name:String, _ view:NSView) {
            let rect = view.convert(view.bounds,to:root)
            records.append(["name":name,"x":rect.minX,"yFromTop":root.bounds.maxY-rect.maxY,
                            "width":rect.width,"height":rect.height,"flipped":view.isFlipped])
        }
        for button in [bar.sidebarToggle,bar.utilitiesButton,bar.backButton,bar.forwardButton,bar.reloadButton] {
            record(button.accessibilityLabel() ?? "",button)
            let glyph = try #require(UITestSupport.imageViews(in:button).first)
            record((button.accessibilityLabel() ?? "")+" glyph",glyph)
        }
        record("Address plate",bar.addressField)
        record("Address text",try #require(UITestSupport.buttons(in:bar.addressField).first { $0.accessibilityLabel() == "Address" }))
        for (index,entry) in [("Close",NSWindow.ButtonType.closeButton),("Minimize",.miniaturizeButton),("Zoom",.zoomButton)].enumerated() {
            let button = try #require(window.standardWindowButton(entry.1))
            let rect = button.convert(button.bounds,to:root)
            #expect(rect.midX == 19+CGFloat(index)*23)
            #expect(root.bounds.maxY-rect.midY == 24.5)
            record(entry.0,button)
        }
        if let directory = ProcessInfo.processInfo.environment["BARC_HEADER_CAPTURE_DIR"] {
            let base = URL(fileURLWithPath:directory)
            let png = base.appending(path:"barc-header206.png")
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:png)
            let data = try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
            let metadata = base.appending(path:"barc-header206-frames.json")
            try data.write(to:metadata)
            for path in [png,metadata] { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path) }
        }
    }

    @Test("The single-draw URL label keeps click, disabled-placeholder and hover-copy behavior")
    func addressInput() throws {
        let address = AddressField()
        let host = UITestSupport.host(address,width:212,height:36)
        let button = try #require(UITestSupport.buttons(in:address).first { $0.accessibilityLabel() == "Address" })
        var opened = 0
        address.onOpen = { opened += 1 }
        button.performClick(nil)
        #expect(opened == 0)
        let url = URL(string:"https://mail.google.com/mail/u/0/#inbox")!
        address.show(display:"mail.google.com",url:url)
        button.performClick(nil)
        #expect(opened == 1 && button.toolTip == url.absoluteString)
        address.mouseEntered(with:UITestSupport.hoverEvent())
        host.layoutSubtreeIfNeeded()
        let copy = try #require(UITestSupport.buttons(in:address).first { $0.accessibilityLabel() == "Copy Address" })
        #expect(!copy.isHidden)
        button.performClick(nil)
        #expect(opened == 2)
        address.show(display:"",url:nil)
        button.performClick(nil)
        #expect(opened == 2 && !button.isEnabled)
    }
}
