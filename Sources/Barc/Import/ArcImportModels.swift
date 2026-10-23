import Foundation
import CryptoKit

enum ArcImportFailure: LocalizedError, Equatable {
    case invalidFolder, unreadable(String), invalidSidebar, sourceChanging, invalidDatabase(String)
    case unsupportedStorage(String), keyUnavailable, cancelled, alreadyRunning, noSelection, incompleteSnapshot

    var errorDescription: String? {
        switch self {
        case .invalidFolder: return "Choose Arc's folder in Library/Application Support, containing StorableSidebar.json and User Data."
        case .unreadable(let file): return "Could not read Arc's \(file). Check access to the selected folder."
        case .invalidSidebar: return "This Arc sidebar format is not recognised. No Spaces were imported."
        case .sourceChanging: return "Arc's data kept changing while it was copied. Quit Arc and try again."
        case .invalidDatabase(let file): return "The copy of Arc's \(file) could not be validated. Quit Arc and try again."
        case .unsupportedStorage(let reason): return "Website storage could not be read: \(reason)."
        case .keyUnavailable: return "Arc's encryption key was unavailable or macOS access was declined. Other selected data can still be imported."
        case .cancelled: return "Import cancelled."
        case .alreadyRunning: return "An Arc import is already running. Wait for it to finish before starting another."
        case .noSelection: return "Select at least one Arc profile and one data category to import."
        case .incompleteSnapshot: return "This preview contains only sidebar data. Choose Arc's folder again to read other data categories."
        }
    }
}

enum ArcImportID {
    static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("barc.arc-import.v1/" + text).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func fingerprint(_ source: URL) -> String {
        SHA256.hash(data: Data(source.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct ArcProfile: Identifiable, Sendable, Equatable {
    var id: String { folder }
    let folder: String
    let name: String
}

struct ArcSidebar: Sendable {
    struct Item: Sendable {
        let id: String
        let parentID: String?
        let title: String?
        let children: [String]
        let url: URL?
        let isFolder: Bool
        let lastActiveAt: Date?
        var customName: String? = nil
        var isCollapsed: Bool? = nil
        var folderEmoji: String? = nil
        var folderBadge: String? = nil
    }
    struct Space: Sendable {
        let id: String
        let name: String
        let profile: String
        let pinnedRoot: String?
        let unpinnedRoot: String?
        let color: String?
        let emoji: String?
    }
    struct Archived: Sendable {
        let id: String
        let spaceID: String?
        let url: URL
        let title: String?
        let date: Date
        var customName: String? = nil
    }
    var spaces: [Space]
    var items: [String: Item]
    var orderedItemIDs: [String]
    var favoritesRoots: [String: String]
    var archived: [Archived]
    var skippedItems: Int
    var selectedItems: [String: String] = [:]
    var activeSpaceID: String? = nil
}

struct ArcSourceSnapshot: Sendable {
    let root: URL
    let sourceFingerprint: String
    let profiles: [ArcProfile]
    let sidebar: ArcSidebar
    let unsupportedIndexedDBFolders: [String: Int]
    let extensions: [String: Int]
    var sidebarOnly: Bool = false

    func profileURL(_ profile: ArcProfile) -> URL {
        root.appending(path: "User Data").appending(path: profile.folder)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct ArcImportOptions: Sendable {
    var profileIDs: Set<String>
    var sidebar = true
    var history = true
    var bookmarks = true
    var passwords = true
    var cookies = true
    var localStorage = true
    var supplementary = true
}

struct ArcImportReport: Codable, Sendable {
    struct Count: Codable, Sendable {
        var source = 0
        var imported = 0
        var existing = 0
        var skipped = 0
        var failed = 0
        var verified = 0
        var skipReasons: [String: Int]? = nil
        var failureReasons: [String: Int]? = nil
    }
    struct Profile: Codable, Sendable {
        var name: String
        var folder: String
        var counts: [String: Count] = [:]
        var notes: [String] = []
    }
    var startedAt = Date()
    var finishedAt: Date?
    var profiles: [Profile] = []
    var notes: [String] = []
    var completed = false

    var summary: String {
        let failures = profiles.reduce(0) { $0 + $1.counts.values.reduce(0) { $0 + $1.failed } }
        return failures == 0 ? "Import finished. Review the results and any skipped data below."
            : "Import finished with some data unavailable. Imported data was kept; see the results below."
    }
}
