import Testing
import WebKit
@testable import Barc

@Suite("Read-only page controls", .serialized)
@MainActor
struct ReadOnlyHibernationTests {
    @Test("Application events on untouched read-only controls are not unsaved edits", arguments: [
        "<input id='field' readonly>",
        "<textarea id='field' readonly></textarea>",
        "<div id='field' role='textbox' aria-readonly='true'>Saved text</div>"
    ])
    func viewedReadOnlyControl(html: String) async throws {
        let page = try await MemoryTestPage.make(html: html)
        _ = try await page.evaluateJavaScript("if ('value' in field) field.value='Saved application data'; field.dispatchEvent(new Event('input',{bubbles:true})); field.dispatchEvent(new Event('change',{bubbles:true})); true")
        #expect(await MemoryTestPage.safe(page), "An untouched read-only field must not pin an idle application in memory")
    }

    @Test("A real edit stays protected if its field becomes read-only during a save")
    func savingLockDoesNotEraseDraft() async throws {
        let page = try await MemoryTestPage.make(html: "<textarea id='field'></textarea>")
        _ = try await page.evaluateJavaScript("field.dispatchEvent(new Event('beforeinput',{bubbles:true})); field.value='Unsaved note'; field.dispatchEvent(new Event('input',{bubbles:true})); field.readOnly=true; field.dispatchEvent(new Event('change',{bubbles:true})); true")
        #expect(!(await MemoryTestPage.safe(page)))
        #expect(try await page.evaluateJavaScript("field.value") as? String == "Unsaved note")
    }
}
