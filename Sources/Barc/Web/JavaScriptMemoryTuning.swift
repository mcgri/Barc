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
///
/// A pool carrying the directory must never prewarm. WebKit hands a content
/// process its `JSC.config` along with its data store, and a prewarmed process
/// gets its data store only when it is taken, after JavaScriptCore has already
/// started. Parsing the file then crashes the process (`EXC_BREAKPOINT` in
/// `JSC::ConfigFile::parse`). WebKit turns prewarming on after a tab's first
/// process swap, so the crash came at the second, on a navigation still
/// provisional: WebKit tells no delegate, and the old page simply stays on
/// screen. Signing in to FreeAgent with Google did exactly that.
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
    private static let allocate = Selector(("alloc"))
    private static let poolConfiguration = Selector(("_configuration"))
    private static let poolInitialiser = Selector(("_initWithConfiguration:"))
    private static let prewarmingKey = "prewarmsProcessesAutomatically"

    /// The pools made here, the only ones allowed to carry the directory.
    private static let unwarmedPools = NSHashTable<WKProcessPool>.weakObjects()

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

    /// Refuses a directory for any pool that can prewarm. Such a page keeps
    /// WebKit's defaults, which is always safe.
    static func apply(directory: URL?, to pool: WKProcessPool) {
        guard pool.responds(to: selector), directory == nil || unwarmedPools.contains(pool) else { return }
        pool.perform(selector, with: directory)
    }

    /// Gives a configuration Barc is building a pool that can carry the
    /// directory. Only for new configurations: one WebKit passes for
    /// `window.open` has to keep its opener's pool, and WebKit throws if the
    /// two differ.
    static func installProcessPool(in configuration: WKWebViewConfiguration,
                                   enabled: Bool = Settings.shared.compactsJavaScriptMemory) {
        guard enabled, let pool = makeUnwarmedPool() else { return }
        configuration.processPool = pool
    }

    /// A pool like WebKit's default in every way but prewarming, or nil where
    /// this WebKit cannot make one. The setting has to be made explicitly:
    /// left unset, WebKit turns prewarming on by itself after a process swap.
    static func makeUnwarmedPool() -> WKProcessPool? {
        let template = WKProcessPool()
        guard template.responds(to: poolConfiguration), template.responds(to: poolInitialiser),
              let settings = template.perform(poolConfiguration)?.takeUnretainedValue() as? NSObject,
              settings.responds(to: Selector((prewarmingKey))) else { return nil }
        settings.setValue(false, forKey: prewarmingKey)
        // `alloc`'s reference is the one the initialiser consumes.
        guard let allocated = (WKProcessPool.self as AnyObject).perform(allocate)?.takeUnretainedValue(),
              let pool = allocated.perform(poolInitialiser, with: settings)?.takeRetainedValue() as? WKProcessPool
        else { return nil }
        unwarmedPools.add(pool)
        return pool
    }
}
