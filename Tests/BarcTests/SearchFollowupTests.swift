// Modified for Barc: one combined search follow-up verification batch, 2026-10-25.
import AppKit
import Foundation
import Testing
@testable import Barc

private final class SearchProtocolLog:@unchecked Sendable {
    private let lock = NSLock()
    private var requests:[URLRequest] = []
    func record(_ request:URLRequest) { lock.withLock { requests.append(request) } }
    var all:[URLRequest] { lock.withLock { requests } }
}
private final class SearchFixtureProtocol:URLProtocol,@unchecked Sendable {
    static let log = SearchProtocolLog()
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.record(request)
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json","Set-Cookie":"fixture=never-store"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(#"["river",["river","river flow","river bank","RIVER FLOW"]]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Selected-engine predictions", .serialized)
struct SearchPredictionTests {
    @Test("Requests use only the chosen engine and exclude URL paths, credentials and multi-line text")
    func endpoints() throws {
        for engine in SearchEngine.all {
            let request = try #require(SearchSuggestions.request(for:"river",engine:engine))
            #expect(request.url?.scheme == "https" && !request.httpShouldHandleCookies)
            #expect(request.value(forHTTPHeaderField:"Cookie") == nil && request.value(forHTTPHeaderField:"Authorization") == nil)
            #expect(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.contains { $0.value == "river" } == true)
        }
        for query in ["", "https://private.invalid/token", "user@example.invalid", "words\nother words", "host.invalid/path", "?token=secret"] {
            #expect(SearchSuggestions.request(for:query,engine:.google) == nil)
        }
        let custom = try #require(SearchEngine.custom(name:"Other",address:"https://other.invalid/?q=%s",keyword:"o"))
        #expect(SearchSuggestions.request(for:"river",engine:custom) == nil)
    }
    @Test("The native transport returns deduplicated predictions without cookies or credentials")
    func transport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchFixtureProtocol.self]
        configuration.httpCookieStorage = nil;configuration.urlCredentialStorage = nil
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        let client = SearchSuggestions(session:session)
        #expect(await client.suggestions(for:"river",engine:.google) == ["river flow","river bank"])
        #expect(SearchFixtureProtocol.log.all.last?.url?.host() == "www.google.com")
        #expect(SearchFixtureProtocol.log.all.last?.httpShouldHandleCookies == false)
    }
    @Test("Malformed, wrong-query, oversized and multiline predictions are rejected")
    func responses() {
        #expect(SearchSuggestions.decode(Data(#"["other",["river flow"]]"#.utf8),query:"river").isEmpty)
        #expect(SearchSuggestions.decode(Data("bad".utf8),query:"river").isEmpty)
        #expect(SearchSuggestions.decode(Data(repeating:65,count:SearchSuggestions.maximumBytes+1),query:"river").isEmpty)
        #expect(SearchSuggestions.decode(Data(#"["river",["river\nflow","river bank"]]"#.utf8),query:"river") == ["river bank"])
        #expect(SearchSuggestions.decode(Data(")]}'\n[\"river\",[\"river bank\"]]".utf8),query:"river") == ["river bank"])
        let latin = #"["café",["cafés"]]"#.data(using:.isoLatin1)!
        #expect(SearchSuggestions.decode(latin,query:"café",encodingName:"ISO-8859-1") == ["cafés"])
    }
    @Test("Predictions extend local ordering and retain their engine's destination and keyword prefix")
    func merge() throws {
        let local = try #require(CommandSearch.row(query:"river",engine:.google))
        let rows = CommandSearch.adding(["river","river flow","river flow"],query:"river",engine:.google,completionPrefix:"g ",to:[local])
        #expect(rows.count == 2 && rows[0] == local)
        #expect(rows[1].completionText == "g river flow")
        #expect(rows[1].action == .openURL(SearchEngine.google.url(for:"river flow")!))
    }
    @Test("The local candidate budget admits the fifteen matches exposed by the saved reference")
    func localBudget() {
        let rows = CommandRanker.rank(query:"Example",tabs:[],history:(0..<30).map {
            HistoryCandidate(url:URL(string:"https://example.invalid/\($0)")!,title:"Example \($0)",key:"example.invalid/\($0)",visitCount:1)
        })
        #expect(rows.count == 15)
    }
}

@Suite("Search follow-up native controls", .serialized)
@MainActor
struct SearchFollowupTests {
    private func window(width:CGFloat = 1000,height:CGFloat = 650) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;return window
    }
    private func field(_ bar:CommandBar) throws -> NSTextField {
        try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }
    private func edit(_ value:String,bar:CommandBar,editor:NSTextView) throws {
        editor.selectAll(nil);editor.insertText(value,replacementRange:NSRange(location:NSNotFound,length:0))
        try publish(bar,editor:editor)
    }
    private func publish(_ bar:CommandBar,editor:NSTextView) throws {
        let field = try field(bar);field.stringValue = editor.string
        bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
    }
    private func rows(_ count:Int) -> [CommandResult] {
        (0..<count).map { index in
            CommandResult(id:"row\(index)",kind:.history,title:"Page \(index)",subtitle:"",symbolName:"globe",
                action:.openURL(URL(string:"https://page\(index).invalid/")!),score:0,completionText:"page\(index).invalid")
        }
    }
    @Test("Every result remains keyboard-accessible below the viewport without moving the input",arguments:[false,true])
    func scrollable(compact:Bool) throws {
        let window = window(height:500);defer { window.close() }
        let root = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:root)
        if compact {
            let anchor = NSView(frame:NSRect(x:8,y:400,width:220,height:28));root.addSubview(anchor)
            bar.openAddress(text:"page",anchor:anchor)
        } else { bar.openNewTab(recentResults:[]) }
        bar.setResults(rows(20));root.layoutSubtreeIfNeeded();root.layoutSubtreeIfNeeded()
        let field = try field(bar),before = field.convert(field.bounds,to:root)
        let table = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? CommandResultsView }.first)
        let scroll = try #require(table.enclosingScrollView)
        #expect(table.accessibilityRowCount() == 20 && scroll.contentSize.height<table.bounds.height)
        bar.moveSelection(by:-1);root.layoutSubtreeIfNeeded();root.layoutSubtreeIfNeeded()
        #expect(bar.selectedIndex == 19 && bar.queryText == "page19.invalid")
        let last = try #require(table.arrangedSubviews.last as? CommandRowView)
        #expect(!last.visibleRect.isEmpty && table.accessibilityVisibleRows()?.contains { ($0 as? NSView) === last } == true)
        #expect(field.convert(field.bounds,to:root) == before)
        bar.moveSelection(by:1);root.layoutSubtreeIfNeeded()
        #expect(bar.selectedIndex == 0 && scroll.contentView.bounds.minY<1)
        bar.moveSelection(by:-1)
        var destination:CommandAction?
        bar.onRun = { destination = $0;_ = $1;_ = $2 };bar.submit()
        #expect(destination == rows(20)[19].action)
    }

    @Test("Delayed predictions retain local views, the selected identity and its text preview")
    func delayedPredictions() async throws {
        let window = window();defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let (events,started) = AsyncStream<Void>.makeStream();var iterator = events.makeAsyncIterator()
        var pending:CheckedContinuation<[String],Never>?
        let local = rows(2)
        bar.resultsProvider = { _ in local }
        bar.resultsEnricher = { query,_,local in
            let predictions = await withCheckedContinuation { continuation in pending = continuation;started.yield(()) }
            return CommandSearch.adding(predictions,query:query,engine:.duckDuckGo,to:local)
        }
        bar.open(text:"river")
        _ = await iterator.next()
        bar.moveSelection(by:1)
        let selected = bar.selectedIndex,preview = bar.queryText
        let table = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? CommandResultsView }.first)
        let first = table.arrangedSubviews.first
        try #require(pending).resume(returning:["river flow"])
        await Task.yield();await Task.yield()
        #expect(bar.results.count == 3 && bar.selectedIndex == selected && bar.queryText == preview)
        #expect(table.arrangedSubviews.first === first)
        bar.close();started.finish()
    }

    @Test("Predictions from an older edit, opening, owner or composition cannot change current input",arguments:[0,1,2,3])
    func stalePredictions(_ variant:Int) async throws {
        let window = window();defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        var owner = "first";bar.ownerTokenProvider = { owner }
        let (events,started) = AsyncStream<Void>.makeStream();var iterator = events.makeAsyncIterator()
        var pending:CheckedContinuation<[String],Never>?,first = true
        bar.resultsProvider = { query in [CommandSearch.row(query:query,engine:.duckDuckGo)!] }
        bar.resultsEnricher = { query,_,local in
            guard first else { return local };first = false
            let predictions = await withCheckedContinuation { continuation in pending = continuation;started.yield(()) }
            return CommandSearch.adding(predictions,query:query,engine:.duckDuckGo,to:local)
        }
        bar.open(text:"river")
        _ = await iterator.next()
        let editor = try #require(window.firstResponder as? NSTextView)
        switch variant {
        case 0:try edit("forest",bar:bar,editor:editor)
        case 1:bar.close();bar.open(text:"river")
        case 2:owner = "second";#expect(!bar.validateOwner() && !bar.isOpen)
        default:
            editor.setMarkedText("河",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:editor.string.utf16.count))
            try publish(bar,editor:editor);#expect(editor.hasMarkedText())
        }
        try #require(pending).resume(returning:["stale prediction"])
        await Task.yield();await Task.yield()
        #expect(!bar.results.contains { $0.title == "stale prediction" })
        if variant == 0 { #expect(bar.queryText == "forest") }
        if variant == 3 { #expect(editor.hasMarkedText() && bar.queryText == "河") }
        bar.close();started.finish()
    }

    @Test("A configured keyword plus Tab enters site mode and Return searches that site",arguments:[false,true])
    func siteSearch(compact:Bool) async throws {
        let window = window();defer { window.close() }
        let root = try #require(window.contentView)
        let bar = CommandBar();bar.install(in:root)
        let wiki = try #require(SearchEngine.custom(name:"Wikipedia",address:"https://en.wikipedia.org/w/index.php?search=%s",keyword:"w"))
        bar.searchEnginesProvider = { [wiki] }
        var calls = 0;bar.resultsProvider = { _ in calls += 1;return [] }
        let (events,started) = AsyncStream<SearchEngine?>.makeStream();var iterator = events.makeAsyncIterator()
        bar.resultsEnricher = { _,site,local in started.yield(site);return local }
        if compact {
            let anchor = NSView(frame:NSRect(x:8,y:500,width:220,height:28));root.addSubview(anchor)
            bar.openAddress(text:"",anchor:anchor)
        } else { bar.openNewTab(recentResults:[]) }
        let editor = try #require(window.firstResponder as? NSTextView)
        try edit("w",bar:bar,editor:editor)
        root.layoutSubtreeIfNeeded();let before = try #require(bar.subviews.first).frame.maxY
        #expect(bar.control(try field(bar),textView:editor,doCommandBy:#selector(NSResponder.insertTab(_:))))
        #expect(bar.siteSearchEngine == wiki && bar.queryText.isEmpty && bar.fieldHasFocus)
        root.layoutSubtreeIfNeeded();#expect(abs(try #require(bar.subviews.first).frame.maxY-before)<0.5)
        bar.submit();#expect(bar.isOpen)
        try edit("cats & dogs",bar:bar,editor:editor)
        #expect(await iterator.next() == .some(wiki))
        #expect(calls == 0 && bar.results.first?.action == .openURL(wiki.url(for:"cats & dogs")!))
        var destination:CommandAction?
        bar.onRun = { destination = $0;_ = $1;_ = $2 };bar.submit()
        #expect(destination == .openURL(wiki.url(for:"cats & dogs")!))
        started.finish()
    }

    @Test("Backspace leaves empty site mode, and Escape/reopening clear its site identity")
    func exitSiteSearch() throws {
        let window = window();defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        bar.searchEnginesProvider = { [.google] };bar.openNewTab(recentResults:rows(2))
        let editor = try #require(window.firstResponder as? NSTextView)
        try edit("g",bar:bar,editor:editor)
        #expect(bar.control(try field(bar),textView:editor,doCommandBy:#selector(NSResponder.insertTab(_:))))
        #expect(bar.siteSearchEngine == .google)
        #expect(bar.control(try field(bar),textView:editor,doCommandBy:#selector(NSResponder.deleteBackward(_:))))
        #expect(bar.siteSearchEngine == nil && bar.results.count == 2 && bar.queryText.isEmpty)
        try edit("g",bar:bar,editor:editor)
        _ = bar.control(try field(bar),textView:editor,doCommandBy:#selector(NSResponder.insertTab(_:)))
        bar.cancelOperation(nil);bar.openNewTab(recentResults:[])
        #expect(bar.siteSearchEngine == nil)
        bar.close()
    }

    @Test("Native marked-text composition keeps its text and submits only after committing")
    func composition() async throws {
        let window = window();defer { window.close() }
        let bar = CommandBar();bar.install(in:try #require(window.contentView))
        let (events,started) = AsyncStream<String>.makeStream();var iterator = events.makeAsyncIterator()
        var calls:[String] = []
        bar.resultsProvider = { query in calls.append(query);started.yield(query);return [] }
        bar.openNewTab(recentResults:rows(2))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setMarkedText("河",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        try publish(bar,editor:editor)
        #expect(editor.hasMarkedText() && calls.isEmpty && bar.selectedIndex == nil)
        #expect(!bar.control(try field(bar),textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))))
        bar.submit();#expect(bar.isOpen)
        editor.insertText("河流",replacementRange:NSRange(location:NSNotFound,length:0));try publish(bar,editor:editor)
        #expect(!editor.hasMarkedText())
        #expect(await iterator.next() == "河流")
        #expect(calls == ["河流"] && bar.queryText == "河流")
        bar.close();started.finish()
    }

    @Test("The real window routes keyword searches and closes New Tab on a Space change")
    func windowIntegration() async throws {
        let session = TestSession.make().0
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? CommandBar }.first)
        let (events,started) = AsyncStream<Void>.makeStream();var iterator = events.makeAsyncIterator()
        let enrich = bar.resultsEnricher
        bar.resultsEnricher = { query,site,local in
            let result = await enrich?(query,site,local) ?? local;started.yield(());return result
        }
        bar.open(text:"g cats",openInNewTab:true)
        _ = await iterator.next()
        #expect(bar.results.first?.action == .openURL(SearchEngine.google.url(for:"cats")!))
        bar.close();bar.openNewTab(recentResults:rows(2))
        _ = session.addSpace(named:"Another profile")
        #expect(!bar.isOpen)
        started.finish()
    }
    @Test("Ordinary web queries cannot select unrelated browser actions through scattered letters")
    func literalSearchPrecedesUnrelatedActions() {
        let session = TestSession.make().0
        let commands = CommandCatalog.available(in:session)
        for query in ["weather","weather forecast","eat","mountain trails","coffee beans","splt"] {
            let search = SearchCandidate(engineName:"Fixture",url:SearchEngine.duckDuckGo.url(for:query)!)
            let rows = CommandRanker.rank(query:query,tabs:[],commands:commands,history:[],search:search)
            #expect(rows.first?.kind == .search,"Query \(query): \(rows.map(\.title))")
            #expect(!rows.contains { $0.kind == .command },"Query \(query) must not invoke an unrelated action")
        }
        let reload = CommandRanker.rank(query:"reload",tabs:[],commands:commands,history:[])
        #expect(reload.contains { $0.kind == .command && $0.title == "Reload Page" })
        #expect(CommandRanker.rank(query:"site search",tabs:[],commands:commands,history:[]).first?.action == .runCommand("site-search"))
    }

    @Test("Private Spaces cannot send predictions through the real window integration")
    func privatePredictions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchFixtureProtocol.self]
        let network = URLSession(configuration:configuration);defer { network.invalidateAndCancel() }
        let store = SessionStore(fileURL:FileManager.default.temporaryDirectory.appending(path:"private-prediction-\(UUID()).json"))
        let settings = Settings(defaults:UserDefaults(suiteName:"private.prediction.\(UUID())")!)
        let session = BrowserSession(database:nil,sessionStore:store,settings:settings,searchSuggestions:SearchSuggestions(session:network))
        _ = session.addSpace(named:"Private",isPrivate:true)
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? CommandBar }.first)
        let enrich = try #require(bar.resultsEnricher)
        let local = [CommandSearch.row(query:"private words",engine:.google)!]
        func matchingRequests() -> Int {
            SearchFixtureProtocol.log.all.filter { request in
                URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.contains { $0.value == "private words" } == true
            }.count
        }
        let count = matchingRequests()
        #expect(await enrich("private words",nil,local) == local)
        #expect(matchingRequests() == count)
    }

}
