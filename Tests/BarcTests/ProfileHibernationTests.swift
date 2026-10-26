// Modified for Barc: real-page hibernation and preservation regression tests, 2026-10-26.
import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@MainActor
enum MemoryTestPage {
    enum Failure: Error { case loadTimedOut }
    static func make(identity: Space.Identity = .makeEphemeral(), html: String = "<p>A quiet page</p>",
                     scripts: [String] = []) async throws -> WKWebView {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebEnvironment.shared.dataStore(for: identity)
        PageHibernationGuard.shared.attach(config.userContentController)
        for script in scripts {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WebEnvironment.shared.makeWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        try await load(view, html: html)
        return view
    }
    static func load(_ view: WKWebView, html: String) async throws {
        view.loadHTMLString("<!doctype html><html><body>\(html)<i id='fixtureReady'></i></body></html>", baseURL: URL(string: "http://127.0.0.1/fixture/"))
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('fixtureReady')")) as? Bool == true { return }
        }
        throw Failure.loadTimedOut
    }
    static func safe(_ view: WKWebView) async -> Bool {
        for _ in 0..<10 {
            if await PageHibernationGuard.shared.permitsHibernation(of: view) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite("Live page hibernation protections", .serialized)
@MainActor
struct LivePageHibernationTests {
    @Test("Quiet documents qualify; typing and a submit event do not discard a draft")
    func inputDraft() async throws {
        let view = try await MemoryTestPage.make(html: "<form><textarea id='draft'></textarea></form>")
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("draft.value='unfinished'; draft.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('form').dispatchEvent(new Event('submit')); true")
        #expect(!(await MemoryTestPage.safe(view)))
        #expect(try await view.evaluateJavaScript("draft.value") as? String == "unfinished")
        try await MemoryTestPage.load(view, html: "<p>A new document</p>")
        #expect(await MemoryTestPage.safe(view), "Only navigation clears the old draft protection")
    }

    @Test("Autofill input events and edits to existing rich text remain protected")
    func autofillAndRichDrafts() async throws {
        let view = try await MemoryTestPage.make(html: "<input id='email'>")
        _ = try await view.evaluateJavaScript("email.value='unsubmitted@example.invalid'; email.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
        try await MemoryTestPage.load(view, html: "<div id='editor' contenteditable='true'>Saved rich text</div>")
        _ = try await view.evaluateJavaScript("editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); editor.textContent='An unsaved change'; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
    }

    @Test("A draft in a child frame protects the whole document")
    func frameDraft() async throws {
        let view = try await MemoryTestPage.make(html: "<iframe srcdoc=\"<textarea id='draft'></textarea>\"></iframe>")
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("const d=document.querySelector('iframe').contentDocument; const editor=d.getElementById('draft'); editor.value='child draft'; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
    }

    @Test("Data-only calls keep the page awake until the peer is closed")
    func dataCall() async throws {
        let view = try await MemoryTestPage.make()
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("window.peer=new RTCPeerConnection(); peer.createDataChannel('fixture'); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("peer.close(); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("An upload stays protected while its request is pending")
    func upload() async throws {
        let fakeNetwork = "window.fetch = function() { return new Promise(resolve => { window.finishUpload=resolve; }); };"
        // Install fake transport BEFORE the guard, so the guard wraps it just
        // as it wraps native fetch. No fixture traffic leaves the process.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: fakeNetwork, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        PageHibernationGuard.shared.attach(config.userContentController)
        let view = WKWebView(frame: .zero, configuration: config)
        try await MemoryTestPage.load(view, html: "<p>Upload fixture</p>")
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("fetch('/upload',{method:'POST',body:'fixture'}); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("finishUpload({ok:true}); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("Uninstrumented documents never grant permission")
    func unknown() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        try await MemoryTestPage.load(view, html: "<p>No guard attached</p>")
        #expect(!(await PageHibernationGuard.shared.permitsHibernation(of: view)))
    }
}

@Suite("Profile hibernation lifecycle", .serialized)
@MainActor
struct ProfileHibernationTests {
    private func settings() -> Settings { Settings(defaults: UserDefaults(suiteName: "barc.hibernate.\(UUID())")!) }

    @Test("The minute starts on hiding, not when a long reading session began")
    func clockTransitions() {
        let a = UUID(), b = UUID(), profile = Space.Identity.makeIsolated()
        var clock = ProfileHibernationClock()
        clock.update(tabs: [a: profile, b: profile], visible: [a], now: 0)
        clock.update(tabs: [a: profile, b: profile], visible: [b], now: 300)
        #expect(clock.tabIdle(a, now: 359) == 59)
        #expect(clock.visibleProfiles.contains(profile))
        #expect(clock.profileIdle(profile, now: 600) == 0)
        clock.update(tabs: [a: profile, b: profile], visible: [], now: 600)
        #expect(clock.profileIdle(profile, now: 659) == 59)
        #expect(clock.profileIdle(profile, now: 660) == 60)
    }

    @Test("Inactive profile views unload after a full minute and only selected content wakes")
    func unloadAndLazyWake() async throws {
        let session = TestSession.make().0
        let profile = try #require(session.addProfile(named: "Hibernate fixture"))
        session.addSpace(named: "Fixture", profile: profile)
        let firstView = try await MemoryTestPage.make(identity: profile.identity)
        let first = session.adoptGlancedTab(firstView, after: session.activeTab)
        let secondView = try await MemoryTestPage.make(identity: profile.identity)
        let second = session.adoptGlancedTab(secondView, after: first)
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, additionalVisibleProfiles: { [] })
        time = 300 // a long reading session must not count as background time
        let elsewhere = session.addSpace(named: "Elsewhere")
        time = 359
        await driver.evaluate(.idle)
        #expect(first.isLoaded && second.isLoaded)
        time = 360
        await driver.evaluate(.idle)
        #expect(!first.isLoaded && !second.isLoaded)
        #expect(driver.lastSweepUnloadedCount == 2)
        #expect(session.activeSpace === elsewhere)
        #expect(session.allTabs.contains { $0 === first })
        session.selectTab(first)
        _ = first.webView()
        #expect(first.isLoaded && !second.isLoaded)
        first.unload()
    }

    @Test("A draft survives automatic hibernation even under critical pressure")
    func protectedDraft() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity, html: "<textarea id='draft'></textarea>")
        let draft = session.adoptGlancedTab(view, after: session.activeTab)
        _ = try await view.evaluateJavaScript("draft.value='Keep this'; draft.dispatchEvent(new Event('input')); true")
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere"); time = 61
        for trigger in [TabSuspension.Trigger.idle, .memoryWarning, .memoryCritical] { await driver.evaluate(trigger) }
        #expect(draft.currentWebView === view)
        #expect(try await view.evaluateJavaScript("draft.value") as? String == "Keep this")
        draft.unload()
    }

    @Test("Returning during inspection cancels a stale unload")
    func activationRace() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity)
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        let original = session.activeSpace
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, inspectPage: { _ in
            session.selectSpace(original)
            return true
        }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere"); time = 61
        await driver.evaluate(.idle)
        #expect(tab.isLoaded && session.activeTab === tab)
        tab.unload()
    }

    @Test("Transfer hosts are protected; never-sleep leaves profile settings independent")
    func transferAndSetting() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity)
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        let preferences = settings()
        #expect(preferences.profileHibernationDelay == 60)
        #expect(preferences.tabSuspensionDelay == 600)
        preferences.profileHibernationMinutes = 0
        #expect(preferences.profileHibernationDelay == nil)
        #expect(preferences.tabSuspensionDelay == 600)
        preferences.profileHibernationMinutes = 1
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { time },
                                  protectsTransfer: { $0 === view }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere"); time = 1000
        await driver.evaluate(.memoryCritical)
        #expect(tab.isLoaded)
        tab.unload()
    }

    @Test("Hibernation retains persistent and session-only cookies in the same isolated store")
    func sessionCookies() async throws {
        let session = TestSession.make().0
        let profile = try #require(session.addProfile(named: "Authentication fixture"))
        session.addSpace(named: "Signed in", profile: profile)
        let store = WebEnvironment.shared.dataStore(for: profile.identity)
        let sessionCookie = try #require(HTTPCookie(properties: [.name:"session-fixture",.value:"fictional",.domain:"127.0.0.1",.path:"/"]))
        let persistent = try #require(HTTPCookie(properties: [.name:"persistent-fixture",.value:"fictional",.domain:"127.0.0.1",.path:"/",.expires:Date().addingTimeInterval(3600)]))
        await store.httpCookieStore.setCookie(sessionCookie); await store.httpCookieStore.setCookie(persistent)
        let view = try await MemoryTestPage.make(identity: profile.identity)
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        var time: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: settings(), uptime: { time }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere"); time = 61
        await driver.evaluate(.idle)
        #expect(!tab.isLoaded)
        #expect(WebEnvironment.shared.dataStore(for: profile.identity) === store)
        let cookies = await store.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == sessionCookie.name && $0.value == "fictional" })
        #expect(cookies.contains { $0.name == persistent.name && $0.value == "fictional" })
        await store.httpCookieStore.deleteCookie(sessionCookie); await store.httpCookieStore.deleteCookie(persistent)
        WebEnvironment.shared.releaseDataStore(for: profile.identity)
    }
}
