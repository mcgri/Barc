// Modified for Barc: full sidebar band positions against the frozen reference, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar vertical reference", .serialized)
@MainActor
struct SidebarVerticalReferenceTests {
    @Test("Favorites, Space label, retained rows and New Tab render in the complete sidebar")
    func renderedSidebar() throws {
        let density = Settings.shared.sidebarDensity
        Settings.shared.sidebarDensity = .regular
        defer { Settings.shared.sidebarDensity = density }
        let session = TestSession.make().0
        let space = session.activeSpace
        space.name = "Space 1"
        space.icon = .emoji("🪐")
        space.theme = .custom
        space.look.customColorHex = "#e39778"
        space.look.appearance = .light
        for index in 0..<3 {
            session.pin(session.newTab(url:URL(string:"https://rhythm.invalid/favorite-\(index)")!))
        }
        let folder = session.createGroup(named:"Pull Requests")
        folder.isCollapsed = true
        for name in ["Messaging Terms","Example Dashboard"] {
            let tab = session.newTab(url:URL(string:"https://rhythm.invalid/\(name.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!)")!)
            session.rename(tab,to:name); tab.setKeepsInSidebar(true)
        }
        let a = session.newTab(url:URL(string:"https://rhythm.invalid/barc")!)
        session.rename(a,to:"mocky/Browser: This is a sample browser")
        let site = session.newTab(url:URL(string:"https://rhythm.invalid/site")!)
        session.rename(site,to:"Lightweight Mac browser")
        let b = session.newTab(url:URL(string:"https://rhythm.invalid/repository")!)
        // A frozen loading caption, supplied as fixture content, not a rule
        // for deriving production titles from hostnames.
        session.rename(b,to:"github.com")
        session.splitTabs([a,b],grid:.sideBySide); session.selectTab(a)
        let sidebar = SidebarViewController(session:session), bar = ContentTopBar()
        sidebar.installBrowserControls([bar])
        bar.addressField.show(display:"github.com",url:URL(string:"https://github.com/mcgri/Barc"))
        bar.update(canGoBack:true,canGoForward:false,isLoading:false,hasPage:true)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:228,height:1027),
            styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:true)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = sidebar.view
        defer { window.contentView = nil }
        sidebar.view.layoutSubtreeIfNeeded()
        let root = sidebar.view
        let height:CGFloat = 490
        let region = NSRect(x:0,y:root.bounds.maxY-height,width:228,height:height)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:456,pixelsHigh:980,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = region.size
        root.cacheDisplay(in:region,to:bitmap)
        let pins = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? PinnedTilesView }.first)
        let tiles = pins.subviews.filter { !$0.isHidden && $0.accessibilityRole() == .button }
        #expect(tiles.count == 3)
        let frames = tiles.map(\.frame).sorted { $0.minX < $1.minX }
        for pair in zip(frames,frames.dropFirst()) { #expect(abs(pair.1.minX-pair.0.maxX-8) < 0.01) }
        func light(_ x:Int, _ y:Int) -> Double {
            let color = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            return Double(color.redComponent+color.greenComponent+color.blueComponent)/3
        }
        let background = (60..<420).map { light($0,630) }.reduce(0,+)/360
        let dividerRows = (631..<650).filter { y in
            let level = (60..<420).map { light($0,y) }.reduce(0,+)/360
            return background-level > background*0.04
        }
        #expect(dividerRows == [637,638])
        let tileBackground = light(154,200)
        #expect(light(80,200) < tileBackground)
        let textBackground = (80..<260).map { light($0,675) }.reduce(0,+)/180
        let peak = (675..<730).flatMap { y in (80..<260).map { textBackground-light($0,y) } }.max()!
        let textRows = (675..<730).filter { y in
            (80..<260).contains { textBackground-light($0,y) > peak*0.45 }
        }
        #expect(textRows.first == 694 && textRows.last == 714)
        let selectedRows = (730..<835).filter { light(230,$0) > 210.0/255 }
        #expect(selectedRows.first == 750 && selectedRows.last == 821)
        var records: [[String:Any]] = []
        func record(_ name:String, _ view:NSView) {
            let rect = view.convert(view.bounds,to:root)
            records.append(["name":name,"x":rect.minX,"yFromTop":root.bounds.maxY-rect.maxY,"width":rect.width,"height":rect.height])
        }
        record("Address plate",bar.addressField)
        for label in UITestSupport.textFields(in:root) where ["Space 1","Pull Requests","Messaging Terms","Example Dashboard","New Tab","mocky/Browser: This is a sample browser","github.com","Lightweight Mac browser"].contains(label.stringValue) {
            record(label.stringValue,label)
        }
        for view in UITestSupport.descendants(of:root) where view is SidebarSpaceIdentityView || view is PinnedTilesView || view is SplitRowView {
            record(String(describing:type(of:view)),view)
            if view is PinnedTilesView {
                for tile in tiles { record("Favorite tile",tile) }
            }
        }
        let table = sidebar.tabListTableView
        for index in 0..<table.numberOfRows {
            let rect = table.convert(table.rect(ofRow:index),to:root)
            records.append(["name":"Table row \(index)","x":rect.minX,"yFromTop":root.bounds.maxY-rect.maxY,"width":rect.width,"height":rect.height])
        }
        #expect(table.numberOfRows == 6)
        if let directory = ProcessInfo.processInfo.environment["BARC_VERTICAL_CAPTURE_DIR"] {
            let base = URL(fileURLWithPath:directory)
            let png = base.appending(path:"barc-vertical207.png"), metadata = base.appending(path:"barc-vertical207-frames.json")
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:png)
            try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:metadata)
            for path in [png,metadata] { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path) }
        }
    }

    @Test("Two and three Favorites use the widths measured in the saved Arc strips", arguments:[2,3])
    func favoriteWidths(count:Int) {
        let plan = TileGrid.plan(itemCount:count,availableWidth:212)
        #expect(plan.columns == count && plan.rows == 1 && plan.height == 46)
        let expected:CGFloat = count == 2 ? 102 : 196.0/3
        #expect(abs(plan.tileWidth-expected) < 0.001)
    }
}
