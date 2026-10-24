// Modified for Barc: source window geometry and non-destructive dock layout, 2026-10-24.
import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Arc sidebar layout import", .serialized)
@MainActor
struct ArcSidebarLayoutTests {
    @Test("The front Arc window supplies the width for its imported Spaces")
    func frontWindowWidth() throws {
        let source = try ArcImportBench.snapshot();defer { source.remove() }
        let windows = try JSONSerialization.data(withJSONObject:["lastFocusedSpaceID":"work-space","windows":[
            ["focusedSpaceID":"personal-space","sidebarWidth":310],
            ["focusedSpaceID":"work-space","sidebarWidth":228]
        ]])
        let sidebar = try ArcSidebarReader.read(sidebar:ArcImportBench.sidebar(),archive:nil,profiles:source.profiles,windows:windows)
        #expect(sidebar.sidebarWidth == 228)
        let frozen = ArcSourceSnapshot(root:source.root,sourceFingerprint:source.sourceFingerprint,profiles:source.profiles,
            sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
        let spaces = ArcSpaceBuilder.build(frozen,options:ArcImportOptions(profileIDs:["Default","Profile 1"]))
        #expect(spaces.count == 2 && spaces.allSatisfy { $0.snapshot.look?.sidebarWidth == 228 })
        for invalid:Any in [true,0,-1,"228",NSNull()] {
            let data = try JSONSerialization.data(withJSONObject:["windows":[["sidebarWidth":invalid]]])
            #expect(try ArcSidebarReader.read(sidebar:ArcImportBench.sidebar(),archive:nil,profiles:source.profiles,windows:data).sidebarWidth == nil)
        }
    }

    @Test("Unnamed Space labels follow sidebar order, independently of profile names")
    func automaticSpaceNames() throws {
        var root = try #require(JSONSerialization.jsonObject(with:ArcImportBench.sidebar()) as? [String:Any])
        var sidebar = try #require(root["sidebar"] as? [String:Any])
        var containers = try #require(sidebar["containers"] as? [[String:Any]])
        var spaces = try #require(containers[1]["spaces"] as? [Any])
        for i in [1,3] {
            var space = try #require(spaces[i] as? [String:Any])
            var info = space["customInfo"] as? [String:Any] ?? [:]
            info.removeValue(forKey:"name");info.removeValue(forKey:"title")
            space["customInfo"] = info;space.removeValue(forKey:"title");spaces[i] = space
        }
        containers[1]["spaces"] = spaces;sidebar["containers"] = containers;root["sidebar"] = sidebar
        root["firebaseSyncState"] = ["syncData":["orderedSpaceIDs":["value":["work-space","personal-space"]]]]
        let read = try ArcSidebarReader.read(sidebar:JSONSerialization.data(withJSONObject:root),archive:nil,profiles:ArcImportBench.profiles)
        #expect(read.spaces.map(\.id) == ["work-space","personal-space"])
        #expect(read.spaces.map(\.name) == ["Space 1","Space 2"])
    }

    @Test("The imported width is durable and repeat imports keep a later divider resize")
    func widthPreference() {
        let name = "arc-width.\(UUID())"
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let settings = Settings(defaults:defaults)
        settings.sidebarWidth = 298
        #expect(!settings.importArcSidebarWidth(nil,sourceID:"source"))
        #expect(settings.importArcSidebarWidth(228,sourceID:"source"))
        #expect(settings.sidebarWidth == 228 && !settings.sidebarWidthIsPerSpace)
        settings.sidebarWidth = 340
        #expect(!Settings(defaults:defaults).importArcSidebarWidth(245,sourceID:"source"))
        #expect(Settings(defaults:defaults).sidebarWidth == 340)
        #expect(settings.importArcSidebarWidth(245,sourceID:"another-source"))
        #expect(settings.sidebarWidth == 245)
    }

    @Test("Existing imported Spaces gain a missing width while an explicit per-Space resize survives")
    func enrichingWidth() throws {
        let source = try ArcImportBench.snapshot();defer { source.remove() }
        let session = TestSession.make().0
        var incoming = ArcSpaceBuilder.build(source,options:ArcImportOptions(profileIDs:["Default"])).map(\.snapshot)
        try session.applyArcSpaces(incoming)
        let imported = try #require(session.spaces.first { $0.id == incoming[0].id })
        incoming[0].look?.sidebarWidth = 228
        try session.applyArcSpaces(incoming)
        #expect(imported.look.sidebarWidth == 228)
        var look = imported.look;look.sidebarWidth = 320;session.setLook(look,for:imported)
        try session.applyArcSpaces(incoming)
        #expect(imported.look.sidebarWidth == 320)
    }

    @Test("An imported width updates the live sidebar and the return width behind the Library")
    func liveWidth() throws {
        let settings = Settings.shared,defaults = UserDefaults.standard
        let oldWidth = settings.sidebarWidth,oldScope = settings.sidebarWidthIsPerSpace,oldPosition = settings.sidebarPosition
        let oldSources = defaults.object(forKey:"arcSidebarWidthSources")
        let oldCategory = defaults.object(forKey:"sidebarLibraryCategory")
        let oldCompact = settings.compactModeEnabled,oldMode = settings.sidebarMode
        defer {
            settings.sidebarWidth = oldWidth;settings.sidebarWidthIsPerSpace = oldScope;settings.sidebarPosition = oldPosition
            settings.compactModeEnabled = oldCompact;settings.sidebarMode = oldMode
            if let oldSources { defaults.set(oldSources,forKey:"arcSidebarWidthSources") } else { defaults.removeObject(forKey:"arcSidebarWidthSources") }
            if let oldCategory { defaults.set(oldCategory,forKey:"sidebarLibraryCategory") } else { defaults.removeObject(forKey:"sidebarLibraryCategory") }
        }
        settings.sidebarWidth = 298;settings.sidebarWidthIsPerSpace = false;settings.sidebarPosition = .leading
        settings.compactModeEnabled = false;settings.sidebarMode = .expanded
        let session = TestSession.make().0
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let window = try #require(controller.window),root = try #require(window.contentView)
        window.setContentSize(NSSize(width:1400,height:900));root.layoutSubtreeIfNeeded()
        let splitController = try #require(window.contentViewController?.children.compactMap { $0 as? BarcSplitViewController }.first)
        let split = splitController.splitView
        splitController.viewDidLayout()
        #expect(abs(split.subviews[0].frame.width-298)<0.5)
        settings.importArcSidebarWidth(228,sourceID:"fixture-\(UUID())")
        root.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width-228)<0.5)
        controller.toggleArchive(nil)
        root.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width-417)<0.5)
        settings.importArcSidebarWidth(240,sourceID:"fixture-\(UUID())")
        #expect(abs(split.subviews[0].frame.width-417)<0.5)
        controller.toggleArchive(nil);root.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width-240)<0.5)
        session.addSpace(named:"Other");root.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width-240)<0.5)
    }

    @Test("A hidden Space keeps its data, remains recoverable and is skipped by dock navigation")
    func hiddenSpaceNavigation() throws {
        let session = TestSession.make().0
        let first = session.activeSpace
        let hidden = session.addSpace(named:"Retained")
        let page = session.newTab(url:URL(string:"https://fixture.invalid/retained")!)
        session.rename(page,to:"Saved page")
        let folder = session.createGroup(named:"Saved folder",containing:[page])
        let last = session.addSpace(named:"Last")
        session.selectSpace(first)
        let allIDs = session.allTabs.map(\.id),profile = hidden.profile
        #expect(session.setDockVisible(false,for:hidden))
        #expect(session.sidebarSpaces.map(\.id) == [first.id,last.id])
        session.selectSpace(offsetBy:1)
        #expect(session.activeSpace === last)
        #expect(session.setDockVisible(false,for:first))
        #expect(!session.setDockVisible(false,for:last),"The last persistent dock entry cannot be hidden")
        session.selectSpace(hidden)
        #expect(session.sidebarSpaces.map(\.id) == [hidden.id,last.id])
        session.selectSpace(offsetBy:1)
        #expect(session.activeSpace === last && session.sidebarSpaces.map(\.id) == [last.id])
        #expect(session.allTabs.map(\.id) == allIDs && hidden.profile === profile)
        #expect(hidden.tabs.contains { $0 === page } && page.customName == "Saved page" && page.groupID == folder.id)
        let restored = try #require(BrowserSession.spaces(from:JSONDecoder().decode(SessionSnapshot.self,
            from:JSONEncoder().encode(session.snapshot())))?.first { $0.id == hidden.id })
        #expect(!restored.look.showsInDock && restored.look.dockVisibilityWasCustomized)
        #expect(SpaceLook().showsInDock)
    }

    @Test("Space menus and numbered shortcuts use the dock order, including a temporarily opened Space")
    func dockMenuOrder() throws {
        let session = TestSession.make().0
        let first = session.activeSpace
        let hidden = session.addSpace(named:"Hidden")
        let last = session.addSpace(named:"Last")
        session.selectSpace(first)
        session.setDockVisible(false,for:hidden)
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let second = NSMenuItem(title:"",action:#selector(BrowserWindowController.selectSpaceByNumber(_:)),keyEquivalent:"")
        second.tag = 2
        controller.selectSpaceByNumber(second)
        #expect(session.activeSpace === last && controller.switchableCount == 2 && controller.activeSwitchableIndex == 1)
        session.selectSpace(hidden)
        #expect(controller.switchableCount == 3 && controller.activeSwitchableIndex == 1)
        controller.selectSpaceByNumber(second)
        #expect(session.activeSpace === hidden)
        session.selectSpace(last)
        second.tag = 3
        #expect(!controller.validateMenuItem(second))
        let sidebar = SidebarViewController(session:session)
        let hide = try #require(sidebar.makeSpaceOptionsMenu(for:last,anchor:sidebar.view).items.first { $0.title == "Hide from Switcher" })
        #expect(hide.isEnabled)
        session.setDockVisible(false,for:first)
        let only = try #require(sidebar.makeSpaceOptionsMenu(for:last,anchor:sidebar.view).items.first { $0.title == "Hide from Switcher" })
        #expect(!only.isEnabled)
        let show = try #require(sidebar.makeSpaceOptionsMenu(for:hidden,anchor:sidebar.view).items.first { $0.title == "Show in Switcher" })
        #expect(show.isEnabled)
    }

    @Test("Orphan archives stay in the Library without adding a synthetic dock icon; an explicit visibility choice wins")
    func orphanArchives() throws {
        let source = try ArcImportBench.snapshot();defer { source.remove() }
        var sidebar = source.sidebar
        sidebar.archived = [.init(id:"orphan",spaceID:"deleted-space",url:URL(string:"https://fixture.invalid/archive")!,title:"Recovered",date:.now)]
        let frozen = ArcSourceSnapshot(root:source.root,sourceFingerprint:source.sourceFingerprint,profiles:source.profiles,
            sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
        let built = ArcSpaceBuilder.build(frozen,options:ArcImportOptions(profileIDs:["Default"]))
        let orphan = try #require(built.first { $0.sourceSpaceID == "unassigned-archive" })
        #expect(orphan.snapshot.look?.showsInDock == false)
        let session = TestSession.make().0
        try session.applyArcSpaces(built.map(\.snapshot))
        let space = try #require(session.spaces.first { $0.id == orphan.snapshot.id })
        #expect(!session.sidebarSpaces.contains { $0 === space } && session.archivedTabs.count == 1)
        let entries = LibraryCatalog.entries(for:.archive,session:session,downloads:.shared,boosts:.shared)
        #expect(entries.contains { $0.title == "Recovered" })
        session.setDockVisible(true,for:space)
        try session.applyArcSpaces([orphan.snapshot])
        #expect(space.look.showsInDock && session.archivedTabs.count == 1)
    }
}
