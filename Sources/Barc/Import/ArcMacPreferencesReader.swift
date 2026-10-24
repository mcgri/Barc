// Modified for Barc: read only Arc's profile-scoped empty Favorites hint setting, 2026-10-24.
import Foundation

enum ArcMacPreferencesReader {
    static func dismissedFavoritesProfiles(_ data: Data, profiles: [ArcProfile]) -> Set<String>? {
        guard let object = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              let dismissed = object["topAppsEmptyStateDismissedForProfiles"] as? [String] else { return nil }
        return Set(dismissed).intersection(Set(profiles.map(\.folder)))
    }
}
