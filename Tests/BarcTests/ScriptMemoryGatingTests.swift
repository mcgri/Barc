import Foundation
import Testing
import WebKit
@testable import Barc

@MainActor
struct ScriptMemoryGatingTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "barc.script-gating.\(UUID())")!)
    }

    @Test func genericCosmeticsSettingPreservesBlockingAndExceptions() {
        let settings = settings()
        #expect(settings.hideGenericPageElements)
        let original = AdblockRuleConverter().convert("##.generic\nexample.com##.specific\n||ads.example^\n@@||good.example^")
        #expect(original.filteringGenericCosmetics(hide: true).rules == original.rules)
        settings.hideGenericPageElements = false
        let filtered = original.filteringGenericCosmetics(hide: settings.hideGenericPageElements)
        #expect(filtered.rules.count == original.rules.count - 1)
        #expect(filtered.rules.contains { $0.actionType == "block" })
        #expect(filtered.rules.contains { $0.actionType == "ignore-previous-rules" })
        #expect(filtered.rules.contains { $0.selector == ".specific" })
        #expect(!filtered.rules.contains { $0.selector == ".generic" })
    }

    @Test func cookieAndJSONTogglesPreserveOtherScripts() {
        let settings = settings()
        settings.autoRejectCookieBanners = false
        settings.formatsJSON = false
        let controller = WKUserContentController()
        let sentinel = WKUserScript(source: "/* sentinel */", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(sentinel)
        let cookies = CookieConsentAutoReject(settings: settings)
        let json = JSONFormatting(settings: settings)
        cookies.attach(controller)
        json.attach(controller)
        #expect(controller.userScripts.count == 1)
        settings.autoRejectCookieBanners = true
        settings.formatsJSON = true
        cookies.preferencesChanged()
        json.preferencesChanged()
        #expect(controller.userScripts.count == 3)
        #expect(controller.userScripts.contains { $0.source == CookieConsentAutoReject.source && !$0.isForMainFrameOnly })
        #expect(controller.userScripts.contains { $0.source == JSONFormatting.source && $0.isForMainFrameOnly })
        settings.autoRejectCookieBanners = false
        settings.formatsJSON = false
        cookies.preferencesChanged()
        json.preferencesChanged()
        #expect(controller.userScripts.map(\.source) == [sentinel.source])
    }

    @Test func fontsInstallOnlyForCustomDefaults() {
        let controller = WKUserContentController()
        WebFontStyling.install(.webKitDefaults, in: controller)
        #expect(controller.userScripts.isEmpty)
        var fonts = WebFonts.webKitDefaults
        fonts.standardSize = 20
        WebFontStyling.install(fonts, in: controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first?.isForMainFrameOnly == false)
        WebFontStyling.install(.webKitDefaults, in: controller)
        #expect(controller.userScripts.isEmpty)
    }

    @Test func boostsInstallAndRemoveOnStoreChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "boost-gating-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoostStore(folder: directory)
        let coordinator = BoostCoordinator(store: store)
        let controller = WKUserContentController()
        coordinator.attach(controller)
        #expect(controller.userScripts.isEmpty)
        var boost = Boost(host: "example.com")
        boost.customCSS = "body { color: red; }"
        store.save(boost)
        #expect(controller.userScripts.count == 1)
        boost.isEnabled = false
        store.save(boost)
        #expect(controller.userScripts.isEmpty)
        boost.isEnabled = true
        store.save(boost)
        #expect(controller.userScripts.count == 1)
        store.delete(id: boost.id)
        #expect(controller.userScripts.isEmpty)
    }

    @Test func linkHintsReadSettingOnEachInvocation() {
        let settings = settings()
        let coordinator = LinkHintsCoordinator(settings: settings)
        settings.linkHintsEnabled = false
        #expect(coordinator.script(openInNewTab: false) == nil)
        settings.linkHintsEnabled = true
        #expect(coordinator.script(openInNewTab: false) != nil)
        settings.linkHintsEnabled = false
        #expect(coordinator.script(openInNewTab: true) == nil)
    }

    @Test func formAutofillTogglesExistingController() {
        let settings = settings()
        settings.formAutofillEnabled = false
        settings.cardAutofillEnabled = false
        let coordinator = FormAutofill(settings: settings)
        let controller = WKUserContentController()
        coordinator.attach(controller)
        #expect(controller.userScripts.isEmpty)
        settings.formAutofillEnabled = true
        #expect(controller.userScripts.count == 1)
        settings.cardAutofillEnabled = true
        settings.formAutofillEnabled = false
        #expect(controller.userScripts.count == 1)
        settings.cardAutofillEnabled = false
        #expect(controller.userScripts.isEmpty)
    }

    @Test func childFrameAutofillInitializesOnFirstFieldFocus() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: FormAutofill.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<iframe srcdoc=\"<input type='search'>\"></iframe>", baseURL: nil)
        for _ in 0..<500 {
            try await Task.sleep(for: .milliseconds(10))
            if !view.isLoading { break }
        }
        let before = try await view.evaluateJavaScript("typeof document.querySelector('iframe').contentWindow.__barcAutofill") as? String
        #expect(before == "undefined")
        _ = try await view.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('input').dispatchEvent(new FocusEvent('focus')); true")
        let after = try await view.evaluateJavaScript("typeof document.querySelector('iframe').contentWindow.__barcAutofill.classify") as? String
        #expect(after == "function")
    }

    @Test func genericPreferenceRecompilesRegisteredBlocker() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "blocker-gating-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("! Fixture\n##.generic\nexample.com##.specific\n||ads.example^".utf8)
            .write(to: directory.appending(path: "easylist.txt"))
        let settings = settings()
        settings.autoUpdatesFilterLists = false
        var preferences = ContentBlockingPreferences()
        preferences.listOverrides = Dictionary(uniqueKeysWithValues: FilterList.all.map { ($0.id, $0.id == "easylist") })
        settings.contentBlocking = preferences
        let ruleStore = try #require(WKContentRuleListStore(url: directory.appending(path: "compiled")))
        let blocker = ContentBlocker(settings: settings, store: FilterListStore(directory: directory), ruleStore: ruleStore)
        let controller = WKUserContentController()
        blocker.attach(controller)
        for (hide, expected) in [(true, 3), (false, 2), (true, 3)] {
            settings.hideGenericPageElements = hide
            blocker.preferencesChanged()
            for _ in 0..<500 {
                if case .ready(let count, _) = blocker.statuses["easylist"], count == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .ready(let count, _) = blocker.statuses["easylist"] else {
                Issue.record("Fixture list did not compile")
                return
            }
            #expect(count == expected)
        }
    }
}
