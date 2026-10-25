// Modified for Barc: workspace-scoped launcher destinations and profile-owned history, 2026-10-25.
import AppKit
import Testing
@testable import Barc

@Suite("Launcher profile isolation", .serialized)
@MainActor
struct LauncherProfileIsolationTests {
    private func bar(in controller: BrowserWindowController) throws -> CommandBar {
        let view = try #require(controller.window?.contentView)
        return try #require(UITestSupport.descendants(of: view).compactMap { $0 as? CommandBar }.first)
    }

    @Test("History suggestions and top sites come only from the current profile, including identical URLs")
    func profileHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launcher-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Settings(defaults: UserDefaults(suiteName: "barc.tests.\(UUID())")!)
        let database = try BrowserDatabase(path: directory.appending(path: "browser.sqlite"))
        let routing = SpaceRoutingService(store: SpaceRoutingStore(fileURL: directory.appending(path: "routes.json")))
        let session = BrowserSession(database: database, sessionStore: SessionStore(fileURL: directory.appending(path: "session.json")),
            settings: settings, routing: routing, searchSuggestions: nil)
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")
        let workDatabase = try #require(session.database(for: work.identity))
        let sharedURL = try #require(URL(string: "https://console-isolation.invalid/shared"))
        let personalURL = try #require(URL(string: "https://console-isolation.invalid/personal"))
        let workURL = try #require(URL(string: "https://console-isolation.invalid/work"))
        for url in [sharedURL, personalURL] {
            try await database.recordVisit(url: url, title: "Personal Console", key: AddressFormatter.display(url))
        }
        for url in [sharedURL, workURL] {
            try await workDatabase.recordVisit(url: url, title: "Work Console", key: AddressFormatter.display(url))
        }
        var sources = settings.suggestionSources
        sources.history = true; sources.openTabs = false; sources.searchEngine = false
        settings.suggestionSources = sources
        session.selectSpace(personal)
        let controller = BrowserWindowController(session: session, commandSettings: settings)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let commandBar = try bar(in: controller)
        let provider = try #require(commandBar.resultsProvider)
        let personalRows = await provider("console-isolation")
        #expect(personalRows.contains { $0.action == .openURL(personalURL) })
        #expect(personalRows.contains { $0.action == .openURL(sharedURL) && $0.title == "Personal Console" })
        #expect(!personalRows.contains { $0.action == .openURL(workURL) || $0.title == "Work Console" })
        #expect(Set(await session.topSites().map(\.url)) == Set([sharedURL, personalURL]))
        session.selectSpace(work)
        let workRows = await provider("console-isolation")
        #expect(workRows.contains { $0.action == .openURL(workURL) })
        #expect(workRows.contains { $0.action == .openURL(sharedURL) && $0.title == "Work Console" })
        #expect(!workRows.contains { $0.action == .openURL(personalURL) || $0.title == "Personal Console" })
        #expect(Set(await session.recentHistory().map(\.url)) == Set([sharedURL, workURL]))
        session.addSpace(named: "Private", isPrivate: true)
        let privateRows = await provider("console-isolation")
        #expect(!privateRows.contains { $0.kind == .history })
        #expect(await session.topSites().isEmpty)
    }

    @Test("Submitting a URL stays in the workspace even when a domain rule points to another profile")
    func manualURLIgnoresRouting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launcher-route-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let routing = SpaceRoutingService(store: SpaceRoutingStore(fileURL: directory.appending(path: "routes.json")))
        let session = BrowserSession(database: nil, sessionStore: SessionStore(fileURL: directory.appending(path: "session.json")),
            settings: Settings(defaults: UserDefaults(suiteName: "barc.tests.\(UUID())")!), routing: routing, searchSuggestions: nil)
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")
        let address = try #require(URL(string: "https://console-isolation.invalid/ec2"))
        routing.add(SpaceRoutingRules.rule(forHost: "console-isolation.invalid", destination: .space(work.id)))
        session.selectSpace(personal)
        let workCount = work.tabs.count
        let controller = BrowserWindowController(session: session)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let commandBar = try bar(in: controller)
        commandBar.onRun?(.openURL(address), true, address.absoluteString)
        #expect(session.activeSpace === personal)
        #expect(session.activeTab?.identity == personal.identity)
        #expect(session.activeTab?.url == address)
        #expect(work.tabs.count == workCount)
    }
}
