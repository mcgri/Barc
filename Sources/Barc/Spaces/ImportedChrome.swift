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

    var isValid: Bool {
        color.isValid && intensity.isFinite && (0...1).contains(intensity)
            && noise.isFinite && (0...1).contains(noise)
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
        let result = ImportedChrome(
            color: Color(red: red, green: green, blue: blue, alpha: raw["alpha"] as? Double ?? 1),
            intensity: modifiers?["intensityFactor"] as? Double ?? 1,
            noise: modifiers?["overlay"] as? String == "grain" ? modifiers?["noiseFactor"] as? Double ?? 0 : 0,
            usesDarkText: appearance == "light", usesLightMaterial: translucency == "light")
        return result.isValid ? result : nil
    }
}
