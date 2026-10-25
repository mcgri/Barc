// Added for Barc: website browser-version compatibility, 2026-10-25.
import AppKit
import Testing
import WebKit
@testable import Barc

@Suite("Browser identification", .serialized)
@MainActor
struct BrowserUserAgentTests {
    @Test("Default pages identify the installed Safari generation instead of a bare embedded WebKit")
    func defaultBrowserIdentity() async throws {
        let identity = Space.Identity.makeEphemeral()
        defer { WebEnvironment.shared.releaseDataStore(for: identity) }
        let web = WebEnvironment.shared.makeWebView(identity: identity)
        let agent = try #require(try await web.evaluateJavaScript("navigator.userAgent") as? String)
        let safari = try #require(Bundle(path: "/Applications/Safari.app"))
        let version = try #require(safari.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(agent.contains("Version/\(version)"), "The default browser identification must track the system Safari version")
        #expect(agent.contains("Safari/"))
        #expect(agent.contains("AppleWebKit/"))
        #expect(!agent.contains("Chrome/"))
    }

    @Test("WebKit-provided child configurations receive browser identification while custom overrides still work")
    func childAndCustomIdentity() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WebEnvironment.shared.makeWebView(configuration: config)
        let defaultAgent = try #require(try await web.evaluateJavaScript("navigator.userAgent") as? String)
        #expect(defaultAgent.contains("Version/"))
        #expect(defaultAgent.contains("Safari/"))
        web.customUserAgent = "FixtureBrowser/1.0"
        #expect(try await web.evaluateJavaScript("navigator.userAgent") as? String == "FixtureBrowser/1.0")
        web.customUserAgent = nil
        #expect(try await web.evaluateJavaScript("navigator.userAgent") as? String == defaultAgent)
    }

    @Test("Explicit Safari mode uses the installed version rather than a frozen older release")
    func safariSiteMode() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "barc-ua-sites-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let rules = SiteSettings(file: file)
        rules.update { $0.set("safari", for: "fixture.invalid", in: .userAgent) }
        let agent = try #require(rules.userAgent(for: URL(string: "https://fixture.invalid/")))
        let safari = try #require(Bundle(path: "/Applications/Safari.app"))
        let version = try #require(safari.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(agent.contains("Version/\(version)"))
        #expect(rules.userAgent(for: URL(string: "https://unconfigured.invalid/")) == nil)
    }

}
