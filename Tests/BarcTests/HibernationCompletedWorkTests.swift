import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Completed work permits automatic sleep", .serialized)
@MainActor
struct HibernationCompletedWorkTests {
    @Test("Clearing a draft permits the next idle sweep without navigating")
    func clearedDraft() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity,
            html: "<textarea id='draft'></textarea>")
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        defer { tab.unload() }
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.completed-work.\(UUID())")!)
        var now: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, additionalVisibleProfiles: { [] })
        _ = try await view.evaluateJavaScript("draft.value='Unfinished'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        session.addSpace(named: "Elsewhere")
        now = 61
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "An unfinished draft must survive automatic sleep")
        #expect(tab.automaticSleepExplanation == "Unfinished form or draft")
        _ = try await view.evaluateJavaScript("draft.value=''; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        now = 71
        await driver.evaluate(.idle)
        #expect(!tab.isLoaded, "An empty editor must not keep its profile awake forever")
        #expect(tab.automaticSleepExplanation == "Asleep")
    }

    @Test("Cleared rich editors sleep; text, attachments and failed submissions stay protected")
    func richDrafts() async throws {
        let view = try await MemoryTestPage.make(html: "<form><div id='editor' contenteditable='true'></div></form>")
        _ = try await view.evaluateJavaScript("editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); editor.textContent='Unsent'; editor.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('form').dispatchEvent(new Event('submit')); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("editor.innerHTML='<img alt=\"Unsent attachment\">'; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("editor.innerHTML='<br>'; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("Detached drafts and framework default-value updates do not count as saved work")
    func detachedDrafts() async throws {
        let view = try await MemoryTestPage.make(html: "<textarea id='draft'></textarea>")
        _ = try await view.evaluateJavaScript("window.savedEditor=draft; draft.value='Unsent'; draft.dispatchEvent(new Event('input', {bubbles:true})); draft.defaultValue='Unsent'; true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("savedEditor.remove(); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("savedEditor.value=''; true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("Deleting existing content is still an unsaved edit, even in a detached editor")
    func unsavedDeletion() async throws {
        let view = try await MemoryTestPage.make(html: "<textarea id='draft'>Original note</textarea><div id='editor' contenteditable='true'>Original rich note</div>")
        _ = try await view.evaluateJavaScript("draft.dispatchEvent(new Event('beforeinput', {bubbles:true})); draft.value=''; draft.dispatchEvent(new Event('input', {bubbles:true})); draft.remove(); editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); editor.textContent=''; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)), "Emptying existing content must not discard an unsaved deletion")
    }

    @Test("Returning form choices to their initial state permits sleep")
    func revertedChoices() async throws {
        let view = try await MemoryTestPage.make(html: "<input type='checkbox' id='choice'><select id='selection'><option>One</option><option>Two</option></select>")
        _ = try await view.evaluateJavaScript("choice.checked=true; choice.dispatchEvent(new Event('change', {bubbles:true})); selection.selectedIndex=1; selection.dispatchEvent(new Event('change', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("choice.checked=false; selection.selectedIndex=0; true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("Removing an idle iframe does not permanently block the parent")
    func removedFrame() async throws {
        let view = try await MemoryTestPage.make(html: "<iframe srcdoc='<p>Idle child</p>'></iframe>")
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("document.querySelector('iframe').remove(); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("Unloading a registered page releases the actual web view")
    func releasesView() async throws {
        let session = TestSession.make().0
        let content = WebContentViewController(session: session)
        _ = content.view
        weak var released: WKWebView?
        let tab: Tab = try await {
            let view = try await MemoryTestPage.make(identity: session.activeSpace.identity)
            #expect(await MemoryTestPage.safe(view))
            released = view
            return session.adoptGlancedTab(view, after: session.activeTab)
        }()
        session.addSpace(named: "Elsewhere")
        session.suspend([tab])
        for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!tab.isLoaded)
        #expect(released == nil, "Sleeping must release the WKWebView, not just its tab reference")
        withExtendedLifetime(content) {}
    }

    @Test("Repeated edit, clear, sleep and wake cycles release every old page view")
    func repeatedCompletedWork() async throws {
        let session = TestSession.make().0
        let home = session.activeSpace
        let tab = try #require(session.activeTab)
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.completed-work-cycles.\(UUID())")!)
        var now: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, additionalVisibleProfiles: { [] })
        let away = session.addSpace(named: "Elsewhere")
        let content = WebContentViewController(session: session)
        _ = content.view
        for _ in 0..<8 {
            session.selectSpace(home)
            var view: WKWebView? = tab.webView()
            weak var released = view
            try await MemoryTestPage.load(try #require(view), html: "<textarea id='draft'></textarea>")
            _ = try await view?.evaluateJavaScript("window.payload=new Uint8Array(16*1024*1024); for(let i=0;i<payload.length;i+=4096)payload[i]=1; draft.value='In progress'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
            session.selectSpace(away)
            now += 61
            await driver.evaluate(.idle)
            #expect(tab.isLoaded)
            _ = try await view?.evaluateJavaScript("draft.value=''; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
            view = nil
            now += 10
            await driver.evaluate(.idle)
            #expect(tab.isAsleep)
            for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(released == nil, "A completed-work cycle must not retain an old document")
        }
        withExtendedLifetime(content) {}
    }

    @Test("A view retained outside the tab cannot keep its retired document running")
    func externallyRetainedView() async throws {
        let session = TestSession.make().0
        let server = try MemoryHTTPFixture()
        defer { server.stop() }
        let base = try await server.start()
        session.addSpace(named: "Private fixture", isPrivate: true)
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity)
        view.load(URLRequest(url: base.appending(path: "original")))
        try await waitForHTTP(view)
        _ = try await view.evaluateJavaScript("history.pushState({}, '', '/current'); document.cookie='retirement=fictional;path=/'; true")
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        _ = try await view.evaluateJavaScript("window.fixtureRetainedPayload=new Uint8Array(16*1024*1024); true")
        session.addSpace(named: "Elsewhere")
        session.suspend([tab])
        #expect(tab.isAsleep)
        for _ in 0..<500 {
            if (try? await view.evaluateJavaScript("typeof window.fixtureRetainedPayload")) as? String == "undefined", !view.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await view.evaluateJavaScript("typeof window.fixtureRetainedPayload") as? String == "undefined",
            "An external editing-UI reference must not keep the sleeping page's document alive")
        #expect(view.backForwardList.backList.isEmpty, "The retired view must not cache the old document in history")
        #expect(tab.isSuspended, "The real tab still keeps its separate restoration state")
        let restored = tab.webView()
        defer { tab.unload() }
        try await waitForHTTP(restored)
        #expect(restored.url?.path == "/current")
        #expect(restored.backForwardList.backList.contains { $0.url.path == "/original" })
        #expect(try await restored.evaluateJavaScript("document.cookie.includes('retirement=fictional')") as? Bool == true,
            "Retiring the old view must preserve the profile's session cookies")
    }

    @Test("A retired view handed to a new owner or attached to a view stays intact")
    func retirementHandoff() async throws {
        let view = try await MemoryTestPage.make()
        _ = try await view.evaluateJavaScript("window.fixtureOwner='new-owner'; true")
        var now: TimeInterval = 0
        let retirement = WebViewRetirement(delay: 60, uptime: { now })
        retirement.retire(view)
        retirement.claim(view)
        now = 61
        await retirement.releaseRetainedDocuments()
        #expect(try await view.evaluateJavaScript("fixtureOwner") as? String == "new-owner")
        let host = NSView()
        host.addSubview(view)
        retirement.retire(view)
        now = 122
        await retirement.releaseRetainedDocuments()
        #expect(try await view.evaluateJavaScript("fixtureOwner") as? String == "new-owner")
        withExtendedLifetime(host) {}
    }

    private func waitForHTTP(_ view: WKWebView) async throws {
        for _ in 0..<500 {
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MemoryTestPage.Failure.loadTimedOut
    }
}
