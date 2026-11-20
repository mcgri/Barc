import Foundation

/// Persists `WKWebView.interactionState` blobs out-of-line on disk, compressed
/// with Rust LZ4 (or Apple LZFSE fallback), so sleeping tabs hold 0 bytes of
/// serialized WebKit state in Swift RAM and `session.json` stays tiny (<300 KB
/// instead of 12+ MB).
final class InteractionStateStore: @unchecked Sendable {
    static let shared = InteractionStateStore()

    /// Blobs larger than this (e.g. multi-megabyte SPA `history.state` dumps)
    /// are dropped instead of written; the tab restores cleanly from URL +
    /// `hibernationViewport` scroll position.
    static let maxUncompressedBytes = 256 * 1024

    private let directory: URL?
    private let queue = DispatchQueue(label: "barc.interaction-state", qos: .utility)

    init(directory: URL? = InteractionStateStore.defaultDirectory) {
        self.directory = directory
    }

    private static var defaultDirectory: URL? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return AppPaths.supportDirectory.appending(path: "TabStates", directoryHint: .isDirectory)
    }

    private func fileURL(forKey key: String) -> URL? {
        guard let directory, !key.isEmpty, !key.contains("/"), !key.contains("..") else { return nil }
        return directory.appending(path: "\(key).barcstate")
    }

    /// Stores `data` out-of-line under `key`. Returns `key` on success, or `nil`
    /// if the blob exceeds `maxUncompressedBytes` or storage is unavailable
    /// (for example in unit tests without a bundle identifier).
    @discardableResult
    func store(_ data: Data, forKey key: String) -> String? {
        guard !data.isEmpty, data.count <= Self.maxUncompressedBytes else {
            remove(forKey: key)
            return nil
        }
        guard let url = fileURL(forKey: key) else { return nil }
        let path = url.path
        queue.async {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if RustCoreBridge.writeCompressedState(data, to: path) {
                return
            }
            // Fallback when RustCore dylib is unavailable: Apple LZFSE with magic header.
            if let compressed = try? (data as NSData).compressed(using: .lzfse) as Data {
                var wrapped = Data([0x42, 0x4C, 0x5A, 0x46]) // "BLZF"
                wrapped.append(compressed)
                try? wrapped.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        return key
    }

    /// Synchronous read used only when waking a single sleeping tab.
    func load(forKey key: String) -> Data? {
        guard let url = fileURL(forKey: key) else { return nil }
        return queue.sync {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            // Check for LZFSE fallback magic header first.
            if let raw = try? Data(contentsOf: url),
               raw.count >= 4,
               raw[0] == 0x42, raw[1] == 0x4C, raw[2] == 0x5A, raw[3] == 0x46 {
                return try? (raw.dropFirst(4) as NSData).decompressed(using: .lzfse) as Data
            }
            return RustCoreBridge.readCompressedState(from: path)
        }
    }

    func remove(forKey key: String) {
        guard let url = fileURL(forKey: key) else { return }
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes state files that no live or archived tab references anymore.
    func prune(keeping validKeys: Set<String>) {
        guard let directory else { return }
        queue.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".barcstate") {
                let key = String(name.dropLast(".barcstate".count))
                if !validKeys.contains(key) {
                    try? FileManager.default.removeItem(at: directory.appending(path: name))
                }
            }
        }
    }
}
