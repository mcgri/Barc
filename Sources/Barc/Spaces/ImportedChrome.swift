// Modified for Barc: retain Arc's sidebar background independently of its accent, 2026-10-24.
import AppKit

/// Arc's accent swatch is not its window background. Keep the background's
/// extended-sRGB components and modifiers until the window actually draws it.
struct ImportedChrome: Codable, Hashable, Sendable {
    struct Color: Codable, Hashable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        var isValid: Bool {
            [red, green, blue].allSatisfy { $0.isFinite && (-1...2).contains($0) }
                && alpha.isFinite && (0...1).contains(alpha)
        }

        var nsColor: NSColor {
            NSColor(colorSpace: .extendedSRGB,
                    components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)], count: 4)
        }
    }

    let color: Color
    let intensity: Double
    let noise: Double
    let usesDarkText: Bool
    let usesLightMaterial: Bool
    var lightFocus: Color? = nil
    var darkFocus: Color? = nil
    var lightSubtitle: Color? = nil
    var darkSubtitle: Color? = nil
    var lightMaxContrast: Color? = nil
    var darkMaxContrast: Color? = nil

    var isValid: Bool {
        color.isValid && intensity.isFinite && (0...1).contains(intensity)
            && noise.isFinite && (0...1).contains(noise)
            && lightFocus?.isValid != false && darkFocus?.isValid != false
            && lightSubtitle?.isValid != false && darkSubtitle?.isValid != false
            && lightMaxContrast?.isValid != false && darkMaxContrast?.isValid != false
    }

    func enrichingPalette(from source: ImportedChrome) -> ImportedChrome {
        guard color == source.color else { return self }
        var result = self
        result.lightFocus = lightFocus ?? source.lightFocus
        result.darkFocus = darkFocus ?? source.darkFocus
        result.lightSubtitle = lightSubtitle ?? source.lightSubtitle
        result.darkSubtitle = darkSubtitle ?? source.darkSubtitle
        result.lightMaxContrast = lightMaxContrast ?? source.lightMaxContrast
        result.darkMaxContrast = darkMaxContrast ?? source.darkMaxContrast
        return result
    }

    /// Decode only the supported solid background. Unknown future styles keep
    /// the ordinary Space colour rather than silently guessing a different one.
    static func read(_ theme: [String: Any]?) -> ImportedChrome? {
        func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
        guard let single = object(object(theme?["background"])?["single"]),
              let background = object(single["_0"]),
              let style = object(background["style"]),
              let colorStyle = object(object(style["color"])?["_0"]),
              let blended = object(object(colorStyle["blendedSingleColor"])?["_0"]),
              let raw = object(blended["color"]),
              raw["colorSpace"] as? String == "extendedSRGB",
              let red = raw["red"] as? Double, let green = raw["green"] as? Double,
              let blue = raw["blue"] as? Double,
              let appearance = background["contentOverBackgroundAppearance"] as? String,
              ["light", "dark"].contains(appearance),
              let translucency = blended["translucencyStyle"] as? String,
              ["light", "dark"].contains(translucency) else { return nil }
        let modifiers = object(blended["modifiers"])
        var result = ImportedChrome(
            color: Color(red: red, green: green, blue: blue, alpha: raw["alpha"] as? Double ?? 1),
            intensity: modifiers?["intensityFactor"] as? Double ?? 1,
            noise: modifiers?["overlay"] as? String == "grain" ? modifiers?["noiseFactor"] as? Double ?? 0 : 0,
            usesDarkText: appearance == "light", usesLightMaterial: translucency == "light")
        let palettes = object(object(theme?["semanticColorPalette"])?["appearanceBased"])
        func semantic(_ role: String, _ appearance: String) -> Color? {
            guard let raw = object(object(palettes?[appearance])?[role]),
                  raw["colorSpace"] as? String == "extendedSRGB",
                  let r = raw["red"] as? Double, let g = raw["green"] as? Double,
                  let b = raw["blue"] as? Double else { return nil }
            let value = Color(red: r, green: g, blue: b, alpha: raw["alpha"] as? Double ?? 1)
            return value.isValid ? value : nil
        }
        result.lightFocus = semantic("focus", "light")
        result.darkFocus = semantic("focus", "dark")
        result.lightSubtitle = semantic("subtitle", "light")
        result.darkSubtitle = semantic("subtitle", "dark")
        result.lightMaxContrast = semantic("maxContrastColor", "light")
        result.darkMaxContrast = semantic("maxContrastColor", "dark")
        return result.isValid ? result : nil
    }
}
