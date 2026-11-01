import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

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

    private func webAssemblyType(directory: URL?) async throws -> String? {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
