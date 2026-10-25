// Modified for Barc: preserve source unit names independently of pane names, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Split unit names", .serialized)
@MainActor
struct SplitNameImportTests {
    private func namedSource(favorite:Bool) throws -> ArcSourceSnapshot {
        try ArcSplitImportTests().source(favorite:favorite,name:"Research split")
    }

    @Test("A named source Favorite announces its unit name without renaming either pane")
    func favoriteLabel() throws {
        let source = try namedSource(favorite:true);defer { source.remove() }
        let incoming = try #require(ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).first?.snapshot)
        let session = TestSession.make().0
        try session.applyArcSpaces([incoming])
        session.selectSpace(try #require(session.spaces.first { $0.id == incoming.id }))
        let sidebar = SidebarViewController(session:session)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        let strip = try #require(UITestSupport.descendants(of:host).compactMap { $0 as? PinnedTilesView }.first)
        let tile = try #require(strip.subviews.first { $0.accessibilityRole() == .button })
        #expect(tile.toolTip == "Research split")
        #expect(tile.accessibilityLabel() == "Research split")
        #expect(session.activeSpace.profile.favoriteTabs.map(\.displayTitle) == ["a","b"])
    }

    @Test("Source names survive a real reopen, unpin, archive and Favorite conversion",arguments:[false,true])
    func lifecycle(favorite:Bool) throws {
        let source = try namedSource(favorite:favorite);defer { source.remove() }
        let incoming = try #require(ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).first?.snapshot)
        #expect(incoming.splits?.first?.customName == "Research split")
        #expect(incoming.pinnedSites?.first?.split?.customName == (favorite ? "Research split":nil))
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        try session.applyArcSpaces([incoming])
        let owner = try #require(session.spaces.first { $0.id == incoming.id })
        session.selectSpace(owner);session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"split-name.\(UUID())")!)
        settings.restoresSession = true
        let restored = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let space = try #require(restored.spaces.first { $0.id == owner.id })
        restored.selectSpace(space)
        let page = try #require(restored.activeTab)
        #expect(space.splits.name(containing:page.id) == "Research split")
        if favorite { restored.removePinnedSite(try #require(space.pinnedSites.first)) }
        let pages = try #require(restored.activeSplit).tabIDs.compactMap { id in space.tabs.first { $0.id == id } }
        restored.archive(pages)
        let returned = restored.restoreAllArchived(in:space)
        #expect(returned.count == 2)
        let first = try #require(returned.first)
        #expect(space.splits.name(containing:first.id) == "Research split")
        restored.pin(first)
        #expect(space.pinnedSites.first?.title == "Research split")
        #expect(space.pinnedSites.first?.split?.customName == "Research split")
        #expect(returned.map(\.displayTitle) == ["a","b"])
    }

    @Test("An edited group name survives repeated imports and a stale sibling's focus change")
    func localNameOwnership() throws {
        let source = try namedSource(favorite:true);defer { source.remove() }
        let incoming = try #require(ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).first?.snapshot)
        let session = TestSession.make().0
        try session.applyArcSpaces([incoming])
        let owner = try #require(session.spaces.first { $0.id == incoming.id })
        let site = try #require(owner.pinnedSites.first)
        let sibling = session.addSpace(named:"Sibling",profile:owner.profile)
        session.openPinnedSite(site)
        let pages = owner.profile.favoriteTabs
        let first = try #require(pages.first)
        owner.splits.setName(" Local name ",containing:first.id)
        owner.splits.setIcon(.emoji("🐮"),containing:first.id)
        #expect(owner.pinnedSites.first?.title == "Local name")
        #expect(sibling.splits.name(containing:first.id) == "Research split")
        session.selectSpace(sibling);session.selectTab(first)
        #expect(owner.pinnedSites.first?.title == "Local name")
        #expect(owner.pinnedSites.first?.split?.customName == "Local name")
        #expect(owner.pinnedSites.first?.icon == .emoji("🐮"))
        try session.applyArcSpaces([incoming])
        #expect(owner.pinnedSites.first?.title == "Local name")
        session.openPinnedSite(site)
        #expect(sibling.splits.name(containing:first.id) == "Local name")
        sibling.splits.setName(" \n",containing:first.id)
        #expect(owner.pinnedSites.first?.title == "a / b")
        #expect(owner.pinnedSites.first?.split?.customName == nil)
    }

    @Test("Names follow group identity through copy, merge and removal")
    func identity() throws {
        let ids = (0..<4).map { _ in UUID() }
        var source = SplitCollection()
        source.join(Array(ids.prefix(2)),grid:.sideBySide)
        source.join(Array(ids.suffix(2)),grid:.stacked)
        source.setName("First",containing:ids[0]);source.setName("Second",containing:ids[2])
        source.join([ids[2],ids[0]],grid:.sideBySide)
        #expect(source.name(containing:ids[0]) == "Second")
        let copiedIDs = ids.map { _ in UUID() }
        var copy = source
        copy.copyCompleteGroups(from:source,mapping:Dictionary(uniqueKeysWithValues:zip(ids,copiedIDs)))
        #expect(copy.name(containing:copiedIDs[0]) == "Second")
        #expect(copy.identifier(containing:copiedIDs[0]) != copy.identifier(containing:ids[0]))
        copy.dissolve(containing:ids[0])
        #expect(copy.name(containing:ids[1]) == nil && copy.name(containing:copiedIDs[1]) == "Second")
        copy.setName(nil,containing:copiedIDs[1])
        let saved = try #require(copy.snapshot(tabIDs:copiedIDs))
        let data = try JSONEncoder().encode(saved)
        #expect(!String(decoding:data,as:UTF8.self).contains("customName"))
        let decoded = try JSONDecoder().decode([SessionSnapshot.Split].self,from:data)
        #expect(SplitCollection.restoring(decoded,tabIDs:ids).name(containing:ids[0]) == nil)
    }

    @Test("Only a nonempty root name names the whole unit; pane and nested names remain separate",arguments:["  "," Named group "])
    func rootName(_ name:String) throws {
        let original = try ArcSplitImportTests().source(nested:true,favorite:true)
        defer { original.remove() }
        var sidebar = original.sidebar
        sidebar.items["unit"]?.customName = name
        sidebar.items["left"]?.customName = "Inner unit"
        sidebar.items["a"]?.customName = "First pane"
        let source = ArcSourceSnapshot(root:original.root,sourceFingerprint:original.sourceFingerprint,profiles:original.profiles,
            sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
        let built = try #require(ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).first?.snapshot)
        let expected:String? = name == "  " ? nil:"Named group"
        #expect(built.splits?.first?.customName == expected)
        #expect(built.pinnedSites?.first?.split?.customName == expected)
        #expect(built.pinnedSites?.first?.title == (expected ?? "First pane / b / c / d"))
        #expect(built.tabs.first?.customName == "First pane" && built.tabs.dropFirst().allSatisfy { $0.customName == nil })
    }

    @Test("Private split names are absent from the saved session")
    func privateName() throws {
        let session = TestSession.make().0
        let owner = session.addSpace(named:"Private",isPrivate:true)
        let pages = (0..<2).map { index in session.newTab(url:URL(string:"https://private-split-name.invalid/\(index)")!) }
        session.splitTabs(pages)
        owner.splits.setName("Private unit name",containing:pages[0].id)
        session.pin(pages[0])
        #expect(owner.pinnedSites.first?.title == "Private unit name")
        let text = String(decoding:try JSONEncoder().encode(session.snapshot()),as:UTF8.self)
        #expect(!text.contains("Private unit name") && !text.contains("private-split-name.invalid"))
    }
}
