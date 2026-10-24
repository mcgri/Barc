import AppKit
import Testing
@testable import Barc

@Suite("Sidebar folder actions", .serialized)
@MainActor
struct FolderActionsTests {
    private func fixture() -> (BrowserSession, Space, TabGroup, TabGroup, [Tab]) {
        let session = TestSession.make().0
        let space = session.activeSpace
        let a = session.newTab(url: URL(string: "https://example.invalid/a")!)
        let b = session.newTab(url: URL(string: "https://example.invalid/b")!)
        let c = session.newTab(url: URL(string: "https://example.invalid/c")!)
        let root = session.createGroup(named: "Project", containing: [a, c])
        let child = session.createGroup(named: "Research", containing: [b], parent: root)
        c.sidebarPosition = 0; child.sidebarPosition = 1; a.sidebarPosition = 2
        root.isCollapsed = true; child.isCollapsed = true
        return (session, space, root, child, [a, b, c])
    }

    @Test("Copy links follows mixed nested ordering even when folders are collapsed")
    func links() {
        let (session, space, root, _, tabs) = fixture()
        session.rename(tabs[1], to: "A [label]\\ with\na newline")
        #expect(FolderContents.tabs(in: root, space: space).map(\.id) == [tabs[2].id, tabs[1].id, tabs[0].id])
        #expect(FolderContents.links(in: root, space: space) == "https://example.invalid/c\nhttps://example.invalid/b\nhttps://example.invalid/a")
        #expect(FolderContents.links(in: root, space: space, markdown: true).contains("[A \\[label\\]\\\\ with a newline](https://example.invalid/b)"))
        let elsewhere = session.addSpace(named: "Elsewhere")
        #expect(FolderContents.links(in: root, space: elsewhere).isEmpty)
        #expect(FolderContents.tabs(in: root, space: space).count == 3)
    }

    @Test("Duplicate preserves names, nested metadata and order without reusing tabs or imported identities")
    func duplicate() throws {
        let (session, space, root, child, tabs) = fixture()
        session.rename(tabs[0], to: "Named page")
        tabs[0].setNote("A saved note"); tabs[0].setEmoji("🌱")
        root.setIcon(.symbol("ionicon.planet"))
        let sibling = session.createGroup(named: "After")
        let selected = session.activeTab
        let copy = try #require(try session.duplicateFolder(root))
        #expect(copy !== root && copy.name == root.name && copy.icon == root.icon)
        #expect(copy.isCollapsed == root.isCollapsed)
        let copiedChild = try #require(space.groups.first { $0.parentID == copy.id })
        #expect(copiedChild !== child && copiedChild.name == child.name && copiedChild.isCollapsed)
        let copies = FolderContents.tabs(in: copy, space: space)
        #expect(copies.map(\.url) == [tabs[2].url, tabs[1].url, tabs[0].url])
        #expect(Set(copies.map(\.id)).isDisjoint(with: Set(tabs.map(\.id))))
        #expect(copies.allSatisfy { $0.identity == space.identity && !$0.isLoaded && $0.snapshot().importedSourceID == nil })
        #expect(copies.last?.customName == "Named page")
        #expect(copies.last?.note == "A saved note" && copies.last?.emoji == "🌱")
        #expect(session.activeTab === selected)
        let roots = SidebarOrder.items(groups: space.groups, tabs: space.listedTabs).compactMap { item -> UUID? in
            if case .folder(let folder) = item { folder.id } else { nil }
        }
        #expect(roots == [root.id, copy.id, sibling.id])
        session.rename(copy, to: "Independent")
        #expect(root.name == "Project" && child.parentID == root.id)
    }

    @Test("An inactive folder's menu duplicates its owning Space, never the currently selected Space")
    func inactiveOwner() throws {
        let (session, source, root, _, _) = fixture()
        let sidebar = SidebarViewController(session: session)
        let duplicate = try #require(sidebar.makeGroupMenu(for: root).items.first { $0.title == "Duplicate" })
        let other = session.addSpace(named: "Other")
        let before = other.tabs.count
        #expect(NSApp.sendAction(try #require(duplicate.action), to: duplicate.target, from: duplicate))
        #expect(source.groups.filter { $0.name == "Project" }.count == 2)
        #expect(session.activeSpace === other && other.tabs.count == before && other.groups.isEmpty)
    }

    @Test("Copied custom icons have independent ownership and failures leave the tree unchanged")
    func iconOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "folder-icons-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let file = directory.appending(path: "original.tiff")
        try #require(image.tiffRepresentation).write(to: file)
        let icons = SpaceIconStore(directory: directory.appending(path: "owned"))
        let name = try icons.importIcon(from: file)
        let (session, source, root, child, _) = fixture()
        root.setIcon(.custom(name))
        let copy = try #require(try session.duplicateFolder(root, iconStore: icons))
        let copiedName = try #require(copy.iconFileName)
        #expect(copiedName != name && icons.image(named: copiedName) != nil)
        icons.remove(named: copiedName)
        #expect(icons.image(named: name) != nil)
        child.setIcon(.custom("missing.png"))
        let before = session.snapshot()
        #expect(throws: (any Error).self) { try session.duplicateFolder(root, iconStore: icons) }
        #expect(session.snapshot() == before)
        #expect(source.groups.count == 4)
    }

    @Test("Turning a folder into a Space keeps profile, pages, Favorites and nested ordering")
    func turnIntoSpace() throws {
        let (session, source, root, child, tabs) = fixture()
        root.setIcon(.symbol("ionicon.planet"))
        let profile = source.profile
        let outside = session.newTab(url: URL(string: "https://example.invalid/outside")!)
        let favorite = session.newTab(url: URL(string: "https://example.invalid/favorite")!)
        session.pin(favorite)
        session.selectTab(tabs[1])
        let result = try #require(session.turnFolderIntoSpace(root))
        #expect(session.activeSpace === result && result.name == "Project")
        #expect(result.profile === profile && result.identity == source.identity)
        #expect(result.tabs.contains { $0 === favorite } && source.tabs.contains { $0 === favorite })
        #expect(result.icon == .symbol("ionicon.planet"))
        #expect(result.groups.count == 1 && result.groups.first === child && child.parentID == nil)
        #expect(result.workspaceTabs.count == 3 && result.workspaceTabs.allSatisfy { tab in tabs.contains { $0 === tab } })
        #expect(result.activeTab === tabs[1])
        #expect(tabs[0].groupID == nil && tabs[0].keepsInSidebar)
        #expect(tabs[2].groupID == nil && tabs[2].keepsInSidebar)
        #expect(source.group(withID: root.id) == nil && source.group(withID: child.id) == nil)
        #expect(source.tabs.contains { $0 === outside } && !source.tabs.contains { $0 === tabs[1] })
        #expect(session.profiles.filter { $0 === profile }.count == 1)
        #expect(SidebarOrder.items(groups: result.groups, tabs: result.listedTabs).map(\.id) == [tabs[2].id, child.id, tabs[0].id])
    }

    @Test("A copied imported tab keeps its readable metadata without sharing its source identifier or browsing state")
    func importedCopy() throws {
        let session = TestSession.make().0
        let root = session.createGroup(named: "Imported")
        let original = Tab(restoring: SessionSnapshot.Tab(url: URL(string: "https://example.invalid/imported")!,
            title: "Original title", groupID: root.id, customName: "Chosen name", interactionState: Data([1, 2, 3]),
            note: "Keep this note", importedSourceID: "arc:fixture:one"), identity: session.activeSpace.identity)
        session.activeSpace.insert(original, at: session.activeSpace.workspaceTabs.count)
        let copy = try #require(try session.duplicateFolder(root))
        let copiedTab = try #require(FolderContents.tabs(in: copy, space: session.activeSpace).first)
        let saved = copiedTab.snapshot()
        #expect(saved.importedSourceID == nil && saved.interactionState == nil)
        #expect(saved.customName == "Chosen name" && saved.title == "Original title" && saved.note == "Keep this note")
        #expect(original.snapshot().importedSourceID == "arc:fixture:one")
        #expect(original.snapshot().interactionState == Data([1, 2, 3]))
    }

    @Test("Duplicating a nested folder keeps the copy inside its parent and an empty promoted folder starts cleanly")
    func nestedAndEmpty() throws {
        let (session, source, root, child, _) = fixture()
        let copy = try #require(try session.duplicateFolder(child))
        #expect(copy.parentID == root.id)
        #expect(FolderContents.tabs(in: copy, space: source).count == 1)
        let empty = session.createGroup(named: "Empty")
        let profileCount = session.profiles.count
        let promoted = try #require(session.turnFolderIntoSpace(empty))
        #expect(promoted.groups.isEmpty && promoted.workspaceTabs.count == 1)
        #expect(promoted.activeTab?.showsStartPage == true)
        #expect(promoted.profile === source.profile && session.profiles.count == profileCount)
    }

    @Test("Folder copies and promoted Spaces restore with their saved identities and icon choices")
    func roundTrip() throws {
        let (session, _) = TestSession.make()
        let tab = session.newTab(url: URL(string: "https://example.invalid/restored")!)
        let root = session.createGroup(named: "Saved", containing: [tab])
        root.setIcon(.symbol("ionicon.skull"))
        let copy = try #require(try session.duplicateFolder(root))
        let target = try #require(session.turnFolderIntoSpace(copy))
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "folder-roundtrip-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        try store.save(session.snapshot())
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: UserDefaults(suiteName: "folder-roundtrip.\(UUID())")!))
        let restored = try #require(reopened.spaces.first { $0.id == target.id })
        #expect(restored.profile === reopened.spaces[0].profile)
        #expect(restored.icon == .symbol("ionicon.skull"))
        #expect(restored.workspaceTabs.count == 1 && restored.workspaceTabs[0].url == tab.url)
        #expect(restored.workspaceTabs[0].keepsInSidebar)
    }

    @Test("Stale and provider-managed folders cannot create new Spaces or copies")
    func excludedFolders() throws {
        let (session, source, root, _, _) = fixture()
        let before = session.spaces.count
        root.isLocked = true
        #expect(session.turnFolderIntoSpace(root) == nil)
        root.isLocked = false; root.isLive = true
        #expect(try session.duplicateFolder(root) == nil && session.turnFolderIntoSpace(root) == nil)
        root.isLive = false; source.detachGroup(root)
        #expect(try session.duplicateFolder(root) == nil && session.turnFolderIntoSpace(root) == nil)
        #expect(session.spaces.count == before)
    }

    @Test("The compact menu exposes working folder operations and Option alternatives")
    func menu() throws {
        let (session, owner, root, _, _) = fixture()
        _ = session.addSpace(named: "Other")
        let sidebar = SidebarViewController(session: session)
        let menu = sidebar.makeGroupMenu(for: root)
        #expect(menu.items.filter { !$0.isAlternate && !$0.isSeparatorItem }.map(\.title) == [
            "New Nested Folder…", "Turn “Project” into Space", "Copy All Links", "Change Icon…", "Rename…", "Duplicate", "Move to", "Delete"
        ])
        #expect(menu.items.allSatisfy { $0.image == nil })
        let markdown = try #require(menu.items.first { $0.title == "Copy All Links as Markdown" })
        #expect(markdown.isAlternate && markdown.keyEquivalentModifierMask == .option)
        let move = try #require(menu.items.first { $0.title == "Move to" }?.submenu)
        #expect(move.items.first { $0.title == owner.name }?.state == .on)
        #expect(move.items.last?.title == "New Space…")
        let convert = try #require(menu.items.first { $0.title == "Turn “Project” into Space" })
        #expect(NSApp.sendAction(try #require(convert.action), to: convert.target, from: convert))
        #expect(session.activeSpace.name == "Project" && session.activeSpace !== owner)
    }
}

@Suite("Compact folder icon chooser")
@MainActor
struct FolderIconPickerTests {
    @Test("All 24 licensed icons render, and the picker has eight columns and three rows")
    func picker() throws {
        var chosen: FolderIcon?
        let picker = FolderIconPicker(selected: .symbol("ionicon.star")) { chosen = $0 }
        let host = UITestSupport.host(picker.view, width: 270, height: 144)
        host.layoutSubtreeIfNeeded()
        let buttons = UITestSupport.buttons(in: picker.view)
        #expect(buttons.count == 24)
        #expect(buttons.allSatisfy { $0.image?.isTemplate == false && $0.image?.size == NSSize(width: 14, height: 14) })
        #expect(Set(buttons.map { $0.frame.midY }).count == 3)
        #expect(Set(buttons.map { $0.frame.midX }).count == 8)
        for choice in FolderSymbols.choices {
            let image = try #require(FolderSymbols.image(named: choice.storedName))
            #expect(image.isTemplate && image.tiffRepresentation != nil)
        }
        let skull = try #require(buttons.first { $0.accessibilityLabel() == "Skull" })
        skull.performClick(nil)
        #expect(chosen == .symbol("ionicon.skull"))
        #expect(FolderSymbols.image(named: "briefcase.fill") != nil)
        #expect(FolderSymbols.image(named: "ionicon.no-such-icon") == nil)
    }
}
