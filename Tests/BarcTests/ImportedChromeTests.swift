import AppKit
import Foundation
import Testing
@testable import Barc

@Suite("Imported sidebar backgrounds")
@MainActor
struct ImportedChromeTests {
    private var reference: ImportedChrome {
        ImportedChrome(color: .init(red: 0.92, green: -0.02, blue: 0.85, alpha: 1),
                       intensity: 0.8, noise: 0.8, usesDarkText: true, usesLightMaterial: true)
    }

    private func theme(color: [String: Any] = ["colorSpace": "extendedSRGB", "red": 0.92, "green": -0.02, "blue": 0.85]) -> [String: Any] {
        ["background": ["single": ["_0": [
            "contentOverBackgroundAppearance": "light",
            "style": ["color": ["_0": ["blendedSingleColor": ["_0": [
                "color": color, "translucencyStyle": "light",
                "modifiers": ["overlay": "grain", "noiseFactor": 0.8, "intensityFactor": 0.8]
            ]]]]]
        ]]]]
    }

    @Test("Arc's actual shaded background stays separate from its accent swatch")
    func readerBuilderAndRestore() throws {
        var root = try #require(JSONSerialization.jsonObject(with: ArcImportBench.sidebar()) as? [String: Any])
        var sidebar = try #require(root["sidebar"] as? [String: Any])
        var containers = try #require(sidebar["containers"] as? [[String: Any]])
        var spaces = try #require(containers[1]["spaces"] as? [Any])
        var space = try #require(spaces[1] as? [String: Any])
        var info = try #require(space["customInfo"] as? [String: Any])
        var background = theme()
        background["primaryColorPalette"] = ["midTone": ["red": 1.0, "green": 0.0, "blue": 0.0]]
        info["windowTheme"] = background; space["customInfo"] = info; spaces[1] = space
        containers[1]["spaces"] = spaces; sidebar["containers"] = containers; root["sidebar"] = sidebar
        let source = try ArcImportBench.snapshot()
        defer { source.remove() }
        let parsed = try ArcSidebarReader.read(sidebar: JSONSerialization.data(withJSONObject: root),
                                              archive: nil, profiles: source.profiles)
        let snapshot = ArcSourceSnapshot(root: source.root, sourceFingerprint: source.sourceFingerprint,
            profiles: source.profiles, sidebar: parsed, unsupportedIndexedDBFolders: [:], extensions: [:])
        let built = try #require(ArcSpaceBuilder.build(snapshot, options: ArcImportOptions(profileIDs: ["Default"])).first?.snapshot)
        #expect(built.look?.customColorHex == "#ff0000")
        #expect(built.look?.importedChrome == reference)
        let restored = try #require(BrowserSession.spaces(from: SessionSnapshot(spaces: [built], activeSpaceIndex: 0))?.first)
        let color = try #require(restored.wash?.usingColorSpace(.extendedSRGB))
        #expect(abs(color.greenComponent + 0.02) < 0.0001, "Preserve out-of-gamut components until rendering")
        #expect(abs(color.redComponent - 0.92) < 0.0001)
        #expect(abs(color.alphaComponent - 0.64) < 0.0001)
        #expect(restored.chromeGrain == 0.8)
        let saved = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(restored.look))
        #expect(saved.importedChrome == reference)
    }

    @Test("Unknown or malformed backgrounds leave the regular colour available")
    func malformed() throws {
        #expect(ImportedChrome.read(["background": ["gradient": [:]]]) == nil)
        #expect(ImportedChrome.read(theme(color: ["colorSpace": "extendedSRGB", "red": 800, "green": 0, "blue": 0])) == nil)
        #expect(ImportedChrome.read(theme(color: ["colorSpace": "unknown", "red": 1, "green": 0, "blue": 0])) == nil)
        var look = SpaceLook()
        look.importedChrome = ImportedChrome(color: reference.color, intensity: -1, noise: 0,
                                            usesDarkText: true, usesLightMaterial: true)
        look.showsBookmarksBar = true
        let decoded = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(look))
        #expect(decoded.importedChrome == nil)
        #expect(decoded.showsBookmarksBar)
    }

    @Test("Repeat imports enrich old colours but preserve later user edits, including the same accent")
    func repeatedImportAndUserEdits() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        session.setCustomColor(.red, for: space)
        // A legacy imported look predates the customization marker.
        space.look.importedChromeWasCustomized = false
        var incoming = session.snapshot().spaces[0]
        incoming.look?.importedChrome = reference
        let before = space.tabs.map(\.id)
        let identity = space.identity
        _ = try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == reference)
        #expect(space.tabs.map(\.id) == before)
        #expect(space.identity == identity)
        session.setCustomColor(.red, for: space)
        #expect(space.look.importedChrome == nil)
        _ = try session.applyArcSpaces([incoming])
        #expect(space.look.importedChrome == nil, "Re-choosing the same accent is still a user decision")
        #expect(BrowserSession.spaces(from: session.snapshot())?.first?.look.importedChromeWasCustomized == true)
    }

    @Test("Fonts and strength keep the imported shade; a gradient replaces it")
    func editsAndWebsiteColor() {
        let session = TestSession.make().0
        let space = session.activeSpace
        space.theme = .custom
        space.look.importedChrome = reference
        var look = space.look
        look.fonts.standardFamily = "Georgia"
        look.washOpacity = 0.5
        session.setLook(look, for: space)
        #expect(space.look.importedChrome == reference)
        #expect(space.chromeGrain == 0.4)
        look.allowsWebsiteThemeColor = true
        session.setLook(look, for: space)
        space.activeTab?.recordThemeColor(.blue)
        #expect(space.chromeGrain == 0)
        #expect(space.activeImportedChrome == nil)
        session.setSpaceGradient(SpaceGradient(startHex: "#112233", endHex: "#445566"), for: space)
        #expect(space.look.importedChrome == nil)
    }
}
