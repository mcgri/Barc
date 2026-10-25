// Modified for Barc: owner-scoped whole-row archival and retained tab actions, 2026-10-25.
import Foundation

@MainActor
extension BrowserSession {
    enum SidebarArchiveScope: Equatable { case tab, other, above, below }

    func sidebarOwner(of tab: Tab) -> Space? {
        if activeSpace.tabs.contains(where: { $0 === tab }) { return activeSpace }
        return spaces.first { $0.tabs.contains(where: { $0 === tab }) }
    }

    /// Customization targets the selected website, never a background or PDF page.
    func customizablePageHost(for tab:Tab) -> String? {
        guard activeSpace.activeTab === tab,tab.document == nil,
              let scheme = tab.displayURL.scheme?.lowercased(),["http","https"].contains(scheme),
              let rawHost = tab.displayURL.host() else { return nil }
        let host = SiteSettings.normalise(rawHost)
        return host.isEmpty ? nil:host
    }

    /// Space pins and profile-wide Favorites are different destinations.
    func canChangeSidebarPin(_ tab: Tab) -> Bool {
        sidebarPinUnit(for:tab) != nil
    }

    func setSidebarPin(_ retained: Bool, for tab: Tab) {
        guard let (owner,members) = sidebarPinUnit(for:tab),
              members.contains(where:{ $0.isSidebarRetained != retained }) else { return }
        changes.batch {
            selectSpace(owner)
            let folder = retained ? tab.groupID.flatMap { owner.group(withID:$0) }:nil
            moveSidebarTabs(members,to:owner.tabs.count,group:folder,before:nil,retained:retained)
        }
    }

    /// Resolve the complete row before changing anything. A protected page or
    /// profile-owned Favorite must never leave a split half filed in Today.
    private func sidebarPinUnit(for tab:Tab) -> (Space,[Tab])? {
        guard let owner = sidebarOwner(of:tab) else { return nil }
        let ids = owner.splits.layout(containing:tab.id)?.tabIDs ?? [tab.id]
        let members = ids.compactMap { id in owner.workspaceTabs.first { $0.id == id } }
        guard members.count == ids.count,
              members.allSatisfy({ $0.pinnedSiteID == nil && !$0.isLocked
                  && !$0.isSidebarPlaceholder && !isInLiveFolder($0) }) else { return nil }
        return (owner,members)
    }

    func canResetSidebarPin(_ tab: Tab) -> Bool {
        sidebarOwner(of: tab) != nil && tab.pinnedSiteID == nil && tab.isSidebarRetained
            && tab.pinnedPageURL != nil && tab.pinnedPageURL != tab.url && !isInLiveFolder(tab)
    }

    func todayTabs(in space: Space) -> [Tab] {
        SidebarOrder.items(groups: [], tabs: space.sidebarVisibleTabs.filter {
            $0.groupID == nil && !$0.keepsInSidebar && !$0.isSidebarPlaceholder
        }).compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
    }

    func sidebarArchiveCandidates(relativeTo tab: Tab, in owner: Space, scope: SidebarArchiveScope) -> [Tab] {
        guard spaces.contains(where: { $0 === owner }), owner.tabs.contains(where: { $0 === tab }) else { return [] }
        let today = todayTabs(in: owner)
        let byID = Dictionary(uniqueKeysWithValues:today.map { ($0.id,$0) })
        var seen: Set<Tab.ID> = []
        var rows: [[Tab]] = []
        for candidate in today where !seen.contains(candidate.id) {
            let ids = owner.splits.layout(containing:candidate.id)?.tabIDs ?? [candidate.id]
            seen.formUnion(ids)
            // An arrangement reaching outside Today is retained as a whole.
            guard ids.allSatisfy({ byID[$0] != nil }) else { continue }
            rows.append(ids.compactMap { byID[$0] })
        }
        guard let index = rows.firstIndex(where:{ $0.contains { $0 === tab } }) else { return [] }
        return rows.enumerated().flatMap { offset, members -> [Tab] in
            let included: Bool = switch scope {
            case .tab: offset == index
            case .other: offset != index
            case .above: offset < index
            case .below: offset > index
            }
            guard included, members.allSatisfy({ !$0.isLocked && (scope == .tab || !$0.isPlayingMedia) }) else { return [] }
            return members
        }
    }

    func archiveSidebarTabs(relativeTo tab: Tab, in owner: Space, scope: SidebarArchiveScope) {
        let candidates = sidebarArchiveCandidates(relativeTo: tab, in: owner, scope: scope)
        if owner.isPrivate {
            for candidate in candidates { closeTab(candidate) }
        } else {
            archive(candidates)
        }
    }

    func removeSidebarPin(_ tab: Tab, in owner: Space) {
        guard spaces.contains(where: { $0 === owner }), owner.tabs.contains(where: { $0 === tab }),
              !tab.isLocked, !isInLiveFolder(tab) else { return }
        if tab.pinnedSiteID != nil {
            selectSpace(owner)
            unpin(tab)
        } else {
            setSidebarPin(false,for:tab)
        }
    }
}
