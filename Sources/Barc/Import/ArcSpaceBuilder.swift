// Modified for Barc: preserve Arc's separate Favorites and pinned list, 2026-10-24.
import Foundation

@MainActor
enum ArcSpaceBuilder {
    struct Built {
        let profile: String?
        let sourceSpaceID: String
        let snapshot: SessionSnapshot.Space
    }

    static func build(_ source: ArcSourceSnapshot, options: ArcImportOptions) -> [Built] {
        let sidebar = source.sidebar
        let prefix = source.sourceFingerprint
        var definitions = sidebar.spaces.filter { options.profileIDs.contains($0.profile) }
        for profile in source.profiles where options.profileIDs.contains(profile.folder) && !definitions.contains(where: { $0.profile == profile.folder }) {
            definitions.append(.init(id: "profile:\(profile.folder)", name: profile.name, profile: profile.folder,
                                     pinnedRoot: nil, unpinnedRoot: nil, color: nil, emoji: nil))
        }
        var output: [Built] = []
        for space in definitions {
            let spaceID = ArcImportID.uuid(prefix + "/space/" + space.id)
            let identity = Space.Identity.isolated(ArcImportID.uuid(prefix + "/profile/" + space.profile))
            var tabs: [SessionSnapshot.Tab] = []
            var groups: [SessionSnapshot.Group] = []
            var pins: [SessionSnapshot.Pinned] = []
            var visited: Set<String> = []
            var sidebarPosition = 0
            func children(_ id: String) -> [String] {
                let named = sidebar.items[id]?.children ?? []
                return named + sidebar.orderedItemIDs.filter { sidebar.items[$0]?.parentID == id && !named.contains($0) }
            }
            func walk(_ id: String, group: UUID?, pinned: Bool, favorite: Bool, root: Bool = false) {
                guard visited.insert(id).inserted, let item = sidebar.items[id] else { return }
                let position = sidebarPosition
                sidebarPosition += 1
                var parent = group
                if item.isFolder, !root {
                    let groupID = ArcImportID.uuid(prefix + "/group/" + space.id + "/" + id)
                    groups.append(.init(id: groupID, name: item.title ?? "Folder", emoji: nil, tint: space.color ?? "#007aff",
                                        appearance: nil, isCollapsed: false, parentID: group, symbolName: "folder", isLive: nil,
                                        sidebarPosition: position))
                    parent = groupID
                }
                if let url = item.url {
                    let pinID = favorite && group == nil ? ArcImportID.uuid(prefix + "/pin/" + space.id + "/" + id) : nil
                    if let pinID { pins.append(.init(id: pinID, url: url, title: item.title ?? url.host() ?? url.absoluteString)) }
                    tabs.append(SessionSnapshot.Tab(url: url, title: item.title, groupID: group, customName: item.customName,
                                                     pinnedSiteID: pinID, lastActiveAt: item.lastActiveAt,
                                                     keepsInSidebar: pinned ? true : nil,
                                                     importedSourceID: prefix + "/tab/" + space.id + "/" + id,
                                                     sidebarPosition: position))
                }
                for child in children(id) { walk(child, group: parent, pinned: pinned, favorite: favorite) }
            }
            if options.sidebar {
                for (root, pinned, favorite) in [(sidebar.favoritesRoots[space.profile], true, true),
                                                 (space.pinnedRoot, true, false), (space.unpinnedRoot, false, false)] {
                    if let root { walk(root, group: nil, pinned: pinned, favorite: favorite, root: true) }
                }
            }
            let archives = options.sidebar ? sidebar.archived.filter { $0.spaceID == space.id }.map { record in
                SessionSnapshot.Archived(tab: SessionSnapshot.Tab(url: record.url, title: record.title, customName: record.customName,
                    importedSourceID: prefix + "/archive/" + record.id), archivedAt: record.date)
            } : []
            var look = SpaceLook()
            look.customColorHex = space.color
            let selected = sidebar.selectedItems[space.id].flatMap { selected in
                tabs.firstIndex { $0.importedSourceID == prefix + "/tab/" + space.id + "/" + selected }
            }
            let snapshot = SessionSnapshot.Space(
                id: spaceID, name: space.name, tabs: tabs, activeTabIndex: selected ?? tabs.firstIndex { $0.pinnedSiteID == nil } ?? (tabs.isEmpty ? nil : 0),
                identity: identity, theme: space.color == nil ? "blue" : "custom", look: look, groups: groups, pinnedSites: pins,
                archiveHours: 0, archivedTabs: archives, bookmarkFolder: "From Arc/" + space.name,
                icon: space.emoji.map { .emoji($0) })
            output.append(Built(profile: space.profile, sourceSpaceID: space.id, snapshot: snapshot))
        }
        if options.sidebar {
            let knownIDs = Set(sidebar.spaces.map(\.id))
            let unknown = sidebar.archived.filter { $0.spaceID.map { !knownIDs.contains($0) } ?? true }
            if !unknown.isEmpty {
                let id = ArcImportID.uuid(prefix + "/unassigned-archive")
                let records = unknown.map { record in
                    SessionSnapshot.Archived(tab: SessionSnapshot.Tab(url: record.url, title: record.title, customName: record.customName,
                        importedSourceID: prefix + "/archive/" + record.id), archivedAt: record.date)
                }
                output.append(Built(profile: nil, sourceSpaceID: "unassigned-archive", snapshot: SessionSnapshot.Space(
                    id: id, name: "Unassigned Arc archive", identity: .isolated(id), archiveHours: 0, archivedTabs: records)))
            }
        }
        return output
    }
}
