import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Viewing saved page content permits sleep", .serialized)
@MainActor
struct UneditedPageHibernationTests {
    @Test("An untouched saved task title does not count as a draft")
    func savedRichContent() async throws {
        let view = try await MemoryTestPage.make(html: "<div contenteditable='true'>Saved task title</div>")
        #expect(await MemoryTestPage.safe(view), "Viewing existing editable text must not keep a tab awake forever")
    }

    @Test("Framework-populated controls do not count as user edits")
    func hydratedControls() async throws {
        let view = try await MemoryTestPage.make(html: "<input id='title'><textarea id='description'></textarea><input id='completed' type='checkbox'><select id='taskStatus'><option>Open</option><option>Done</option></select>")
        _ = try await view.evaluateJavaScript("title.value='Saved task'; description.value='Saved description'; completed.checked=true; taskStatus.selectedIndex=1; true")
        #expect(await MemoryTestPage.safe(view), "Loading saved application data must not be mistaken for a draft")
    }

    @Test("Focusing existing text and application-level custom events do not create drafts")
    func viewOnlyInteraction() async throws {
        let view = try await MemoryTestPage.make(html: "<div id='title' role='textbox' aria-readonly='true'>Saved task title</div>")
        _ = try await view.evaluateJavaScript("title.dispatchEvent(new Event('focusin', {bubbles:true})); title.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight',bubbles:true})); document.dispatchEvent(new Event('change', {bubbles:true})); document.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("A hydrated field uses its actual pre-edit value, including after late hydration")
    func actualBaseline() async throws {
        let view = try await MemoryTestPage.make(html: "<textarea id='description'></textarea>")
        _ = try await view.evaluateJavaScript("description.dispatchEvent(new Event('focusin', {bubbles:true})); description.value='Saved description'; description.dispatchEvent(new Event('beforeinput', {bubbles:true})); description.value='Unsaved edit'; description.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("description.value='Saved description'; description.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(await MemoryTestPage.safe(view), "Reverting to the hydrated value must permit sleep")
    }

    @Test("Deleting existing text remains protected even after the editor is removed", arguments: [
        "<input id='editor' value='Saved task'>",
        "<textarea id='editor'>Saved task</textarea>",
        "<div id='editor' contenteditable='true'>Saved task</div>"
    ])
    func existingTextDeletion(html: String) async throws {
        let view = try await MemoryTestPage.make(html: html)
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript("editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); if ('value' in editor) editor.value=''; else editor.textContent=''; editor.dispatchEvent(new Event('input', {bubbles:true})); editor.remove(); true")
        #expect(!(await MemoryTestPage.safe(view)), "An empty editor can hold an unsaved deletion")
    }

    @Test("Input-only rich-editor changes with an unknown starting state remain protected")
    func unknownRichDeletion() async throws {
        let view = try await MemoryTestPage.make(html: "<div id='editor' contenteditable='true'>Saved task</div>")
        _ = try await view.evaluateJavaScript("editor.textContent=''; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
    }

    @Test("Framework-loaded choices can be changed and reverted without using HTML defaults")
    func hydratedChoices() async throws {
        let view = try await MemoryTestPage.make(html: "<input id='completed' type='checkbox'><select id='taskStatus'><option>Open</option><option>Done</option></select>")
        _ = try await view.evaluateJavaScript("completed.checked=true; taskStatus.selectedIndex=1; completed.dispatchEvent(new Event('focusin', {bubbles:true})); taskStatus.dispatchEvent(new Event('focusin', {bubbles:true})); completed.checked=false; taskStatus.selectedIndex=0; completed.dispatchEvent(new Event('change', {bubbles:true})); taskStatus.dispatchEvent(new Event('change', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
        _ = try await view.evaluateJavaScript("completed.checked=true; taskStatus.selectedIndex=1; true")
        #expect(await MemoryTestPage.safe(view))
    }

    @Test("A submitted search query does not keep a single-page app awake", arguments: [
        "<form role='search'><input id='editor' aria-label='Search mail'></form>",
        "<input id='editor' type='search'>",
        "<input id='editor' name='q'>",
        "<input id='editor' name='search_query' role='combobox'>",
        "<input id='editor' placeholder='Filter projects'>",
        "<search><input id='editor'></search>"
    ])
    func searchQuery(html: String) async throws {
        let view = try await MemoryTestPage.make(html: html)
        _ = try await view.evaluateJavaScript("editor.dispatchEvent(new Event('focusin', {bubbles:true})); editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); editor.value='jet2'; editor.dispatchEvent(new Event('input', {bubbles:true})); editor.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true})); editor.dispatchEvent(new Event('change', {bubbles:true})); true")
        #expect(await MemoryTestPage.safe(view), "A query left in a search box is not unsaved work")
    }

    @Test("A real field beside a search box stays protected")
    func fieldBesideSearch() async throws {
        let view = try await MemoryTestPage.make(html: "<form role='search'><input id='query' aria-label='Search'></form><input id='subject' aria-label='Subject'>")
        _ = try await view.evaluateJavaScript("query.value='jet2'; query.dispatchEvent(new Event('input', {bubbles:true})); subject.dispatchEvent(new Event('beforeinput', {bubbles:true})); subject.value='Unsent subject'; subject.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)))
    }

    @Test("Typing inside a component's shadow root is tracked against the real field")
    func shadowRootEditor() async throws {
        let view = try await MemoryTestPage.make(html: "<div id='host'></div>")
        _ = try await view.evaluateJavaScript("window.field = host.attachShadow({mode:'open'}).appendChild(document.createElement('textarea')); field.dispatchEvent(new Event('beforeinput', {bubbles:true, composed:true})); field.value='Unsent note'; field.dispatchEvent(new Event('input', {bubbles:true, composed:true})); true")
        #expect(!(await MemoryTestPage.safe(view)), "A draft inside a web component is still a draft")
        _ = try await view.evaluateJavaScript("field.value=''; field.dispatchEvent(new Event('input', {bubbles:true, composed:true})); true")
        #expect(await MemoryTestPage.safe(view), "Clearing the component's field must release the page, not leave it unknown forever")
    }

    @Test("A sandboxed frame where page scripts cannot run does not keep the page awake", arguments: [false, true])
    func scriptlessSandboxedFrame(dynamic: Bool) async throws {
        // YouTube embeds a blank frame with sandbox="allow-same-origin" and no allow-scripts.
        let view = try await MemoryTestPage.make(html: dynamic ? "<p>Video list</p>" : "<iframe sandbox='allow-same-origin'></iframe>")
        if dynamic {
            _ = try await view.evaluateJavaScript("const f = document.createElement('iframe'); f.setAttribute('sandbox', 'allow-same-origin'); document.body.appendChild(f); true")
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await MemoryTestPage.safe(view), "A frame that cannot run page scripts has no uploads or calls to protect")
    }

    @Test("A muted autoplay clip does not keep a page awake; audible playback still does", arguments: [true, false])
    func decorativeVideo(muted: Bool) async throws {
        let view = try await MemoryTestPage.make(html: "<video id='clip'></video>")
        _ = try await view.evaluateJavaScript("for (const [key, value] of Object.entries({paused: false, ended: false, muted: \(muted), volume: 1})) Object.defineProperty(clip, key, {get: () => value}); true")
        #expect(await MemoryTestPage.safe(view) == muted, muted ? "Decoration is not something the person is listening to" : "Audible playback stays protected")
    }

    @Test("A frame the content blocker stopped does not keep the page awake")
    func blockedAdFrame() async throws {
        // NYT embeds static01.nyt.com/ads/...; Barc's own ad blocking stops it, and
        // the empty frame left behind never runs Barc's scripts.
        let rules = #"[{"trigger": {"url-filter": "blocked-ad"}, "action": {"type": "block"}}]"#
        let list = try #require(try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "barc-test-blocked-ad", encodedContentRuleList: rules))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebEnvironment.shared.dataStore(for: .makeEphemeral())
        PageHibernationGuard.shared.attach(config.userContentController)
        config.userContentController.add(list)
        let view = WebEnvironment.shared.makeWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        try await MemoryTestPage.load(view, html: "<iframe id='ad' src='http://127.0.0.1/fixture/blocked-ad.html'></iframe><textarea id='draft'></textarea>")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await MemoryTestPage.safe(view), "An emptied ad frame holds nothing to protect")
        _ = try await view.evaluateJavaScript("draft.dispatchEvent(new Event('beforeinput', {bubbles:true})); draft.value = 'Unsent'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)), "A draft elsewhere on the page still protects it")
    }

    @Test("A script-free frame removed from the page does not keep it awake")
    func removedScriptlessFrame() async throws {
        // News sites add and remove sandboxed ad frames; one without allow-scripts
        // cannot report its own removal.
        let view = try await MemoryTestPage.make()
        _ = try await view.evaluateJavaScript("window.ad = document.createElement('iframe'); ad.setAttribute('sandbox', 'allow-same-origin'); document.body.appendChild(ad); true")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await view.evaluateJavaScript("ad.remove(); true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await MemoryTestPage.safe(view), "A frame that has left the page cannot hold anything to protect")
    }

    @Test("A draft typed inside a script-free sandboxed frame still protects the page")
    func draftInScriptlessSandboxedFrame() async throws {
        let view = try await MemoryTestPage.make(html: "<iframe id='frame' sandbox='allow-same-origin' srcdoc=\"<textarea id='draft'></textarea>\"></iframe>")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await view.evaluateJavaScript("const editor = frame.contentDocument.getElementById('draft'); editor.dispatchEvent(new Event('beforeinput', {bubbles:true})); editor.value = 'Unsent reply'; editor.dispatchEvent(new Event('input', {bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(view)), "Barc's own world still sees drafts where page scripts are off")
    }

    @Test("Read-only task pages sleep on the normal tab or inactive-profile deadline", arguments: [false, true])
    func automaticDeadlines(inactiveProfile: Bool) async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity,
            html: "<div contenteditable='true'>Saved task title</div><textarea id='description'></textarea>")
        _ = try await view.evaluateJavaScript("description.value='Saved task description'; true")
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        defer { tab.unload() }
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.unedited-task.\(UUID())")!)
        var now: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, additionalVisibleProfiles: { [] })
        if inactiveProfile { session.addSpace(named: "Elsewhere") }
        else { session.newTab() }
        let deadline: TimeInterval = inactiveProfile ? 60 : 600
        now = deadline - 1
        await driver.evaluate(.idle)
        #expect(tab.isLoaded)
        now = deadline + 1
        await driver.evaluate(.idle)
        #expect(tab.isAsleep, "Untouched saved task data must not block the idle deadline")
    }
}
