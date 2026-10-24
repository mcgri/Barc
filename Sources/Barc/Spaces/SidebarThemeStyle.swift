// Modified for Barc: editable sidebar colors, intensity and texture, 2026-10-24.
import AppKit

struct SidebarThemeStyle: Codable, Hashable, Sendable {
    var colors: [ImportedChrome.Color]
    var intensity: Double
    var grain: Double
    var hasGrain: Bool

    init(colors: [ImportedChrome.Color], intensity: Double = 0.8, grain: Double = 0, hasGrain: Bool = true) {
        self.colors = colors.filter(\.isValid)
        self.intensity = Self.unit(intensity)
        self.grain = Self.unit(grain)
        self.hasGrain = hasGrain
    }

    @MainActor
    init(space: Space) {
        if let style = space.look.sidebarTheme { self = style; return }
        if let chrome = space.activeImportedChrome {
            self.init(colors: [chrome.color], intensity: chrome.intensity * space.look.washOpacity, grain: chrome.noise)
        } else if let gradient = space.look.gradient {
            self.init(colors: [Self.color(gradient.startColor), Self.color(gradient.endColor)], intensity: space.look.washOpacity)
        } else {
            self.init(colors: space.theme == .neutral ? [] : [Self.color(space.color)], intensity: space.look.washOpacity * 0.8)
        }
    }

    @MainActor
    static func color(_ color: NSColor) -> ImportedChrome.Color {
        let rgb = color.usingColorSpace(.extendedSRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return .init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    func chrome(dark: Bool) -> ImportedChrome? {
        colors.first.map { ImportedChrome(color: $0, intensity: intensity, noise: hasGrain ? grain : 0,
            usesDarkText: !dark, usesLightMaterial: !dark) }
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private enum CodingKeys: String, CodingKey { case colors, intensity, grain, hasGrain }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(colors: (try? c.decode([ImportedChrome.Color].self, forKey: .colors)) ?? [],
            intensity: (try? c.decode(Double.self, forKey: .intensity)) ?? 0.8,
            grain: (try? c.decode(Double.self, forKey: .grain)) ?? 0,
            hasGrain: (try? c.decode(Bool.self, forKey: .hasGrain)) ?? true)
    }
}
