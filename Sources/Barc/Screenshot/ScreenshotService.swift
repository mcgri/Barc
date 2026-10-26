// Modified for Barc: complete offscreen page capture with bounded in-memory rasterization, 2026-10-25.
// Modified for Barc: application identity and isolated screenshot test inputs, 2026-10-24.
import AppKit
import Foundation
import WebKit

/// The scope of a webpage screenshot capture.
public enum ScreenshotScope: String, Sendable, CaseIterable {
    /// Captures the visible area (viewport) of the web page.
    case visible
    /// Captures the entire scrollable height and width of the web page.
    case fullPage
}

/// The destination for a captured screenshot.
public enum ScreenshotDestination: Sendable {
    /// Saves the screenshot as a PNG file to the Downloads folder (or custom directory).
    case saveToDownloads(customDirectory: URL? = nil)
    /// Copies the screenshot as an image and PNG data to the system clipboard.
    case copyToClipboard
    /// Opens the screenshot in the editor to crop and mark up before saving.
    case annotate
}

/// Coordinates capturing, rendering, saving, and copying screenshots of web pages.
@MainActor
public enum ScreenshotService {
    /// JavaScript snippet to calculate the complete scrollable dimensions of the page.
    private static let pageDimensionScript = """
    (function() {
        var b = document.body;
        var d = document.documentElement;
        var w = Math.max(
            b ? b.scrollWidth : 0,
            b ? b.offsetWidth : 0,
            d ? d.clientWidth : 0,
            d ? d.scrollWidth : 0,
            d ? d.offsetWidth : 0
        );
        var h = Math.max(
            b ? b.scrollHeight : 0,
            b ? b.offsetHeight : 0,
            d ? d.clientHeight : 0,
            d ? d.scrollHeight : 0,
            d ? d.offsetHeight : 0
        );
        return { width: w, height: h };
    })()
    """

    /// Limit the raster size, scaling very long pages instead of cutting off their footer.
    public static let maxFullPageHeight: Double = 24000.0
    static let maxFullPagePixels: Double = 32_000_000

    enum CaptureFailure: Error { case invalidDimensions, invalidRendering }

    /// Captures a screenshot of the specified `WKWebView`.
    ///
    /// - Parameters:
    ///   - webView: The web view to capture.
    ///   - scope: Whether to capture visible viewport or full scrollable page.
    /// - Returns: Rendered `NSImage`.
    public static func capture(webView: WKWebView, scope: ScreenshotScope) async throws -> NSImage {
        switch scope {
        case .visible:
            return try await webView.takeSnapshot(configuration: nil)

        case .fullPage:
            let dimensions = try await webView.callAsyncJavaScript(
                "return " + pageDimensionScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
            let zoom = webView.pageZoom
            let width = max(webView.bounds.width, ((dimensions?["width"] as? NSNumber)?.doubleValue ?? 0) * zoom)
            let height = max(webView.bounds.height, ((dimensions?["height"] as? NSNumber)?.doubleValue ?? 0) * zoom)
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= 1_000_000, height <= 1_000_000 else { throw CaptureFailure.invalidDimensions }

            // takeSnapshot only paints the viewport on macOS, leaving the rest
            // white. WebKit's PDF capture paints the full document without
            // resizing the browser or changing its scroll position. Rasterize
            // that in memory so the destination receives an ordinary image.
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            let data = try await webView.pdf(configuration: config)
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), document.numberOfPages > 0 else { throw CaptureFailure.invalidRendering }
            let displayScale = max(1, webView.window?.backingScaleFactor ?? 1)
            let scale = min(displayScale, sqrt(maxFullPagePixels / (width * height)),
                            maxFullPageHeight / max(width, height))
            let pixelsWide = max(1, Int(floor(width * scale)))
            let pixelsHigh = max(1, Int(floor(height * scale)))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidRendering }
            let target = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(target)
            // WebKit splits documents taller than 14,400 points into PDF
            // pages. Composite all of them vertically, including the footer.
            var offset: CGFloat = 0
            let verticalScale = CGFloat(pixelsHigh) / height
            for index in 1...document.numberOfPages {
                guard let page = document.page(at: index) else { throw CaptureFailure.invalidRendering }
                let bounds = page.getBoxRect(.mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { throw CaptureFailure.invalidRendering }
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(pixelsHigh) - (offset + bounds.height) * verticalScale)
                // Explicit scaling also avoids the blank margins introduced
                // by CGPDFPage's non-upscaling convenience transform on Retina.
                context.scaleBy(x: CGFloat(pixelsWide) / bounds.width, y: verticalScale)
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                context.drawPDFPage(page)
                context.restoreGState()
                offset += bounds.height
                if offset >= height { break }
            }
            guard offset >= height - 1 else { throw CaptureFailure.invalidRendering }
            guard let bitmap = context.makeImage() else { throw CaptureFailure.invalidRendering }
            return NSImage(cgImage: bitmap, size: NSSize(width: Double(pixelsWide) / displayScale,
                                                        height: Double(pixelsHigh) / displayScale))
        }
    }

    /// Converts an `NSImage` to PNG `Data`.
    public static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Copies image and PNG data to the destination; browser actions use the
    /// system clipboard, while a test can supply its own named pasteboard.
    public static func copyImageToClipboard(image: NSImage, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        if let png = pngData(from: image) {
            pasteboard.setData(png, forType: .png)
        }
    }

    /// Saves an `NSImage` to disk in the user's Downloads directory (or specified directory).
    ///
    /// - Parameters:
    ///   - image: The captured image.
    ///   - tabTitle: Page title used to name the file.
    ///   - url: URL used as fallback name.
    ///   - customDirectory: Optional directory override.
    ///   - timestamp: The capture time used to name the file.
    /// - Returns: URL of the written file.
    public static func saveImageToDownloads(
        image: NSImage,
        tabTitle: String?,
        url: URL?,
        customDirectory: URL? = nil,
        timestamp: Date = Date()
    ) throws -> URL {
        let dir = customDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let initialFilename = generateFilename(title: tabTitle ?? url?.host() ?? "Page", timestamp: timestamp)
        var targetURL = dir.appendingPathComponent(initialFilename)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            let baseName = (initialFilename as NSString).deletingPathExtension
            let ext = (initialFilename as NSString).pathExtension
            var counter = 1
            repeat {
                let candidate = "\(baseName) (\(counter)).\(ext)"
                targetURL = dir.appendingPathComponent(candidate)
                counter += 1
            } while FileManager.default.fileExists(atPath: targetURL.path)
        }

        guard let data = pngData(from: image) else {
            throw NSError(domain: "Barc.Screenshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to convert screenshot to PNG format."
            ])
        }

        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    /// Formats a clean, readable filename for screenshots.
    public static func generateFilename(title: String?, timestamp: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dateStr = formatter.string(from: timestamp)

        let sanitized = sanitizeFilename(title ?? "")
        if sanitized.isEmpty {
            return "Screenshot \(dateStr).png"
        } else {
            let truncated = String(sanitized.prefix(50))
            return "\(truncated) - Screenshot \(dateStr).png"
        }
    }

    /// Sanitizes arbitrary page titles into filesystem-safe filename components.
    public static func sanitizeFilename(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}[]$!'@+`=")
        let cleaned = string.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Displays a momentary visual shutter flash over the web view.
    public static func flashFeedback(in view: NSView) {
        let overlay = NSView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit runs this block on the main thread, but it is imported as
            // `@Sendable`, so the compiler cannot prove it. Assume what is true
            // rather than hop to the actor and leave the flash up an extra turn.
            MainActor.assumeIsolated {
                overlay.removeFromSuperview()
            }
        })
    }

    /// Plays a subtle shutter sound feedback.
    public static func playShutterSound() {
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.play()
        }
    }
}
