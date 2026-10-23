import Foundation
import Testing
@testable import Barc

@Suite("Mixed sidebar ordering")
@MainActor
struct SidebarOrderTests {
    private func ids(_ session: BrowserSession) -> [UUID] {
        FolderRowPlan.rows(groups: session.activeSpace.groups, tabs: session.activeSpace.listedTabs, activeTabID: nil).map {
            switch $0 { case .folder(let group, _, _): group.id; case .tab(let tab, _, _): tab.id }
        }
    }

    @Test("Folders and retained tabs keep mixed order after saving and reopening")
    func roundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = Settings(defaults: UserDefaults(suiteName: "barc.tests.\(UUID().uuidString)")!)
        let store = SessionStore(fileURL: file)
        let session = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let ordinary = try #require(session.activeTab)
        let a = TabGroup(name: "First", sidebarPosition: 0)
        let b = TabGroup(name: "Last", sidebarPosition: 2)
        session.activeSpace.addGroup(a)
        session.activeSpace.addGroup(b)
        let retained = session.newTab(url: URL(string: "https://retained.invalid/")!, select: false)
        retained.setKeepsInSidebar(true)
        retained.sidebarPosition = 1
        // Even a stale rank cannot move an ordinary tab above the divider.
        ordinary.sidebarPosition = -10
        #expect(ids(session) == [a.id, retained.id, b.id, ordinary.id])
        session.saveNow()
        let restored = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let rows = FolderRowPlan.rows(groups: restored.activeSpace.groups, tabs: restored.activeSpace.listedTabs, activeTabID: nil)
        #expect(rows.map {
            switch $0 { case .folder(let group, _, _): group.name; case .tab(let tab, _, _): tab.url.host() ?? "new" }
        } == ["First", "retained.invalid", "Last", "start"])
    }

    @Test("Dragging a folder between retained tabs leaves ordinary tabs below it")
    func folderBetweenTabs() throws {
        let session = TestSession.make().0
        let ordinary = try #require(session.activeTab)
        let folder = TabGroup(name: "Work")
        session.activeSpace.addGroup(folder)
        let a = session.newTab(url: URL(string: "https://a.invalid/")!, select: false)
        let b = session.newTab(url: URL(string: "https://b.invalid/")!, select: false)
        a.setKeepsInSidebar(true)
        b.setKeepsInSidebar(true)
        session.positionSidebarItem(.folder(folder), before: .tab(b))
        #expect(ids(session) == [a.id, folder.id, b.id, ordinary.id])
        session.positionSidebarItem(.tab(b), before: .folder(folder))
        #expect(ids(session) == [a.id, b.id, folder.id, ordinary.id])
        session.positionSidebarItem(.folder(folder), before: nil)
        #expect(ids(session) == [a.id, b.id, folder.id, ordinary.id])
        session.positionSidebarItem(.tab(a), before: .tab(a))
        #expect(ids(session) == [a.id, b.id, folder.id, ordinary.id])
    }

    @Test("Crossing the divider changes retention and preserves the requested order")
    func crossingDivider() throws {
        let session = TestSession.make().0
        let ordinary = try #require(session.activeTab)
        let pinned = session.newTab(url: URL(string: "https://pin.invalid/")!, select: false)
        pinned.setKeepsInSidebar(true)
        session.positionSidebarItem(.tab(ordinary), before: .tab(pinned), retained: true)
        #expect(ordinary.keepsInSidebar)
        #expect(ids(session) == [ordinary.id, pinned.id])
        session.positionSidebarItem(.tab(ordinary), before: nil, retained: false)
        #expect(!ordinary.keepsInSidebar)
        #expect(ids(session) == [pinned.id, ordinary.id])
    }

    @Test("Saved order also interleaves nested folders with their sibling tabs")
    func nestedOrder() throws {
        let session = TestSession.make().0
        let root = TabGroup(name: "Root")
        let nested = TabGroup(name: "Nested", parentID: root.id, sidebarPosition: 2)
        let first = session.newTab(url: URL(string: "https://first.invalid/")!, select: false)
        first.setGroupID(root.id)
        first.sidebarPosition = 1
        let last = session.newTab(url: URL(string: "https://last.invalid/")!, select: false)
        last.setGroupID(root.id)
        last.sidebarPosition = 3
        let rows = FolderRowPlan.rows(groups: [root, nested], tabs: [last, first], activeTabID: nil)
        #expect(rows == [.folder(root, depth: 0, showsEscapedTab: false), .tab(first, depth: 1, isEscaping: false),
                         .folder(nested, depth: 1, showsEscapedTab: false), .tab(last, depth: 1, isEscaping: false)])
        root.isCollapsed = true
        #expect(FolderRowPlan.rows(groups: [root, nested], tabs: [last, first], activeTabID: nil).count == 1)
    }
}
