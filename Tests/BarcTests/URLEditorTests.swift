// Modified for Barc: separate keyboard/pointer URL entry and profile-local ranked suggestions, 2026-10-24.
import AppKit
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
        bar.onRun = { action = $0; newTab = $1 }
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
