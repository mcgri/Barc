// Modified for Barc: source-observed folder commands and navigation, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Arc folder commands", .serialized)
@MainActor
struct FolderCommandTests {
    @Test("Matching folder names expose distinct owning paths with search directly below the best match")
    func candidates() {
        let personal = UUID(), work = UUID(), a = UUID(), b = UUID()
        let folders = [FolderCandidate(id:a,spaceID:personal,name:"Research",path:"Personal / Research"),
                       FolderCandidate(id:b,spaceID:work,name:"Research",path:"Work / Project / Research")]
        let search = SearchCandidate(engineName:"Fixture",url:URL(string:"https://search.invalid/?q=Research")!)
        let results = CommandRanker.rank(query:"Research",tabs:[],folders:folders,history:[],search:search)
        #expect(results.map(\.kind) == [.folder,.search,.folder])
        #expect(Set(results.filter { $0.kind == .folder }.map(\.title)) ==
            ["Open Personal / Research","Open Work / Project / Research"])
        #expect(results.contains { $0.action == .openFolder(spaceID:work,folderID:b) })
        #expect(results.first?.completionText == "Research")
        let path = CommandRanker.rank(query:"Work / Project",tabs:[],folders:folders,history:[])
        #expect(path.first?.action == .openFolder(spaceID:work,folderID:b))
        var sources = CommandSources();sources.spaces = false
        #expect(CommandRanker.rank(query:"Research",tabs:[],folders:folders,history:[],sources:sources).isEmpty)
    }

    @Test("Opening expands ancestors and the pinned section without changing any selected page or tab identity")
    func nestedFolder() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let personalPage = session.newTab(url:URL(string:"https://fixture.invalid/personal")!)
        let work = session.addSpace(named:"Work")
        let workPage = session.newTab(url:URL(string:"https://fixture.invalid/work")!)
        let root = session.createGroup(named:"Project")
        let child = session.createGroup(named:"Research",parent:root)
        let other = session.createGroup(named:"Unrelated")
        for folder in [root,child,other] { folder.isCollapsed = true }
        work.look.pinnedSectionCollapsed = true
        session.selectSpace(personal)
        let ids = session.allTabs.map(\.id)
        #expect(session.openFolder(child,in:work))
        #expect(session.activeSpace === work && work.activeTab === workPage && personal.activeTab === personalPage)
        #expect(!root.isCollapsed && !child.isCollapsed && other.isCollapsed && !work.look.pinnedSectionCollapsed)
        #expect(session.allTabs.map(\.id) == ids)
        session.selectSpace(personal)
        #expect(!session.openFolder(child,in:personal) && session.activeSpace === personal)
        work.removeGroup(child)
        #expect(!session.openFolder(child,in:work) && session.activeSpace === personal)
    }

    @Test("The launcher opens a global folder in its own Space and rejects foreign private or stale destinations")
    func providerAndNavigation() async throws {
        let old = Settings.shared.openCommandBarOnNewTab
        Settings.shared.openCommandBarOnNewTab = true
        defer { Settings.shared.openCommandBarOnNewTab = old }
        let session = TestSession.make().0
        let personal = session.activeSpace
        let personalPage = session.newTab(url:URL(string:"https://fixture.invalid/personal")!)
        let work = session.addSpace(named:"Work")
        let workPage = session.newTab(url:URL(string:"https://fixture.invalid/work")!)
        let root = session.createGroup(named:"Project")
        let child = session.createGroup(named:"Research",parent:root)
        root.isCollapsed = true;child.isCollapsed = true
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let hidden = session.createGroup(named:"Research")
        hidden.isCollapsed = true
        session.selectSpace(personal)
        let count = session.allTabs.count
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let content = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:content).compactMap { $0 as? CommandBar }.first)
        let provider = try #require(bar.resultsProvider)
        let rows = await provider("Research")
        let action = CommandAction.openFolder(spaceID:work.id,folderID:child.id)
        #expect(rows.contains { $0.action == action && $0.title == "Open Work / Project / Research" })
        #expect(!rows.contains { $0.action == .openFolder(spaceID:secret.id,folderID:hidden.id) })
        controller.newTab(nil)
        bar.setResults(rows);bar.select(try #require(rows.firstIndex { $0.action == action }));bar.submit()
        #expect(!bar.isOpen && session.activeSpace === work && work.activeTab === workPage)
        #expect(personal.activeTab === personalPage && session.allTabs.count == count)
        #expect(!root.isCollapsed && !child.isCollapsed && hidden.isCollapsed)
        session.selectSpace(secret)
        let privateRows = await provider("Research")
        #expect(privateRows.contains { $0.action == .openFolder(spaceID:secret.id,folderID:hidden.id) })
        #expect(!privateRows.contains { $0.action == action })
        bar.onRun?(action,true)
        #expect(session.activeSpace === secret && hidden.isCollapsed)
        session.selectSpace(personal)
        work.removeGroup(child)
        bar.onRun?(action,true)
        #expect(session.activeSpace === personal && session.allTabs.count == count)
    }

    @Test("Folder paths form a separate truncating chip and selected symbols stay visible on their white plate")
    func folderRow() throws {
        let host = NSView(frame:NSRect(x:0,y:0,width:350,height:46))
        let row = CommandRowView();host.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo:host.trailingAnchor),row.topAnchor.constraint(equalTo:host.topAnchor)])
        let path = "Work / Project / Research with a long name"
        row.configure(.init(id:"folder",kind:.folder,title:"Open \(path)",subtitle:path,symbolName:"folder",
            action:.openFolder(spaceID:UUID(),folderID:UUID()),score:1),compact:true)
        row.selectionColor = .systemOrange;row.isSelected = true
        host.layoutSubtreeIfNeeded()
        let fields = UITestSupport.descendants(of:row).compactMap { $0 as? NSTextField }
        let verb = try #require(fields.first { $0.stringValue == "Open" })
        let label = try #require(fields.first { $0.stringValue == path && !$0.isHiddenOrHasHiddenAncestor })
        let plate = try #require(label.superview)
        #expect(plate.layer?.cornerRadius == 3 && label.lineBreakMode == .byTruncatingTail)
        #expect(plate.frame.width > 20 && plate.convert(plate.bounds,to:row).maxX <= row.bounds.maxX)
        #expect(verb.frame.width > 20 && row.frame.height == 46)
        #expect(row.accessibilityLabel() == "Open \(path)")
        let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(icon.contentTintColor == .systemOrange)
        #expect(row.hitTest(plate.convert(NSPoint(x:10,y:10),to:row)) === row)
        row.configure(.init(id:"page",kind:.history,title:"Page",subtitle:"fixture.invalid",symbolName:"globe",
            action:.openURL(URL(string:"https://fixture.invalid")!),score:1),compact:true)
        #expect(label.isHiddenOrHasHiddenAncestor)
        #expect(row.accessibilityLabel() == "Page, fixture.invalid")
    }
}
