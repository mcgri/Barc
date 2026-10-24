// Modified for Barc: imported semantic focus colours and launcher face regression checks, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Launcher appearance", .serialized)
@MainActor
struct LauncherAppearanceTests {
    private final class ResultHost: NSView {
        var outsidePresses = 0
        override func mouseDown(with event: NSEvent) { outsidePresses += 1 }
    }
    private let light = ImportedChrome.Color(red: 0.826347351, green: 0.591038585, blue: 0.47506243, alpha: 1)
    private let dark = ImportedChrome.Color(red: 0.720435321, green: 0.341610074, blue: 0.154899195, alpha: 0.8075)
    private let lightSubtitle = ImportedChrome.Color(red: 0.861077845, green: 0.67283082, blue: 0.580049932, alpha: 1)
    private let darkSubtitle = ImportedChrome.Color(red: 0.501807392, green: 0.459225595, blue: 0.444477081, alpha: 1)
    private func theme() -> [String: Any] {
        func raw(_ c: ImportedChrome.Color) -> [String: Any] {
            ["colorSpace":"extendedSRGB","red":c.red,"green":c.green,"blue":c.blue,"alpha":c.alpha]
        }
        return ["background":["single":["_0":["contentOverBackgroundAppearance":"light",
            "style":["color":["_0":["blendedSingleColor":["_0":["color":raw(.init(red:1,green:0.522,blue:0.344,alpha:1)),
                "translucencyStyle":"light"]]]]]]]],
            "semanticColorPalette":["appearanceBased":["light":["focus":raw(light),"subtitle":raw(lightSubtitle)],"dark":["focus":raw(dark),"subtitle":raw(darkSubtitle)]]]]
    }

    @Test("Semantic focus colours survive import and storage while older sessions still decode")
    func retainedPalette() throws {
        let chrome = try #require(ImportedChrome.read(theme()))
        #expect(chrome.lightFocus == light && chrome.darkFocus == dark)
        #expect(chrome.lightSubtitle == lightSubtitle && chrome.darkSubtitle == darkSubtitle)
        let restored = try JSONDecoder().decode(ImportedChrome.self, from: JSONEncoder().encode(chrome))
        #expect(restored == chrome)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chrome)) as? [String: Any])
        for key in ["lightFocus", "darkFocus", "lightSubtitle", "darkSubtitle"] { old.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(ImportedChrome.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.isValid && legacy.lightFocus == nil && legacy.darkFocus == nil)
        #expect(legacy.enrichingPalette(from: chrome) == chrome)
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
        legacy.lightSubtitle = nil; legacy.darkSubtitle = nil
        space.theme = .custom; space.look.customColorHex = "#ff8558"; space.look.importedChrome = legacy
        let tabs = space.tabs.map(\.id), identity = space.identity
        var incoming = session.snapshot().spaces[0]; incoming.look?.importedChrome = chrome
        _ = try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == chrome && space.tabs.map(\.id) == tabs && space.identity == identity)
        session.setBrowserAppearance(.dark)
        #expect(space.look.importedChrome?.lightFocus == light && space.look.importedChrome?.darkFocus == dark)
        #expect(space.look.importedChrome?.lightSubtitle == lightSubtitle && space.look.importedChrome?.darkSubtitle == darkSubtitle)
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

    @Test("URL selection follows the Space separately from its selected result")
    func spaceTextSelection() throws {
        let space = TestSession.make().0.activeSpace
        space.theme = .custom; space.look.importedChrome = try #require(ImportedChrome.read(theme()))
        for (name, expected) in [(NSAppearance.Name.aqua, lightSubtitle), (.darkAqua, darkSubtitle)] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let color = space.commandTextSelectionColor.usingColorSpace(.extendedSRGB)!
                #expect(abs(color.redComponent - expected.red) < 0.0001)
                #expect(abs(color.greenComponent - expected.green) < 0.0001)
                #expect(abs(color.blueComponent - expected.blue) < 0.0001)
            }
        }
    }

    @Test("Closing, submitting and moving focus restore the shared field editor's original highlight")
    func fieldEditorRestoration() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1200,height:800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let other = NSTextField(frame: NSRect(x:0,y:0,width:120,height:24)); root.addSubview(other)
        let bar = CommandBar(); bar.install(in:root)
        let editor = try #require(window.fieldEditor(true, for:other) as? NSTextView)
        window.makeFirstResponder(other)
        let original = editor.selectedTextAttributes
        for exit in 0..<3 {
            bar.textSelectionColor = lightSubtitle.nsColor
            bar.openLocation(text:"https://example.invalid/",suggestions:[])
            let active = try #require(window.firstResponder as? NSTextView)
            #expect(active === editor)
            #expect((active.selectedTextAttributes[.backgroundColor] as? NSColor) == lightSubtitle.nsColor)
            var attributes = active.selectedTextAttributes
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            active.selectedTextAttributes = attributes
            bar.textSelectionColor = darkSubtitle.nsColor
            #expect(active.selectedTextAttributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
            #expect((active.selectedTextAttributes[.backgroundColor] as? NSColor) == darkSubtitle.nsColor)
            if exit == 0 { bar.close() }
            if exit == 1 { bar.submit() }
            if exit == 2 { window.makeFirstResponder(other) }
            #expect(NSDictionary(dictionary:editor.selectedTextAttributes).isEqual(to:original))
            window.makeFirstResponder(other)
            #expect(NSDictionary(dictionary:editor.selectedTextAttributes).isEqual(to:original))
            bar.close()
        }
    }

    @Test("Light and dark launchers blur within their window with a translucent tint above the effect")
    func frostedPanel() throws {
        _ = NSApplication.shared
        let host = NSView(frame:NSRect(x:0,y:0,width:1400,height:900))
        let command = CommandBar(); command.install(in:host)
        let panel = try #require(UITestSupport.descendants(of:command).compactMap { $0 as? CommandPanelView }.first)
        #expect(panel.material == .hudWindow && panel.blendingMode == .withinWindow && panel.state == .active)
        let tint = try #require(panel.subviews.first)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            command.appearance = NSAppearance(named:name)
            panel.viewDidChangeEffectiveAppearance()
            let rgb = NSColor(cgColor:try #require(tint.layer?.backgroundColor))!.usingColorSpace(.sRGB)!
            #expect(abs(rgb.alphaComponent - 0.8) < 0.001)
            #expect(abs(rgb.redComponent - (name == .aqua ? 253.0/255 : 20.0/255)) < 0.002)
        }
        #expect(panel.layer?.masksToBounds == true)
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

    @Test("Compact URL text retains its trailing action space without changing its font or icon alignment")
    func compactTextColumn() throws {
        let host = NSView(frame:NSRect(x:0,y:0,width:1200,height:900))
        let anchor = NSView(frame:NSRect(x:8,y:800,width:220,height:36));host.addSubview(anchor)
        let bar = CommandBar();bar.install(in:host)
        let title = "Example News - Headlines, World News, Sports, Business and Technology"
        for shortcut in [nil, "Jump"] as [String?] {
            let result = CommandResult(id:"site",kind:.history,title:title,subtitle:"bbc.co.uk",symbolName:"globe",
                action:.openURL(URL(string:"https://www.bbc.co.uk/")!),score:0,shortcut:shortcut)
            bar.openAddress(text:"https://current.invalid/",anchor:anchor,recentResults:[result])
            host.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
            let panel = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? CommandPanelView }.first)
            let row = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? CommandRowView }.first)
            let label = try #require(UITestSupport.descendants(of:row).compactMap { $0 as? NSTextField }.first { $0.stringValue == title })
            let rect = try #require(label.superview).convert(label.alignmentRect(forFrame:label.frame),to:panel)
            #expect(abs(rect.minX-52)<0.5 && abs(rect.maxX-267)<0.5)
            #expect(label.font?.pointSize == 13 && row.frame.height == 46)
            bar.close()
        }
    }

    @Test("Accessibility exposes the visible suggestion rows and moves the same single selection as the keyboard")
    func accessibleResults() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let choices = (0..<3).map { index in
            CommandResult(id:"site\(index)",kind:.history,title:"Site \(index)",subtitle:"",symbolName:"globe",
                action:.openURL(URL(string:"https://site\(index).invalid/")!),score:0,completionText:"site\(index).invalid")
        }
        bar.openLocation(text:"https://current.invalid/",suggestions:choices)
        let table = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? CommandResultsView }.first)
        let rows = try #require(table.accessibilityRows() as? [CommandRowView])
        #expect(table.isAccessibilityElement() && table.accessibilityRole() == .table && table.accessibilityRowCount() == 3)
        #expect(rows.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .row })
        #expect(rows.enumerated().allSatisfy { $0.element.accessibilityIndex() == $0.offset })
        #expect(rows[0].isAccessibilitySelected() && !rows[1].isAccessibilitySelected())
        table.setAccessibilitySelectedRows([rows[2]])
        #expect(bar.selectedIndex == 2 && bar.queryText == "site2.invalid")
        #expect((table.accessibilitySelectedRows()?.first as? CommandRowView) === rows[2])
        bar.moveSelection(by:1)
        #expect(rows[0].isAccessibilitySelected() && !rows[2].isAccessibilitySelected())
        table.setAccessibilitySelectedRows([NSView()])
        #expect(bar.selectedIndex == 0)
        var action:CommandAction?;bar.onRun = { action = $0;_ = $1;_ = $2 }
        #expect(rows[0].accessibilityPerformPress())
        #expect(action == choices[0].action && !bar.isOpen)
        #expect(table.accessibilityRowCount() == 0 && rows.allSatisfy { !$0.isAccessibilitySelected() })
        action = nil
        bar.openLocation(text:"https://different.invalid/",suggestions:Array(choices.reversed()))
        #expect(!rows[0].accessibilityPerformPress(), "An accessibility client may still hold the old element after the list changes")
        #expect(action == nil && bar.isOpen)
        bar.select(1)
        rows[0].onHover?()
        #expect(bar.selectedIndex == 1)
        bar.close()
    }

    @Test("A result consumes its press and runs on release, while releasing outside cancels")
    func mousePressSequence() throws {
        _ = NSApplication.shared
        let host = ResultHost(frame:NSRect(x:0,y:0,width:400,height:100))
        let row = CommandRowView(frame:NSRect(x:0,y:0,width:300,height:46))
        host.addSubview(row)
        row.configure(.init(id:"row",kind:.openTab,title:"Research",subtitle:"",symbolName:"globe",
            action:.switchToTab(UUID()),score:0),splitChoice:true)
        var chosen = 0;row.onClick = { chosen += 1 }
        func event(_ type:NSEvent.EventType,_ point:NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,
                windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        row.mouseDown(with:try event(.leftMouseDown,NSPoint(x:280,y:23)))
        #expect(host.outsidePresses == 0 && chosen == 0)
        row.mouseUp(with:try event(.leftMouseUp,NSPoint(x:280,y:23)))
        #expect(chosen == 1)
        row.mouseDown(with:try event(.leftMouseDown,NSPoint(x:280,y:23)))
        row.mouseUp(with:try event(.leftMouseUp,NSPoint(x:350,y:23)))
        #expect(chosen == 1 && host.outsidePresses == 0)
    }

    @Test("A suggestion appearing under a stationary pointer cannot replace the keyboard selection")
    func stationaryPointerSelection() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let choices = (0..<3).map { index in
            CommandResult(id:"row\(index)",kind:.openTab,title:"Page \(index)",subtitle:"",symbolName:"globe",
                action:.switchToTab(UUID()),score:0)
        }
        bar.openNewTab(recentResults:choices)
        window.contentView?.layoutSubtreeIfNeeded()
        let rows = UITestSupport.descendants(of:bar).compactMap { $0 as? CommandRowView }
        try #require(rows.count == 3 && bar.selectedIndex == 0)
        let point = rows[2].convert(NSPoint(x:30,y:20),to:nil)
        let entered = try #require(NSEvent.enterExitEvent(with:.mouseEntered,location:point,modifierFlags:[],timestamp:1,
            windowNumber:window.windowNumber,context:nil,eventNumber:1,trackingNumber:1,userData:nil))
        rows[2].mouseEntered(with:entered)
        #expect(bar.selectedIndex == 0, "Creating a tracking area under the pointer is not a request to select that row")
        bar.select(1)
        rows[2].mouseEntered(with:entered)
        #expect(bar.selectedIndex == 1, "A tracking refresh must not undo keyboard navigation")
        let moved = try #require(NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:2,
            windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:0,pressure:0))
        rows[2].mouseMoved(with:moved)
        #expect(bar.selectedIndex == 2, "Real mouse movement still selects the pointed result")
        bar.moveSelection(by:1)
        #expect(bar.selectedIndex == 0)
        rows[2].updateTrackingAreas()
        #expect(rows[2].trackingAreas.contains {
            $0.options.contains(.mouseMoved) && ($0.owner as? CommandRowView) === rows[2]
        }, "AppKit must deliver real movement to the result row without moving focus out of the query field")
        rows[2].mouseEntered(with:entered)
        #expect(bar.selectedIndex == 0)
        bar.setResults(Array(choices.reversed()));bar.select(0)
        window.contentView?.layoutSubtreeIfNeeded()
        rows[2].mouseMoved(with:moved)
        #expect(bar.selectedIndex == 0, "A removed row cannot select the same index in a replacement list")
        let replaced = UITestSupport.descendants(of:bar).compactMap { $0 as? CommandRowView }
        let newPoint = replaced[2].convert(NSPoint(x:30,y:20),to:nil)
        let newMove = try #require(NSEvent.mouseEvent(with:.mouseMoved,location:newPoint,modifierFlags:[],timestamp:3,
            windowNumber:window.windowNumber,context:nil,eventNumber:3,clickCount:0,pressure:0))
        replaced[2].mouseMoved(with:newMove)
        #expect(bar.selectedIndex == 2)
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 };bar.submit()
        #expect(action == choices[0].action && !bar.isOpen)
    }
}
