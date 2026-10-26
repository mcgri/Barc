// Modified for Barc: preserve Favorites, pinned rows and current split structure, 2026-10-25.
import Foundation

@MainActor
enum ArcSpaceBuilder {
    struct Built {
        let profile: String?
        let sourceSpaceID: String
        let snapshot: SessionSnapshot.Space
        var sourceSplitKeys:[String] = []
        var unsupportedSplitKeys:[String] = []
        var sourceSplitCount:Int { sourceSplitKeys.count }
        var unsupportedSplits:Int { unsupportedSplitKeys.count }
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
            var tabIndices:[String:Int] = [:]
            var splitRoots:[(id:String,favorite:Bool)] = []
            var visited: Set<String> = []
            var sidebarPosition = 0
            func children(_ id: String) -> [String] {
                let named = sidebar.items[id]?.children ?? []
                return named + sidebar.orderedItemIDs.filter { sidebar.items[$0]?.parentID == id && !named.contains($0) }
            }
            func walk(_ id: String, group: UUID?, pinned: Bool, favorite: Bool, root: Bool = false, inSplit:Bool = false) {
                guard visited.insert(id).inserted, let item = sidebar.items[id] else { return }
                if item.split != nil,!inSplit { splitRoots.append((id,favorite)) }
                let position = sidebarPosition
                sidebarPosition += 1
                var parent = group
                if item.isFolder, !root {
                    let groupID = ArcImportID.uuid(prefix + "/group/" + space.id + "/" + id)
                    groups.append(.init(id: groupID, name: item.title ?? "Folder", emoji: item.folderEmoji, tint: space.color ?? "#007aff",
                                        appearance: nil, isCollapsed: item.isCollapsed ?? false, parentID: group,
                                        symbolName: item.folderBadge == "github" ? "arc.github.folder" : "folder", isLive: item.liveGitHub,
                                        sidebarPosition: position))
                    parent = groupID
                }
                if let url = item.url {
                    tabIndices[id] = tabs.count
                    let pinID = favorite && group == nil ? ArcImportID.uuid(prefix + "/pin/" + space.id + "/" + id) : nil
                    if let pinID { pins.append(.init(id: pinID, url: url, title: item.title ?? url.host() ?? url.absoluteString)) }
                    tabs.append(SessionSnapshot.Tab(url: url, title: item.title, groupID: group, customName: item.customName,
                                                     pinnedSiteID: pinID, lastActiveAt: item.lastActiveAt,
                                                     keepsInSidebar: pinned ? true : nil,
                                                     importedSourceID: prefix + "/tab/" + space.id + "/" + id,
                                                     sidebarPosition: position))
                }
                for child in children(id) {
                    walk(child,group:parent,pinned:pinned,favorite:favorite,inSplit:inSplit || item.split != nil)
                }
            }
            if options.sidebar {
                for (root, pinned, favorite) in [(sidebar.favoritesRoots[space.profile], true, true),
                                                 (space.pinnedRoot, true, false), (space.unpinnedRoot, false, false)] {
                    if let root { walk(root, group: nil, pinned: pinned, favorite: favorite, root: true) }
                }
            }
            var splits:[SessionSnapshot.Split] = [],splitSelections:[String:Int] = [:],claimed:Set<Int> = []
            func splitPrefix(_ favorite:Bool) -> String {
                prefix+(favorite ? "/profile/"+space.profile+"/favorite":"/space/"+space.id)
            }
            func splitKey(_ candidate:(id:String,favorite:Bool)) -> String {
                splitPrefix(candidate.favorite)+"/split/"+candidate.id
            }
            for candidate in splitRoots {
                splitSelections[candidate.id] = ArcSplitBuilder.focusedIndex(root:candidate.id,
                    items:sidebar.items,children:children,tabIndices:tabIndices)
            }
            for candidate in splitRoots {
                guard let built = ArcSplitBuilder.build(root:candidate.id,items:sidebar.items,children:children,
                    tabIndices:tabIndices,prefix:splitPrefix(candidate.favorite)),
                      let groupID = built.record.id,
                      built.record.tabIndices.allSatisfy({ candidate.favorite
                          ? tabs[$0].pinnedSiteID != nil && tabs[$0].groupID == nil
                          : tabs[$0].pinnedSiteID == nil }),
                      claimed.isDisjoint(with:built.record.tabIndices) else { continue }
                if candidate.favorite {
                    let pinID = ArcImportID.uuid(splitKey(candidate)+"/pin")
                    let members = zip(built.record.layout.tabIDs,built.record.tabIndices).map { member,index -> FavoriteSplit.Member in
                        var saved = tabs[index]
                        saved.pinnedSiteID = nil;saved.pinnedMemberID = nil;saved.interactionState = nil; saved.hibernationViewport = nil
                        return .init(id:member,page:saved)
                    }
                    let focusedMember = zip(built.record.layout.tabIDs,built.record.tabIndices)
                        .first { $0.1 == built.focusedIndex }?.0
                    let destination = FavoriteSplit(id:groupID,members:members,layout:built.record.layout,
                        focusedMemberID:focusedMember,stickyMemberID:nil,customName:built.record.customName)
                    let oldIDs = Set(built.record.tabIndices.compactMap { tabs[$0].pinnedSiteID })
                    let position = pins.firstIndex { oldIDs.contains($0.id) } ?? pins.count
                    pins.removeAll { oldIDs.contains($0.id) }
                    pins.insert(.init(id:pinID,url:members[0].page.url,
                        title:destination.customName ?? members.map { $0.page.customName ?? $0.page.title ?? $0.page.url.host() ?? "Tab" }.joined(separator:" / "),
                        split:destination),at:min(position,pins.count))
                    for (member,index) in zip(built.record.layout.tabIDs,built.record.tabIndices) {
                        tabs[index].pinnedSiteID = pinID;tabs[index].pinnedMemberID = member
                    }
                }
                splits.append(built.record)
                splitSelections[candidate.id] = built.focusedIndex
                claimed.formUnion(built.record.tabIndices)
            }
            let archives = options.sidebar ? sidebar.archived.filter { $0.spaceID == space.id }.map { record in
                SessionSnapshot.Archived(tab: SessionSnapshot.Tab(url: record.url, title: record.title, customName: record.customName,
                    importedSourceID: prefix + "/archive/" + record.id), archivedAt: record.date)
            } : []
            var look = SpaceLook()
            look.customColorHex = space.color
            look.importedChrome = space.chrome
            look.sidebarWidth = sidebar.sidebarWidth
            look.pinnedSectionCollapsed = space.pinnedSectionCollapsed ?? false
            let selected = sidebar.selectedItems[space.id].flatMap { selected in
                tabs.firstIndex { $0.importedSourceID == prefix + "/tab/" + space.id + "/" + selected }
                    ?? splitSelections[selected]
            }
            if let selected {
                for index in splits.indices where splits[index].tabIndices.contains(selected) {
                    splits[index].focusedTabIndex = selected
                    if let pin = pins.firstIndex(where:{ $0.split?.id == splits[index].id }),
                       let member = zip(splits[index].layout.tabIDs,splits[index].tabIndices).first(where:{ $0.1 == selected })?.0 {
                        pins[pin].split?.focusedMemberID = member
                    }
                }
            }
            let snapshot = SessionSnapshot.Space(
                id: spaceID, name: space.name, tabs: tabs, activeTabIndex: selected ?? tabs.firstIndex { $0.pinnedSiteID == nil } ?? (tabs.isEmpty ? nil : 0),
                profileName: source.profiles.first { $0.folder == space.profile }?.name,
                identity: identity, theme: space.color == nil ? "blue" : "custom", look: look, groups: groups, pinnedSites: pins,
                archiveHours: 0, archivedTabs: archives, bookmarkFolder: "From Arc/" + space.name,
                icon: space.emoji.map { .emoji($0) } ?? space.symbolName.map { .symbol($0) },
                splits:splits.isEmpty ? nil:splits,importedSplitIDs:splits.isEmpty ? nil:splits.compactMap(\.id))
            let supported = Set(splits.compactMap(\.id))
            output.append(Built(profile:space.profile,sourceSpaceID:space.id,snapshot:snapshot,
                sourceSplitKeys:splitRoots.map(splitKey),unsupportedSplitKeys:splitRoots.filter {
                    !supported.contains(ArcImportID.uuid(splitKey($0)))
                }.map(splitKey)))
        }
        if options.sidebar {
            let knownIDs = Set(sidebar.spaces.map(\.id))
            let unknown = sidebar.archived.filter { $0.spaceID.map { !knownIDs.contains($0) } ?? true }
            if !unknown.isEmpty {
                let id = ArcImportID.uuid(prefix + "/unassigned-archive")
                var archiveLook = SpaceLook()
                archiveLook.showsInDock = false
                let records = unknown.map { record in
                    SessionSnapshot.Archived(tab: SessionSnapshot.Tab(url: record.url, title: record.title, customName: record.customName,
                        importedSourceID: prefix + "/archive/" + record.id), archivedAt: record.date)
                }
                output.append(Built(profile: nil, sourceSpaceID: "unassigned-archive", snapshot: SessionSnapshot.Space(
                    id: id, name: "Unassigned Arc archive", identity: .isolated(id), look:archiveLook, archiveHours: 0, archivedTabs: records)))
            }
        }
        return output
    }
}
