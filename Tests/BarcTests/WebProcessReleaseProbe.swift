import AppKit
import Darwin
import Testing
import WebKit
@testable import Barc

@Suite("Web process release probe", .serialized)
@MainActor
struct WebProcessReleaseProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARC_PROCESS_CACHE_PROBE"] == "1"))
    func compareRelease() async throws {
        print("PROCESS_PROBE defaultScheduling=\(WKPreferences().inactiveSchedulingPolicy.rawValue)")
        for active in [true, false] {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        if active { NSApplication.shared.activate(ignoringOtherApps: true) }
        else { NSApplication.shared.hide(nil) }
        try await Task.sleep(for: .seconds(1))
        print("PROCESS_PROBE requestedActive=\(active) actualActive=\(NSApplication.shared.isActive)")
        for address in ["https://example.com/", "https://en.wikipedia.org/wiki/WebKit"] {
        let url = URL(string: address)!
        for blank in [false, true] {
            let identifier = UUID()
            do {
            try await trial(url: url, blank: blank, identifier: identifier)
            } catch {
                try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
                throw error
            }
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        }
        }
        }
    }

    private func trial(url: URL, blank: Bool, identifier: UUID) async throws {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
            var view: WKWebView? = WKWebView(frame: .zero, configuration: configuration)
            view!.load(URLRequest(url: url))
            for _ in 0..<3000 {
                try await Task.sleep(for: .milliseconds(10))
                if !view!.isLoading, view!.url == url { break }
            }
            #expect(!view!.isLoading)
            let ready = try await view!.evaluateJavaScript("document.readyState === 'complete' && document.body.innerText.length > 100")
            try #require(ready as? Bool == true)
            let selector = Selector(("_webProcessIdentifier"))
            let supported = view!.responds(to: selector)
            #expect(supported)
            guard supported else { return }
            let pid = try #require(view!.value(forKey: "_webProcessIdentifier") as? pid_t)
            print("PROCESS_PROBE url=\(url) active=\(NSApplication.shared.isActive) blank=\(blank) pid=\(pid) initial=\(ProcessSampler.read(pid: pid)?.memoryBytes ?? 0)")
            try await observe(view: &view, blank: blank, pid: pid)
    }

    private func observe(view: inout WKWebView?, blank: Bool, pid: pid_t) async throws {
        if blank {
            view!.loadHTMLString("", baseURL: nil)
            for _ in 0..<500 {
                try await Task.sleep(for: .milliseconds(10))
                if !view!.isLoading, view!.url?.absoluteString == "about:blank" { break }
            }
            #expect(view!.url?.absoluteString == "about:blank")
        }
        view = nil
        for second in 0...120 {
            if second > 0 { try await Task.sleep(for: .seconds(1)) }
            if [0, 5, 10, 30, 60, 120].contains(second) {
                print("PROCESS_PROBE blank=\(blank) second=\(second) exists=\(kill(pid, 0) == 0) bytes=\(ProcessSampler.read(pid: pid)?.memoryBytes ?? 0)")
            }
        }
    }
}
