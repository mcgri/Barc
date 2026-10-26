// Modified for Barc: profile-scoped browsing preferences shared by assigned Spaces, 2026-10-24.
import Foundation

struct BrowserTopSite: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var favicon: PageFavicon? = nil

    var isValid: Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil }
}

struct ProfilePreferences: Codable, Equatable, Sendable {
    var archiveHours: Int?
    var downloadsDirectoryPath: String?
    var bookmarkFolder: String?
    var enabledExtensionIDs: Set<UUID>?
    var passwordVaultAccount: String?
    var customProxy: ProxySettings?
    var searchEngineID: String?
    var userAgent: String?
    var sleepMinutes: Int?
    var defaultZoom: String?
    /// Arc's ranked local shortcuts. Nil is an older import; an empty list
    /// records that browsing history was deliberately cleared.
    var arcTopSites: [BrowserTopSite]?
    var folderCommandHistory: FolderCommandHistory?
    /// Process each source once. Kept after history clearing so a repeat
    /// import cannot silently restore choices the user deliberately removed.
    var arcFolderCommandSources: Set<String>?
    /// Favorites and their empty-state hint belong to the shared profile.
    /// Nil retains compatibility with an older per-Space dismissal flag.
    var favoritesHintDismissed: Bool?
}
