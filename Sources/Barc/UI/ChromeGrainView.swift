// Modified for Barc: static, pixel-sized sidebar grain, 2026-10-24.
import AppKit

/// Arc's light translucent ground is dimmer than AppKit's current sidebar
/// material. Shade the material below the tint, leaving text and tiles alone.
@MainActor
final class ChromeMaterialShadeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.21).cgColor
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("ChromeMaterialShadeView is created in code only") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One small texture, tiled at device-pixel scale. It has no timer and never
/// changes seed when the pointer moves, the window resizes, or a Space changes.
@MainActor
final class ChromeGrainView: NSView {
    var amount: Double = 0 {
        didSet {
            guard amount != oldValue else { return }
            isHidden = amount <= 0
            alphaValue = min(1, max(0, amount)) * 0.125
        }
    }

    private static let texture: CGImage? = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x42617263
        for index in 0..<(side * side) {
            for channel in 0..<3 {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                bytes[index * 4 + channel] = UInt8(truncatingIfNeeded: seed)
            }
            bytes[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("ChromeGrainView is created in code only") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = Self.texture, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128 / scale, height: 128 / scale), byTiling: true)
    }
}
