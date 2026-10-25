// Modified for Barc: separate keyboard/pointer URL entry and profile-local ranked suggestions, 2026-10-24.
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Barc

@Suite("Arc URL editors", .serialized)
@MainActor
struct URLEditorTests {
    private func site(_ name: String) -> BrowserTopSite {
        .init(url: URL(string: "https://\(name).invalid/")!, title: name)
    }
    private func command(_ controller: BrowserWindowController) throws -> CommandBar {
        try #require(controller.window?.contentView.flatMap {
            UITestSupport.descendants(of: $0).compactMap { $0 as? CommandBar }.first
        })
    }
    private func close(_ controller: BrowserWindowController) {
        controller.window?.delegate = nil; controller.window?.close()
    }
    private func png(_ color: NSColor) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("Search rows keep magnifying glasses when the engine's page icon is available")
    func searchImages() throws {
        let session = TestSession.make().0
        let url = try #require(SearchEngine.duckDuckGo.url(for:"weather?"))
        var engineSite = BrowserTopSite(url:url,title:"Engine page")
        engineSite.favicon = .init(pageURL:url,data:try png(.red))
        session.activeSpace.profile.preferences.arcTopSites = [engineSite]
        let controller = BrowserWindowController(session:session);defer { close(controller) }
        let bar = try command(controller)
        let page = CommandResult(id:"engine-page",kind:.history,title:"Engine page",subtitle:"",symbolName:"globe",action:.openURL(url),score:0)
        #expect(bar.resultImageProvider?(page) != nil)
        let literal = try #require(CommandSearch.row(query:"weather?",engine:.duckDuckGo))
        let searches = CommandSearch.adding(["weather? tomorrow"],query:"weather?",engine:.duckDuckGo,to:[literal])
        for result in searches {
            #expect(result.symbolName == "magnifyingglass" && bar.resultImageProvider?(result) == nil)
        }
        bar.openNewTab(recentResults:[]);bar.setResults(searches);bar.moveSelection(by:1)
        let images = UITestSupport.descendants(of:bar).compactMap { $0 as? NSImageView }
        #expect(!images.isEmpty && images.allSatisfy { $0.image == nil || $0.image?.isTemplate == true })
        bar.close()
    }

    @Test("Command-L centres a selected full URL while clicking Address opens the sidebar popup")
    func twoEntrypoints() throws {
        _ = NSApplication.shared
        let sources = Settings.shared.suggestionSources
        var enabled = sources; enabled.openTabs = true; enabled.history = true; enabled.topHits = true
        Settings.shared.suggestionSources = enabled
        defer { Settings.shared.suggestionSources = sources }
        let session = TestSession.make().0
        let source = session.newTab(url: site("current").url)
        session.enrichArcTopSites([site("second"), site("first"), site("third")], for: session.activeSpace.identity)
        let controller = BrowserWindowController(session: session)
        defer { close(controller) }
        let command = try command(controller), count = session.allTabs.count
        controller.openLocation(nil)
        #expect(command.isLocationMode && !command.isAddressMode && !command.isNewTabMode)
        #expect(command.queryText == source.url.absoluteString && command.selectedIndex == 0)
        #expect(command.results.map(\.title).suffix(3) == ["second", "first", "third"])
        #expect(command.results.first?.isCurrentPage == true)
        #expect(command.results.dropFirst().map(\.subtitle) == ["— second.invalid", "— first.invalid", "— third.invalid"])
        let editor = try #require(controller.window?.firstResponder as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: (source.url.absoluteString as NSString).length))
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        let panel = try #require(UITestSupport.descendants(of: command).compactMap { $0 as? CommandPanelView }.first)
        let rect = panel.convert(panel.bounds, to: root)
        #expect(abs(rect.midX - root.bounds.midX) < 0.5 && abs(rect.midY - root.bounds.midY - 5) < 0.5)
        command.cancelOperation(nil)
        let address = try #require(UITestSupport.descendants(of: root).compactMap { $0 as? AddressField }.first)
        address.onOpen?()
        #expect(command.isAddressMode && !command.isLocationMode && !command.isNewTabMode)
        #expect(command.results.map(\.title).suffix(3) == ["second", "first", "third"])
        root.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        let rows = UITestSupport.descendants(of: command).compactMap { $0 as? CommandRowView }
        #expect(rows.count == 4 && rows.allSatisfy { abs($0.frame.height - 46) < 0.5 })
        let title = try #require(UITestSupport.descendants(of: rows[1]).compactMap { $0 as? NSTextField }.first { $0.stringValue == "second" })
        let titleRect = try #require(title.superview).convert(title.alignmentRect(forFrame: title.frame), to: panel)
        #expect(abs(titleRect.minX - 52) < 0.5)
        #expect(abs(abs(rows[1].frame.midY - rows[0].frame.midY) - 50) < 0.5)
        command.cancelOperation(nil)
        #expect(session.activeTab === source && session.allTabs.count == count)
        controller.openLocation(nil)
        session.addSpace(named: "Work")
        #expect(!command.isOpen, "An editor cannot carry a previous profile's URL into a different Space")
    }

    @Test("Clearing Command-L restores its suggestions; Return edits the current page without making a tab")
    func editingContract() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = CommandBar(); bar.install(in: try #require(window.contentView))
        let current = CommandResult(id: "current", kind: .openTab, title: "Current", subtitle: "",
            symbolName: "globe", action: .switchToTab(UUID()), score: 0, isCurrentPage: true)
        bar.openLocation(text: "https://current.invalid/path", suggestions: [current])
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("replacement.invalid", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bar.visibleResults.isEmpty && bar.selectedIndex == nil)
        editor.selectAll(nil); editor.deleteBackward(nil)
        #expect(bar.queryText.isEmpty && bar.visibleResults == [current] && bar.selectedIndex == 0)
        editor.insertText("replacement.invalid", replacementRange: NSRange(location: NSNotFound, length: 0))
        var action: CommandAction?, newTab = true
        bar.onRun = { action = $0; newTab = $1; _ = $2 }
        bar.submit()
        #expect(action == .openURL(URL(string: "https://replacement.invalid")!) && !newTab)
    }

    @Test("Long titles truncate inside both URL editors without widening their panels")
    func longTitles() throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        NSLayoutConstraint.activate([host.widthAnchor.constraint(equalToConstant: 1200), host.heightAnchor.constraint(equalToConstant: 800)])
        let anchor = NSView(frame: NSRect(x: 8, y: 680, width: 220, height: 36)); host.addSubview(anchor)
        let bar = CommandBar(); bar.install(in: host)
        let long = CommandResult(id: "long", kind: .openTab, title: String(repeating: "A lengthy browser page title ", count: 12),
            subtitle: "", symbolName: "globe", action: .switchToTab(UUID()), score: 0)
        for centred in [true, false] {
            if centred { bar.openLocation(text: "https://example.invalid/", suggestions: [long]) }
            else { bar.openAddress(text: "https://example.invalid/", anchor: anchor, recentResults: [long]) }
            host.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
            let panel = try #require(UITestSupport.descendants(of: bar).compactMap { $0 as? CommandPanelView }.first)
            #expect(abs(panel.frame.width - (centred ? 765 : 350)) < 0.5)
            #expect(host.bounds.contains(panel.convert(panel.bounds, to: host)))
            bar.close()
        }
    }

    @Test("Top Sites retain source ranks and skip non-web URLs, and older profile preferences still decode")
    func rankedSource() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "url-editor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ArcProfileReader.topSites(folder).isEmpty)
        let db = try SQLiteDatabase(path: folder.appending(path: "Top Sites").path)
        try db.execute("CREATE TABLE top_sites (url TEXT, title TEXT, url_rank INTEGER);")
        for (name, rank) in [("third", 2), ("first", 0), ("second", 1)] {
            try db.run("INSERT INTO top_sites VALUES (?,?,?);", [.text(site(name).url.absoluteString), .text(name), .integer(Int64(rank))])
        }
        try db.run("INSERT INTO top_sites VALUES ('javascript:alert(1)','unsafe',-1);")
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        #expect(try ArcProfileReader.topSites(folder) == [site("first"), site("second"), site("third")])
        let history = try SQLiteDatabase(path: folder.appending(path: "History").path)
        try history.execute("CREATE TABLE urls(url TEXT, title TEXT);")
        try history.run("INSERT INTO urls VALUES (?, 'Current history title');", [.text(site("first").url.absoluteString)])
        try history.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        var first = site("first"); first.title = "Current history title"
        #expect(try ArcProfileReader.topSites(folder) == [first, site("second"), site("third")])
        #expect(try JSONDecoder().decode(ProfilePreferences.self, from: Data("{}".utf8)).arcTopSites == nil)
    }

    @Test("Enrichment preserves existing profile choices and keeps ranked suggestions isolated after reopening")
    func profileStorage() throws {
        let (session, store) = TestSession.make()
        let first = session.activeSpace
        let other = session.addSpace(named: "Other")
        #expect(session.enrichArcTopSites([site("personal")], for: first.identity) == 1)
        #expect(session.enrichArcTopSites([site("work")], for: other.identity) == 1)
        #expect(session.enrichArcTopSites([site("replacement")], for: first.identity) == 0)
        session.saveNow()
        let restored = try #require(store.load())
        #expect(restored.profiles?.first { $0.id == first.profile.id }?.preferences?.arcTopSites == [site("personal")])
        #expect(restored.profiles?.first { $0.id == other.profile.id }?.preferences?.arcTopSites == [site("work")])
        first.profile.preferences.arcTopSites = []
        #expect(session.enrichArcTopSites([site("replacement")], for: first.identity) == 0)
        session.clearHistory()
        #expect(other.profile.preferences.arcTopSites == [], "Profile shortcuts are removed even when its history database is unavailable")
    }

    @Test("Missing shortcut icons can be enriched without replacing labels, ranks or a chosen icon")
    func enrichImages() throws {
        let session = TestSession.make().0, identity = session.activeSpace.identity
        var first = site("first"), second = site("second")
        second.favicon = .init(pageURL: second.url, data: try png(.blue))
        session.enrichArcTopSites([first, second], for: identity)
        var incoming = first; incoming.title = "Changed source label"
        incoming.favicon = .init(pageURL: first.url, data: try png(.red))
        var replacement = second; replacement.favicon = .init(pageURL: second.url, data: try png(.green))
        #expect(session.enrichArcTopSites([replacement, incoming], for: identity) == 0)
        first.favicon = incoming.favicon
        #expect(session.activeSpace.profile.preferences.arcTopSites == [first, second])
    }

    @Test("Shortcut and sleeping-tab icons render immediately from the correct profile without loading their pages")
    func profileImages() throws {
        _ = NSApplication.shared
        let session = TestSession.make().0
        var red = site("same-image-url"), blue = red
        red.favicon = .init(pageURL: red.url, data: try png(.red))
        blue.favicon = .init(pageURL: blue.url, data: try png(.blue))
        let sleeping = session.newTab(url: red.url, select: false)
        sleeping.restoredFavicon = red.favicon
        session.activeSpace.profile.preferences.arcTopSites = [red]
        let controller = BrowserWindowController(session: session)
        defer { close(controller) }
        let bar = try command(controller)
        let result = CommandResult(id: "shortcut", kind: .history, title: "Site", subtitle: "", symbolName: "globe", action: .openURL(red.url), score: 0)
        func color(_ result: CommandResult) throws -> NSColor {
            let image = try #require(bar.resultImageProvider?(result))
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return try #require(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        }
        let first = try color(result)
        #expect(first.redComponent > first.blueComponent + 0.5, "\(first)")
        let tabResult = CommandResult(id: "sleeping", kind: .openTab, title: "Site", subtitle: "", symbolName: "globe", action: .switchToTab(sleeping.id), score: 0)
        let sleepingColor = try color(tabResult)
        #expect(sleepingColor.redComponent > sleepingColor.blueComponent + 0.5 && !sleeping.isLoaded, "\(sleepingColor)")
        let other = session.addSpace(named: "Other")
        other.profile.preferences.arcTopSites = [blue]
        let second = try color(result)
        #expect(second.blueComponent > second.redComponent + 0.5, "\(second)")
        blue.favicon = .init(pageURL: site("wrong-page").url, data: try png(.red))
        other.profile.preferences.arcTopSites = [blue]
        #expect(bar.resultImageProvider?(result) == nil)
    }

}

// These imports share the coordinator's process-wide exclusion gate with the
// existing orchestration tests, so they belong to that serialized suite.
extension ArcImportFlowTests {
    @Test("The importer snapshots ranked sites from each profile and repeated imports preserve them")
    func importPipeline() async throws {
        func site(_ name: String) -> BrowserTopSite {
            .init(url: URL(string: "https://\(name).invalid/")!, title: name)
        }
        let root = try ArcImportBench.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arc = root.appending(path: "Arc")
        let source = try ArcFlowBench.source(in: arc)
        for (index, profile) in source.profiles.enumerated() {
            let db = try SQLiteDatabase(path: source.profileURL(profile).appending(path: "Top Sites").path)
            try db.execute("CREATE TABLE top_sites(url TEXT, title TEXT, url_rank INTEGER);")
            try db.run("INSERT INTO top_sites VALUES(?,?,0);", [.text(site("profile\(index)").url.absoluteString), .text("profile\(index)")])
        }
        let preview = try ArcSourceSnapshotter.capture(arc, temporaryParent: root, sidebarOnly: true)
        defer { preview.remove() }
        #expect(preview.profiles.allSatisfy { !FileManager.default.fileExists(atPath: preview.profileURL($0).appending(path: "Top Sites").path) })
        let captured = try ArcSourceSnapshotter.capture(arc, temporaryParent: root)
        defer { captured.remove() }
        let db = try BrowserDatabase(path: root.appending(path: "browser.sqlite"))
        let session = BrowserSession(database: db, sessionStore: SessionStore(fileURL: root.appending(path: "session.json")))
        let coordinator = ArcImportCoordinator(session: session,
            downloads: DownloadManager(store: DownloadStore(fileURL: root.appending(path: "downloads.json"))),
            reportDirectory: root.appending(path: "reports"))
        var options = ArcImportOptions(profileIDs: Set(captured.profiles.map(\.folder)))
        options.bookmarks = false; options.passwords = false; options.cookies = false
        options.localStorage = false; options.supplementary = false
        let first = try await coordinator.run(captured, options: options)
        #expect(first.profiles.allSatisfy { $0.counts["Top Sites"]?.imported == 1 && $0.counts["Top Sites"]?.verified == 1 })
        let built = ArcSpaceBuilder.build(captured, options: options)
        for (index, profile) in source.profiles.enumerated() {
            let identity = try #require(built.first { $0.profile == profile.folder }?.snapshot.identity)
            #expect(session.profiles.first { $0.identity == identity }?.preferences.arcTopSites == [site("profile\(index)")])
        }
        let second = try await coordinator.run(captured, options: options)
        #expect(second.profiles.allSatisfy { $0.counts["Top Sites"]?.imported == 0 && $0.counts["Top Sites"]?.existing == 1 })
    }

}

extension URLEditorTests {
    @Test("Clearing history removes only the initiating profile's imported suggestions, even after a Space switch")
    func historyPrivacy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "url-history-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try BrowserDatabase(path: folder.appending(path: "browser.sqlite"))
        let settings = Settings(defaults: UserDefaults(suiteName: "url-tests.\(UUID())")!)
        let session = BrowserSession(database: database, sessionStore: SessionStore(fileURL: folder.appending(path: "session.json")), settings: settings)
        let first = session.activeSpace
        session.enrichArcTopSites([site("personal")], for: first.identity)
        let other = session.addSpace(named: "Other")
        session.enrichArcTopSites([site("work")], for: other.identity)
        session.selectSpace(first); session.clearHistory(); session.selectSpace(other)
        for _ in 0..<200 {
            if first.profile.preferences.arcTopSites == [] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.profile.preferences.arcTopSites == [])
        #expect(other.profile.preferences.arcTopSites == [site("work")])
    }
}
