// Modified for Barc: measured shared-process samples and page helper regressions, 2026-10-26.
import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Memory sampler correctness")
@MainActor
struct MemorySamplerTests {
    @Test("A shared PID is sampled once and every tab receives the same CPU interval")
    func sharedPID() {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let first = session.adoptChildTab(of: session.activeTab!, configuration: WKWebViewConfiguration())
        let second = session.adoptChildTab(of: first, configuration: WKWebViewConfiguration())
        var calls = 0, time = 10.0
        var cpu: UInt64 = 1_000_000_000
        let monitor = TabResourceMonitor(readProcess: { _ in
            calls += 1
            return ProcessSampler.Reading(memoryBytes: 123_000_000, cpuNanoseconds: cpu)
        }, processID: { $0.isLoaded ? 123 : nil }, uptime: { time })
        _ = monitor.sampleAllTabs(in: session)
        #expect(calls == 1)
        time = 12; cpu = 2_000_000_000
        let readings = monitor.sampleAllTabs(in: session).filter { !$0.isSuspended }
        #expect(calls == 2)
        #expect(readings.count == 2)
        #expect(readings.allSatisfy { $0.processPageCount == 2 })
        #expect(readings.allSatisfy { $0.cpuPercentage == 50 && $0.memoryBytes == 123_000_000 })
        first.unload(); second.unload()
    }

    @Test("Unknown readings remain unknown and unloaded tabs have no invented memory charge")
    func unavailable() {
        _ = NSApplication.shared
        let session = TestSession.make().0
        let tab = session.adoptChildTab(of: session.activeTab!, configuration: WKWebViewConfiguration())
        let monitor = TabResourceMonitor(readProcess: { _ in nil }, processID: { $0.isLoaded ? 123 : nil })
        let usages = monitor.sampleAllTabs(in: session)
        let live = usages.first { $0.tabId == tab.id }
        #expect(live?.hasMeasuredMemory == false)
        #expect(live?.formattedMemory == "Unavailable")
        #expect(live?.memoryBytes == 0)
        #expect(usages.filter(\.isSuspended).allSatisfy { $0.memoryBytes == 0 })
        tab.unload()
    }
}

@Suite("Page helper efficiency", .serialized)
@MainActor
struct PageHelperEfficiencyTests {
    @Test("Native video preserves real visibility and schedules no overlay polling on ordinary pages")
    func nativeVisibilityAndPolling() async throws {
        let counters = "window.intervalCount=0; const interval=window.setInterval; window.setInterval=function(){ intervalCount++; return interval.apply(this,arguments); };"
        let view = try await MemoryTestPage.make(html: "<input id='field'><video id='video'></video>", scripts: [counters, SiteBehaviourScripts.nativeVideoPlayer])
        #expect(try await view.evaluateJavaScript("Object.getOwnPropertyDescriptor(document,'hidden') === undefined && Object.getOwnPropertyDescriptor(document,'visibilityState') === undefined") as? Bool == true)
        #expect(try await view.evaluateJavaScript("intervalCount") as? Int == 0)
        #expect(try await view.evaluateJavaScript("video.controls && !video.disablePictureInPicture") as? Bool == true)
        _ = try await view.evaluateJavaScript("window.visibilityEvents=0; document.addEventListener('visibilitychange',()=>visibilityEvents++); document.dispatchEvent(new Event('visibilitychange')); true")
        #expect(try await view.evaluateJavaScript("visibilityEvents") as? Int == 1)
    }

    @Test("Dynamic videos are enhanced without repeated document-wide scans")
    func incrementalVideos() async throws {
        let counters = "window.fullScans=0; const query=Document.prototype.querySelectorAll; Document.prototype.querySelectorAll=function(){ fullScans++; return query.apply(this,arguments); };"
        let view = try await MemoryTestPage.make(scripts: [counters, SiteBehaviourScripts.nativeVideoPlayer])
        let initial = try #require(try await view.evaluateJavaScript("fullScans") as? Int)
        let result = try await view.callAsyncJavaScript("""
            for(let i=0;i<30;i++) {
              const node=document.createElement('div'); node.textContent='change '+i;
              document.body.appendChild(node);
              await Promise.resolve();
            }
            const video=document.createElement('video'); video.id='dynamic'; document.body.appendChild(video);
            await Promise.resolve();
            return video.controls;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(result == true)
        #expect(try await view.evaluateJavaScript("fullScans") as? Int == initial)
    }
}
