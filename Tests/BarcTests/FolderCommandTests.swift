// Modified for Barc: source-observed folder commands and navigation, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Arc folder commands", .serialized)
@MainActor
struct FolderCommandTests {
    @Test("A saved folder choice follows its query through case folding, serialization and bounded eviction")
    func savedQueryChoices() throws {
        let chosen = UUID(), another = UUID()
        var history = FolderCommandHistory()
        history.record(chosen,for:"  RÉSEARCH  ")
        history.record(another,for:"Planning")
        #expect(history.preferredFolder(for:"research") == chosen)
        #expect(history.preferredFolder(for:"Different query") == nil)
        let restored = try JSONDecoder().decode(FolderCommandHistory.self,from:JSONEncoder().encode(history))
        #expect(restored == history && restored.preferredFolder(for:"RESEARCH") == chosen)
        var bounded = FolderCommandHistory()
        for i in 0...FolderCommandHistory.maximumCount {
            bounded.record(chosen,for:"Query \(i)",at:Date(timeIntervalSinceReferenceDate:Double(i)))
        }
        #expect(bounded.count == FolderCommandHistory.maximumCount)
        #expect(bounded.preferredFolder(for:"Query 0") == nil)
        #expect(bounded.preferredFolder(for:"Query \(FolderCommandHistory.maximumCount)") == chosen)
        let unchanged = bounded
        bounded.record(another,for:"")
        bounded.record(another,for:String(repeating:"x",count:513))
        bounded.record(another,for:"Invalid date",at:Date(timeIntervalSinceReferenceDate:.infinity))
        #expect(bounded == unchanged)
    }

    @Test("A learned folder wins equal matches only for its recorded query")
    func learnedRanking() {
        let space = UUID(), a = UUID(), b = UUID()
        let folders = [FolderCandidate(id:a,spaceID:space,name:"Research",path:"A / Research"),
                       FolderCandidate(id:b,spaceID:space,name:"Research",path:"B / Research")]
        let search = SearchCandidate(engineName:"Fixture",url:URL(string:"https://search.invalid/?q=Research")!)
        #expect(CommandRanker.rank(query:"research",tabs:[],folders:folders,history:[]).first?.action == .openFolder(spaceID:space,folderID:a))
        let rows = CommandRanker.rank(query:"research",tabs:[],folders:folders,history:[],search:search,preferredFolderID:b)
        #expect(rows.map(\.kind) == [.folder,.search,.folder])
        #expect(rows.first?.action == .openFolder(spaceID:space,folderID:b))
        #expect(CommandRanker.rank(query:"unrelated",tabs:[],folders:folders,history:[],preferredFolderID:b).isEmpty)
    }

    @Test("The original query is saved to the originating profile before a cross-profile folder choice is restored")
    func originatingProfileChoice() async throws {
        let session = TestSession.make().0
        let origin = session.activeSpace
        let local = session.createGroup(named:"Research")
        let work = session.addSpace(named:"Work")
        let remote = session.createGroup(named:"Research")
        session.selectSpace(origin)
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let content = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:content).compactMap { $0 as? CommandBar }.first)
        let provider = try #require(bar.resultsProvider)
        let rows = await provider("research")
        let action = CommandAction.openFolder(spaceID:work.id,folderID:remote.id)
        bar.open(text:"research");bar.setResults(rows)
        bar.select(try #require(rows.firstIndex { $0.action == action }));bar.submit()
        #expect(bar.queryText.isEmpty && session.activeSpace === work)
        #expect(session.preferredFolderCommand(for:"RESEARCH",profile:origin.profile) == remote.id)
        #expect(session.preferredFolderCommand(for:"research",profile:work.profile) == nil)
        #expect(session.preferredFolderCommand(for:"another query",profile:origin.profile) == nil)
        session.selectSpace(origin)
        session.rememberFolderCommand(local,in:origin,query:"research",profile:origin.profile)
        let learned = await provider("Research")
        #expect(learned.first?.action == .openFolder(spaceID:origin.id,folderID:local.id))
        let saved = try JSONDecoder().decode(SessionSnapshot.self,from:JSONEncoder().encode(session.snapshot()))
        let restored = try #require(BrowserSession.spaces(from:saved)?.first { $0.id == origin.id })
        #expect(restored.profile.preferences.folderCommandHistory?.preferredFolder(for:"research") == local.id)
        session.clearHistory()
        #expect(session.preferredFolderCommand(for:"research",profile:origin.profile) == nil)
    }

    @Test("Private folder choices stay in memory and never enter a profile snapshot")
    func privateChoices() throws {
        let session = TestSession.make().0
        let ordinary = session.activeSpace
        let ordinaryFolder = session.createGroup(named:"Ordinary")
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let folder = session.createGroup(named:"Research")
        let query = "private-command-query-never-on-disk"
        session.rememberFolderCommand(folder,in:secret,query:query,profile:secret.profile)
        #expect(session.preferredFolderCommand(for:query,profile:secret.profile) == folder.id)
        #expect(secret.profile.preferences.folderCommandHistory == nil)
        let data = try JSONEncoder().encode(session.snapshot())
        #expect(!String(decoding:data,as:UTF8.self).contains(query))
        session.rememberFolderCommand(ordinaryFolder,in:ordinary,query:query,profile:secret.profile)
        #expect(session.preferredFolderCommand(for:query,profile:secret.profile) == folder.id)
        session.clearHistory()
        #expect(session.preferredFolderCommand(for:query,profile:secret.profile) == nil)
    }

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
        bar.onRun?(action,true,"Research")
        #expect(session.activeSpace === secret && hidden.isCollapsed)
        session.selectSpace(personal)
        work.removeGroup(child)
        bar.onRun?(action,true,"Research")
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
        #expect(plate.layer?.cornerRadius == 3 && label.lineBreakMode == .byTruncatingTail && plate.frame.height == 24)
        #expect(plate.frame.width > 20 && plate.convert(plate.bounds,to:row).maxX <= row.bounds.maxX)
        #expect(verb.frame.width > 20 && row.frame.height == 46)
        #expect(row.accessibilityLabel() == "Open \(path)")
        let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(icon.contentTintColor == .systemOrange)
        row.isSelected = false
        #expect(row.subviews.filter { !$0.isHidden && $0.layer?.cornerRadius == 4 }.count == 1)
        #expect(label.textColor == Style.Colors.secondaryText)
        #expect(row.hitTest(plate.convert(NSPoint(x:10,y:10),to:row)) === row)
        row.configure(.init(id:"page",kind:.history,title:"Page",subtitle:"fixture.invalid",symbolName:"globe",
            action:.openURL(URL(string:"https://fixture.invalid")!),score:1),compact:true)
        #expect(label.isHiddenOrHasHiddenAncestor)
        #expect(row.accessibilityLabel() == "Page, fixture.invalid")
    }
}
