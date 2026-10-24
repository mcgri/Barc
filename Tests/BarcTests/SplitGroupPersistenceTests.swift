// Modified for Barc: independent split groups and durable profile-safe layouts, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Independent split groups and session restoration", .serialized)
@MainActor
struct SplitGroupPersistenceTests {
    private func tab(_ name: String, in session: BrowserSession) -> Tab {
        session.newTab(url: URL(string: "https://split-groups.invalid/\(name)")!)
    }
    private func reopen(_ store: SessionStore) -> BrowserSession {
        let settings = Settings(defaults: UserDefaults(suiteName: "split.restore.\(UUID())")!)
        settings.restoresSession = true
        return BrowserSession(database: nil, sessionStore: store, settings: settings)
    }

    @Test("Creating a second split preserves the first, including each layout's proportions")
    func independentGroups() throws {
        let session = TestSession.make().0
        let a = tab("a", in: session), b = tab("b", in: session)
        let c = tab("c", in: session), d = tab("d", in: session)
        #expect(session.splitTabs([a,b], grid: .sideBySide))
        let first = try #require(session.activeSplit).settingShares(at: [], to: [0.7,0.3])
        session.updateSplitLayout(first)
        session.selectTab(c)
        #expect(session.splitTabs([c,d], grid: .stacked))
        let second = try #require(session.activeSplit)
        session.selectTab(a)
        #expect(session.activeSplit == first)
        #expect(session.visibleTabIDs == Set([a.id,b.id]))
        session.selectTab(c)
        #expect(session.activeSplit == second)
        #expect(Set(session.splitCohorts) == Set([Set([a.id,b.id]),Set([c.id,d.id])]))
        session.unsplit()
        #expect(session.activeSplit == nil)
        session.selectTab(a)
        #expect(session.activeSplit == first)
    }

    @Test("The saved file restores both groups, selected page, geometry and sticky pane")
    func persistedGroups() throws {
        let (session, store) = TestSession.make()
        let a = tab("a", in: session), b = tab("b", in: session)
        let c = tab("c", in: session), d = tab("d", in: session)
        session.splitTabs([a,b], grid: .sideBySide)
        session.updateSplitLayout(try #require(session.activeSplit).settingShares(at: [], to: [0.7,0.3]))
        session.selectTab(c)
        session.splitTabs([c,d], grid: .stacked)
        session.selectTab(a)
        session.toggleStickPane(a.id)
        session.selectTab(d)
        session.saveNow()
        let restored = reopen(store)
        #expect(restored.activeTab?.url == d.url)
        #expect(restored.activeSplit?.grid == .stacked)
        #expect(restored.activeSplit?.tabIDs.count == 2)
        let restoredA = try #require(restored.activeSpace.tabs.first { $0.url == a.url })
        restored.selectTab(restoredA)
        let first = try #require(restored.activeSplit)
        #expect(first.grid == .sideBySide && first.tabIDs.count == 2)
        #expect(abs((first.unitFrames()[restoredA.id]?.width ?? 0)-0.7) < 0.00000001)
        #expect(restored.isSticky(restoredA.id))
    }

    @Test("Split undo and redo restore every group without replacing unrelated layouts")
    func undoGroups() throws {
        let session = TestSession.make().0
        let a = tab("a", in: session), b = tab("b", in: session)
        let c = tab("c", in: session), d = tab("d", in: session)
        session.splitTabs([a,b])
        session.splitTabs([c,d])
        session.unsplit()
        session.undoSplit()
        #expect(session.activeSplit?.tabIDs == [c.id,d.id])
        session.selectTab(a)
        #expect(session.activeSplit?.tabIDs == [a.id,b.id])
        session.undoSplit()
        session.selectTab(c)
        #expect(session.activeSplit == nil)
        session.selectTab(a)
        #expect(session.activeSplit?.tabIDs == [a.id,b.id])
    }

    @Test("A split refuses tabs from another Space, even when that Space shares a profile")
    func ownerValidation() throws {
        let session = TestSession.make().0
        let owner = session.activeSpace
        let a = tab("a", in: session), b = tab("b", in: session)
        session.splitTabs([a,b])
        let first = session.activeSplit
        let elsewhere = session.addSpace(named: "Same profile", profile: owner.profile)
        let foreign = tab("foreign", in: session)
        session.selectSpace(owner)
        #expect(!session.splitTabs([a,foreign]))
        #expect(session.activeSplit == first && elsewhere.tabs.contains { $0 === foreign })
    }

    @Test("Closing a member in a background split leaves the active independent group intact")
    func closeBackgroundMember() throws {
        let session = TestSession.make().0
        let a = tab("a", in: session), b = tab("b", in: session)
        let c = tab("c", in: session), d = tab("d", in: session)
        session.splitTabs([a,b]); session.splitTabs([c,d])
        let active = session.activeSplit
        session.closeTab(a)
        #expect(session.activeSplit == active && session.activeTab === c)
        #expect(session.splitCohorts == [Set([c.id,d.id])])
        session.selectTab(b)
        #expect(session.activeSplit == nil)
    }

    @Test("Joining groups over the pane limit refuses atomically and keeps both groups usable")
    func overLimitIsAtomic() throws {
        let session = TestSession.make().0
        let pages = (0..<6).map { tab("page-\($0)", in: session) }
        session.splitTabs(Array(pages[0..<3]))
        session.splitTabs(Array(pages[3..<6]), grid: .stacked)
        let before = session.splitGroups(in: session.activeSpace)
        #expect(!session.splitTabs([pages[0],pages[3]]))
        #expect(session.splitGroups(in: session.activeSpace) == before)
        #expect(session.activeSplit?.tabIDs == Array(pages[3..<6]).map(\.id))
        session.selectTab(pages[0])
        #expect(session.activeSplit?.tabIDs == Array(pages[0..<3]).map(\.id))
    }

    @Test("Saved slots keep duplicate URLs distinct, and malformed groups do not discard good groups")
    func restoredSlots() throws {
        let session = TestSession.make().0
        let pages = (0..<4).map { _ in tab("same-url", in: session) }
        for (index,page) in pages.enumerated() { session.rename(page, to: "Page \(index)") }
        session.splitTabs(Array(pages.prefix(2)))
        session.splitTabs(Array(pages.suffix(2)), grid: .stacked)
        var snapshot = session.snapshot()
        let first = try #require(snapshot.spaces[0].splits?.first)
        let second = try #require(snapshot.spaces[0].splits?.last)
        var bad = first; bad.tabIndices = [-1,999]
        var duplicateSlots = first; duplicateSlots.tabIndices = [0,0]
        let encoded = String(decoding: try JSONEncoder().encode(first.layout), as: UTF8.self)
        let corrupt = try JSONDecoder().decode(SplitLayout.self, from: Data(encoded.replacingOccurrences(of:"\"share\":0.5", with:"\"share\":-0.5").utf8))
        var invalidGeometry = first; invalidGeometry.layout = corrupt
        snapshot.spaces[0].splits = [bad,duplicateSlots,invalidGeometry,first,first,second]
        let restored = TestSession.make().0
        restored.replaceWithSnapshot(snapshot)
        let groups = restored.splitGroups(in: restored.activeSpace)
        #expect(groups.count == 2 && groups[0].grid == .grid && groups[1].grid == .stacked)
        let names = groups.map { layout in layout.tabIDs.compactMap { id in restored.activeSpace.tabs.first { $0.id == id }?.customName } }
        #expect(names == [["Page 0","Page 1"],["Page 2","Page 3"]])
    }

    @Test("Private split browsing stays in memory and leaves no saved URLs or layout metadata")
    func privateGroups() throws {
        let (session,store) = TestSession.make()
        let privateSpace = session.addSpace(named:"Private",isPrivate:true)
        let a = tab("secret-split-a",in:session), b = tab("secret-split-b",in:session)
        session.splitTabs([a,b])
        #expect(session.activeSplit != nil)
        session.saveNow()
        let stored = try #require(store.load()?.spaces.first { $0.id == privateSpace.id })
        #expect(stored.tabs.isEmpty && stored.splits == nil)
        #expect(!(try String(contentsOf:store.fileURL,encoding:.utf8)).contains("secret-split"))
        let restored = reopen(store)
        #expect(restored.activeSpace.isPrivate && restored.activeSplit == nil)
    }


    @Test("A shared Favorite restores into both Space layouts and closing it repairs both groups")
    func sharedFavoriteGroups() throws {
        let (session,store) = TestSession.make()
        let firstSpace = session.activeSpace
        let favorite = tab("shared-favorite",in:session)
        session.pin(favorite)
        let a = tab("a",in:session)
        session.splitTabs([a,favorite])
        let secondSpace = session.addSpace(named:"Sibling",profile:firstSpace.profile)
        let b = tab("b",in:session)
        session.splitTabs([b,favorite],grid:.stacked)
        session.saveNow()
        let restored = reopen(store)
        let restoredFavorite = try #require(restored.activeSpace.tabs.first { $0.url == favorite.url })
        #expect(restored.spaces[0].profile === restored.spaces[1].profile)
        #expect(restored.splitGroups(in:restored.spaces[0]).first?.contains(restoredFavorite.id) == true)
        #expect(restored.splitGroups(in:restored.spaces[1]).first?.contains(restoredFavorite.id) == true)
        restored.closeTab(restoredFavorite)
        #expect(restored.splitCohorts.isEmpty)
        #expect(restored.spaces.allSatisfy { !$0.tabs.contains { $0 === restoredFavorite } })
        #expect(session.activeSpace === secondSpace && session.splitCohorts.count == 2)
    }

    @Test("Native content switches between restored groups without showing panes from the other group")
    func nativeContentGroups() throws {
        _ = NSApplication.shared
        let (session,store) = TestSession.make()
        let a = tab("a",in:session), b = tab("b",in:session)
        let c = tab("c",in:session), d = tab("d",in:session)
        session.splitTabs([a,b],grid:.sideBySide)
        session.splitTabs([c,d],grid:.stacked)
        session.saveNow()
        let restored = reopen(store)
        let controller = BrowserWindowController(session:restored)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        let container = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? SplitContainerView }.first)
        let restoredPages = try [a,b,c,d].map { original in try #require(restored.activeSpace.tabs.first { $0.url == original.url }) }
        #expect(container.paneView(for:restoredPages[2].id) != nil && container.paneView(for:restoredPages[3].id) != nil)
        #expect(container.paneView(for:restoredPages[0].id) == nil && container.paneView(for:restoredPages[1].id) == nil)
        restored.selectTab(restoredPages[0])
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        #expect(container.paneView(for:restoredPages[0].id) != nil && container.paneView(for:restoredPages[1].id) != nil)
        #expect(container.paneView(for:restoredPages[2].id) == nil && container.paneView(for:restoredPages[3].id) == nil)
        let first = try #require(container.paneView(for:restoredPages[0].id))
        let second = try #require(container.paneView(for:restoredPages[1].id))
        let left = first.convert(first.bounds,to:container), right = second.convert(second.bounds,to:container)
        #expect(left.maxX <= right.minX && abs(left.midY-right.midY)<0.5)
    }

}
