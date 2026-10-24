import AppKit
import QuartzCore
import Testing
@testable import Barc

@Suite("Sidebar theme editing", .serialized)
@MainActor
struct SidebarThemeEditorTests {
    private func button(_ label: String, in editor: SidebarThemeEditor) throws -> NSButton {
        try #require(UITestSupport.buttons(in: editor.view).first { $0.accessibilityLabel() == label })
    }
    private var imported: ImportedChrome {
        ImportedChrome(color: .init(red: 0.92, green: -0.02, blue: 0.85, alpha: 1), intensity: 0.8, noise: 0.65,
            usesDarkText: true, usesLightMaterial: true)
    }
    private func fixture() -> (BrowserSession, Space, SidebarThemeEditor) {
        let session = TestSession.make().0
        let space = session.activeSpace
        space.theme = .custom; space.look.importedChrome = imported
        let editor = SidebarThemeEditor(session: session, space: space)
        _ = UITestSupport.host(editor.view, width: 356, height: 500)
        return (session, space, editor)
    }

    @Test("Opening and paging the editor never rewrites the imported theme or other session data")
    func openingAndPaging() throws {
        let session = TestSession.make().0
        let space = session.activeSpace
        space.theme = .custom; space.look.importedChrome = imported
        let before = session.snapshot()
        let editor = SidebarThemeEditor(session: session, space: space)
        _ = editor.view
        #expect(editor.style.colors == [imported.color] && editor.style.intensity == 0.8 && editor.style.grain == 0.65)
        #expect(!((try button("Move to previous preset page.", in: editor)).isEnabled))
        for _ in 0..<4 { try button("Move to next preset page.", in: editor).performClick(nil) }
        #expect(editor.presetPage == 4)
        #expect(!(try button("Move to next preset page.", in: editor)).isEnabled)
        for _ in 0..<4 { try button("Move to previous preset page.", in: editor).performClick(nil) }
        #expect(editor.presetPage == 0 && session.snapshot() == before)
        #expect(UITestSupport.buttons(in: editor.view).filter { $0.accessibilityLabel()?.hasPrefix("Set space color to") == true }.count == 9)
    }

    @Test("Preset, intensity and grain actions update only the chosen Space while preserving its profile and pages")
    func editsInactiveSpace() throws {
        let (session, source, editor) = fixture()
        let target = session.addSpace(named: "Other")
        let beforeOther = target.look
        let profile = source.profile
        let tabs = source.tabs.map(\.id)
        try button("Set space color to #e59fbb", in: editor).performClick(nil)
        editor.intensity.setAccessibilityValue(0.25 as NSNumber)
        editor.grain.setAccessibilityValue(0.4 as NSNumber)
        #expect(source.look.sidebarTheme?.colors.first?.nsColor.hexString == "#e59fbb")
        #expect(source.look.sidebarTheme?.intensity == 0.25 && source.chromeGrain == 0.4)
        #expect(abs((source.wash?.alphaComponent ?? 0) - 0.2) < 0.0001)
        #expect(source.look.importedChrome == nil && source.look.importedChromeWasCustomized)
        #expect(source.profile === profile && source.tabs.map(\.id) == tabs)
        #expect(session.activeSpace === target && target.look == beforeOther)
        try button("Cycle noise texture", in: editor).performClick(nil)
        #expect(source.chromeGrain == 0 && source.look.sidebarTheme?.grain == 0.4)
        try button("Cycle noise texture", in: editor).performClick(nil)
        #expect(source.chromeGrain == 0.4)
    }

    @Test("Every added color reaches the actual gradient layer, and removing the last clears the tint")
    func multipleColors() throws {
        let (_, space, editor) = fixture()
        try button("Add", in: editor).performClick(nil)
        try button("Add", in: editor).performClick(nil)
        #expect(editor.style.colors.count == 3)
        let gradient = try #require(space.washGradient(for: nil))
        #expect(gradient.additionalColors.count == 1 && gradient.usesFullColor)
        let tint = TintView()
        _ = UITestSupport.host(tint, width: 200, height: 500)
        tint.gradientWash = gradient
        let layer = try #require(tint.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        #expect(layer.colors?.count == 3)
        for _ in 0..<3 { try button("Remove", in: editor).performClick(nil) }
        #expect(space.theme == .neutral && space.wash == nil && space.washGradient(for: nil) == nil)
        #expect(!(try button("Remove", in: editor)).isEnabled)
        try button("Add", in: editor).performClick(nil)
        #expect(space.theme == .custom && space.wash != nil && space.look.sidebarTheme?.colors.count == 1)
    }

    @Test("Appearance applies across Spaces and survives restoring, including color and texture choices")
    func globalAppearanceAndRestore() throws {
        let name = "sidebar-theme.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "sidebar-theme-\(UUID()).json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let settings = Settings(defaults: defaults)
        let session = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let source = session.activeSpace
        source.theme = .custom; source.look.importedChrome = imported
        let other = session.addSpace(named: "Other", profile: source.profile)
        let editor = SidebarThemeEditor(session: session, space: other)
        _ = editor.view
        try button("Dark", in: editor).performClick(nil)
        #expect(settings.appearance == .dark && session.spaces.allSatisfy { $0.look.appearance == .dark })
        #expect(source.look.importedChrome?.usesLightMaterial == false && source.look.importedChrome?.usesDarkText == false)
        editor.grain.setAccessibilityValue(0.6 as NSNumber)
        try button("Add", in: editor).performClick(nil)
        session.saveNow()
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let restored = try #require(reopened.spaces.first { $0.id == other.id })
        #expect(reopened.browserAppearance == .dark && restored.look.sidebarTheme == other.look.sidebarTheme)
        #expect(restored.chromeGrain == 0.6 && restored.washGradient(for: nil) != nil)
        #expect(restored.profile === reopened.spaces[0].profile)
        try button("Automatic", in: editor).performClick(nil)
        #expect(session.spaces.allSatisfy { $0.look.appearance == .system } && settings.appearance == .system)
    }

    @Test("Existing theme settings can replace the new editor's theme without stale colors winning")
    func existingSettingsOverride() {
        let (session, source, editor) = fixture()
        let style = editor.style
        session.setSidebarTheme(style, for: source)
        session.setTheme(.green, for: source)
        #expect(source.look.sidebarTheme == nil && source.color.hexString == SpaceTheme.green.color.hexString)
        session.setSidebarTheme(style, for: source)
        session.setCustomColor(.blue, for: source)
        #expect(source.look.sidebarTheme == nil && source.color.hexString == "#0000ff")
        session.setSidebarTheme(style, for: source)
        session.setSpaceGradient(SpaceGradient(startHex: "#ff0000", endHex: "#00ff00"), for: source)
        #expect(source.look.sidebarTheme == nil && source.washGradient(for: nil)?.usesFullColor == false)
        session.setSidebarTheme(style, for: source)
        var look = source.look; look.customColorHex = "#abcdef"
        session.setLook(look, for: source)
        #expect(source.look.sidebarTheme == nil)
    }

    @Test("Color handles respond to keys and stay in place when unrelated controls change")
    func handleStability() throws {
        let (_, space, editor) = fixture()
        let handle = try #require(UITestSupport.descendants(of: editor.view).compactMap { $0 as? NSControl }.first { $0.accessibilityLabel() == "Color 1" })
        let before = handle.frame
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        handle.keyDown(with: event)
        #expect(handle.frame.origin.x == before.origin.x + 3)
        #expect(space.look.sidebarTheme != nil)
        let moved = handle.frame
        editor.intensity.setAccessibilityValue(0.4 as NSNumber)
        #expect(handle.frame == moved)
        #expect(editor.intensity.accessibilityPerformIncrement() && editor.intensity.value == 0.45)
        #expect(editor.grain.accessibilityPerformDecrement() && editor.grain.value == 0.6)
    }

    @Test("Malformed values are bounded and old session files still decode without an editor theme")
    func malformedAndLegacy() throws {
        let data = Data(#"{"colors":[{"red":500,"green":0,"blue":0,"alpha":1}],"intensity":4,"grain":-3}"#.utf8)
        let decoded = try JSONDecoder().decode(SidebarThemeStyle.self, from: data)
        #expect(decoded.colors.isEmpty && decoded.intensity == 1 && decoded.grain == 0)
        let style = SidebarThemeStyle(colors: [imported.color], intensity: .nan, grain: .infinity)
        #expect(style.intensity == 0 && style.grain == 0)
        #expect(try JSONDecoder().decode(SpaceLook.self, from: Data("{}".utf8)).sidebarTheme == nil)
        #expect(try JSONDecoder().decode(SidebarThemeStyle.self, from: JSONEncoder().encode(style)) == style)
    }
}
