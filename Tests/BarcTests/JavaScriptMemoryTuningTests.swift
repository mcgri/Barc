import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

/// Answers `window.open` the way a tab does: through `WebEnvironment`.
@MainActor
private final class PopupMaker: NSObject, WKUIDelegate {
    var made: WKWebView?

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        made = WebEnvironment.shared.makeWebView(configuration: configuration)
        return made
    }
}

@Suite("JavaScript memory tuning")
@MainActor
struct JavaScriptMemoryTuningTests {
    @Test("The configuration file is one jscOptions block JavaScriptCore can parse")
    func fileFormat() {
        #expect(JavaScriptMemoryTuning.configuration([("a", "1"), ("b", "two")]) == "jscOptions {\n    a=1\n    b=two\n}\n")
    }

    @Test("JavaScriptCore is told the Mac has at most 8 GB, never more than it really has")
    func ramSizeCap() {
        let gb: UInt64 = 1 << 30
        #expect(JavaScriptMemoryTuning.options(physicalMemory: 24 * gb).map(\.value) == ["\(8 * gb)"])
        #expect(JavaScriptMemoryTuning.options(physicalMemory: 8 * gb).map(\.value) == ["\(8 * gb)"])
        #expect(JavaScriptMemoryTuning.options(physicalMemory: 4 * gb).map(\.value) == ["\(4 * gb)"])
        #expect(JavaScriptMemoryTuning.options().map(\.key) == ["forceRAMSize"])
    }

    @Test("Turning the setting off writes nothing and leaves WebKit's defaults")
    func disabled() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-jsc-\(UUID())")
        #expect(JavaScriptMemoryTuning.prepare(enabled: false, directory: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// The real proof: a page started for a tuned configuration runs with the
    /// option. `useWasm` stands in for the heap options because a page can see
    /// it; each configuration has its own pool, so no other test is affected.
    @Test("Pages started for a tuned configuration read its options; others do not")
    func reachesContentProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-jsc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try #require(JavaScriptMemoryTuning.prepare(enabled: true, options: [("useWasm", "false")], directory: directory))
        #expect(try String(contentsOf: directory.appending(path: "JSC.config"), encoding: .utf8).contains("useWasm=false"))

        #expect(try await webAssemblyType(directory: prepared) == "undefined")
        #expect(try await webAssemblyType(directory: nil) == "object")
    }

    @Test("A pool that can prewarm refuses the directory")
    func refusesPrewarmingPool() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-jsc-\(UUID())")
        let ordinary = WKProcessPool()
        JavaScriptMemoryTuning.apply(directory: directory, to: ordinary)
        #expect(ordinary.value(forKey: "_javaScriptConfigurationDirectory") == nil)

        let unwarmed = try #require(JavaScriptMemoryTuning.makeUnwarmedPool())
        JavaScriptMemoryTuning.apply(directory: directory, to: unwarmed)
        #expect(unwarmed.value(forKey: "_javaScriptConfigurationDirectory") != nil)
    }

    @Test("The setting off leaves a configuration on WebKit's own pool")
    func settingOffKeepsDefaultPool() {
        let configuration = WKWebViewConfiguration()
        let original = configuration.processPool
        JavaScriptMemoryTuning.installProcessPool(in: configuration, enabled: false)
        #expect(configuration.processPool === original)
    }

    /// The FreeAgent report, on loopback. WebKit turns prewarming on at a tab's
    /// first swap. The second then took the spare process, which crashed on
    /// `JSC.config` and left the old page on screen with no delegate call. The
    /// last site has to be a new one: a site visited before returns to its own
    /// suspended process, and never touches the spare.
    @Test("A second cross-site hop in a tuned tab still arrives")
    func secondCrossSiteHop() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-jsc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try #require(JavaScriptMemoryTuning.prepare(enabled: true, directory: directory))
        let fixture = try MemoryHTTPFixture()
        let port = try #require(try await fixture.start().port)
        defer { fixture.stop() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        JavaScriptMemoryTuning.installProcessPool(in: configuration, enabled: true)
        let pool = configuration.processPool
        JavaScriptMemoryTuning.apply(directory: prepared, to: pool)
        #expect(pool.value(forKey: "_javaScriptConfigurationDirectory") != nil)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)

        func arrive(at address: String) async -> Bool {
            for _ in 0..<500 {
                try? await Task.sleep(for: .milliseconds(10))
                if !view.isLoading, (try? await view.evaluateJavaScript("location.href")) as? String == address,
                   (try? await view.evaluateJavaScript("!!document.getElementById('httpReady')")) as? Bool == true { return true }
            }
            return false
        }
        func process() -> Int { (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0 }

        let first = "http://127.0.0.1:\(port)/one"
        let second = "http://localhost:\(port)/two"
        let third = "http://barc-third.localhost:\(port)/three"
        view.load(URLRequest(url: URL(string: first)!))
        #expect(await arrive(at: first))
        let firstProcess = process()

        _ = try await view.evaluateJavaScript("location.href = '\(second)'; true")
        #expect(await arrive(at: second))
        let secondProcess = process()
        // Long enough for the spare process WebKit would otherwise start.
        try await Task.sleep(for: .milliseconds(500))
        #expect(pool.value(forKey: "_hasPrewarmedWebProcess") as? Bool == false)

        _ = try await view.evaluateJavaScript("location.href = '\(third)'; true")
        #expect(await arrive(at: third))
        // Sites still get their own processes: only prewarming went away.
        #expect(Set([firstProcess, secondProcess, process()]).count == 3)
    }

    /// Sign-in popups come through here. WebKit throws if a popup's pool is
    /// not its opener's, so this pool must never be swapped for a new one.
    @Test("window.open from a tuned page stays on its opener's pool")
    func popupKeepsOpenerPool() async throws {
        _ = NSApplication.shared
        let configuration = WebEnvironment.shared.makeConfiguration(for: .makeEphemeral())
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let opener = WebEnvironment.shared.makeWebView(configuration: configuration)
        let popups = PopupMaker()
        opener.uiDelegate = popups
        try await MemoryTestPage.load(opener, html: "<p>Opener</p>")

        _ = try await opener.evaluateJavaScript("window.open('about:blank'); true")
        for _ in 0..<300 where popups.made == nil { try await Task.sleep(for: .milliseconds(10)) }
        let popup = try #require(popups.made)
        #expect(popup.configuration.processPool === opener.configuration.processPool)
    }

    private func webAssemblyType(directory: URL?) async throws -> String? {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        JavaScriptMemoryTuning.installProcessPool(in: configuration, enabled: true)
        JavaScriptMemoryTuning.apply(directory: directory, to: configuration.processPool)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        view.loadHTMLString("<!doctype html><p>tuning</p>", baseURL: nil)
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
        }
        return try await view.evaluateJavaScript("typeof WebAssembly") as? String
    }
}
