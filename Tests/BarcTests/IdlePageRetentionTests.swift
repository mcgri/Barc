import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Idle page retention", .serialized)
@MainActor
struct IdlePageRetentionTests {
    enum Preview: CaseIterable { case glance, floating, littleWindow }
    enum BackgroundActivity: String, CaseIterable { case completed, pending, draft, call }

    @Test("Only completed background work permits sleep at the safety reply boundary", arguments: BackgroundActivity.allCases)
    func completedBackgroundRequest(activity: BackgroundActivity) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source:
            "window.fixtureRequests=0; window.fetch=()=>{fixtureRequests++; return window.fixtureHold ? new Promise(resolve=>{window.fixtureFinish=resolve;}) : Promise.resolve({ok:true});};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        PageHibernationGuard.shared.attach(configuration.userContentController)
        let page = WebEnvironment.shared.makeWebView(configuration: configuration)
        try await MemoryTestPage.load(page, html: "<p>Saved task details</p><textarea id='draft'></textarea>")
        // Put a completed background request at the IPC reply boundary. This
        // makes the race deterministic instead of depending on timer luck.
        _ = try await page.evaluateJavaScript("""
            window.fixtureActivity = '\(activity.rawValue)';
            const query = Document.prototype.querySelectorAll;
            Document.prototype.querySelectorAll = function(selector) {
                if (selector === 'iframe, frame') {
                    window.fixtureHold = fixtureActivity === 'pending';
                    void fetch('/background', {method:'POST',body:'refresh'});
                    if (fixtureActivity === 'draft') {
                        draft.value = 'Unsent comment';
                        draft.dispatchEvent(new Event('input', {bubbles:true}));
                    }
                    if (fixtureActivity === 'call' && !window.fixturePeer) window.fixturePeer = new RTCPeerConnection();
                }
                return query.call(this, selector);
            }; true
            """)
        let session = TestSession.make().0
        let tab = session.adoptGlancedTab(page, after: session.activeTab)
        defer { tab.unload() }
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.idle-replies.\(UUID())")!)
        var now: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere")
        now = 61
        await driver.evaluate(.idle)
        #expect(try await page.evaluateJavaScript("fixtureRequests") as? Int ?? 0 > 0)
        #expect(tab.isAsleep == (activity == .completed),
                "Completed requests may sleep; pending requests, edits and calls must remain protected")
        if activity == .draft {
            #expect(try await page.evaluateJavaScript("draft.value") as? String == "Unsent comment")
        }
        _ = try? await page.evaluateJavaScript("if(window.fixturePeer) fixturePeer.close(); true")
    }

    @Test("An edit in an already checked split pane cancels sleep for the entire group")
    func splitDraftDuringInspection() async throws {
        let session = TestSession.make().0
        let firstPage = try await MemoryTestPage.make(html: "<textarea id='draft'></textarea>")
        let first = session.adoptGlancedTab(firstPage, after: session.activeTab)
        let secondPage = try await MemoryTestPage.make(html: "<textarea id='draft'></textarea>")
        let second = session.adoptGlancedTab(secondPage, after: first)
        defer { first.unload(); second.unload() }
        try #require(session.splitTabs([first, second]))
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.split-recheck.\(UUID())")!)
        var now: TimeInterval = 0
        var earlier: WKWebView?
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, inspectPage: { page in
            if let earlier {
                _ = try? await earlier.evaluateJavaScript("draft.value='Unsent comment'; draft.dispatchEvent(new Event('input',{bubbles:true})); true")
            }
            let safe = await PageHibernationGuard.shared.permitsHibernation(of: page)
            earlier = page
            return safe
        }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere")
        now = 61
        await driver.evaluate(.idle)
        #expect(first.isLoaded && second.isLoaded, "An edit after a pane's audit must invalidate the group approval")
        #expect(try await earlier?.evaluateJavaScript("document.querySelector('textarea') !== null") as? Bool == true)
    }

    @Test("Closing a preview releases its document even if an editing panel retains the view", arguments: Preview.allCases)
    func dismissedPreview(kind: Preview) async throws {
        let server = try MemoryHTTPFixture()
        defer { server.stop() }
        let url = try await server.start()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let existing = Set(WebEnvironment.shared.liveWebViews.map(ObjectIdentifier.init))
        let close: () -> Void
        switch kind {
        case .glance:
            let glance = GlanceController()
            glance.install(in: host, ownerPage: { nil }, identity: { .makeEphemeral() })
            glance.open(url: url, origin: .centre, source: .command)
            close = { glance.dismiss(.ownerTabClosed) }
        case .floating:
            let page = try await MemoryTestPage.make()
            let controller = FloatingWebWindowController(webView: page)
            page.load(URLRequest(url: url))
            close = { controller.close() }
        case .littleWindow:
            let controller = LittleArcWindowController(url: url, identity: .makeEphemeral())
            close = { controller.close() }
        }
        let page = try #require(WebEnvironment.shared.liveWebViews.first { !existing.contains(ObjectIdentifier($0)) })
        defer { close() }
        for _ in 0..<500 {
            if !page.isLoading, (try? await page.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await page.evaluateJavaScript("window.fixturePayload=new Uint8Array(16*1024*1024); true")
        close()
        try #require(page.superview == nil)
        for _ in 0..<400 {
            if (try? await page.evaluateJavaScript("typeof fixturePayload")) as? String == "undefined", !page.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await page.evaluateJavaScript("typeof fixturePayload") as? String == "undefined",
                "A closed preview must not keep its old document alive in other web content")
        #expect(page.backForwardList.backList.isEmpty)
    }

    @Test("Closing a standalone web app detaches and retires its page")
    func dismissedWebApp() async throws {
        let server = try MemoryHTTPFixture()
        defer { server.stop() }
        let app = InstalledWebApp(name: "Retention fixture", url: try await server.start())
        let controller = WebAppWindowController(app: app, identity: .makeEphemeral())
        defer { controller.close() }
        let page = controller.webView
        for _ in 0..<500 {
            if !page.isLoading, (try? await page.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await page.evaluateJavaScript("window.fixturePayload=new Uint8Array(16*1024*1024); true")
        controller.close()
        try #require(page.superview == nil)
        for _ in 0..<400 {
            if (try? await page.evaluateJavaScript("typeof fixturePayload")) as? String == "undefined", !page.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await page.evaluateJavaScript("typeof fixturePayload") as? String == "undefined")
    }

    @Test("Moving a preview into a tab keeps its live draft after the old surface closes", arguments: Preview.allCases)
    func previewHandoff(kind: Preview) async throws {
        let server = try MemoryHTTPFixture()
        defer { server.stop() }
        let url = try await server.start()
        let session = TestSession.make().0
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let existing = Set(WebEnvironment.shared.liveWebViews.map(ObjectIdentifier.init))
        var kept: Tab?
        let adopt: (WKWebView) -> Void = { page in
            page.removeFromSuperview()
            kept = session.adoptGlancedTab(page, after: session.activeTab)
        }
        let handoff: () -> Void
        let close: () -> Void
        switch kind {
        case .glance:
            let glance = GlanceController()
            glance.install(in: host, ownerPage: { nil }, identity: { session.activeSpace.identity })
            glance.onPromote = { page, _, _ in adopt(page) }
            glance.open(url: url, origin: .centre, source: .command)
            handoff = { glance.promote() }
            close = { glance.dismiss(.applicationQuitting) }
        case .floating:
            let page = try await MemoryTestPage.make(identity: session.activeSpace.identity)
            let controller = FloatingWebWindowController(webView: page)
            controller.onDockBack = { page, _ in adopt(page) }
            page.load(URLRequest(url: url))
            handoff = { controller.dockBack() }
            close = { controller.close() }
        case .littleWindow:
            let controller = LittleArcWindowController(url: url, identity: session.activeSpace.identity)
            controller.spaceChoices = {
                [.init(id: session.activeSpace.id, title: "Fixture", image: nil, isOwner: true)]
            }
            controller.onMove = { _, _, page, _ in adopt(page) }
            handoff = { controller.keepInOwnerSpace() }
            close = { controller.close() }
        }
        defer { close(); kept?.unload() }
        let page = try #require(WebEnvironment.shared.liveWebViews.first { !existing.contains(ObjectIdentifier($0)) })
        for _ in 0..<500 {
            if !page.isLoading, (try? await page.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await page.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<textarea id=liveDraft></textarea>'); liveDraft.value='Keep this unsent draft'; liveDraft.dispatchEvent(new Event('input',{bubbles:true})); true")
        try await Task.sleep(for: .milliseconds(500))
        handoff()
        for _ in 0..<200 where kept == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(kept?.currentWebView === page)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(try await page.evaluateJavaScript("liveDraft.value") as? String == "Keep this unsent draft")
        #expect(!(await MemoryTestPage.safe(page)), "A handed-over draft must still protect the new tab")
    }
}
