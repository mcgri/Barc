// Modified for Barc: source Space label geometry and contrasting symbol colors, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Sidebar Space appearance", .serialized)
@MainActor
struct SidebarSpaceAppearanceTests {
    private let light = ImportedChrome.Color(red:0.652692854,green:0.182112411,blue:-0.049859397,alpha:1)
    private let dark = ImportedChrome.Color(red:1.003614784,green:0.91845119,blue:0.888954163,alpha:1)

    private func theme() -> [String:Any] {
        func raw(_ c:ImportedChrome.Color)->[String:Any] {
            ["colorSpace":"extendedSRGB","red":c.red,"green":c.green,"blue":c.blue,"alpha":c.alpha]
        }
        return ["background":["single":["_0":["contentOverBackgroundAppearance":"light",
            "style":["color":["_0":["blendedSingleColor":["_0":["color":raw(.init(red:1,green:0.522,blue:0.344,alpha:1)),"translucencyStyle":"light"]]]]]]]],
            "semanticColorPalette":["appearanceBased":["light":["maxContrastColor":raw(light)],"dark":["maxContrastColor":raw(dark)]]]]
    }

    private func opaqueColor(_ image:NSImage) throws -> NSColor {
        let side = 60
        let context = try #require(CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        image.draw(in:NSRect(x:0,y:0,width:side,height:side))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(context.data).assumingMemoryBound(to:UInt8.self)
        let opaque = (0..<(side*side)).first { data[$0*4+3] == 255 }
        let pixel = try #require(opaque, "No opaque pixel in \(image.size); maximum alpha \((0..<(side*side)).map { data[$0*4+3] }.max() ?? 0)")*4
        return NSColor(srgbRed:CGFloat(data[pixel])/255,green:CGFloat(data[pixel+1])/255,blue:CGFloat(data[pixel+2])/255,alpha:1)
    }

    @Test("The actual sidebar header and selected dock symbol use Arc's contrasting palette, not its pale accent")
    func renderedHeaderAndDock() throws {
        let session = TestSession.make().0,space = session.activeSpace
        space.name = "Space 1";space.theme = .custom;space.look.customColorHex = "#ff8558"
        space.icon = .symbol("ionicon.planet")
        space.look.importedChrome = try #require(ImportedChrome.read(theme()))
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            var sampled:Result<[NSColor],Error>?
            NSAppearance(named:name)!.performAsCurrentDrawingAppearance {
                sampled = Result {
                    let sidebar = SidebarViewController(session:session)
                    let root = sidebar.view
                    root.appearance = NSAppearance(named:name)
                    let header = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? MenuLabelButton }.first)
                    let headerImage = try #require(UITestSupport.descendants(of:header).compactMap { $0 as? NSImageView }.first?.image)
                    let dock = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? SpaceDockButton }.first)
                    let dockImage = try #require(UITestSupport.descendants(of:dock).compactMap { $0 as? NSImageView }.first?.image)
                    return try [headerImage,dockImage].map(opaqueColor)
                }
            }
            let expected = (name == .aqua ? light : dark).nsColor.usingColorSpace(.extendedSRGB)!
            for color in try #require(sampled).get() {
                #expect(abs(color.redComponent-expected.redComponent)<0.02)
                #expect(abs(color.greenComponent-expected.greenComponent)<0.02)
                #expect(abs(color.blueComponent-expected.blueComponent)<0.06)
            }
        }
    }

    @Test("Contrasting colors survive storage and enrich an older import without replacing an explicit theme or icon choice")
    func retainedPaletteAndChoices() throws {
        let chrome = try #require(ImportedChrome.read(theme()))
        #expect(chrome.lightMaxContrast == light && chrome.darkMaxContrast == dark)
        #expect(try JSONDecoder().decode(ImportedChrome.self,from:JSONEncoder().encode(chrome)) == chrome)
        var raw = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(chrome)) as? [String:Any])
        raw.removeValue(forKey:"lightMaxContrast");raw.removeValue(forKey:"darkMaxContrast")
        let legacy = try JSONDecoder().decode(ImportedChrome.self,from:JSONSerialization.data(withJSONObject:raw))
        let session = TestSession.make().0,space = session.activeSpace
        space.theme = .custom;space.look.customColorHex = "#ff8558";space.look.importedChrome = legacy
        session.setIcon(.symbol("ionicon.planet"),for:space)
        let before = space.tabs.map(\.id),profile = space.profile
        var incoming = session.snapshot().spaces[0];incoming.look?.importedChrome = chrome
        try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == chrome && space.tabs.map(\.id) == before && space.profile === profile)
        session.setIcon(.emoji("🌱"),for:space)
        #expect(space.sidebarIconColor == space.color)
        try session.applyArcSpaces([incoming])
        #expect(space.icon == .emoji("🌱"))
        session.setCustomColor(.green,for:space)
        try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == nil && space.sidebarIconColor == space.color)
    }

    @Test("Standard sidebar folders use the contrasting palette with any Space icon; custom folder colors remain explicit")
    func folderPaletteAndGeometry() throws {
        let session = TestSession.make().0, space = session.activeSpace
        space.theme = .custom; space.look.customColorHex = "#ff8558"
        space.icon = .emoji("🌱")
        space.look.importedChrome = try #require(ImportedChrome.read(theme()))
        let standard = session.createGroup(named:"Standard")
        let custom = session.createGroup(named:"Custom")
        custom.tint = .systemGreen
        custom.appearance = TabGroupAppearance(fill:.solid,startColorHex:"#00aa00")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            var sampled:Result<Void,Error>?
            NSAppearance(named:appearance)!.performAsCurrentDrawingAppearance {
                sampled = Result {
                    let sidebar = SidebarViewController(session:session)
                    sidebar.view.appearance = NSAppearance(named:appearance)
                    let list = try #require(UITestSupport.descendants(of:sidebar.view).compactMap { $0 as? NSTableView }
                        .first { ($0.dataSource as AnyObject?) === sidebar })
                    let column = try #require(list.tableColumns.first)
                    var seen = Set<String>()
                    for row in 0..<list.numberOfRows {
                        guard let cell = sidebar.tableView(list,viewFor:column,row:row),
                              let header = UITestSupport.descendants(of:cell).compactMap({ $0 as? TabGroupHeaderView }).first else { continue }
                        let name = header.accessibilityLabel() ?? ""
                        guard [standard.name,custom.name].contains(name) else { continue }
                        cell.frame = NSRect(x:0,y:0,width:228,height:sidebar.tableView(list,heightOfRow:row))
                        cell.layoutSubtreeIfNeeded()
                        let face = try #require(header.iconPickerAnchor as? NSImageView)
                        let image = try #require(face.image)
                        if name == standard.name {
                            let color = try opaqueColor(image).usingColorSpace(.extendedSRGB)!
                            let expected = (appearance == .aqua ? light : dark).nsColor.usingColorSpace(.extendedSRGB)!
                            #expect(abs(color.redComponent-expected.redComponent)<0.02)
                            #expect(abs(color.greenComponent-expected.greenComponent)<0.02)
                            #expect(abs(color.blueComponent-expected.blueComponent)<0.06)
                        } else {
                            // Label-color blending can retain transparency. Compare
                            // the complete custom artwork instead of requiring an
                            // opaque pixel that this style does not promise.
                            #expect(image.tiffRepresentation == SidebarFolderGlyph.image(tint:custom.tint).tiffRepresentation)
                        }
                        #expect(face.frame.width == 20 && face.frame.height == 20)
                        seen.insert(name)
                    }
                    #expect(seen == [standard.name,custom.name])
                }
            }
            try #require(sampled).get()
        }
    }

    @Test("New themes, legacy imports and incomplete palettes keep their ordinary folder tint")
    func folderPaletteFallback() throws {
        let space = TestSession.make().0.activeSpace
        #expect(space.sidebarFolderColor == nil)
        space.theme = .custom
        var chrome = try #require(ImportedChrome.read(theme()))
        chrome.darkMaxContrast = nil
        space.look.importedChrome = chrome
        #expect(space.sidebarFolderColor == nil)
        chrome.lightMaxContrast = nil
        space.look.importedChrome = chrome
        #expect(space.sidebarFolderColor == nil)
    }

    @Test("A dock symbol resolves its own appearance and refreshes cached artwork after the window changes appearance")
    func dockAppearanceCache() throws {
        let color = NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
                ? NSColor(srgbRed:0.9,green:0.8,blue:0.7,alpha:1) : NSColor(srgbRed:0.6,green:0.2,blue:0.1,alpha:1)
        }
        let button = SpaceDockButton(id:UUID())
        button.appearance = NSAppearance(named:.aqua)
        button.configure(.init(id:button.id,name:"Space",icon:.symbol("ionicon.planet"),color:color),selected:true)
        for (appearance,drawAppearance,red,green) in [(NSAppearance.Name.aqua,NSAppearance.Name.darkAqua,0.6,0.2),(.darkAqua,.aqua,0.9,0.8)] {
            button.appearance = NSAppearance(named:appearance)
            button.viewDidChangeEffectiveAppearance()
            let image = try #require(UITestSupport.descendants(of:button).compactMap { $0 as? NSImageView }.first?.image)
            var sampled:Result<NSColor,Error>?
            NSAppearance(named:drawAppearance)!.performAsCurrentDrawingAppearance { sampled = Result { try opaqueColor(image) } }
            let value = try #require(sampled).get()
            #expect(abs(value.redComponent-red)<0.01 && abs(value.greenComponent-green)<0.01)
            #expect(button.isSelectedSpace && button.accessibilityValue() as? String == "Selected")
        }
    }

    @Test("Decorative button faces stay enabled for drawing and let presses reach their controls")
    func buttonFacesDoNotDimOrInterceptPresses() throws {
        for button in [IconButton(symbolName:"plus",label:"Add",side:24),SpaceDockButton(id:UUID())] as [NSButton] {
            button.frame = NSRect(x:0,y:0,width:24,height:50)
            let host = NSView(frame:NSRect(x:0,y:0,width:24,height:50));host.addSubview(button)
            host.layoutSubtreeIfNeeded()
            let face = try #require(UITestSupport.descendants(of:button).compactMap { $0 as? NSImageView }.first)
            #expect(face.isEnabled)
            #expect(face.hitTest(NSPoint(x:face.frame.midX,y:face.frame.midY)) == nil)
            #expect(button.hitTest(NSPoint(x:button.frame.midX,y:button.frame.midY)) === button)
            button.isEnabled = false
            #expect(!button.isEnabled && face.isEnabled)
            button.isEnabled = true
            #expect(face.isEnabled)
        }
    }

    @Test("Inactive Space artwork stays monochrome while magnifying, and selected artwork restores its original color")
    func inactiveArtwork() throws {
        let button = SpaceDockButton(id:UUID())
        button.appearance = NSAppearance(named:.aqua)
        let item = SpaceDockItem(id:button.id,name:"Space",icon:.symbol("circle.fill"),color:.red)
        button.configure(item,selected:false)
        button.apply(frame:NSRect(x:0,y:0,width:24,height:50),iconSize:18)
        let face = try #require(UITestSupport.descendants(of:button).compactMap { $0 as? NSImageView }.first)
        let muted = try #require(face.image),gray = try opaqueColor(muted)
        #expect(abs(gray.redComponent-gray.greenComponent)<0.01 && abs(gray.greenComponent-gray.blueComponent)<0.01)
        button.apply(frame:button.frame,iconSize:22)
        #expect(face.image === muted && face.alphaValue == 0.175)
        button.configure(item,selected:true)
        button.apply(frame:button.frame,iconSize:18)
        let colored = try opaqueColor(try #require(face.image))
        #expect(colored.redComponent>0.9 && colored.greenComponent<0.05 && colored.blueComponent<0.05)
        #expect(face.alphaValue == 1)
    }

    @Test("The Space mark starts at 18 points and the 13-point name at 44, without moving the rename editor")
    func headerGeometry() throws {
        let name = MenuLabelButton()
        name.show(title:"Space 1",icon:SpaceIcon.symbol("ionicon.planet").image(color:.brown,title:"Space 1",side:16),
                  accessibilityLabel:"Space",tooltip:nil,identity:UUID())
        let identity = SidebarSpaceIdentityView(nameButton:name)
        let host = UITestSupport.host(identity,width:228,height:32)
        host.layoutSubtreeIfNeeded()
        let icon = try #require(UITestSupport.descendants(of:name).compactMap { $0 as? NSImageView }.first)
        let field = try #require(UITestSupport.descendants(of:name).compactMap { $0 as? NSTextField }.first)
        #expect(abs(icon.convert(icon.bounds,to:identity).minX-18)<0.1)
        #expect(abs(name.convert(field.alignmentRect(forFrame:field.frame),to:identity).minX-44)<0.1)
        #expect(field.font?.pointSize == 13)
        #expect(field.textColor == Style.Colors.secondaryText)
        #expect(abs(name.frame.midY-identity.bounds.midY+3)<0.1)
        let frame = field.convert(field.bounds,to:identity)
        name.beginRenaming { _ in };host.layoutSubtreeIfNeeded()
        #expect(field.convert(field.bounds,to:identity) == frame)
        name.finishRenaming(commit:false)
    }
}
