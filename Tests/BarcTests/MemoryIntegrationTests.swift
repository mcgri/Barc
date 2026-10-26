// Modified for Barc: real restore, transfer, retention and persistence checks, 2026-10-26.
import AppKit
import Combine
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Memory integration", .serialized)
@MainActor
struct MemoryIntegrationTests {
    private func settings() -> Settings { Settings(defaults: UserDefaults(suiteName: "barc.memory-integration.\(UUID())")!) }
    private func waitForPage(_ view: WKWebView) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { return }
        }
        throw MemoryTestPage.Failure.loadTimedOut
    }

    @Test("An unloaded view is deallocated, rather than retained by its frame guard")
    func releasedView() async throws {
        let session = TestSession.make().0
        var view: WKWebView? = try await MemoryTestPage.make(identity: session.activeSpace.identity)
        weak var released = view
        let tab = session.adoptGlancedTab(try #require(view), after: session.activeTab)
        view = nil
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere"); time = 61
        await driver.evaluate(.idle)
        #expect(!tab.isLoaded)
        for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released == nil)
    }

    @Test("A real HTTP page wakes with its session cookie, persistent cookie and scroll position")
    func authenticatedRestore() async throws {
        let server = try MemoryHTTPFixture(); defer { server.stop() }
        let base = try await server.start()
        let session = TestSession.make().0
        let profile = try #require(session.addProfile(named: "Restore fixture"))
        session.addSpace(named: "Signed in", profile: profile)
        let store = WebEnvironment.shared.dataStore(for: profile.identity)
        let cookie = try #require(HTTPCookie(properties: [.name:"session-test",.value:"fictional-login",.domain:"127.0.0.1",.path:"/"]))
        let persistent = try #require(HTTPCookie(properties: [.name:"persistent-test",.value:"fictional-login",.domain:"127.0.0.1",.path:"/",.expires:Date().addingTimeInterval(3600)]))
        await store.httpCookieStore.setCookie(cookie); await store.httpCookieStore.setCookie(persistent)
        var view: WKWebView? = try await MemoryTestPage.make(identity: profile.identity)
        let tab = session.adoptGlancedTab(try #require(view), after: session.activeTab)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:480),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = view
        window.orderFront(nil)
        view?.load(URLRequest(url: base.appending(path:"page")))
        try await waitForPage(try #require(view))
        _ = try await view?.evaluateJavaScript("scrollTo(0,900); true")
        let before = try #require(try await view?.evaluateJavaScript("scrollY") as? Double)
        #expect(before == 900)
        try await Task.sleep(for:.milliseconds(150))
        #expect(await MemoryTestPage.safe(try #require(view)))
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, additionalVisibleProfiles: { [] })
        let original = session.activeSpace
        session.addSpace(named:"Elsewhere"); time = 61
        window.orderOut(nil)
        window.contentView = nil
        await driver.evaluate(.idle)
        #expect(!tab.isLoaded)
        #expect(tab.snapshot().hibernationViewport?.y == 900)
        view = nil
        session.selectSpace(original)
        let restored = tab.webView()
        window.contentView = restored
        window.orderFront(nil)
        try await waitForPage(restored)
        let cookies = try #require(try await restored.evaluateJavaScript("document.cookie") as? String)
        #expect(cookies.contains("session-test=fictional-login"))
        #expect(cookies.contains("persistent-test=fictional-login"))
        #expect(restored.configuration.websiteDataStore === store)
        for _ in 0..<100 {
            if (try? await restored.evaluateJavaScript("scrollY")) as? Double == before { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let after = try await restored.evaluateJavaScript("scrollY") as? Double
        #expect(after == before)
        tab.unload()
        await store.httpCookieStore.deleteCookie(cookie); await store.httpCookieStore.deleteCookie(persistent)
        WebEnvironment.shared.releaseDataStore(for:profile.identity)
    }

    private final class DownloadNavigation: NSObject, WKNavigationDelegate {
        let manager: DownloadManager
        init(_ manager: DownloadManager) { self.manager = manager }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) { decisionHandler(manager.policy(for:response)) }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { manager.adopt(download) }
    }

    @Test("A real in-progress download protects its host and finishes without interruption")
    func runningDownload() async throws {
        let server = try MemoryHTTPFixture(); defer { server.stop() }
        let base = try await server.start()
        let root = FileManager.default.temporaryDirectory.appending(path:"barc-transfer-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let session = TestSession.make().0
        let original = session.activeSpace
        session.setDownloadsDirectoryPath(root.path, for:original)
        let manager = DownloadManager(store:DownloadStore(fileURL:root.appending(path:"downloads.json")), settings:settings())
        manager.spaceResolver = { _ in original }
        let view = try await MemoryTestPage.make(identity:original.identity)
        let tab = session.adoptGlancedTab(view, after:session.activeTab)
        let navigation = DownloadNavigation(manager)
        view.navigationDelegate = navigation
        view.load(URLRequest(url:base.appending(path:"download")))
        for _ in 0..<300 where manager.downloads.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        let item = try #require(manager.downloads.first)
        #expect(item.state == .running)
        #expect(manager.protectsFromHibernation(view))
        var time:TimeInterval = 0
        let driver = TabSuspender(session:session,settings:settings(),uptime:{time},
                                  protectsTransfer:{manager.protectsFromHibernation($0)}, additionalVisibleProfiles:{[]})
        session.addSpace(named:"Elsewhere");time = 61
        for trigger in [TabSuspension.Trigger.idle,.memoryWarning,.memoryCritical] { await driver.evaluate(trigger) }
        #expect(tab.currentWebView === view)
        server.finishDownloads()
        for _ in 0..<300 where item.state == .running { try await Task.sleep(for:.milliseconds(10)) }
        #expect(item.state == .finished)
        #expect(try Data(contentsOf:item.destination).count == MemoryHTTPFixture.downloadBytes)
        #expect(!manager.protectsFromHibernation(view))
        manager.saveNow()
        tab.unload()
    }

    @Test("Queued checkpoints cannot overwrite a later explicit save or survive clear")
    func persistenceOrder() throws {
        let file = FileManager.default.temporaryDirectory.appending(path:"barc-save-order-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at:file) }
        let store = SessionStore(fileURL:file)
        let older = SessionSnapshot(spaces:[SessionSnapshot.Space(name:"Older")],activeSpaceIndex:0)
        let newer = SessionSnapshot(spaces:[SessionSnapshot.Space(name:"Latest")],activeSpaceIndex:0)
        for _ in 0..<20 { store.enqueue(older) }
        try store.save(newer)
        #expect(store.load() == newer)
        store.enqueue(older);store.clear()
        #expect(store.load() == nil)
        try store.save(older)
        #expect(store.load() == older)
        let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Transient progress refreshes the UI without gathering and encoding a new session")
    func transientChanges() async throws {
        let (session,store) = TestSession.make()
        defer { try? FileManager.default.removeItem(at:store.fileURL) }
        session.saveNow()
        let before = store.encodingPassCount
        let tab = try #require(session.activeTab)
        var changes = 0
        let observer = session.changes.sink { if case .tab = $0 { changes += 1 } }
        for _ in 0..<30 { tab.transientDidChange.send() }
        try await Task.sleep(for:.milliseconds(1200))
        #expect(changes == 30)
        #expect(store.encodingPassCount == before)
        tab.setNote("Persist this note")
        try await Task.sleep(for:.milliseconds(1200))
        #expect(store.encodingPassCount == before + 1)
        #expect(store.load()?.spaces.first?.tabs.first?.note == "Persist this note")
        observer.cancel()
    }
}

extension MemoryIntegrationTests {
    private final class WeakView {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }
    @Test("Repeated profile sleep and wake cycles do not accumulate live views")
    func repeatedCycles() async throws {
        let server = try MemoryHTTPFixture();defer {server.stop()}
        let base = try await server.start()
        let session = TestSession.make().0
        let profile = try #require(session.addProfile(named:"Cycle fixture"))
        let original = session.addSpace(named:"Cycle",profile:profile)
        var initial: WKWebView? = try await MemoryTestPage.make(identity:profile.identity)
        let tab = session.adoptGlancedTab(try #require(initial),after:session.activeTab)
        initial?.load(URLRequest(url:base.appending(path:"page")))
        try await waitForPage(try #require(initial))
        initial = nil
        let elsewhere = session.addSpace(named:"Elsewhere")
        var time: TimeInterval = 0
        let driver = TabSuspender(session:session,settings:settings(),uptime:{time},additionalVisibleProfiles:{[]})
        var references:[WeakView] = []
        for _ in 0..<8 {
            session.selectSpace(original)
            var view:WKWebView? = tab.webView()
            try await waitForPage(try #require(view))
            references.append(WeakView(try #require(view)))
            session.selectSpace(elsewhere);time += 61
            await driver.evaluate(.idle)
            #expect(!tab.isLoaded)
            view = nil
        }
        for _ in 0..<100 where references.contains(where:{$0.value != nil}) {try await Task.sleep(for:.milliseconds(10))}
        #expect(references.allSatisfy{$0.value == nil})
        #expect(session.allTabs.filter{$0.identity == profile.identity}.count == 2,"Only the original start tab and fixture page remain")
        WebEnvironment.shared.releaseDataStore(for:profile.identity)
    }
}

@Suite("Scheduled profile hibernation", .serialized)
@MainActor
struct ScheduledProfileHibernationTests {
    @Test("The real scheduler waits a minute and then unloads a quiet inactive profile", .timeLimit(.minutes(2)))
    func realMinute() async throws {
        let session = TestSession.make().0
        var view:WKWebView? = try await MemoryTestPage.make(identity:session.activeSpace.identity)
        let tab = session.adoptGlancedTab(try #require(view),after:session.activeTab)
        view = nil
        let preferences = Settings(defaults:UserDefaults(suiteName:"barc.minute-scheduler.\(UUID())")!)
        let driver = TabSuspender(session:session,settings:preferences,additionalVisibleProfiles:{[]})
        driver.start();defer {driver.stop();tab.unload()}
        session.addSpace(named:"Elsewhere")
        try await Task.sleep(for:.seconds(55))
        #expect(tab.isLoaded,"The page must not unload before a full minute")
        for _ in 0..<30 where tab.isLoaded {try await Task.sleep(for:.seconds(1))}
        #expect(!tab.isLoaded,"The ordinary timer, not a direct policy call, released the page")
    }
}
