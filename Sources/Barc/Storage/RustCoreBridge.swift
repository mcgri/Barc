import Darwin
import Foundation

/// Dynamic bridge to `libbarc_core.dylib` (Rust native core: Brave `adblock-rust`
/// + `lz4_flex` compressed out-of-line state blobs).
///
/// Loaded lazily via `dlopen` so plain `swift build` / `swift test` never fail
/// when the dylib is not yet bundled, while bundled builds automatically use
/// the Rust implementation and coordinate with custom-compiled WebKit's
/// `NetworkProcess` adblocker.
enum RustCoreBridge {
    private typealias StateWriteFn = @convention(c) (UnsafePointer<CChar>, UnsafePointer<UInt8>, Int) -> Int32
    private typealias StateReadFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Int32
    private typealias BytesFreeFn = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void

    private final class Library: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer?
        let stateWrite: StateWriteFn?
        let stateRead: StateReadFn?
        let bytesFree: BytesFreeFn?

        init() {
            let candidates = Self.searchPaths()
            var opened: UnsafeMutableRawPointer?
            for path in candidates {
                if FileManager.default.fileExists(atPath: path),
                   let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                    opened = h
                    break
                }
            }
            self.handle = opened
            if let opened {
                self.stateWrite = dlsym(opened, "barc_state_write").map { unsafeBitCast($0, to: StateWriteFn.self) }
                self.stateRead = dlsym(opened, "barc_state_read").map { unsafeBitCast($0, to: StateReadFn.self) }
                self.bytesFree = dlsym(opened, "barc_bytes_free").map { unsafeBitCast($0, to: BytesFreeFn.self) }
            } else {
                self.stateWrite = nil
                self.stateRead = nil
                self.bytesFree = nil
            }
        }

        private static func searchPaths() -> [String] {
            var paths: [String] = []
            if let envPath = ProcessInfo.processInfo.environment["BARC_RUST_CORE_DYLIB"], !envPath.isEmpty {
                paths.append(envPath)
            }
            if let frameworks = Bundle.main.privateFrameworksURL {
                paths.append(frameworks.appending(path: "libbarc_core.dylib").path)
            }
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
            if let execDir {
                paths.append(execDir.appending(path: "../Frameworks/libbarc_core.dylib").standardized.path)
            }
            // Local development checkout fallback.
            paths.append("/Volumes/DiskC/browsermigration/Barc/RustCore/target/release/libbarc_core.dylib")
            return paths
        }
    }

    private static let library = Library()

    /// True when `libbarc_core.dylib` is loaded in this process.
    static var isLoaded: Bool { library.handle != nil }

    /// True when Barc is running against our custom-compiled `WebKit.framework`
    /// with `adblock-rust` embedded in `NetworkProcess`.
    static var isCustomWebKitActive: Bool {
        if ProcessInfo.processInfo.environment["BARC_CUSTOM_WEBKIT"] == "1" { return true }
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        return FileManager.default.fileExists(atPath: frameworks.appending(path: "WebKit.framework/WebKit").path)
    }

    /// True when custom WebKit's `NetworkProcess` is filtering network requests
    /// via `libbarc_core.dylib` (Brave `adblock-rust`), so WebContent processes
    /// do not need 63 MB of compiled `WKContentRuleList` DFAs mapped into every tab.
    static var isNetworkProcessAdblockActive: Bool {
        if ProcessInfo.processInfo.environment["BARC_RUST_NETWORK_ADBLOCK"] == "0" { return false }
        if ProcessInfo.processInfo.environment["BARC_RUST_NETWORK_ADBLOCK"] == "1" { return true }
        return isCustomWebKitActive && isLoaded
    }

    /// Writes `data` compressed with Rust `lz4_flex` to `path` atomically.
    /// Returns true if handled by Rust; false if caller should use native fallback.
    static func writeCompressedState(_ data: Data, to path: String) -> Bool {
        guard let writeFn = library.stateWrite else { return false }
        return path.withCString { cPath in
            data.withUnsafeBytes { raw in
                let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                // Pass a valid non-null pointer for empty buffers.
                var dummy: UInt8 = 0
                let effectivePtr = ptr ?? withUnsafePointer(to: &dummy) { $0 }
                return writeFn(cPath, effectivePtr, data.count) == 0
            }
        }
    }

    /// Reads an LZ4 state blob written by `writeCompressedState`.
    static func readCompressedState(from path: String) -> Data? {
        guard let readFn = library.stateRead, let freeFn = library.bytesFree else { return nil }
        return path.withCString { cPath in
            var outPtr: UnsafeMutablePointer<UInt8>?
            var outLen: Int = 0
            guard readFn(cPath, &outPtr, &outLen) == 0 else { return nil }
            guard let ptr = outPtr else { return Data() }
            defer { freeFn(ptr, outLen) }
            return Data(bytes: ptr, count: outLen)
        }
    }
}
