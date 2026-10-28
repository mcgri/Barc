import AppKit
import Foundation
import Testing
import WebKit
@testable import Barc

@Suite(.serialized)
@MainActor
struct RuleListMemoryProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARC_RULELIST_MEMORY_PROBE"] == "1"))
    func measure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-rule-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/io.github.mcgri.Barc/filter-lists")
        let lists = FilterList.all.filter(\.isDefault)
        var outputs: [AdblockRuleConverter.Output] = []
        for list in lists {
            let cached = cache.appending(path: "\(list.id).txt")
            let text: String
            if let data = try? Data(contentsOf: cached) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                let (data, response) = try await URLSession.shared.data(from: list.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                try data.write(to: directory.appending(path: "\(list.id).txt"))
                text = String(decoding: data, as: UTF8.self)
            }
            let output = await Task.detached { AdblockRuleConverter().convert(text) }.value
            print("RULE_PROBE list=\(list.id) rules=\(output.rules.count) exceptions=\(output.rules.filter { $0.actionType == "ignore-previous-rules" }.count) generic=\(output.rules.filter { $0.actionType == "css-display-none" && $0.ifDomain == nil }.count)")
            outputs.append(output)
        }
        let total = outputs.reduce(0) { $0 + $1.rules.count }
        let exceptionLists = outputs.filter { $0.rules.contains { $0.actionType == "ignore-previous-rules" } }.count
        print("RULE_PROBE total=\(total) exceptionLists=\(exceptionLists)")
        let ruleStore = try #require(WKContentRuleListStore(url: directory.appending(path: "compiled")))
        var full: [WKContentRuleList] = []
        var specific: [WKContentRuleList] = []
        for (index, output) in outputs.enumerated() {
            for generic in [true, false] {
                let filtered = output.filteringGenericCosmetics(hide: generic)
                let json = try filtered.encoded()
                let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                    ruleStore.compileContentRuleList(forIdentifier: "probe-\(index)-\(generic)", encodedContentRuleList: json) { list, error in
                        if let list { continuation.resume(returning: list) }
                        else { continuation.resume(throwing: error ?? CocoaError(.coderInvalidValue)) }
                    }
                }
                if generic { full.append(compiled) } else { specific.append(compiled) }
            }
        }
        let server = try MemoryHTTPFixture()
        defer { server.stop() }
        let url = try await server.start()
        for round in 1...3 {
            for (name, rules) in [("none", [WKContentRuleList]()), ("all", full), ("specific", specific)] {
                try await sample(name: name, round: round, rules: rules, url: url)
            }
        }
    }

    private func sample(name: String, round: Int, rules: [WKContentRuleList], url: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        rules.forEach { configuration.userContentController.add($0) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        defer { view.stopLoading() }
        view.load(URLRequest(url: url))
        for _ in 0..<1000 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading, view.url == url { break }
        }
        #expect(!view.isLoading)
        _ = try await view.callAsyncJavaScript("await Promise.all(Array.from({length:5},()=>new Promise(resolve=>{let f=document.createElement('iframe');f.onload=resolve;f.src='/frame';document.body.appendChild(f);}))); return true;", contentWorld: .page)
        try await Task.sleep(for: .seconds(3))
        guard view.responds(to: Selector(("_webProcessIdentifier"))) else {
            throw CocoaError(.featureUnsupported)
        }
        let pid = try #require(view.value(forKey: "_webProcessIdentifier") as? pid_t)
        let footprint = try #require(ProcessSampler.read(pid: pid)?.memoryBytes)
        print("RULE_PROBE round=\(round) mode=\(name) pid=\(pid) footprint=\(footprint)")
    }
}
