// Modified for Barc: profile-scoped browsing preferences shared by assigned Spaces, 2026-10-24.
import Foundation

struct BrowserTopSite: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var favicon: PageFavicon? = nil

    var isValid: Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil }
}

struct ProfilePreferences: Codable, Equatable {
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
}
