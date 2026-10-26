// Modified for Barc: opt-in 30-minute disposable-profile memory soak, 2026-10-26.
import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite("Long profile memory soak", .serialized)
@MainActor
struct MemorySoakTests {
    private final class Reference {
        weak var view:WKWebView?
        init(_ view:WKWebView) {self.view = view}
    }
    private struct Sample:Codable {
        let cycle:Int
        let elapsedSeconds:Double
        let loadedViews:Int
        let retainedOldViews:Int
        let measuredFootprintBytes:UInt64
        let trackedProcessCount:Int
    }
    private struct Report:Codable {
        let startedAt:Date
        let initialFootprintBytes:UInt64
        var samples:[Sample]
        var complete = false
    }

    @Test("Thirty minutes of real idle periods preserve private cookies and release old pages",
          .enabled(if:ProcessInfo.processInfo.environment["BARC_MEMORY_SOAK"] == "1"), .timeLimit(.minutes(40)))
    func thirtyMinutes() async throws {
        let server = try MemoryHTTPFixture();defer {server.stop()}
        let base = try await server.start()
        let session = TestSession.make().0
        var spaces:[Space] = [], tabs:[Tab] = [], references:[Reference] = []
        var pids:Set<pid_t> = [getpid()]
        let begin = ProcessInfo.processInfo.systemUptime
        let started = Date()
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appending(path:"_local/memory-soak-result-2026-10-26.json")
        for index in 0..<3 {
            let space = session.addSpace(named:"Soak \(index)",isPrivate:true)
            spaces.append(space)
            var view:WKWebView? = try await MemoryTestPage.make(identity:space.identity)
            view?.load(URLRequest(url:base.appending(path:"page")))
            try await ready(try #require(view))
            let cookie = try #require(HTTPCookie(properties:[.name:"soak-session",.value:"fictional-\(index)",.domain:"127.0.0.1",.path:"/"]))
            await WebEnvironment.shared.dataStore(for:space.identity).httpCookieStore.setCookie(cookie)
            let tab = session.adoptGlancedTab(try #require(view),after:session.activeTab)
            tabs.append(tab)
            try await allocate(try #require(view))
            if let pid = TabResourceMonitor.contentProcessID(try #require(view)) {pids.insert(pid)}
            references.append(Reference(try #require(view)))
            view = nil
        }
        pids.formUnion(WebEnvironment.shared.networkProcessIdentifiers)
        if let gpu = GPUMetrics.processIdentifier(in:session) {pids.insert(gpu)}
        let initial = footprint(pids)
        var report = Report(startedAt:started,initialFootprintBytes:initial,samples:[])
        let preferences = Settings(defaults:UserDefaults(suiteName:"barc.soak.\(UUID())")!)
        let driver = TabSuspender(session:session,settings:preferences,additionalVisibleProfiles:{[]})
        driver.start()
        defer {
            driver.stop()
            for tab in tabs {tab.unload()}
            for space in spaces {WebEnvironment.shared.releaseDataStore(for:space.identity)}
        }
        for cycle in 0..<26 {
            let index = cycle % spaces.count
            session.selectSpace(spaces[index])
            var view:WKWebView? = tabs[index].webView()
            try await ready(try #require(view))
            let cookies = try #require(try await view?.evaluateJavaScript("document.cookie") as? String)
            #expect(cookies.contains("soak-session=fictional-\(index)"))
            try await allocate(try #require(view))
            if let pid = TabResourceMonitor.contentProcessID(try #require(view)) {pids.insert(pid)}
            references.append(Reference(try #require(view)))
            view = nil
            // Real wall-clock inactivity, in addition to the separate real-timer
            // regression. An explicit sweep models return from App Nap.
            try await Task.sleep(for:.seconds(70))
            await driver.evaluate(.idle)
            try await Task.sleep(for:.milliseconds(100))
            let loaded = tabs.count(where: \.isLoaded)
            let retained = Set(references.compactMap(\.view).map(ObjectIdentifier.init)).count
            #expect(loaded == 1)
            #expect(retained == 1)
            report.samples.append(Sample(cycle:cycle+1,elapsedSeconds:ProcessInfo.processInfo.systemUptime-begin,
                loadedViews:loaded,retainedOldViews:retained-loaded,measuredFootprintBytes:footprint(pids),trackedProcessCount:pids.count))
            try JSONEncoder().encode(report).write(to:output,options:.atomic)
            print("Memory soak cycle \(cycle+1)/26: \(loaded) loaded, \(retained-loaded) stale views, \(footprint(pids)/1_048_576) MiB measured")
        }
        #expect(ProcessInfo.processInfo.systemUptime-begin >= 1800)
        report.complete = true
        try JSONEncoder().encode(report).write(to:output,options:.atomic)
    }
    private func ready(_ view:WKWebView) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for:.milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true {return}
        }
        throw MemoryTestPage.Failure.loadTimedOut
    }
    private func allocate(_ view:WKWebView) async throws {
        _ = try await view.evaluateJavaScript("window.fixtureMemory=new Uint8Array(32*1024*1024); for(let i=0;i<fixtureMemory.length;i+=4096)fixtureMemory[i]=1; true")
    }
    private func footprint(_ pids:Set<pid_t>) -> UInt64 {
        pids.reduce(UInt64(0)) {$0 + (ProcessSampler.read(pid:$1)?.memoryBytes ?? 0)}
    }
}
