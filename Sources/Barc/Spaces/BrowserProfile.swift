// Modified for Barc: shared Favorites retain distinct split members and geometry, 2026-10-25.
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
        if let existing = pinnedSites.first(where: { $0.id == site.id || (site.split == nil && $0.matches(site.url)) }) {
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
            stored.pinnedMemberID = nil
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
        guard let site = pinnedSites.first(where:{ $0.id == pinID }) else { return nil }
        if let split = site.split {
            guard let member = tab.pinnedMemberID,split.members.contains(where:{ $0.id == member }) else { return nil }
        } else if tab.pinnedMemberID != nil { tab.setPinnedMemberID(nil) }
        if let existing = favoriteTabs.first(where: { $0.pinnedSiteID == pinID && $0.pinnedMemberID == tab.pinnedMemberID }) { return existing }
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
                     pinnedSites: identity.isPrivate ? nil : pinnedSites.map { .init(id: $0.id, url: $0.url, title: $0.title,split:$0.split) },
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
        for pin in stored.pinnedSites ?? [] { profile.addPinnedSite(.init(id: pin.id, url: pin.url, title: pin.title,split:pin.split)) }
        profile.importedFavoriteIDs = Set(stored.importedFavoriteIDs ?? [])
        for tab in stored.favoriteTabs ?? [] { profile.adoptFavorite(Tab(restoring: tab, identity: identity)) }
        return profile
    }

    /// Persist only edits to an existing complete unit. Loading another Space
    /// must not overwrite the profile destination with its older saved layout.
    func updateFavoriteSplits(before:SplitCollection,after:SplitCollection) {
        for index in pinnedSites.indices {
            guard var saved = pinnedSites[index].split,saved.isValid else { continue }
            let tabs = saved.members.compactMap { member in
                favoriteTabs.first { $0.pinnedSiteID == pinnedSites[index].id && $0.pinnedMemberID == member.id }
            }
            guard tabs.count == saved.members.count,
                  let old = before.snapshot(tabIDs:tabs.map(\.id))?.first,
                  let new = after.snapshot(tabIDs:tabs.map(\.id))?.first,
                  old.tabIndices.count == tabs.count,new.tabIndices.count == tabs.count,old != new else { continue }
            let bindings = Dictionary(uniqueKeysWithValues:zip(tabs.map(\.id),saved.members.map(\.id)))
            guard let layout = new.layout.mappingTabs({ bindings[$0] }) else { continue }
            saved.layout = layout
            saved.focusedMemberID = new.focusedTabIndex.flatMap { saved.members.indices.contains($0) ? saved.members[$0].id:nil }
            saved.stickyMemberID = new.stickyTabIndex.flatMap { saved.members.indices.contains($0) ? saved.members[$0].id:nil }
            pinnedSites[index].split = saved
        }
    }
}
