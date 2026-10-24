// Modified for Barc: profile-scoped browsing preferences shared by assigned Spaces, 2026-10-24.
import Foundation

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
}
