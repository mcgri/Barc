import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Pages that refused sleep for good", .serialized)
@MainActor
struct StuckPageGuardTests {
    @Test("A late report from a document the tab has left does not keep it awake")
    func lateReportFromLeftDocument() async throws {
        // On a cross-site hop the old page's pagehide runs in its own process
        // after the new page registered; a request it sends on the way out
        // reports from the main frame under the old token.
        let view = try await MemoryTestPage.make()
        #expect(await MemoryTestPage.safe(view))
        _ = try await view.evaluateJavaScript(
            "window.webkit.messageHandlers.barcWorkGuard.postMessage({token: 'left-document', event: 'change', realtime: false, busy: false}); true",
            in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await MemoryTestPage.safe(view), "A document no longer shown has nothing left to protect")
    }

    @Test("A tab whose page never loaded can sleep")
    func neverCommitted() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebEnvironment.shared.dataStore(for: .makeEphemeral())
        PageHibernationGuard.shared.attach(config.userContentController)
        let view = WebEnvironment.shared.makeWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        // Nothing listens on port 1: the load fails before any document commits,
        // as a restored tab does when its dev server is not running.
        view.load(URLRequest(url: URL(string: "http://127.0.0.1:1/")!))
        try await waitUntilLoaded(view)
        #expect(await MemoryTestPage.safe(view), "An empty about:blank frame holds nothing to protect")
    }

    @Test("A failed navigation away from a draft keeps the draft protected")
    func failedNavigationKeepsDraft() async throws {
        let view = try await MemoryTestPage.make(html: "<textarea id='draft'></textarea>")
        _ = try await view.evaluateJavaScript("draft.dispatchEvent(new Event('beforeinput', {bubbles:true})); draft.value='Unsent'; draft.dispatchEvent(new Event('input', {bubbles:true})); true")
        view.load(URLRequest(url: URL(string: "http://127.0.0.1:1/")!))
        try await waitUntilLoaded(view)
        #expect(try await view.evaluateJavaScript("draft.value") as? String == "Unsent")
        #expect(!(await MemoryTestPage.safe(view)), "The page with the draft is still the one shown")
    }

    private func waitUntilLoaded(_ view: WKWebView) async throws {
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<300 where view.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isLoading)
    }
}

@Suite("Sweeps back off from pages that keep refusing", .serialized)
@MainActor
struct SleepRefusalBackoffTests {
    @Test("The delay starts after two refusals and stops at five minutes")
    func schedule() {
        #expect([1, 2, 3, 4, 5, 6, 7, 20].map(TabSuspension.SleepRefusal.delay(afterRefusals:)) == [0, 0, 30, 60, 120, 240, 300, 300])
        var refusal = TabSuspension.SleepRefusal.next(after: nil, revision: 4, at: 0)
        refusal = .next(after: refusal, revision: 4, at: 10)
        refusal = .next(after: refusal, revision: 4, at: 20)
        #expect(refusal.count == 3 && refusal.defers(revision: 4, now: 49) && !refusal.defers(revision: 4, now: 50))
        #expect(!refusal.defers(revision: 5, now: 21), "Any report from the page asks again")
        #expect(TabSuspension.SleepRefusal.next(after: refusal, revision: 5, at: 21).count == 1)
    }

    @Test("A quiet refusing page is inspected less often; a change or memory pressure asks at once")
    func sweeps() async throws {
        let session = TestSession.make().0
        let view = try await MemoryTestPage.make(identity: session.activeSpace.identity)
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        defer { tab.unload() }
        var now: TimeInterval = 0, inspected = 0, revision = 1
        let driver = TabSuspender(session: session, settings: Settings(defaults: UserDefaults(suiteName: "barc.refusal-backoff.\(UUID())")!),
            uptime: { now }, inspectPage: { _ in inspected += 1; return false },
            pageRevision: { _ in revision }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Elsewhere")
        for time in stride(from: 61.0, through: 141, by: 10) { now = time; await driver.evaluate(.idle) }
        // 61, 71, 81 refuse; 81 + 30 = 111 asks again; 111 + 60 = 171 is next.
        #expect(inspected == 4)
        revision = 2
        now = 151; await driver.evaluate(.idle)
        #expect(inspected == 5, "A page that reported something is asked on the next sweep")
        now = 152; await driver.evaluate(.idle)
        now = 153; await driver.evaluate(.idle)
        #expect(inspected == 7)
        now = 154; await driver.evaluate(.idle)
        #expect(inspected == 7)
        await driver.evaluate(.memoryWarning)
        #expect(inspected == 8, "Memory pressure does not wait")
        #expect(tab.isLoaded)
    }
}

@Suite("Measurement log")
struct MeasurementLogTests {
    @Test("The log starts again past its limit and keeps one previous file")
    func rotation() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "barc-log-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "measurements.log")
        for index in 0..<5 { Metrics.append(Data("line \(index)\n".utf8), to: file, limit: 20) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "line 4\n")
        #expect(try String(contentsOf: folder.appending(path: "measurements.1.log"), encoding: .utf8) == "line 2\nline 3\n")
    }
}
