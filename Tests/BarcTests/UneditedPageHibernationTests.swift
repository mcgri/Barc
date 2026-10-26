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
