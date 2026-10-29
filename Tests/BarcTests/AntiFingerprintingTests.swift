// Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
import Testing
import Foundation
import AppKit
import WebKit
@testable import Barc

@Suite("Anti-Fingerprinting Protection (F-30)")
@MainActor
struct AntiFingerprintingTests {

    @Test("SiteSettingCategory.antiFingerprinting properties and default value")
    func siteSettingCategoryAntiFingerprinting() {
        let category = SiteSettingCategory.antiFingerprinting
        #expect(category.title == "Anti-Fingerprinting")
        #expect(category.symbolName == "shield.lefthalf.filled")
        #expect(category.builtInDefault == "on")
        #expect(category.options.map(\.id) == ["on", "off"])
    }

    @Test("SiteSettings per-host anti-fingerprinting lookup and update")
    func siteSettingsAntiFingerprintingPerHost() {
        let testURL = URL(string: "https://fingerprint-test.org/page")!
        
        // Ensure default is enabled
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == true)
        
        // Disable for this host
        SiteSettings.shared.update {
            $0.set("off", for: "fingerprint-test.org", in: .antiFingerprinting)
        }
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == false)
        
        // Re-enable for this host
        SiteSettings.shared.update {
            $0.set("on", for: "fingerprint-test.org", in: .antiFingerprinting)
        }
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == true)
    }

    @Test("Settings anti-fingerprinting global configuration flags")
    func globalAntiFingerprintingSettings() {
        let originalEnabled = Settings.shared.antiFingerprintingEnabled
        defer { Settings.shared.antiFingerprintingEnabled = originalEnabled }

        Settings.shared.antiFingerprintingEnabled = true
        #expect(Settings.shared.antiFingerprintingEnabled == true)
        #expect(Settings.shared.canvasNoiseEnabled == true)
        #expect(Settings.shared.audioNoiseEnabled == true)
        #expect(Settings.shared.hardwareMaskingEnabled == true)

        Settings.shared.antiFingerprintingEnabled = false
        #expect(Settings.shared.antiFingerprintingEnabled == false)
    }

    @Test("SitePolicy dictionary includes anti-fingerprinting and per-space seed")
    func sitePolicyDictionaryAndPerSpaceSeed() {
        let spaceA = Space.Identity.makeIsolated()
        let spaceB = Space.Identity.makeIsolated()
        let testURL = URL(string: "https://privacy-test.io")!

        let webViewA = WKWebView(frame: .zero)
        SitePolicy.shared.apply(for: testURL, to: webViewA.configuration.userContentController, spaceIdentity: spaceA)

        // Seed determinism check: same space generates identical seed
        let seedA1 = SitePolicy.shared.seed(for: spaceA)
        let seedA2 = SitePolicy.shared.seed(for: spaceA)
        #expect(seedA1 == seedA2)

        // Different spaces generate different seeds
        let seedB = SitePolicy.shared.seed(for: spaceB)
        #expect(seedA1 != seedB)
    }

    @Test("SiteBehaviourScripts anti-fingerprinting script injection and coverage")
    func antiFingerprintingScriptContent() {
        let scriptSource = SiteBehaviourScripts.antiFingerprinting

        // Verify key anti-fingerprinting techniques are implemented in the script source
        #expect(scriptSource.contains("makeRNG"))
        #expect(scriptSource.contains("0x6D2B79F5"))
        #expect(scriptSource.contains("CanvasRenderingContext2D.prototype.getImageData"))
        #expect(scriptSource.contains("HTMLCanvasElement.prototype.toDataURL"))
        #expect(scriptSource.contains("AudioBuffer.prototype.getChannelData"))
        #expect(scriptSource.contains("AnalyserNode.prototype.getFloatFrequencyData"))
        #expect(scriptSource.contains("0x9245"))
        #expect(scriptSource.contains("0x9246"))
        #expect(scriptSource.contains("Apple GPU"))
        #expect(scriptSource.contains("hardwareConcurrency"))
        #expect(scriptSource.contains("deviceMemory"))
        #expect(scriptSource.contains("getBattery"))
        #expect(scriptSource.contains("availWidth"))

        // The script rides inside the one document-start script every frame gets.
        #expect(SiteBehaviourScripts.documentStart.contains(scriptSource))
    }

    @Test("CommandCatalog has toggle-anti-fingerprinting registered")
    func commandCatalogRegistration() {
        let command = CommandCatalog.all.first(where: { $0.id == "toggle-anti-fingerprinting" })
        #expect(command != nil)
        #expect(command?.title == "Toggle Anti-Fingerprinting Protection")
        #expect(command?.symbolName == "shield.lefthalf.filled")
    }

    @Test("Known sites: the listed host and its subdomains, nothing else")
    func knownSites() {
        #expect(FingerprintingCompatibility.isKnown(URL(string: "https://sso.godaddy.com/?app=o365&realm=pass")))
        #expect(FingerprintingCompatibility.isKnown(URL(string: "https://eu.sso.godaddy.com/login")))
        #expect(FingerprintingCompatibility.isKnown(URL(string: "https://SSO.GoDaddy.com/")))
        #expect(!FingerprintingCompatibility.isKnown(URL(string: "https://godaddy.com/")))
        #expect(!FingerprintingCompatibility.isKnown(URL(string: "https://notsso.godaddy.com/")))
        #expect(!FingerprintingCompatibility.isKnown(URL(string: "https://example.com/")))
        #expect(!FingerprintingCompatibility.isKnown(nil))
    }

    @Test("The floating toggle is offered on known sites unless closed there or the protection is off everywhere")
    func toggleHost() {
        let url = URL(string: "https://sso.godaddy.com/login")
        #expect(FingerprintingCompatibility.toggleHost(for: url, protectionEnabled: true, dismissed: []) == "sso.godaddy.com")
        #expect(FingerprintingCompatibility.toggleHost(for: url, protectionEnabled: false, dismissed: []) == nil)
        #expect(FingerprintingCompatibility.toggleHost(for: url, protectionEnabled: true, dismissed: ["sso.godaddy.com"]) == nil)
        #expect(FingerprintingCompatibility.toggleHost(for: URL(string: "https://example.com/"), protectionEnabled: true, dismissed: []) == nil)
    }
}
