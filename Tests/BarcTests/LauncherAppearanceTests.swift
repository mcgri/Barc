// Modified for Barc: imported semantic focus colours and launcher face regression checks, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Launcher appearance", .serialized)
@MainActor
struct LauncherAppearanceTests {
    private let light = ImportedChrome.Color(red: 0.826347351, green: 0.591038585, blue: 0.47506243, alpha: 1)
    private let dark = ImportedChrome.Color(red: 0.720435321, green: 0.341610074, blue: 0.154899195, alpha: 0.8075)
    private func theme() -> [String: Any] {
        func raw(_ c: ImportedChrome.Color) -> [String: Any] {
            ["colorSpace":"extendedSRGB","red":c.red,"green":c.green,"blue":c.blue,"alpha":c.alpha]
        }
        return ["background":["single":["_0":["contentOverBackgroundAppearance":"light",
            "style":["color":["_0":["blendedSingleColor":["_0":["color":raw(.init(red:1,green:0.522,blue:0.344,alpha:1)),
                "translucencyStyle":"light"]]]]]]]],
            "semanticColorPalette":["appearanceBased":["light":["focus":raw(light)],"dark":["focus":raw(dark)]]]]
    }

    @Test("Semantic focus colours survive import and storage while older sessions still decode")
    func retainedPalette() throws {
        let chrome = try #require(ImportedChrome.read(theme()))
        #expect(chrome.lightFocus == light && chrome.darkFocus == dark)
        let restored = try JSONDecoder().decode(ImportedChrome.self, from: JSONEncoder().encode(chrome))
        #expect(restored == chrome)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chrome)) as? [String: Any])
        old.removeValue(forKey: "lightFocus"); old.removeValue(forKey: "darkFocus")
        let legacy = try JSONDecoder().decode(ImportedChrome.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.isValid && legacy.lightFocus == nil && legacy.darkFocus == nil)
        #expect(legacy.enrichingFocus(from: chrome) == chrome)
    }

    @Test("Missing or invalid semantic colours do not invalidate a usable imported background")
    func malformedPalette() throws {
        var raw = theme()
        raw["semanticColorPalette"] = ["appearanceBased":["light":["focus":["colorSpace":"unknown","red":1,"green":0,"blue":0]],
                                                                    "dark":["focus":["colorSpace":"extendedSRGB","red":999,"green":0,"blue":0]]]]
        let chrome = try #require(ImportedChrome.read(raw))
        #expect(chrome.isValid && chrome.lightFocus == nil && chrome.darkFocus == nil)
    }

    @Test("An older import can gain focus colours without replacing its background, tabs or user edits")
    func enrichExisting() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        let chrome = try #require(ImportedChrome.read(theme()))
        var legacy = chrome; legacy.lightFocus = nil; legacy.darkFocus = nil
        space.theme = .custom; space.look.customColorHex = "#ff8558"; space.look.importedChrome = legacy
        let tabs = space.tabs.map(\.id), identity = space.identity
        var incoming = session.snapshot().spaces[0]; incoming.look?.importedChrome = chrome
        _ = try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == chrome && space.tabs.map(\.id) == tabs && space.identity == identity)
        session.setBrowserAppearance(.dark)
        #expect(space.look.importedChrome?.lightFocus == light && space.look.importedChrome?.darkFocus == dark)
        session.setCustomColor(.green, for: space)
        _ = try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == nil && space.look.customColor == .green)
    }

    @Test("The current Space supplies light and dark launcher selection rather than the system accent")
    func spaceFocus() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        space.theme = .custom; space.look.importedChrome = try #require(ImportedChrome.read(theme()))
        let color = space.commandFocusColor
        NSAppearance(named:.aqua)!.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.extendedSRGB)!
            #expect(abs(rgb.redComponent - light.red) < 0.0001 && abs(rgb.alphaComponent - 1) < 0.0001)
        }
        NSAppearance(named:.darkAqua)!.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.extendedSRGB)!
            #expect(abs(rgb.greenComponent - dark.green) < 0.0001 && abs(rgb.alphaComponent - dark.alpha) < 0.0001)
        }
    }

    @Test("Opaque panel colours keep website colours out of both light and dark launchers")
    func opaquePanel() throws {
        _ = NSApplication.shared
        let host = NSView(frame:NSRect(x:0,y:0,width:1400,height:900))
        let command = CommandBar(); command.install(in:host)
        let panel = try #require(UITestSupport.descendants(of:command).compactMap { $0 as? CommandPanelView }.first)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            command.appearance = NSAppearance(named:name)
            command.viewDidChangeEffectiveAppearance()
            panel.viewDidChangeEffectiveAppearance()
            let rgb = NSColor(cgColor:try #require(panel.layer?.backgroundColor))!.usingColorSpace(.sRGB)!
            #expect(rgb.alphaComponent == 1)
            #expect(abs(rgb.redComponent - (name == .aqua ? 249.0/255 : 0.1)) < 0.002)
        }
    }

    @Test("The title, icon and separate arrow all invoke the same selectable result")
    func resultFaces() throws {
        let row = CommandRowView(frame:NSRect(x:0,y:0,width:740,height:48))
        row.configure(.init(id:"tab",kind:.openTab,title:"Research",subtitle:"Switch to Tab",symbolName:"globe",
                            action:.switchToTab(UUID()),score:0),splitChoice:true)
        row.selectionColor = light.nsColor; row.isSelected = true
        row.layoutSubtreeIfNeeded()
        for point in [NSPoint(x:20,y:24),NSPoint(x:180,y:24),NSPoint(x:715,y:24)] {
            #expect(row.hitTest(point) === row)
        }
        var chosen = 0; row.onClick = { chosen += 1 }
        #expect(row.accessibilityPerformPress() && chosen == 1)
        #expect(row.accessibilityLabel() == "Research, Switch to Tab")
        let labels = UITestSupport.descendants(of:row).compactMap { $0 as? NSTextField }
        #expect(labels.contains { $0.stringValue == "Switch to Tab" && !$0.isHidden })
        #expect(!labels.contains { $0.stringValue.contains("→") })
    }

    @Test("The chooser aligns its query and result titles and keeps the arrow in its own trailing square")
    func chooserColumns() throws {
        let host = NSView(frame:NSRect(x:0,y:0,width:1400,height:900))
        let command = CommandBar();command.install(in:host)
        command.openSplit(recentResults:[.init(id:"row",kind:.openTab,title:"Research",subtitle:"Switch to Tab",
            symbolName:"globe",action:.switchToTab(UUID()),score:0)])
        host.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
        let panel = try #require(UITestSupport.descendants(of:command).compactMap { $0 as? CommandPanelView }.first)
        let row = try #require(UITestSupport.descendants(of:command).compactMap { $0 as? CommandRowView }.first)
        let title = try #require(UITestSupport.descendants(of:row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Research" })
        let alignment = title.alignmentRect(forFrame:title.frame)
        let rect = try #require(title.superview).convert(alignment,to:panel)
        #expect(abs(rect.minX-52)<0.5 && abs(row.frame.height-46)<0.5)
        let arrow = try #require(row.subviews.first { $0.subviews.contains { $0 is NSImageView } })
        let arrowRect = arrow.convert(arrow.bounds,to:panel)
        #expect(arrowRect.width == 24 && abs(panel.bounds.maxX-arrowRect.maxX-22)<0.5)
        command.cancelOperation(nil)
    }
}
