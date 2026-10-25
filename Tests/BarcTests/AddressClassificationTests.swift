// Modified for Barc: combined address resolution and suggestion identity regressions, 2026-10-25.
import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Address classification and destination identity")
struct AddressClassificationTests {
    @Test("Bracketed IPv6 addresses navigate and local ranges keep HTTP", arguments: [
        ("[::1]:8080/hello", "http://[::1]:8080/hello"),
        ("[::]/", "http://[::]/"),
        ("[fd12::5]/", "http://[fd12::5]/"),
        ("[fe80::1234]:3000/", "http://[fe80::1234]:3000/"),
        ("[::ffff:192.168.1.1]/", "http://[::ffff:192.168.1.1]/"),
        ("[2001:4860:4860::8888]/", "https://[2001:4860:4860::8888]/"),
        ("https://[::1]:8080/", "https://[::1]:8080/")
    ])
    func ipv6(input:String,expected:String) {
        #expect(URLResolver.navigationURL(input)?.absoluteString == expected)
        #expect(URLResolver.resolve(input)?.absoluteString == expected)
    }

    @Test("Pasted web addresses recover omitted slashes and encode resource spaces", arguments: [
        ("https:example.com/docs", "https://example.com/docs"),
        ("https:/example.com/docs", "https://example.com/docs"),
        ("http:localhost:8080/", "http://localhost:8080/"),
        ("HTTPS:\\example.com\\docs", "https://example.com/docs"),
        ("//example.com/docs", "https://example.com/docs"),
        ("//localhost:3000/", "http://localhost:3000/"),
        ("example.com/a b", "https://example.com/a%20b"),
        ("example.com/?q=two words", "https://example.com/?q=two%20words"),
        ("https://example.com/a b", "https://example.com/a%20b"),
        ("intranet/", "http://intranet/"),
        ("devbox:8080", "http://devbox:8080"),
        ("//intranet", "http://intranet"),
        ("intranet/a b", "http://intranet/a%20b"),
        ("example.com./", "https://example.com./")
    ])
    func pasted(input:String,expected:String) {
        #expect(URLResolver.navigationURL(input)?.absoluteString == expected)
    }

    @Test("An empty web port stays valid while a custom path scheme stays local")
    func emptyPortsAndSchemes() {
        for input in ["https://example.com:/path", "example.com:/path", "localhost:/path"] {
            #expect(URLResolver.navigationURL(input)?.path() == "/path")
        }
        for input in ["custom:/private", "private-tool:/private", "file:/private/report"] {
            #expect(SearchSuggestions.request(for:input,engine:.google) == nil)
        }
    }

    @Test("Internationalized domains remain navigable in Unicode and encoded forms", arguments: [
        "xn--bcher-kva.de", "bücher.de", "xn--e1afmkfd.xn--p1ai", "пример.рф"
    ])
    func internationalDomains(input:String) {
        #expect(URLResolver.navigationURL(input)?.host() != nil)
        #expect(URLResolver.resolve(input)?.host() != "duckduckgo.com")
    }

    @Test("Invalid authorities and ordinary prose stay searches", arguments: [
        "http://", "https:", "https://exa mple.com/", "hello world.com is great",
        "example..com", "example.com:99999/", "https://example.com:99999/",
        "[::g]/", "[::1", "localhost:notaport", "3.14", "intranet",
        "why: now?", "C++ / Rust", "custom://example.com/path", "custom:/private",
        "user@example.com"
    ])
    func invalid(input:String) {
        #expect(URLResolver.navigationURL(input) == nil)
        #expect(URLResolver.resolve(input)?.host() == "duckduckgo.com")
    }

    @Test("Fixups still keep private URL resources out of default-engine requests", arguments: [
        "https:example.com/private", "https:/example.com/a b", "//example.com/private",
        "example.com/a b", "example.com/?token=two words", "[::1]:8080/",
        "https://[fd00::1]/private", "http://user:password@example.com/a b",
        "file:/Users/test/report", "custom:/private", "devbox:8080"
    ])
    func privatePredictions(input:String) {
        #expect(SearchSuggestions.request(for:input,engine:.google) == nil)
        #expect(SearchSuggestions.request(for:input,engine:.google,explicitSearch:true) != nil)
    }

    @Test("Destination aliases normalize hosts but preserve resource case and trailing slashes")
    func destinationIdentity() {
        func key(_ text:String) -> String { AddressFormatter.destinationKey(URL(string:text)!) }
        #expect(key("https://WWW.Example.com:443/") == key("http://example.com:80"))
        #expect(key("https://example.com/?q=one") == key("https://example.com?q=one"))
        for (a,b) in [("/Docs","/docs"),("/docs/","/docs"),("/?q=ABC","/?q=abc"),("/#Page","/#page")] {
            #expect(key("https://example.com"+a) != key("https://example.com"+b))
        }
        #expect(key("file:///tmp/Report") != key("file:///tmp/report"))
    }

    @Test("Provider parsing preserves distinct case-sensitive website suggestions")
    func providerCase() throws {
        let urls = ["https://example.com/Docs","https://example.com/docs","https://example.com/docs/","https://example.com/Docs"]
        let data = try JSONSerialization.data(withJSONObject:["example",urls,[],[],["google:suggesttype":Array(repeating:"NAVIGATION",count:4)]])
        let parsed = SearchSuggestions.decodeResults(data,query:"example")
        #expect(parsed.count == 3)
        let tabID = UUID()
        let local = CommandResult(id:"tab",kind:.openTab,title:"Docs",subtitle:"",symbolName:"globe",action:.switchToTab(tabID),score:100)
        let result = CommandSearch.addingResults(parsed,query:"example",engine:.google,openTabs:[tabID:URL(string:urls[0])!],to:[local])
        #expect(result.count == 3)
        #expect(result.dropFirst().compactMap { row -> String? in
            if case .openURL(let url) = row.action { return url.path() };return nil
        } == ["/docs","/docs/"])
    }

    @Test("An open page does not hide distinct history paths or query values")
    func localCase() {
        let tabURL = URL(string:"https://example.com/Docs")!
        let resources = ["https://example.com/Docs","https://example.com/docs","https://example.com/docs/","https://example.com/?q=A","https://example.com/?q=a"]
        let rows = CommandRanker.rank(query:"example",tabs:[.init(id:UUID(),title:"Docs",address:"example.com/Docs",url:tabURL,isActive:false)],history:resources.map {
            .init(url:URL(string:$0)!,title:"Example",key:$0,visitCount:1)
        })
        #expect(rows.filter { $0.kind == .openTab }.count == 1)
        #expect(rows.filter { $0.kind == .history }.count == 4)
    }
}

@Suite("Address classification in native search", .serialized)
@MainActor
struct NativeAddressClassificationTests {
    @Test("Ranked destinations and immediate Return agree without moving the input", arguments: [
        "https:/example.com/a b", "[::1]:8080/", "//example.com/docs", "intranet/"
    ])
    func routes(input:String) async throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let controller = BrowserWindowController(session:session)
        defer { controller.window?.delegate = nil;controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let bar = try #require(UITestSupport.descendants(of:root).compactMap { $0 as? CommandBar }.first)
        let provider = try #require(bar.resultsProvider)
        let rows = await provider(input)
        let expected = try #require(URLResolver.navigationURL(input))
        #expect(rows.first?.action == .openURL(expected))
        var action:CommandAction?
        bar.onRun = { action = $0;_ = $1;_ = $2 }
        bar.open(text:input,openInNewTab:true)
        bar.setResults(rows);bar.select(0)
        root.layoutSubtreeIfNeeded()
        let field = try #require(UITestSupport.descendants(of:bar).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let origin = field.convert(field.bounds,to:root).origin
        bar.setResults([]);bar.select(nil)
        root.layoutSubtreeIfNeeded()
        #expect(field.convert(field.bounds,to:root).origin == origin)
        bar.submit()
        #expect(action == .openURL(expected) && !bar.isOpen)
    }
}
