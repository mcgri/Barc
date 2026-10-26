// Modified for Barc: completed capture must not keep inactive pages awake, 2026-10-26.
import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Hibernation capture cleanup", .serialized)
@MainActor
struct HibernationCaptureCleanupTests {
    @Test("Stopping a real capture track permits idle hibernation, including prototype calls", arguments: [false, true])
    func stoppedTrack(usingPrototype: Bool) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            Object.defineProperty(navigator, 'mediaDevices', {value: {
              getDisplayMedia() {
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = 16;
                const stream = canvas.captureStream(0);
                window.fixtureStream = stream;
                window.fixtureTrack = stream.getVideoTracks()[0];
                window.fixtureEndedEvents = 0;
                fixtureTrack.addEventListener('ended', () => fixtureEndedEvents++);
                return Promise.resolve(stream);
              }
            }});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        PageHibernationGuard.shared.attach(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        try await MemoryTestPage.load(view, html: "<p>Disposable capture fixture</p>")
        #expect(await MemoryTestPage.safe(view))
        let session = TestSession.make().0
        let tab = session.adoptGlancedTab(view, after: session.activeTab)
        defer { tab.unload() }
        _ = try await view.callAsyncJavaScript("await navigator.mediaDevices.getDisplayMedia(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(50))
        #expect(PageHibernationGuard.shared.hasRealtimeActivity(in: view))
        let preferences = Settings(defaults: UserDefaults(suiteName: "barc.capture-cleanup.\(UUID())")!)
        var now: TimeInterval = 0
        let driver = TabSuspender(session: session, settings: preferences, uptime: { now }, additionalVisibleProfiles: { [] })
        session.addSpace(named: "Other profile")
        now = 61
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "Live capture must stay protected")
        _ = try await view.evaluateJavaScript("window.fixtureClone=fixtureTrack.clone(); window.fixturePrototypeClone=MediaStreamTrack.prototype.clone.call(fixtureTrack); window.fixtureStreamClone=fixtureStream.clone().getTracks()[0]; window.fixtureRepackedClone=new MediaStream([fixtureTrack]).clone().getTracks()[0]; true")
        _ = try await view.evaluateJavaScript(usingPrototype ? "MediaStreamTrack.prototype.stop.call(fixtureTrack); true" : "fixtureTrack.stop(); true")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await view.evaluateJavaScript("fixtureTrack.readyState") as? String == "ended")
        #expect(try await view.evaluateJavaScript("fixtureEndedEvents") as? Int == 0,
            "MediaStreamTrack.stop does not dispatch the ended event")
        now = 71
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "A live clone of a capture track must stay protected")
        _ = try await view.evaluateJavaScript("fixtureClone.stop(); true")
        try await Task.sleep(for: .milliseconds(50))
        now = 81
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "A capture clone made via the prototype must stay protected")
        _ = try await view.evaluateJavaScript("fixturePrototypeClone.stop(); true")
        now = 91
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "A capture clone made by MediaStream.clone must stay protected")
        _ = try await view.evaluateJavaScript("fixtureStreamClone.stop(); true")
        try await Task.sleep(for: .milliseconds(50))
        now = 101
        await driver.evaluate(.idle)
        #expect(tab.isLoaded, "Repackaging a captured track in another stream must preserve its protection")
        _ = try await view.evaluateJavaScript("fixtureRepackedClone.stop(); true")
        try await Task.sleep(for: .milliseconds(50))
        now = 111
        await driver.evaluate(.idle)
        if tab.isLoaded { now = 121; await driver.evaluate(.idle) }
        #expect(!tab.isLoaded, "A completed capture must not prevent the ordinary idle sweep")
    }
}
