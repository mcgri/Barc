import Foundation
import SQLite3

enum ArcSourceSnapshotter {
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        let fileID: UInt64
    }

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Arc")
    }

    static func capture(_ selected: URL, temporaryParent: URL = FileManager.default.temporaryDirectory) throws -> ArcSourceSnapshot {
        let manager = FileManager.default
        var source = selected.standardizedFileURL.resolvingSymlinksInPath()
        if source.lastPathComponent == "User Data" { source.deleteLastPathComponent() }
        guard manager.fileExists(atPath: source.appending(path: "StorableSidebar.json").path),
              manager.fileExists(atPath: source.appending(path: "User Data/Local State").path) else {
            throw ArcImportFailure.invalidFolder
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let target = temporaryParent.appending(path: "barc-arc-import-\(UUID().uuidString)", directoryHint: .isDirectory)
            try manager.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                var observed: [String: Stamp] = [:]
                func copy(_ relative: String, required: Bool = false) throws {
                    let from = source.appending(path: relative)
                    guard manager.fileExists(atPath: from.path) else {
                        if required { throw ArcImportFailure.unreadable((relative as NSString).lastPathComponent) }
                        return
                    }
                    let to = target.appending(path: relative)
                    let resolved = from.resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(source.path + "/") else { throw ArcImportFailure.invalidFolder }
                    observed[relative] = try stamp(from)
                    try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try manager.copyItem(at: from, to: to)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
                }
                try copy("StorableSidebar.json", required: true)
                try copy("StorableArchiveItems.json")
                try copy("StorableWindows.json")
                try copy("User Data/Local State", required: true)
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: target.appending(path: "User Data/Local State"))) as? [String: Any]
                let cache = ((state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]) ?? [:]
                var profiles: [ArcProfile] = []
                for name in cache.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    guard validProfileName(name), manager.fileExists(atPath: source.appending(path: "User Data/\(name)").path) else { continue }
                    let display = name == "Default" ? "Personal" : cache[name]?["name"] as? String ?? name
                    profiles.append(ArcProfile(folder: name, name: display))
                }
                guard !profiles.isEmpty else { throw ArcImportFailure.invalidFolder }
                var indexedDB: [String: Int] = [:]
                var extensions: [String: Int] = [:]
                var databases: [String] = []
                for profile in profiles {
                    let prefix = "User Data/\(profile.folder)/"
                    for name in ["Preferences", "Bookmarks"] { try copy(prefix + name) }
                    for name in ["History", "Login Data", "Web Data", "Cookies", "Network/Cookies"] {
                        let relative = prefix + name
                        if manager.fileExists(atPath: source.appending(path: relative).path) {
                            try copy(relative)
                            try copy(relative + "-wal")
                            // A copied WAL is replayed in the private directory. SQLite
                            // may create its own shared-memory index there, never in Arc.
                            databases.append(relative)
                        }
                    }
                    let storage = source.appending(path: prefix + "Local Storage/leveldb")
                    if manager.fileExists(atPath: storage.path) {
                        observed[prefix + "Local Storage/leveldb"] = try stamp(storage)
                        let files = try manager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isRegularFileKey])
                        for file in files where file.lastPathComponent != "LOCK" {
                            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                                try copy(prefix + "Local Storage/leveldb/" + file.lastPathComponent)
                            }
                        }
                        // Detect log rotation/compaction as well as changes to existing files.
                    }
                    let idb = source.appending(path: prefix + "IndexedDB")
                    indexedDB[profile.folder] = ((try? manager.contentsOfDirectory(atPath: idb.path)) ?? []).filter { $0.hasSuffix(".leveldb") }.count
                    let addon = source.appending(path: prefix + "Extensions")
                    extensions[profile.folder] = ((try? manager.contentsOfDirectory(atPath: addon.path)) ?? []).filter { !$0.hasPrefix(".") }.count
                }
                for (path, before) in observed where (try? stamp(source.appending(path: path))) != before {
                    _ = path
                    throw ArcImportFailure.sourceChanging
                }
                for path in databases { try freezeDatabase(target.appending(path: path)) }
                let sidebar = try ArcSidebarReader.read(
                    sidebar: Data(contentsOf: target.appending(path: "StorableSidebar.json")),
                    archive: try? Data(contentsOf: target.appending(path: "StorableArchiveItems.json")), profiles: profiles,
                    windows: try? Data(contentsOf: target.appending(path: "StorableWindows.json")))
                return ArcSourceSnapshot(root: target, sourceFingerprint: ArcImportID.fingerprint(source), profiles: profiles,
                                         sidebar: sidebar, unsupportedIndexedDBFolders: indexedDB, extensions: extensions)
            } catch {
                try? manager.removeItem(at: target)
                if error as? ArcImportFailure == .sourceChanging, attempt < 2 { continue }
                throw error
            }
        }
        throw ArcImportFailure.sourceChanging
    }

    static func validProfileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && (value as NSString).lastPathComponent == value
            && !value.contains("\\") && !value.contains("\0")
    }

    private static func stamp(_ file: URL) throws -> Stamp {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        return Stamp(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                     modified: attrs[.modificationDate] as? Date ?? .distantPast,
                     fileID: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Opens only the private copy. The SQLite backup API incorporates its WAL
    /// into one immutable, validated file for all subsequent import readers.
    static func freezeDatabase(_ file: URL) throws {
        let output = file.appendingPathExtension("snapshot")
        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer { sqlite3_close_v2(source); sqlite3_close_v2(destination) }
        guard sqlite3_open_v2(file.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open_v2(output.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw ArcImportFailure.invalidDatabase(file.lastPathComponent)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw ArcImportFailure.invalidDatabase(file.lastPathComponent) }
        sqlite3_close_v2(source); source = nil
        sqlite3_close_v2(destination); destination = nil
        let check = try SQLiteDatabase(readingOnly: output.path)
        guard try check.query("PRAGMA quick_check;", row: { $0.text(0) }).first == "ok" else {
            throw ArcImportFailure.invalidDatabase(file.lastPathComponent)
        }
        try FileManager.default.removeItem(at: file)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        try FileManager.default.moveItem(at: output, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
