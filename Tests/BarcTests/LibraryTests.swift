import AppKit
import Combine
import Foundation
import Testing
@testable import Barc

@Suite("Library saved data and temporary layout")
@MainActor
struct LibraryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "barc-library-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test("Text, file type and Space filters intersect and preserve download origin")
    func queriesAndProfileAttribution() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = TestSession.make().0
        let personal = session.activeSpace
        let work = session.addSpace(named: "Work")
        let image = DownloadRecord(id: UUID(), sourceURL: URL(string: "https://images.example/cafe.png")!,
            destination: directory.appending(path: "Café estimate.png"), state: .finished, startedAt: Date(), finishedAt: nil, byteCount: 1024,
            sourceProfileKey: ProfileDataPaths.key(for: personal.identity))
        let pdf = DownloadRecord(id: UUID(), sourceURL: URL(string: "https://work.example/estimate.pdf")!,
            destination: directory.appending(path: "Estimate.pdf"), state: .finished, startedAt: Date(timeIntervalSinceNow: -100), finishedAt: nil, byteCount: 2048,
            sourceProfileKey: ProfileDataPaths.key(for: work.identity))
        let store = DownloadStore(fileURL: directory.appending(path: "downloads.json"))
        try store.save([image, pdf])
        let manager = DownloadManager(store: store), boosts = BoostStore(folder: directory)
        let entries = LibraryCatalog.entries(for: .downloads, session: session, downloads: manager, boosts: boosts)
        #expect(entries.count == 2)
        #expect(LibraryQuery(text: "CAFE estimate", spaceID: personal.id, fileKind: .image).apply(to: entries).map(\.id) == [.download(image.id)])
        #expect(LibraryQuery(text: "estimate", spaceID: work.id, fileKind: .image).apply(to: entries).isEmpty)
        #expect(LibraryQuery(spaceID: work.id).apply(to: entries).map(\.id) == [.download(pdf.id)])
        let media = LibraryCatalog.entries(for: .media, session: session, downloads: manager, boosts: boosts)
        #expect(media.map(\.id) == [.download(image.id)])
        #expect(manager.downloads.count == 2, "Filtering never rewrites download history or deletes files")
    }

    @Test("The archive catalog spans real Spaces and filtering cannot restore or discard tabs")
    func archiveCatalog() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = TestSession.make().0
        let personal = session.activeSpace
        let tab = session.newTab(url: URL(string: "https://personal.invalid/page")!)
        session.archive([tab])
        let other = session.addSpace(named: "Other")
        let second = session.newTab(url: URL(string: "https://work.invalid/page")!)
        session.archive([second])
        let manager = DownloadManager(store: DownloadStore(fileURL: directory.appending(path: "empty.json")))
        let entries = LibraryCatalog.entries(for: .archive, session: session, downloads: manager, boosts: BoostStore(folder: directory))
        #expect(entries.count == 2)
        #expect(LibraryQuery(spaceID: personal.id).apply(to: entries).first?.url?.host() == "personal.invalid")
        #expect(LibraryQuery(spaceID: other.id).apply(to: entries).first?.url?.host() == "work.invalid")
        #expect(session.archivedTabs.count == 2)
    }

    @Test("Media is opt-in and Show Media exposes real files without changing download history")
    func mediaOptIn() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "barc.library.media.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let record = DownloadRecord(id: UUID(), sourceURL: URL(string: "https://images.invalid/picture.png")!,
            destination: directory.appending(path: "picture.png"), state: .finished, startedAt: .now, finishedAt: nil, byteCount: 64)
        let store = DownloadStore(fileURL: directory.appending(path: "downloads.json")); try store.save([record])
        let manager = DownloadManager(store: store)
        let view = SidebarLibraryView(session: TestSession.make().0, downloads: manager, boosts: BoostStore(folder: directory), defaults: defaults)
        view.select(.media)
        #expect(view.visibleEntries.isEmpty)
        let search = try #require(UITestSupport.descendants(of: view).compactMap { $0 as? NSSearchField }.first)
        #expect(!search.isEnabled)
        let show = try #require(UITestSupport.descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == "Show Media" })
        show.performClick(nil)
        #expect(search.isEnabled)
        #expect(view.visibleEntries.map(\.id) == [.download(record.id)])
        #expect(manager.downloads.count == 1)
        #expect(defaults.bool(forKey: "sidebarLibraryMediaEnabled"))
    }

    @Test("Switching Library categories never replaces the normal width with a temporary width")
    func widthLease() {
        var state = LibrarySidebarWidth()
        #expect(state.show(.downloads, current: 228) == 417)
        #expect(state.show(.spaces, current: 417) == 112)
        #expect(state.show(.archive, current: 112) == 417)
        #expect(state.resting == 228)
        #expect(state.close() == 228)
        #expect(state.close() == nil)
        #expect(state.show(.spaces, current: 310) == 112)
        #expect(state.close() == 310)
    }

    @Test("The selected category and its query survive leaving and returning to the list")
    func categoryAndSearch() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "barc.library.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoostStore(folder: directory)
        store.save(Boost(host: "one.invalid", name: "Alpha")); store.save(Boost(host: "two.invalid", name: "Beta"))
        let session = TestSession.make().0
        let manager = DownloadManager(store: DownloadStore(fileURL: directory.appending(path: "empty.json")))
        let view = SidebarLibraryView(session: session, downloads: manager, boosts: store, defaults: defaults)
        _ = UITestSupport.host(view, width: 418, height: 800)
        view.select(.boosts)
        #expect(view.visibleEntries.count == 2)
        let field = try #require(UITestSupport.descendants(of: view).compactMap { $0 as? NSSearchField }.first)
        field.stringValue = "Alpha"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(view.visibleEntries.map(\.title) == ["Alpha"])
        view.select(.spaces); view.select(.boosts)
        #expect(field.stringValue == "Alpha")
        #expect(view.visibleEntries.map(\.title) == ["Alpha"])
        let next = SidebarLibraryView(session: session, downloads: manager, boosts: store, defaults: defaults)
        #expect(next.category == .boosts)
    }

    @Test("Header controls can transfer to the Library and back without losing the native window buttons")
    func trafficLightLifecycle() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 418, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let sidebar = SidebarViewController(session: TestSession.make().0)
        window.contentViewController = sidebar
        sidebar.view.layoutSubtreeIfNeeded()
        let button = try #require(window.standardWindowButton(.closeButton))
        let original = button.superview
        sidebar.showLibrary(category: .downloads); sidebar.view.layoutSubtreeIfNeeded()
        let library = try #require(UITestSupport.descendants(of: sidebar.view).compactMap { $0 as? SidebarLibraryView }.first)
        #expect(button.superview === library.header)
        sidebar.hideLibrary(); sidebar.view.layoutSubtreeIfNeeded()
        #expect(button.superview === original)
        #expect(!sidebar.isLibraryVisible)
    }

    @Test("The rail-only Spaces layout does not inherit the hidden browser controls' minimum width")
    func railDoesNotCreep() throws {
        let session = TestSession.make().0
        let sidebar = SidebarViewController(session: session)
        _ = sidebar.view
        sidebar.installBrowserControls([ContentTopBar()])
        _ = UITestSupport.host(sidebar.view, width: 228, height: 800)
        sidebar.showLibrary(category: .spaces)
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(sidebar.view.fittingSize.width <= 112.5)
        sidebar.hideLibrary()
        #expect(!sidebar.isSwitchInFlight)
    }

    @Test("The overview uses saved tabs without creating their sleeping web views")
    func overviewDoesNotWakeTabs() {
        let session = TestSession.make().0
        let first = session.newTab(url: URL(string: "https://sleeping.invalid/")!, select: false)
        let second = session.addSpace(named: "Second")
        let other = session.newTab(url: URL(string: "https://other.invalid/")!, select: false)
        let before = session.spaces.flatMap(\.tabs).map(\.id)
        let view = LibrarySpacesView(session: session)
        _ = UITestSupport.host(view, width: 1000, height: 800)
        view.reload()
        #expect(first.currentWebView == nil)
        #expect(other.currentWebView == nil)
        #expect(session.spaces.flatMap(\.tabs).map(\.id) == before)
        #expect(session.activeSpace === second)
    }

    @Test("Library observers do not replace the Boost coordinator's existing callback")
    func boostObserversCoexist() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoostStore(folder: directory)
        var callbackCount = 0, eventCount = 0
        store.onChange = { callbackCount += 1 }
        let observer = store.changes.sink { eventCount += 1 }
        store.save(Boost(host: "example.invalid"))
        #expect(callbackCount == 1 && eventCount == 1)
        withExtendedLifetime(observer) {}
    }
}
