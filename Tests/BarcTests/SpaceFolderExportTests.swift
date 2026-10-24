import AppKit
import Testing
@testable import Barc

@Suite("Local Space export", .serialized)
@MainActor
struct SpaceFolderExportTests {
    @Test("Export preserves the source and copies mixed ordering, metadata and nested folders into the destination identity")
    func copiesContents() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        source.name = "Research"; source.icon = .symbol("ionicon.planet")
        let loose = session.newTab(url: URL(string: "https://example.invalid/loose")!)
        loose.setKeepsInSidebar(true); loose.sidebarPosition = 1
        let nested = session.newTab(url: URL(string: "https://example.invalid/nested")!)
        session.rename(nested, to: "Saved title"); nested.setNote("A note")
        let folder = session.createGroup(named: "References", containing: [nested])
        folder.sidebarPosition = 0; folder.isCollapsed = true
        folder.setIcon(.symbol("ionicon.leaf")); folder.isLive = true
        let today = session.newTab(url: URL(string: "https://example.invalid/today")!)
        let favorite = session.newTab(url: URL(string: "https://example.invalid/favorite")!)
        session.pin(favorite)
        let target = session.addSpace(named: "Destination")
        let selected = target.activeTab
        let before = source.tabs.map { $0.snapshot() }
        let result = try #require(try session.exportSpace(source, intoFolderIn: target))
        #expect(result.name == "Research" && result.icon == .symbol("ionicon.planet"))
        #expect(session.activeSpace === target && target.activeTab === selected)
        #expect(source.tabs.map { $0.snapshot() } == before)
        #expect(source.groups.count == 1 && source.groups.first === folder && folder.isLive)
        let copiedFolder = try #require(target.groups.first { $0.parentID == result.id })
        #expect(copiedFolder !== folder && copiedFolder.name == "References" && copiedFolder.isCollapsed)
        #expect(copiedFolder.icon == folder.icon && !copiedFolder.isLive)
        let copies = FolderContents.tabs(in: result, space: target)
        #expect(copies.map(\.url) == [nested.url, loose.url, today.url])
        #expect(copies.allSatisfy { $0.identity == target.identity && !$0.isLoaded })
        #expect(Set(copies.map(\.id)).isDisjoint(with: Set(source.tabs.map(\.id))))
        #expect(copies.first?.customName == "Saved title" && copies.first?.note == "A note")
        #expect(copies.allSatisfy { $0.pinnedSiteID == nil && $0.snapshot().importedSourceID == nil && $0.snapshot().interactionState == nil })
        #expect(target.profile !== source.profile && target.pinnedSites.isEmpty)
    }

    @Test("Custom icon copies are independent, and preparation failure changes neither Space")
    func iconOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "space-export-icons-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in NSColor.green.setFill(); rect.fill(); return true }
        let file = directory.appending(path: "original.tiff")
        try #require(image.tiffRepresentation).write(to: file)
        let icons = SpaceIconStore(directory: directory.appending(path: "owned"))
        let name = try icons.importIcon(from: file)
        let session = TestSession.make().0
        let source = session.activeSpace
        source.icon = .custom(name)
        let child = session.createGroup(named: "Child")
        child.setIcon(.custom(name))
        let target = session.addSpace(named: "Target")
        let root = try #require(try session.exportSpace(source, intoFolderIn: target, iconStore: icons))
        let rootFile = try #require(root.iconFileName)
        let childFile = try #require(target.groups.first { $0.parentID == root.id }?.iconFileName)
        #expect(Set([name, rootFile, childFile]).count == 3)
        icons.remove(named: rootFile)
        #expect(icons.image(named: name) != nil && icons.image(named: childFile) != nil)
        child.setIcon(.custom("missing.png"))
        let before = session.snapshot()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "owned").path).sorted()
        #expect(throws: (any Error).self) { try session.exportSpace(source, intoFolderIn: target, iconStore: icons) }
        #expect(session.snapshot() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "owned").path).sorted() == files)
    }

    @Test("Exports survive reopening, keep deep nesting and never move profile Favorites")
    func persistenceAndDepth() throws {
        let (session, store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let source = session.activeSpace
        var parent: TabGroup?
        for i in 0..<FolderTree.maximumDepth { parent = session.createGroup(named: "Level \(i)", parent: parent) }
        let tab = session.newTab(url: URL(string: "https://example.invalid/deep")!)
        session.move(tab, to: parent)
        let favorite = session.newTab(url: URL(string: "https://example.invalid/favorite")!)
        session.pin(favorite)
        let target = session.addSpace(named: "Same profile", profile: source.profile)
        let root = try #require(try session.exportSpace(source, intoFolderIn: target))
        #expect(target.tabs.contains { $0 === favorite } && source.tabs.contains { $0 === favorite })
        #expect(FolderContents.tabs(in: root, space: target).map(\.url) == [tab.url])
        #expect(target.groups.map { FolderTree.depth(of: $0, in: target.groups) }.max() == FolderTree.maximumDepth)
        try store.save(session.snapshot())
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: UserDefaults(suiteName: "space-export.\(UUID())")!))
        let restored = try #require(reopened.spaces.first { $0.id == target.id })
        #expect(restored.profile === reopened.spaces[0].profile)
        #expect(restored.groups.count == target.groups.count)
        #expect(FolderContents.tabs(in: try #require(restored.group(withID: root.id)), space: restored).map(\.url) == [tab.url])
    }

    @Test("Same or unregistered Spaces are refused without side effects; empty exports are valid folders")
    func invalidAndEmpty() throws {
        let session = TestSession.make().0
        let source = session.activeSpace
        let foreign = TestSession.make().0.activeSpace
        let before = session.snapshot()
        #expect(try session.exportSpace(source, intoFolderIn: source) == nil)
        #expect(try session.exportSpace(foreign, intoFolderIn: source) == nil)
        #expect(try session.exportSpace(source, intoFolderIn: foreign) == nil)
        #expect(session.snapshot() == before)
        let target = session.addSpace(named: "Target")
        let root = try #require(try session.exportSpace(source, intoFolderIn: target))
        #expect(FolderContents.tabs(in: root, space: target).isEmpty)
        #expect(target.groups.count == 1 && source.groups.isEmpty)
    }

    @Test("Export submenu names the source, disables itself and dispatches a destination ID without sharing")
    func menu() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let source = session.activeSpace
        let target = session.addSpace(named: "Other")
        var actions: [SpaceOptionsMenu.Action] = []
        let menu = SpaceOptionsMenu.make(canDelete: true, hasGitHubFolder: false,
            exportSource: source, exportDestinations: session.spaces) { actions.append($0) }
        let submenu = try #require(menu.items.first { $0.title == "Export “\(source.name)” into Folder" }?.submenu)
        #expect(submenu.items.map(\.title) == [source.name, target.name])
        #expect(!submenu.items[0].isEnabled && submenu.items[1].isEnabled)
        let item = submenu.items[1]
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(actions == [.exportInto(target.id)])
        #expect(!menu.items.contains { $0.title.contains("Share") })
    }

    @Test("A dock menu exports its own inactive Space and clears imported identities and opaque page state")
    func inactiveMenuTarget() async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let source = session.activeSpace
        let original = Tab(restoring: SessionSnapshot.Tab(url: URL(string: "https://example.invalid/secret-state")!,
            title: "Original page", interactionState: Data([1, 2, 3]), importedSourceID: "arc:source:one"), identity: source.identity)
        source.insert(original, at: source.workspaceTabs.count)
        let target = session.addSpace(named: "Other")
        let sidebar = SidebarViewController(session: session)
        let menu = sidebar.makeSpaceOptionsMenu(for: source, anchor: sidebar.view)
        let submenu = try #require(menu.items.first { $0.title == "Export “\(source.name)” into Folder" }?.submenu)
        let destination = try #require(submenu.items.first { $0.title == target.name })
        #expect(NSApp.sendAction(try #require(destination.action), to: destination.target, from: destination))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let root = try #require(target.groups.first)
        let copy = try #require(FolderContents.tabs(in: root, space: target).first)
        #expect(copy.url == original.url && copy.identity == target.identity && !copy.isLoaded)
        #expect(copy.snapshot().interactionState == nil && copy.snapshot().importedSourceID == nil)
        #expect(original.snapshot().interactionState == Data([1, 2, 3]) && original.snapshot().importedSourceID == "arc:source:one")
        #expect(source.groups.isEmpty && session.activeSpace === target)
    }
}
