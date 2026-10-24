// Modified for Barc: split archive and restoration continuity, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Archived split groups", .serialized)
@MainActor
struct SplitArchiveTests {
    private func tab(_ name:String, in session:BrowserSession) -> Tab {
        let page = session.newTab(url:URL(string:"https://split-archive.invalid/\(name)")!)
        session.rename(page,to:name)
        return page
    }
    private func reopen(_ store:SessionStore) -> BrowserSession {
        let settings = Settings(defaults:UserDefaults(suiteName:"split.archive.\(UUID())")!)
        settings.restoresSession = true
        return BrowserSession(database:nil,sessionStore:store,settings:settings)
    }

    @Test("A complete split occupies one archive row and returns with sizes, focus and sticky pane after reopening")
    func completeRoundTrip() throws {
        let (session,store) = TestSession.make()
        let a = tab("Left",in:session), b = tab("Right",in:session)
        session.splitTabs([a,b],grid:.sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at:[],to:[0.7,0.3]))
        session.selectTab(b); session.toggleStickPane(a.id)
        let groupID = try #require(session.activeSpace.splits.identifier(containing:a.id))
        session.archive([b,a,b])
        #expect(session.archivedTabs.count == 1)
        #expect(session.splitCohorts.isEmpty)
        session.saveNow()
        let restored = reopen(store)
        let record = try #require(restored.archivedTabs.first)
        #expect(record.title.contains("Left") && record.title.contains("Right"))
        let selected = try #require(restored.restoreArchived(record))
        #expect(selected.customName == "Right")
        let split = try #require(restored.activeSplit)
        let pages = split.tabIDs.compactMap { id in restored.activeSpace.tabs.first { $0.id == id } }
        #expect(pages.map(\.customName) == ["Left","Right"])
        #expect(abs((split.unitFrames()[pages[0].id]?.width ?? 0)-0.7)<0.0000001)
        #expect(restored.isSticky(pages[0].id))
        #expect(restored.activeSpace.splits.identifier(containing:pages[0].id) == groupID)
        #expect(restored.archivedTabs.isEmpty)
    }

    @Test("Grid panes with duplicate URLs retain distinct names, icons, folders and nested proportions")
    func gridAndDuplicateURLs() throws {
        let session = TestSession.make().0
        let pages = (0..<4).map { tab("Page \($0)",in:session) }
        for page in pages { page.load(URL(string:"https://same.invalid/")!) }
        let folder = session.createGroup(named:"Research",containing:pages)
        pages[0].setSidebarIcon(.symbol("ionicon.planet"))
        pages[1].setSidebarIcon(.emoji("🪐"))
        session.splitTabs(pages,grid:.grid)
        let layout = try #require(session.activeSplit).settingShares(at:[],to:[0.65,0.35])
            .settingShares(at:[0],to:[0.4,0.6])
        session.updateSplitLayout(layout)
        session.selectTab(pages[2])
        let before = layout.unitFrames()
        let saved = pages.map { $0.snapshot() }
        session.archive(Array(pages.reversed()))
        let restored = session.restoreAllArchived(in:session.activeSpace)
        #expect(restored.map(\.customName) == saved.map(\.customName))
        for (page,snapshot) in zip(restored,saved) {
            #expect(page.groupID == folder.id && page.keepsInSidebar == (snapshot.keepsInSidebar ?? false) && page.url == snapshot.url)
            #expect(page.sidebarSymbolName == snapshot.sidebarSymbolName && page.emoji == snapshot.emoji)
        }
        #expect(session.activeTab === restored[2])
        let split = try #require(session.activeSplit)
        for (old,new) in zip(pages,restored) { #expect(before[old.id] == split.unitFrames()[new.id]) }
    }

    @Test("Restoring independent groups into their owner preserves unrelated active sticky layouts")
    func restoreAllGroupsAndOwners() throws {
        let session = TestSession.make().0, owner = session.activeSpace
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b]);session.selectTab(b)
        let c = tab("c",in:session), d = tab("d",in:session)
        session.splitTabs([c,d],grid:.stacked);session.selectTab(d)
        session.archive([a,b,c,d])
        let x = tab("x",in:session), y = tab("y",in:session)
        session.splitTabs([x,y]);session.toggleStickPane(x.id)
        let unrelated = try #require(session.activeSplit)
        let other = session.addSpace(named:"Elsewhere")
        let elsewhere = tab("elsewhere",in:session)
        session.archive([elsewhere])
        let restored = session.restoreAllArchived(in:owner)
        #expect(restored.map(\.customName) == ["a","b","c","d"])
        #expect(session.activeSpace === owner && session.activeTab?.customName == "d")
        #expect(owner.splits.layouts.count == 3 && owner.splits.layout(containing:x.id) == unrelated)
        #expect(owner.splits.stickyTabIDs.contains(x.id))
        #expect(session.archivedTabs(in:owner).isEmpty && session.archivedTabs(in:other).count == 1)
        #expect(!other.tabs.contains { page in restored.contains { $0 === page } })
    }

    @Test("An older toast undoes only its own archive batch, including a split as one entry")
    func undoIdentity() throws {
        let session = TestSession.make().0
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b]);session.selectTab(b)
        var toasts:[Toast] = [];session.showToast = { toasts.append($0) }
        session.archive([a,b])
        let c = tab("later",in:session)
        session.archive([c])
        try #require(toasts.first?.action).handler()
        #expect(session.activeSplit?.paneCount == 2 && session.activeTab?.customName == "b")
        #expect(session.archivedTabs.map(\.snapshot.customName) == ["later"])
        try #require(toasts.first?.action).handler()
        #expect(session.activeSpace.tabs.filter { $0.customName == "a" || $0.customName == "b" }.count == 2)
        #expect(session.archivedTabs.count == 1)
    }

    @Test("Partial explicit pane archival leaves the other pane available and restores without inventing a group")
    func partialPane() throws {
        let session = TestSession.make().0
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b])
        session.archive([b])
        #expect(session.activeSpace.tabs.contains { $0 === a })
        #expect(!session.activeSpace.tabs.contains { $0 === b })
        let record = try #require(session.archivedTabs.first)
        let restored = try #require(session.restoreArchived(record))
        #expect(restored.customName == "b" && session.splitCohorts.isEmpty)
    }

    @Test("Invalid archived split slots keep every page, and old single-page records still restore")
    func malformedAndLegacy() throws {
        let session = TestSession.make().0
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b]);session.archive([a,b])
        var snapshot = session.snapshot()
        snapshot.spaces[0].archivedTabs?[0].split?.tabIndices = [0,0]
        let legacy = SessionSnapshot.Archived(tab:.init(url:URL(string:"https://legacy.invalid/")!,title:"Legacy"),archivedAt:.now)
        let legacyJSON = try JSONEncoder().encode(legacy)
        #expect(!String(decoding:legacyJSON,as:UTF8.self).contains("additionalTabs"))
        snapshot.spaces[0].archivedTabs?.append(try JSONDecoder().decode(SessionSnapshot.Archived.self,from:legacyJSON))
        let replacement = TestSession.make().0
        replacement.archive([tab("discarded-old-session",in:replacement)])
        replacement.replaceWithSnapshot(snapshot)
        let restored = replacement.restoreAllArchived(in:replacement.activeSpace)
        #expect(restored.map(\.customName).prefix(2) == ["a","b"])
        #expect(restored.count == 3 && replacement.splitCohorts.isEmpty)
        #expect(replacement.archivedTabs.isEmpty)
        #expect(!replacement.activeSpace.tabs.contains { $0.customName == "discarded-old-session" })
    }

    @Test("Today archive actions count complete visible rows and protect a row if any pane is locked or playing")
    func sidebarScopes() throws {
        let session = TestSession.make().0, owner = session.activeSpace
        let above = tab("above",in:session)
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b])
        let below = tab("below",in:session)
        #expect(session.sidebarArchiveCandidates(relativeTo:b,in:owner,scope:.tab).map(\.id) == [a.id,b.id])
        #expect(session.sidebarArchiveCandidates(relativeTo:b,in:owner,scope:.other).map(\.id) == [above.id,below.id])
        #expect(session.sidebarArchiveCandidates(relativeTo:a,in:owner,scope:.above).map(\.id) == [above.id])
        #expect(session.sidebarArchiveCandidates(relativeTo:a,in:owner,scope:.below).map(\.id) == [below.id])
        a.setLocked(true)
        #expect(session.sidebarArchiveCandidates(relativeTo:b,in:owner,scope:.tab).isEmpty)
        a.setLocked(false)
        a.setMediaState(isPlaying:true,hasAudio:true,hasVideo:false,isMuted:false,title:"",artist:"")
        #expect(session.sidebarArchiveCandidates(relativeTo:above,in:owner,scope:.below).map(\.id) == [below.id])
        session.archiveSidebarTabs(relativeTo:b,in:owner,scope:.tab)
        #expect(session.archivedTabs.count == 1 && session.archivedTabs[0].snapshots.count == 2)
    }

    @Test("Private sidebar splits close together without recording any page or layout")
    func privateSidebar() throws {
        let (session,store) = TestSession.make()
        let owner = session.addSpace(named:"Private",isPrivate:true)
        let a = tab("private-a",in:session), b = tab("private-b",in:session)
        session.splitTabs([a,b])
        session.archive([a,b])
        #expect(owner.tabs.contains { $0 === a } && session.archivedTabs.isEmpty)
        session.archiveSidebarTabs(relativeTo:a,in:owner,scope:.tab)
        #expect(owner.tabs.allSatisfy { $0 !== a && $0 !== b } && session.archivedTabs.isEmpty)
        session.saveNow()
        #expect(!(try String(contentsOf:store.fileURL,encoding:.utf8)).contains("private-a"))
    }

    @Test("The native archive presents one restorable row and exposes every pane to accessibility")
    func nativeArchiveRow() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let a = tab("Left",in:session), b = tab("Right",in:session)
        session.splitTabs([a,b]);session.archive([a,b])
        let record = try #require(session.archivedTabs.first)
        let list = ArchiveListView()
        list.show([.init(record:record,spaceName:nil)],isArchivingEnabled:true)
        list.onRestore = { session.restoreArchived($0) }
        let table = try #require(UITestSupport.descendants(of:list).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 1)
        let cell = try #require(list.tableView(table,viewFor:table.tableColumns.first,row:0) as? ArchivedRowView)
        #expect(cell.accessibilityLabel()?.contains("Split View, 2 tabs") == true)
        #expect(cell.accessibilityLabel()?.contains("Left") == true && cell.accessibilityLabel()?.contains("Right") == true)
        #expect(cell.toolTip?.components(separatedBy:"\n").count == 2)
        #expect(cell.accessibilityPerformPress())
        #expect(session.activeSplit?.paneCount == 2 && session.archivedTabs.isEmpty)
        let sidebar = SidebarViewController(session:session)
        _ = UITestSupport.host(sidebar.view,width:228,height:760)
        #expect(sidebar.tabListTableView.numberOfRows == 2)
        let selectedRow = sidebar.tabListTableView.selectedRow
        let splitRow = try #require(sidebar.tabListTableView.view(atColumn:0,row:selectedRow,makeIfNecessary:true) as? SplitRowView)
        #expect(splitRow.members.count == 2 && sidebar.selectedTabs.count == 2)
    }

    @Test("The archive limit evicts complete entries and Undo cannot resurrect an unrelated older entry")
    func archiveLimit() throws {
        let session = TestSession.make().0
        let old = (0..<500).map { tab("old-\($0)",in:session) }
        session.archive(old)
        let a = tab("left",in:session), b = tab("right",in:session)
        session.splitTabs([a,b])
        var toast:Toast?;session.showToast = { toast = $0 }
        session.archive([a,b])
        #expect(session.archivedTabs.count == 500)
        #expect(session.archivedTabs.first?.title == "old-1")
        #expect(session.archivedTabs.last?.snapshots.count == 2)
        try #require(toast?.action).handler()
        #expect(session.archivedTabs.count == 499 && session.activeSplit?.paneCount == 2)
    }

    @Test("The automatic archive policy passes a whole stale split through to a restorable arrangement")
    func automaticCohort() throws {
        let session = TestSession.make().0
        let a = tab("a",in:session), b = tab("b",in:session)
        session.splitTabs([a,b])
        _ = tab("visible",in:session)
        a.backdateLastActive(by:3*86400);b.backdateLastActive(by:3*86400)
        let candidates = TabArchiving.candidates(among:session.allTabs,protecting:session.visibleTabIDs,
            threshold:86400,cohorts:session.splitCohorts)
        #expect(Set(candidates.map(\.id)) == Set([a.id,b.id]))
        session.archive(candidates)
        #expect(session.archivedTabs.count == 1)
        let record = try #require(session.archivedTabs.first)
        #expect(session.restoreArchived(record) != nil && session.activeSplit?.paneCount == 2)
    }

    @Test("Repeating an import cannot reopen the non-leading members of an archived split")
    func repeatedImport() throws {
        let session = TestSession.make().0
        var incoming = session.snapshot().spaces[0]
        incoming.tabs = ["a","b"].map { (name:String) in
            SessionSnapshot.Tab(url:URL(string:"https://split-archive.invalid/\(name)")!,title:name,
                                importedSourceID:"fixture/\(name)")
        }
        _ = try session.applyArcSpaces([incoming])
        let pages = session.activeSpace.tabs.filter { $0.importedSourceID != nil }
        #expect(pages.count == 2)
        session.splitTabs(pages);session.archive(pages)
        let result = try session.applyArcSpaces([incoming])
        #expect(result.tabs == 0 && session.archivedTabs.count == 1)
        #expect(!session.activeSpace.tabs.contains { $0.importedSourceID != nil })
        let restored = session.restoreAllArchived(in:session.activeSpace)
        #expect(Set(restored.compactMap(\.importedSourceID)) == Set(["fixture/a","fixture/b"]))
        #expect(session.activeSplit?.paneCount == 2)
    }

    @Test("A deleted folder cannot hide any restored pane")
    func deletedFolder() throws {
        let session = TestSession.make().0
        let a = tab("a",in:session), b = tab("b",in:session)
        let folder = session.createGroup(named:"Gone",containing:[a,b])
        session.splitTabs([a,b]);session.archive([a,b])
        _ = session.removeGroup(folder)
        let restored = session.restoreAllArchived(in:session.activeSpace)
        #expect(restored.count == 2 && restored.allSatisfy { $0.groupID == nil })
        #expect(session.activeSplit?.paneCount == 2)
    }

    @Test("Overlapping arrangements containing a shared Favorite never archive the same page twice")
    func overlappingSharedFavorite() throws {
        let session = TestSession.make().0, first = session.activeSpace
        let favorite = tab("shared",in:session);session.pin(favorite)
        let a = tab("a",in:session);session.splitTabs([a,favorite])
        let second = session.addSpace(named:"Sibling",profile:first.profile)
        let b = tab("b",in:session);session.splitTabs([b,favorite])
        session.archive([a,favorite,b])
        let snapshots = session.archivedTabs.flatMap(\.snapshots)
        #expect(snapshots.count == 3)
        #expect(snapshots.filter { $0.url == favorite.url }.count == 1)
        #expect(session.archivedTabs(in:first).count == 1 && session.archivedTabs(in:second).count == 1)
    }
}
