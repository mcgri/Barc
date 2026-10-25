// Modified for Barc: Arc Favorite split imports retain one shared profile unit, 2026-10-25.
import AppKit
import Combine
import Testing
@testable import Barc

@Suite("Arc Favorite split import", .serialized)
@MainActor
struct ArcFavoriteSplitImportTests {
    func sourceFixture(nested:Bool = false) throws -> ArcSourceSnapshot {
        let source = try ArcSplitImportTests().source(nested:nested,favorite:true)
        var sidebar = source.sidebar
        sidebar.spaces.append(.init(id:"source-sibling",name:"Sibling",profile:"Default",pinnedRoot:nil,
            unpinnedRoot:nil,color:nil,emoji:nil))
        sidebar.selectedItems["source-sibling"] = "unit"
        return .init(root:source.root,sourceFingerprint:source.sourceFingerprint,profiles:source.profiles,
            sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
    }
    private func snapshots(_ source:ArcSourceSnapshot) -> [SessionSnapshot.Space] {
        ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).map(\.snapshot)
    }
    private func legacy(_ stored:SessionSnapshot.Space) -> SessionSnapshot.Space {
        var copy = stored;copy.splits = nil;copy.importedSplitIDs = nil
        copy.pinnedSites = []
        for index in copy.tabs.indices {
            let id = ArcImportID.uuid(copy.tabs[index].importedSourceID!.replacingOccurrences(of:"/tab/",with:"/pin/"))
            copy.tabs[index].pinnedSiteID = id;copy.tabs[index].pinnedMemberID = nil
            copy.pinnedSites?.append(.init(id:id,url:copy.tabs[index].url,title:copy.tabs[index].title ?? ""))
        }
        return copy
    }

    @Test("Two imported Spaces share one Favorite and distinct duplicate-URL members through reopening",arguments:[false,true])
    func freshAndReopen(nested:Bool) throws {
        let source = try sourceFixture(nested:nested);defer { source.remove() }
        let expected = nested ? 4:2,focused = nested ? "d":"b"
        let built = ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"]))
        #expect(built.count == 2 && built.allSatisfy { $0.unsupportedSplits == 0 && $0.sourceSplitCount == 1 })
        let incoming = built.map(\.snapshot)
        let pin = try #require(incoming[0].pinnedSites?.first)
        #expect(incoming.allSatisfy { $0.pinnedSites?.count == 1 && $0.pinnedSites?.first?.id == pin.id })
        #expect(pin.split?.isValid == true && pin.split?.members.count == expected)
        #expect(Set(incoming[0].tabs.compactMap(\.pinnedMemberID)).count == expected)
        #expect(incoming[0].tabs.map(\.pinnedMemberID) == incoming[1].tabs.map(\.pinnedMemberID))
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        try session.applyArcSpaces(incoming)
        let spaces = incoming.compactMap { stored in session.spaces.first { $0.id == stored.id } }
        #expect(spaces.count == 2 && spaces[0].profile === spaces[1].profile)
        #expect(spaces[0].profile.favoriteTabs.count == expected && spaces.allSatisfy { $0.splits.layouts.count == 1 })
        #expect(spaces.allSatisfy { $0.workspaceTabs.isEmpty && $0.activeTab?.pageTitle == focused })
        let pages = spaces[0].profile.favoriteTabs
        let count = session.allTabs.count
        try session.applyArcSpaces(incoming)
        #expect(session.allTabs.count == count && zip(spaces[0].profile.favoriteTabs,pages).allSatisfy { $0 === $1 })
        session.selectSpace(spaces[1]);session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"arc-favorite-import.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restored = try #require(reopened.spaces.first { $0.id == spaces[1].id })
        #expect(restored.profile.favoriteTabs.count == expected && restored.splits.layouts.count == 1 && restored.activeTab?.pageTitle == focused)
        let sidebar = SidebarViewController(session:reopened)
        let host = UITestSupport.host(sidebar.view,width:228,height:760)
        let strip = try #require(UITestSupport.descendants(of:host).compactMap { $0 as? PinnedTilesView }.first)
        #expect(strip.tileCount == 1 && sidebar.tabListTableView.numberOfRows == 1)
    }

    @Test("Older flat Favorite imports upgrade once without replacing live pages or undoing later removal")
    func legacyUpgrade() throws {
        let source = try sourceFixture();defer { source.remove() }
        let incoming = snapshots(source)[0],flat = legacy(incoming)
        let session = TestSession.make().0
        try session.applyArcSpaces([flat])
        let space = try #require(session.spaces.first { $0.id == incoming.id })
        let pages = space.tabs
        session.selectSpace(space);session.selectTab(pages[0])
        let selected = space.activeTab
        var layouts:[Bool] = []
        let token = session.changes.sink { change in
            switch change {
            case .spaces,.tabs,.structure:
                layouts.append(space.pinnedSites.count == 1 && space.profile.favoriteTabs.count == 2 && space.splits.layouts.count == 1)
            default:break
            }
        }
        try session.applyArcSpaces([incoming])
        token.cancel()
        #expect(layouts == [true])
        #expect(space.pinnedSites.count == 1 && space.pinnedSites.first?.split?.isValid == true)
        #expect(space.profile.favoriteTabs.count == 2 && space.workspaceTabs.isEmpty && space.splits.layouts.count == 1)
        #expect(Set(space.tabs.map(\.id)) == Set(pages.map(\.id)) && space.activeTab === selected)
        session.removePinnedSite(try #require(space.pinnedSites.first))
        try session.applyArcSpaces([incoming])
        #expect(space.pinnedSites.isEmpty && space.profile.favoriteTabs.isEmpty && space.workspaceTabs.count == 2)
    }

    @Test("Older coalesced Favorite copies can upgrade after reopening without losing their live page")
    func reopenedAliases() throws {
        let source = try sourceFixture();defer { source.remove() }
        var incoming = snapshots(source)[0]
        for index in incoming.tabs.indices { incoming.tabs[index].title = "Shared" }
        let flat = legacy(incoming)
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        try session.applyArcSpaces([flat]);session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"arc-favorite-alias.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let space = try #require(reopened.spaces.first { $0.id == incoming.id })
        #expect(space.tabs.count == 1)
        let original = space.tabs[0]
        try reopened.applyArcSpaces([incoming])
        #expect(space.profile.favoriteTabs.count == 2 && space.splits.layouts.count == 1)
        #expect(space.profile.favoriteTabs.contains(where:{ $0 === original }))
    }

    @Test("Two older flat Spaces coalesce unmodified copies but preserve a filing choice in either Space",arguments:[false,true])
    func legacySharedSpaces(edited:Bool) throws {
        let source = try sourceFixture();defer { source.remove() }
        let incoming = snapshots(source),session = TestSession.make().0
        try session.applyArcSpaces(incoming.map(legacy))
        let first = try #require(session.spaces.first { $0.id == incoming[0].id })
        let second = try #require(session.spaces.first { $0.id == incoming[1].id })
        if edited {
            session.selectSpace(second)
            let member = try #require(second.workspaceTabs.first)
            _ = session.createGroup(named:"Local",containing:[member])
        }
        try session.applyArcSpaces(incoming)
        if edited {
            #expect(first.pinnedSites.allSatisfy { $0.split == nil } && first.splits.layouts.isEmpty && second.splits.layouts.isEmpty)
        } else {
            #expect(first.profile.favoriteTabs.count == 2 && first.workspaceTabs.isEmpty && second.workspaceTabs.isEmpty)
            #expect(first.splits.layouts.count == 1 && second.splits.layouts.count == 1)
        }
    }

    @Test("A locally filed or archived member prevents automatic regrouping and resurrection",arguments:[false,true])
    func localChoices(archived:Bool) throws {
        let source = try sourceFixture();defer { source.remove() }
        let incoming = snapshots(source)[0],flat = legacy(incoming)
        let session = TestSession.make().0
        try session.applyArcSpaces([flat])
        let space = try #require(session.spaces.first { $0.id == incoming.id })
        session.selectSpace(space)
        let member = try #require(space.tabs.first { $0.importedSourceID == incoming.tabs[1].importedSourceID })
        if archived { session.archive([member]) }
        else { _ = session.createGroup(named:"Local choice",containing:[member]) }
        let before = space.tabs.map { $0.snapshot() },archiveCount = session.archivedTabs.count
        try session.applyArcSpaces([incoming])
        #expect(space.splits.layouts.isEmpty && space.pinnedSites.allSatisfy { $0.split == nil })
        #expect(space.tabs.map { $0.snapshot() } == before && session.archivedTabs.count == archiveCount)
    }
}

extension ArcImportFlowTests {
    @Test("A Favorite split shared by two Spaces is reported once and verified on repeated imports")
    func favoriteSplitReport() async throws {
        let source = try ArcFavoriteSplitImportTests().sourceFixture()
        defer { source.remove() }
        try FileManager.default.createDirectory(at:source.root.appending(path:"User Data/Default"),withIntermediateDirectories:true)
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        let name = "arc-favorite-report.\(UUID())",defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let coordinator = ArcImportCoordinator(session:session,settings:Settings(defaults:defaults),
            downloads:DownloadManager(store:DownloadStore(fileURL:source.root.appending(path:"downloads.json"))),
            reportDirectory:source.root.appending(path:"reports"))
        var options = ArcImportOptions(profileIDs:["Default"])
        options.history = false;options.bookmarks = false;options.passwords = false
        options.cookies = false;options.localStorage = false;options.supplementary = false
        for repeated in [false,true] {
            let report = try await coordinator.run(source,options:options)
            let profile = try #require(report.profiles.first)
            let count = try #require(profile.counts["Split layouts"])
            #expect(count.source == 1 && count.verified == 1 && count.skipped == 0)
            #expect(count.imported == (repeated ? 0:1) && count.existing == (repeated ? 1:0))
        }
    }
}
