// Modified for Barc: source-observed launcher recents and keyboard preview contracts, 2026-10-24.
import AppKit
import Testing
@testable import Barc

@Suite("Arc launcher keyboard", .serialized)
@MainActor
struct LauncherKeyboardTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1400,height:900),
            styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func publishEdit(_ bar: CommandBar, editor: NSTextView) throws {
        let field = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        // Programmatic editor input does not always publish its control value
        // when another test window is key. Supply the same editing notification.
        field.stringValue = editor.string
        bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
    }

    @Test("An unvisited address has a direct row and a separate literal search choice")
    func directAddress() throws {
        let query = "example.invalid"
        let search = SearchCandidate(engineName:"Fixture",url:URL(string:"https://search.invalid/?q=example.invalid")!)
        let rows = CommandRanker.rank(query:query,tabs:[],history:[],search:search)
        #expect(rows.count == 2 && rows.first?.kind == .address && rows.last?.kind == .search)
        #expect(rows.map(\.title) == [query,query])
        #expect(rows.first?.action == .openURL(URL(string:"https://example.invalid")!))
        #expect(rows.last?.action == .openURL(search.url))
        #expect(rows.allSatisfy { $0.completionText == query })
        #expect(URLResolver.navigationURL("words to search") == nil)
        #expect(URLResolver.navigationURL("localhost:8080/path") == URL(string:"http://localhost:8080/path"))
        let tabID = UUID()
        let same = CommandRanker.rank(query:query,tabs:[.init(id:tabID,title:"Existing",address:query,
            url:URL(string:"https://example.invalid/")!,isActive:false)],history:[],search:search)
        #expect(same.filter { $0.kind == .address }.isEmpty)
        #expect(same.first?.action == .switchToTab(tabID))
    }

    @Test("Web completion removes display-only prefixes while keeping explicit schemes, ports, paths and encoded hosts")
    func completionFormatting() {
        let root = URL(string:"https://www.portal.example/")!
        #expect(AddressFormatter.completion(root) == "portal.example")
        #expect(AddressFormatter.completion(root,matching:"portal") == "portal.example")
        #expect(AddressFormatter.completion(root,matching:"www.portal") == "www.portal.example")
        #expect(AddressFormatter.completion(root,matching:"https://www.portal") == root.absoluteString)
        #expect(AddressFormatter.completion(root,matching:"portal.example/") == "portal.example/")
        #expect(AddressFormatter.completion(URL(string:"http://localhost:1000/path?q=1#part")!) == "localhost:1000/path?q=1#part")
        #expect(AddressFormatter.completion(URL(string:"https://www.xn--nave-6pa.com/path")!) == "xn--nave-6pa.com/path")
        #expect(AddressFormatter.completion(URL(string:"https://www.example.invalid/?q=1")!) == "example.invalid/?q=1")
        #expect(AddressFormatter.completion(URL(string:"file:///tmp/report.pdf")!) == "file:///tmp/report.pdf")
    }

    @Test("Arrow previews retain the typed prefix, wrap, and never requery until the user edits", .timeLimit(.minutes(1)))
    func completionAndWrapping() async throws {
        let window = window(); defer { window.close() }
        let bar = CommandBar(); bar.install(in:try #require(window.contentView))
        let id = UUID()
        let rows = CommandRanker.rank(query:"portal",tabs:[.init(id:id,title:"A matching tab",
            address:"www.portal.example/",url:URL(string:"https://www.portal.example/")!,isActive:false)],history:[],
            search:.init(engineName:"Fixture",url:URL(string:"https://search.invalid/?q=portal")!))
        var calls = [String]()
        let (arrivals, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var iterator = arrivals.makeAsyncIterator()
        bar.resultsProvider = { query in
            calls.append(query)
            continuation.yield(())
            return rows
        }
        bar.openNewTab(recentResults:[])
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("portal",replacementRange:NSRange(location:NSNotFound,length:0))
        // Drive the editing delegate explicitly: other native-window suites
        // can change application focus while this fixture waits asynchronously.
        try publishEdit(bar,editor:editor)
        _ = await iterator.next()
        await Task.yield()
        try #require(!bar.visibleResults.isEmpty)
        #expect(bar.selectedIndex == 0 && bar.queryText == "portal.example")
        #expect(editor.selectedRange() == NSRange(location:6,length:8))
        #expect(calls == ["portal"])
        bar.moveSelection(by:1)
        #expect(bar.selectedIndex == 1 && bar.queryText == "portal")
        #expect(editor.selectedRange() == NSRange(location:6,length:0))
        bar.moveSelection(by:1)
        #expect(bar.selectedIndex == 0 && bar.queryText == "portal.example")
        bar.moveSelection(by:-1)
        #expect(bar.selectedIndex == 1 && bar.queryText == "portal")
        bar.moveSelection(by:-1)
        #expect(bar.selectedIndex == 0 && editor.selectedRange() == NSRange(location:6,length:8))
        #expect(calls == ["portal"] && bar.visibleResults == rows)
        editor.insertText("app",replacementRange:NSRange(location:NSNotFound,length:0))
        try publishEdit(bar,editor:editor)
        #expect(bar.queryText == "portalapp" && bar.visibleResults.isEmpty && bar.selectedIndex == nil)
        bar.close()
        try await Task.sleep(for:.milliseconds(120))
        #expect(calls == ["portal"], "Closing cancels the pending request for the new text")
    }

    @Test("Automatic title matches keep the query; explicit navigation previews the URL", .timeLimit(.minutes(1)),
          arguments:["new", "location", "address", "split"])
    func titleOnlyPreview(mode:String) async throws {
        let window = window();defer { window.close() }
        let root = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:root)
        let query = "Project Notes"
        let url = URL(string:"https://docs.invalid/document/123")!
        let rows = [CommandResult(id:"document",kind:.history,title:query,subtitle:"docs.invalid/document/123",symbolName:"globe",
                        action:.openURL(url),score:100,completionText:"docs.invalid/document/123"),
                    CommandResult(id:"search",kind:.search,title:query,subtitle:"",symbolName:"magnifyingglass",
                        action:.openURL(URL(string:"https://search.invalid/?q=notes")!),score:0,completionText:query)]
        let (arrivals,continuation) = AsyncStream<Void>.makeStream();defer { continuation.finish() }
        var iterator = arrivals.makeAsyncIterator(), calls = [String]()
        bar.resultsProvider = { text in calls.append(text);continuation.yield(());return rows }
        let anchor = NSView(frame:NSRect(x:8,y:800,width:220,height:36));root.addSubview(anchor)
        switch mode {
        case "location":bar.openLocation(text:"https://current.invalid/",suggestions:[])
        case "address":bar.openAddress(text:"https://current.invalid/",anchor:anchor)
        case "split":bar.openSplit(recentResults:[])
        default:bar.openNewTab(recentResults:[])
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText(query,replacementRange:NSRange(location:NSNotFound,length:0));try publishEdit(bar,editor:editor)
        _ = await iterator.next();await Task.yield()
        try #require(bar.visibleResults == rows)
        #expect(bar.selectedIndex == 0 && bar.queryText == query)
        #expect(editor.selectedRange() == NSRange(location:(query as NSString).length,length:0))
        bar.moveSelection(by:1);bar.moveSelection(by:-1)
        #expect(bar.queryText == "docs.invalid/document/123")
        #expect(editor.selectedRange() == NSRange(location:25,length:0))
        bar.moveSelection(by:1)
        #expect(bar.queryText == query && calls == [query])
        editor.insertText(" updated",replacementRange:NSRange(location:NSNotFound,length:0));try publishEdit(bar,editor:editor)
        #expect(bar.queryText == "Project Notes updated" && bar.selectedIndex == nil && bar.visibleResults.isEmpty)
        bar.close()
    }

    @Test("A prefilled URL previews the complete chosen address and selects it for replacement")
    func urlEditorPreview() throws {
        let window = window(); defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let original = "https://current.invalid/path"
        let current = CommandResult(id:"current",kind:.openTab,title:"Current",subtitle:"",symbolName:"globe",
            action:.switchToTab(UUID()),score:0,isCurrentPage:true,completionText:original)
        let site = CommandResult(id:"site",kind:.history,title:"BBC",subtitle:"— bbc.co.uk",symbolName:"globe",
            action:.openURL(URL(string:"https://www.bbc.co.uk/")!),score:0,completionText:"bbc.co.uk")
        bar.openLocation(text:original,suggestions:[current,site])
        let editor = try #require(window.firstResponder as? NSTextView)
        bar.moveSelection(by:1)
        #expect(bar.queryText == "bbc.co.uk" && editor.selectedRange() == NSRange(location:0,length:9))
        bar.moveSelection(by:1)
        #expect(bar.queryText == original && editor.selectedRange() == NSRange(location:0,length:(original as NSString).length))
        editor.selectAll(nil);editor.deleteBackward(nil)
        try publishEdit(bar,editor:editor)
        #expect(bar.queryText.isEmpty && bar.selectedIndex == 0)
        bar.moveSelection(by:1)
        #expect(bar.queryText == "bbc.co.uk" && editor.selectedRange() == NSRange(location:0,length:9))
        bar.moveSelection(by:-1)
        var action:CommandAction?
        bar.onRun = { action = $0; _ = $1; _ = $2 }
        bar.moveSelection(by:1);bar.submit()
        #expect(action == site.action && !bar.isOpen)
    }

    @Test("One Down arrow chooses the literal search ahead of remaining local results", .timeLimit(.minutes(1)),
          arguments:["new", "location", "address", "split"])
    func literalSearchKeyboard(mode:String) async throws {
        let window = window();defer { window.close() }
        let root = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:root)
        let search = SearchCandidate(engineName:"Fixture",url:URL(string:"https://search.invalid/?q=project")!)
        let rows = CommandRanker.rank(query:"project",tabs:[
            .init(id:UUID(),title:"Project Notes",address:"docs.invalid/notes",url:URL(string:"https://docs.invalid/notes")!,isActive:false),
            .init(id:UUID(),title:"Project Plans",address:"docs.invalid/plans",url:URL(string:"https://docs.invalid/plans")!,isActive:false)
        ],history:[],search:search)
        #expect(rows.map(\.kind) == [.openTab,.search,.openTab])
        let (arrivals,continuation) = AsyncStream<Void>.makeStream();defer { continuation.finish() }
        var iterator = arrivals.makeAsyncIterator()
        bar.resultsProvider = { _ in continuation.yield(());return rows }
        let anchor = NSView(frame:NSRect(x:8,y:800,width:220,height:36));root.addSubview(anchor)
        switch mode {
        case "location":bar.openLocation(text:"https://current.invalid/",suggestions:[])
        case "address":bar.openAddress(text:"https://current.invalid/",anchor:anchor)
        case "split":bar.openSplit(recentResults:[])
        default:bar.openNewTab(recentResults:[])
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("project",replacementRange:NSRange(location:NSNotFound,length:0));try publishEdit(bar,editor:editor)
        _ = await iterator.next();await Task.yield()
        try #require(bar.visibleResults == rows)
        #expect(bar.selectedIndex == 0 && bar.queryText == "project")
        bar.moveSelection(by:1)
        #expect(bar.visibleResults[try #require(bar.selectedIndex)].kind == .search)
        #expect(bar.queryText == "project" && editor.selectedRange() == NSRange(location:7,length:0))
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 };bar.submit()
        #expect(action == .openURL(search.url) && !bar.isOpen)
    }

    @Test("Shrinking the list keeps its selected address, visible row and Return destination together")
    func resizedSelection() throws {
        let window = window();defer { window.close() }
        let root = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:root)
        bar.open(text:"page")
        let rows = (0..<6).map { index in
            CommandResult(id:"row\(index)",kind:.history,title:"Page \(index)",subtitle:"",symbolName:"globe",
                action:.openURL(URL(string:"https://page\(index).invalid/")!),score:0,completionText:"page\(index).invalid")
        }
        root.layoutSubtreeIfNeeded();bar.setResults(rows);bar.moveSelection(by:-1)
        #expect(bar.selectedIndex == 5 && bar.queryText == "page5.invalid")
        window.setContentSize(NSSize(width:1400,height:300))
        root.layoutSubtreeIfNeeded();bar.layoutSubtreeIfNeeded()
        let selected = try #require(bar.selectedIndex)
        #expect(selected < 5 && bar.visibleResults.indices.contains(selected))
        #expect(bar.queryText == bar.visibleResults[selected].completionText)
        let expected = bar.visibleResults[selected].action
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 };bar.submit()
        #expect(action == expected)
    }

    @Test("Global recents switch to another profile's existing tab without leaking private tabs")
    func globalRecentsAndPrivacy() async throws {
        let oldSetting = Settings.shared.openCommandBarOnNewTab
        let oldSources = Settings.shared.suggestionSources
        Settings.shared.openCommandBarOnNewTab = true
        var sources = oldSources;sources.openTabs = true
        Settings.shared.suggestionSources = sources
        defer { Settings.shared.openCommandBarOnNewTab = oldSetting;Settings.shared.suggestionSources = oldSources }
        let session = TestSession.make().0
        let personal = session.activeSpace
        let personalTab = session.newTab(url:URL(string:"https://recents.invalid/personal")!)
        let sibling = session.addSpace(named:"Same profile",profile:personal.profile)
        let siblingTab = session.newTab(url:URL(string:"https://recents.invalid/sibling")!)
        let work = session.addSpace(named:"Other profile")
        let workTabs = (0..<6).map { session.newTab(url:URL(string:"https://recents.invalid/work\($0)")!) }
        let secret = session.addSpace(named:"Private",isPrivate:true)
        let secretTab = session.newTab(url:URL(string:"https://recents.invalid/secret")!)
        let privateOther = session.newTab(url:URL(string:"https://recents.invalid/private-other")!)
        session.selectSpace(personal)
        let count = session.allTabs.count
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? CommandBar }.first)
        controller.newTab(nil)
        #expect(bar.visibleResults.count == 4)
        #expect(bar.results.allSatisfy { row in workTabs.contains { row.action == .switchToTab($0.id) } })
        #expect(!bar.results.contains { $0.action == .switchToTab(secretTab.id) || $0.action == .switchToTab(privateOther.id) })
        let provider = try #require(bar.resultsProvider)
        let ordinaryResults = await provider("recents.invalid")
        #expect(ordinaryResults.contains { $0.action == .switchToTab(siblingTab.id) })
        #expect(!ordinaryResults.contains { row in workTabs.contains { row.action == .switchToTab($0.id) } })
        #expect(!ordinaryResults.contains { $0.action == .switchToTab(secretTab.id) || $0.action == .switchToTab(privateOther.id) })
        bar.submit()
        #expect(session.activeSpace === work && workTabs.contains { $0 === session.activeTab })
        #expect(session.allTabs.count == count && personal.activeTab === personalTab && sibling.activeTab === siblingTab)
        let workResults = await provider("recents.invalid")
        #expect(!workResults.contains { $0.action == .switchToTab(personalTab.id) || $0.action == .switchToTab(siblingTab.id) })
        #expect(workResults.contains { row in workTabs.contains { $0 !== session.activeTab && row.action == .switchToTab($0.id) } })
        session.selectSpace(secret)
        controller.newTab(nil)
        #expect(bar.results.map(\.action) == [.switchToTab(secretTab.id)])
        let privateResults = await provider("recents.invalid")
        #expect(!privateResults.contains { row in workTabs.contains { row.action == .switchToTab($0.id) } || row.action == .switchToTab(personalTab.id) })
        bar.close()
    }
}
