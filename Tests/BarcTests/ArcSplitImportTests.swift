// Modified for Barc: import current split nodes without losing pages or local edits, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Arc split sidebar import", .serialized)
@MainActor
struct ArcSplitImportTests {
    func source(axis:String = "horizontal",weights:Any = [Any](),nested:Bool = false,
                        favorite:Bool = false,pinned:Bool = false) throws -> ArcSourceSnapshot {
        let root = try ArcImportBench.directory()
        let leaves = nested ? ["a","b","c","d"]:["a","b"]
        func split(_ id:String,_ children:[String],_ axis:String,_ weights:Any,_ focus:String) -> [String:Any] {
            ["id":id,"childrenIds":children,"data":["splitView":["layoutOrientation":axis,
                "itemWidthFactors":weights,"focusItemID":focus,"customInfo":NSNull()]]]
        }
        var items:[[String:Any]] = [
            ["id":"today","childrenIds":favorite ? []:["unit"],"data":[:]],
            ["id":"favorites","childrenIds":favorite ? ["unit"]:[],"data":[:]],
            split("unit",nested ? ["left","right"]:leaves,axis,weights,nested ? "d":"b")
        ]
        if nested {
            items += [split("left",["a","b"],"vertical",["a",0.4,"b",0.6],"a"),
                      split("right",["c","d"],"vertical",[Any](),"d")]
        }
        items += leaves.map { ArcImportBench.item($0,url:"https://split-import.invalid/shared") }
        let spaces:[[String:Any]] = [["id":"source-space","profile":["default":true],
            "customInfo":["title":"Research"],"containerIDs":[pinned ? "pinned":"unpinned","today"]]]
        let data = try JSONSerialization.data(withJSONObject:["sidebar":["containers":[
            ["items":items,"spaces":spaces,"topAppsContainerIDs":[["default":true],"favorites"]]
        ]],"sidebarSyncState":["items":[split("stale-unit",["ghost-a","ghost-b"],"horizontal",[Any](),"ghost-a")]]])
        let windows = try JSONSerialization.data(withJSONObject:["lastFocusedSpaceID":"source-space","windows":[
            ["focusedSpaceID":"source-space","contents":["splitViewState":["focusedContentID":"surface"],
                "windowContentSidebarItemMap":["keysToValues":["surface","unit"]]]]
        ]])
        let sidebar = try ArcSidebarReader.read(sidebar:data,archive:nil,profiles:ArcImportBench.profiles,windows:windows)
        return ArcSourceSnapshot(root:root,sourceFingerprint:"fixture-split-source",profiles:ArcImportBench.profiles,
            sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
    }
    private func built(_ source:ArcSourceSnapshot) throws -> ArcSpaceBuilder.Built {
        try #require(ArcSpaceBuilder.build(source,options:.init(profileIDs:["Default"])).first)
    }

    @Test("The observed uniform node imports as one native compact row with distinct duplicate-URL panes",arguments:[false,true])
    func uniform(pinned:Bool) throws {
        let source = try source(pinned:pinned);defer { source.remove() }
        let incoming = try built(source)
        let record = try #require(incoming.snapshot.splits?.first)
        #expect(incoming.sourceSplitCount == 1 && incoming.unsupportedSplits == 0)
        #expect(record.tabIndices == [0,1] && record.focusedTabIndex == 1)
        #expect(incoming.snapshot.activeTabIndex == 1 && incoming.snapshot.tabs.count == 2)
        #expect(Set(incoming.snapshot.tabs.compactMap(\.importedSourceID)).count == 2)
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        try session.applyArcSpaces([incoming.snapshot])
        let space = try #require(session.spaces.first { $0.id == incoming.snapshot.id })
        session.selectSpace(space)
        #expect(space.splits.layouts.count == 1 && space.tabs.count == 2)
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        #expect(sidebar.tabListTableView.numberOfRows == 2)
        let row = try #require(sidebar.tabListTableView.view(atColumn:0,row:pinned ? 0:1,makeIfNecessary:true) as? SplitRowView)
        #expect(row.members.count == 2 && row.focusedIndex == 1)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"arc-split-uniform.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        let restored = try #require(reopened.spaces.first { $0.id == space.id })
        #expect(restored.splits.layouts.count == 1 && restored.activeTab?.pageTitle == "b")
        #expect(restored.tabs.allSatisfy { $0.keepsInSidebar == pinned })
        #expect(restored.splits.preferredTab(containing:restored.tabs[0].id) == restored.activeTab?.id)
    }

    @Test("Owned weighted and nested encodings preserve proportions, order and focused leaf")
    func weightedAndNested() throws {
        for nested in [false,true] {
            let source = try source(weights:nested ? ["left":0.65,"right":0.35]:["a":0.65,"b":0.35],nested:nested)
            defer { source.remove() }
            let incoming = try built(source)
            let record = try #require(incoming.snapshot.splits?.first)
            let frames = record.layout.unitFrames(),ids = record.layout.tabIDs
            #expect(ids.count == (nested ? 4:2) && record.focusedTabIndex == (nested ? 3:1))
            #expect(record.layout.grid == (nested ? .grid:.sideBySide))
            #expect(abs(frames[ids[0]]!.width-0.65) < 0.000001)
            #expect(abs(frames[ids.last!]!.width-0.35) < 0.000001)
            if nested { #expect(abs(frames[ids[0]]!.height-0.4) < 0.000001) }
        }
    }

    @Test("Unsupported weights and malformed Favorite units retain every page and report an ungrouped source unit")
    func unsupported() throws {
        let invalid:[Any] = [["a",0.4], ["a",0.4,"a",0.6], ["a":true,"b":1], ["a":0,"b":1], "unknown"]
        for weights in invalid {
            let source = try source(weights:weights);defer { source.remove() }
            let incoming = try built(source)
            #expect(incoming.snapshot.tabs.count == 2 && incoming.snapshot.splits == nil)
            #expect(incoming.sourceSplitCount == 1 && incoming.unsupportedSplits == 1)
            #expect(incoming.snapshot.activeTabIndex == 1)
        }
        let source = try source(axis:"unknown",favorite:true);defer { source.remove() }
        let incoming = try built(source)
        #expect(incoming.snapshot.tabs.count == 2 && incoming.snapshot.splits == nil && incoming.unsupportedSplits == 1)
    }

    @Test("An older flat import is enriched once, and a later local separation survives reimport and reopening")
    func enrichOnce() throws {
        let source = try source();defer { source.remove() }
        let incoming = try built(source).snapshot
        var flat = incoming;flat.splits = nil;flat.importedSplitIDs = nil;flat.activeTabIndex = 0
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        try session.applyArcSpaces([flat])
        let space = try #require(session.spaces.first { $0.id == incoming.id })
        let pages = space.tabs,selected = space.activeTab
        try session.applyArcSpaces([incoming])
        #expect(space.splits.layouts.count == 1 && space.activeTab === selected)
        #expect(zip(space.tabs,pages).allSatisfy { $0 === $1 })
        #expect(space.splits.preferredTab(containing:pages[0].id) == selected?.id)
        session.selectSpace(space);session.unsplit()
        try session.applyArcSpaces([incoming])
        #expect(space.splits.layouts.isEmpty && space.importedSplitIDs.count == 1)
        session.saveNow()
        let settings = Settings(defaults:UserDefaults(suiteName:"arc-split.\(UUID())")!)
        settings.restoresSession = true
        let reopened = BrowserSession(database:nil,sessionStore:store,settings:settings)
        try reopened.applyArcSpaces([incoming])
        let restored = try #require(reopened.spaces.first { $0.id == incoming.id })
        #expect(restored.splits.layouts.isEmpty && restored.importedSplitIDs.count == 1)
    }

    @Test("Local filing choices block grouping without moving or duplicating the pages")
    func localChoices() throws {
        let source = try source();defer { source.remove() }
        let incoming = try built(source).snapshot
        var flat = incoming;flat.splits = nil;flat.importedSplitIDs = nil
        let session = TestSession.make().0
        try session.applyArcSpaces([flat])
        let space = try #require(session.spaces.first { $0.id == incoming.id })
        session.selectSpace(space)
        let page = space.tabs[0]
        let folder = session.createGroup(named:"Local",containing:[page])
        let before = space.tabs.map { $0.snapshot() }
        try session.applyArcSpaces([incoming])
        #expect(space.splits.layouts.isEmpty && page.groupID == folder.id)
        #expect(space.tabs.map { $0.snapshot() } == before && space.importedSplitIDs.count == 1)
    }

    @Test("Disabled sidebar import and private spaces do not retain source unit metadata")
    func disabledAndPrivate() throws {
        let source = try source();defer { source.remove() }
        var options = ArcImportOptions(profileIDs:["Default"]);options.sidebar = false
        let incoming = try #require(ArcSpaceBuilder.build(source,options:options).first)
        #expect(incoming.snapshot.splits == nil && incoming.snapshot.importedSplitIDs == nil && incoming.sourceSplitCount == 0)
        let session = TestSession.make().0
        let secret = session.addSpace(named:"Private",isPrivate:true)
        secret.importedSplitIDs = [UUID()]
        let stored = try #require(session.snapshot().spaces.first { $0.id == secret.id })
        #expect(stored.importedSplitIDs == nil && stored.splits == nil)
    }

    @Test("Cyclic and oversized source units keep their readable pages without building an invalid native tree",
          arguments:[false,true])
    func invalidTrees(oversized:Bool) throws {
        let original = try source();defer { original.remove() }
        var sidebar = original.sidebar
        let old = try #require(sidebar.items["unit"])
        let children = oversized ? ["a","b","c","d","e"]:["a","b","unit"]
        if oversized {
            for id in ["c","d","e"] {
                sidebar.items[id] = .init(id:id,parentID:"unit",title:id,children:[],
                    url:URL(string:"https://split-import.invalid/shared"),isFolder:false,lastActiveAt:nil)
                sidebar.orderedItemIDs.append(id)
            }
        }
        sidebar.items["unit"] = .init(id:old.id,parentID:old.parentID,title:old.title,children:children,
            url:nil,isFolder:false,lastActiveAt:nil,split:old.split)
        let input = ArcSourceSnapshot(root:original.root,sourceFingerprint:original.sourceFingerprint,
            profiles:original.profiles,sidebar:sidebar,unsupportedIndexedDBFolders:[:],extensions:[:])
        let incoming = try built(input)
        #expect(incoming.snapshot.tabs.count == (oversized ? 5:2) && incoming.snapshot.splits == nil)
        #expect(incoming.sourceSplitCount == 1 && incoming.unsupportedSplits == 1)
    }

    @Test("Archived panes and existing local splits remain untouched during enrichment",arguments:[false,true])
    func preservedLocalState(archived:Bool) throws {
        let source = try source();defer { source.remove() }
        let incoming = try built(source).snapshot
        var flat = incoming;flat.splits = nil;flat.importedSplitIDs = nil
        let session = TestSession.make().0
        try session.applyArcSpaces([flat])
        let space = try #require(session.spaces.first { $0.id == incoming.id })
        session.selectSpace(space)
        if archived {
            session.archive([space.tabs[1]])
        } else {
            let page = space.tabs[0]
            let local = session.newTab(url:URL(string:"https://split-import.invalid/local")!)
            session.splitTabs([page,local],grid:.stacked)
        }
        let pages = space.tabs,layout = space.splits,records = session.archivedTabs.map(\.stored)
        try session.applyArcSpaces([incoming])
        #expect(zip(space.tabs,pages).allSatisfy { $0 === $1 } && space.tabs.count == pages.count)
        #expect(space.splits == layout && session.archivedTabs.map(\.stored) == records)
        #expect(space.importedSplitIDs.count == 1)
    }
}

extension ArcImportFlowTests {
    @Test("Split reporting distinguishes supported layouts from malformed Favorite units")
    func splitLayoutReport() async throws {
        for favorite in [false,true] {
            let source = try ArcSplitImportTests().source(axis:favorite ? "unknown":"horizontal",favorite:favorite)
            defer { source.remove() }
            try FileManager.default.createDirectory(at:source.root.appending(path:"User Data/Default"),withIntermediateDirectories:true)
            let (session,store) = TestSession.make()
            defer { try? FileManager.default.removeItem(at:store.fileURL) }
            let name = "arc-split-report.\(UUID())",defaults = UserDefaults(suiteName:name)!
            defer { defaults.removePersistentDomain(forName:name) }
            let coordinator = ArcImportCoordinator(session:session,settings:Settings(defaults:defaults),
                downloads:DownloadManager(store:DownloadStore(fileURL:source.root.appending(path:"downloads.json"))),
                reportDirectory:source.root.appending(path:"reports"))
            var options = ArcImportOptions(profileIDs:["Default"])
            options.history = false;options.bookmarks = false;options.passwords = false
            options.cookies = false;options.localStorage = false;options.supplementary = false
            let report = try await coordinator.run(source,options:options)
            let profile = try #require(report.profiles.first)
            let count = try #require(profile.counts["Split layouts"])
            #expect(count.source == 1 && count.verified == (favorite ? 0:1))
            #expect(count.skipped == (favorite ? 1:0) && profile.notes.contains { $0.contains("Split-wide names") })
        }
    }
}
