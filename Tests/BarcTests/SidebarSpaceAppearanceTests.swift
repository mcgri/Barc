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
        let pixel = try #require(opaque)*4
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
        let frame = field.convert(field.bounds,to:identity)
        name.beginRenaming { _ in };host.layoutSubtreeIfNeeded()
        #expect(field.convert(field.bounds,to:identity) == frame)
        name.finishRenaming(commit:false)
    }
}
