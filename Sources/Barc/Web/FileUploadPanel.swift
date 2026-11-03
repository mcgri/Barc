import AppKit
import UniformTypeIdentifiers
import WebKit

/// The file picker behind `<input type="file">`, and so behind every upload
/// area and attach button built on one. WebKit shows nothing unless the page's
/// UI delegate answers, and Barc's never did: clicking "Choose file", an
/// attach button or a drop zone did nothing at all.
@MainActor
enum FileUploadPanel {
    /// Tests choose files here instead of a person in the real panel.
    static var testChooser: ((NSOpenPanel) -> [URL]?)?

    static func run(_ parameters: WKOpenPanelParameters, for webView: WKWebView,
                    completion: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.prompt = "Upload"
        if let types = contentTypes(mimeTypes: strings(parameters, "_acceptedMIMETypes"),
                                    fileExtensions: strings(parameters, "_acceptedFileExtensions")) {
            panel.allowedContentTypes = types
        }
        if let chooser = testChooser { completion(chooser(panel)); return }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    /// The types a page's `accept` attribute asks for, or nil to offer every
    /// file. Anything that cannot be matched exactly (an unknown MIME type, a
    /// made-up extension) drops the filter rather than hide a file the page
    /// would have taken.
    static func contentTypes(mimeTypes: [String], fileExtensions: [String]) -> [UTType]? {
        guard !mimeTypes.isEmpty || !fileExtensions.isEmpty else { return nil }
        var types: [UTType] = []
        for mimeType in mimeTypes {
            let type: UTType? = switch mimeType.lowercased() {
            case "image/*": .image
            case "video/*": .movie
            case "audio/*": .audio
            case "text/*": .text
            case let exact: UTType(mimeType: exact)
            }
            guard let type, !type.isDynamic else { return nil }
            types.append(type)
        }
        for fileExtension in fileExtensions {
            let name = fileExtension.hasPrefix(".") ? String(fileExtension.dropFirst()) : fileExtension
            guard let type = UTType(filenameExtension: name), !type.isDynamic else { return nil }
            types.append(type)
        }
        return types
    }

    /// WebKit's parsed `accept` attribute, from private but long-standing
    /// properties. Missing means no filter.
    private static func strings(_ parameters: WKOpenPanelParameters, _ key: String) -> [String] {
        guard parameters.responds(to: Selector((key))) else { return [] }
        return parameters.value(forKey: key) as? [String] ?? []
    }
}
