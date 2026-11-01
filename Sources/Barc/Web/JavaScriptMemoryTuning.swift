import Foundation
import WebKit

/// Keeps each page's JavaScript heap closer to the memory it actually uses.
///
/// Since late 2024 JavaScriptCore lets a page's heap grow to about four times
/// its live size between collections on Macs with 16 GB or more (its
/// "aggressive" growth mode). Long-lived web apps such as Gmail, ChatGPT and
/// dashboards then sit on hundreds of megabytes of garbage. Telling
/// JavaScriptCore the Mac has at most 8 GB (`forceRAMSize`) restores its
/// classic growth instead: 2x while a page is under 2 GB, 1.5x to 4 GB, 1.24x
/// beyond. 8 GB rather than less keeps its critical-memory mode, which
/// collects much more often, out of reach below 6.4 GB per page.
///
/// Measured on a page holding 200 MB of live objects while churning garbage:
/// 554-838 MB with WebKit's defaults, 253 MB tuned, in the same run time.
///
/// WebKit reads `JSC.config` from a process pool's JavaScript configuration
/// directory as each content process starts, so the choice reaches every page
/// opened afterwards without relaunching Barc. The `__XPC_JSC_` environment
/// route works only when set before Barc itself launches, and every
/// `WKWebViewConfiguration` has its own pool, so the directory is set on each
/// configuration rather than once.
@MainActor
enum JavaScriptMemoryTuning {
    typealias Options = [(key: String, value: String)]

    /// The most memory JavaScriptCore is told the Mac has.
    static let ramSizeCap: UInt64 = 8 << 30

    /// JavaScriptCore options written to `JSC.config`.
    static func options(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Options {
        [("forceRAMSize", String(min(physicalMemory, ramSizeCap)))]
    }

    private static let selector = Selector(("_setJavaScriptConfigurationDirectory:"))

    /// Nil outside a bundled app: under `swift test` `AppPaths` falls back to
    /// the real Barc's folder, and a test must never write into a real profile.
    static var defaultDirectory: URL? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return AppPaths.supportDirectory.appending(path: "JavaScriptCore", directoryHint: .isDirectory)
    }

    /// The file JavaScriptCore parses: one `jscOptions` block for every process.
    static func configuration(_ options: Options) -> String {
        "jscOptions {\n" + options.map { "    \($0.key)=\($0.value)\n" }.joined() + "}\n"
    }

    /// The directory pages should read, written fresh when the setting is on.
    /// Nil when it is off or the file cannot be written: pages then keep
    /// WebKit's defaults, which is always safe.
    private static var preparedDirectory: URL?
    private static var preparedFor: Bool?

    static func prepare(enabled: Bool, options: Options = Self.options(),
                        directory: URL? = defaultDirectory) -> URL? {
        guard enabled, let directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "JSC.config")
            let contents = Data(configuration(options).utf8)
            if (try? Data(contentsOf: file)) != contents { try contents.write(to: file, options: .atomic) }
            return directory
        } catch {
            return nil
        }
    }

    /// Points a configuration's process pool at the tuned options, or clears
    /// them. Content processes started for this configuration read them.
    static func apply(to configuration: WKWebViewConfiguration, enabled: Bool = Settings.shared.compactsJavaScriptMemory) {
        if preparedFor != enabled {
            preparedDirectory = prepare(enabled: enabled)
            preparedFor = enabled
        }
        apply(directory: preparedDirectory, to: configuration.processPool)
    }

    static func apply(directory: URL?, to pool: WKProcessPool) {
        guard pool.responds(to: selector) else { return }
        pool.perform(selector, with: directory)
    }
}
