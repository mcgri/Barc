// Modified for Barc: browsing profiles outlive Spaces and share their Favorites, 2026-10-24.
import Foundation

@MainActor
final class BrowserProfile: Identifiable {
    let id: UUID
    let identity: Space.Identity
    var name: String
    var hasCustomName = false
    var preferences = ProfilePreferences()
    private(set) var pinnedSites: [PinnedSite] = []
    private(set) var favoriteTabs: [Tab] = []
    private var pinAliases: [UUID: UUID] = [:]
    private(set) var importedFavoriteIDs: Set<String> = []

    init(id: UUID? = nil, name: String, identity: Space.Identity) {
        self.id = id ?? Self.identifier(for: identity)
        self.name = name
        self.identity = identity
    }

    static func identifier(for identity: Space.Identity) -> UUID {
        switch identity {
        case .standard: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .isolated(let id), .ephemeral(let id): id
        }
    }

    func addPinnedSite(_ site: PinnedSite) {
        if let existing = pinnedSites.first(where: { $0.id == site.id || $0.matches(site.url) }) {
            pinAliases[site.id] = existing.id
            return
        }
        pinnedSites.append(site)
        pinAliases[site.id] = site.id
    }

    func removePinnedSite(_ site: PinnedSite) {
        pinnedSites.removeAll { $0.id == site.id }
        pinAliases = pinAliases.filter { $0.value != site.id }
    }

    func movePinnedSite(from source: Int, to destination: Int) {
        guard pinnedSites.indices.contains(source) else { return }
        let site = pinnedSites.remove(at: source)
        let target = source < destination ? destination - 1 : destination
        pinnedSites.insert(site, at: min(max(target, 0), pinnedSites.count))
    }

    func mergeFavorites(from other: BrowserProfile) {
        guard other !== self, other.identity == identity else { return }
        for pin in other.pinnedSites { addPinnedSite(pin) }
        importedFavoriteIDs.formUnion(other.importedFavoriteIDs)
        for tab in other.favoriteTabs { adoptFavorite(tab) }
    }

    /// Old copies may have different import IDs, layout positions and clocks.
    /// Every other saved field must agree before discarding a duplicate page.
    static func sameFavoriteCopy(_ first: Tab, _ second: Tab) -> Bool {
        func content(_ tab: Tab) -> SessionSnapshot.Tab {
            var stored = tab.snapshot()
            stored.pinnedSiteID = nil
            stored.importedSourceID = nil
            stored.sidebarPosition = nil
            stored.lastActiveAt = nil
            stored.groupID = nil
            return stored
        }
        return content(first) == content(second)
    }

    @discardableResult
    func adoptFavorite(_ tab: Tab) -> Tab? {
        guard tab.identity == identity, let originalID = tab.pinnedSiteID,
              let pinID = pinAliases[originalID] ?? pinnedSites.first(where: { $0.id == originalID })?.id else { return nil }
        if let source = tab.importedSourceID { importedFavoriteIDs.insert(source) }
        if originalID != pinID { tab.setPinnedSiteID(pinID) }
        if let existing = favoriteTabs.first(where: { $0.pinnedSiteID == pinID }) { return existing }
        favoriteTabs.append(tab)
        return tab
    }

    @discardableResult
    func removeFavorite(_ tab: Tab) -> Bool {
        guard favoriteTabs.contains(where: { $0 === tab }) else { return false }
        favoriteTabs.removeAll { $0 === tab }
        return true
    }

    func snapshot() -> SessionSnapshot.Profile {
        let kind: SessionSnapshot.Profile.Kind = switch identity {
        case .standard: .standard
        case .isolated(let id): .isolated(id)
        case .ephemeral: .ephemeral
        }
        return .init(id: id, name: name, kind: kind, theme: nil,
                     pinnedSites: identity.isPrivate ? nil : pinnedSites.map { .init(id: $0.id, url: $0.url, title: $0.title) },
                     favoriteTabs: identity.isPrivate ? nil : favoriteTabs.map { $0.snapshot() },
                     importedFavoriteIDs: identity.isPrivate || importedFavoriteIDs.isEmpty ? nil : importedFavoriteIDs.sorted(),
                     preferences: preferences, hasCustomName: hasCustomName)
    }

    static func restore(_ stored: SessionSnapshot.Profile) -> BrowserProfile {
        let identity: Space.Identity = switch stored.kind {
        case .standard: .standard
        case .isolated(let id): .isolated(id)
        case .ephemeral: .ephemeral(stored.id)
        }
        let profile = BrowserProfile(id: stored.id, name: stored.name, identity: identity)
        profile.hasCustomName = stored.hasCustomName ?? true
        profile.preferences = stored.preferences ?? ProfilePreferences()
        guard !identity.isPrivate else { return profile }
        for pin in stored.pinnedSites ?? [] { profile.addPinnedSite(.init(id: pin.id, url: pin.url, title: pin.title)) }
        profile.importedFavoriteIDs = Set(stored.importedFavoriteIDs ?? [])
        for tab in stored.favoriteTabs ?? [] { profile.adoptFavorite(Tab(restoring: tab, identity: identity)) }
        return profile
    }
}
