// Modified for Barc: owner-scoped Today archival and retained tab actions, 2026-10-24.
import Foundation

@MainActor
extension BrowserSession {
    enum SidebarArchiveScope: Equatable { case tab, other, above, below }

    func sidebarOwner(of tab: Tab) -> Space? {
        if activeSpace.tabs.contains(where: { $0 === tab }) { return activeSpace }
        return spaces.first { $0.tabs.contains(where: { $0 === tab }) }
    }

    /// Space pins and profile-wide Favorites are different destinations.
    func canChangeSidebarPin(_ tab: Tab) -> Bool {
        sidebarOwner(of: tab) != nil && tab.pinnedSiteID == nil && !tab.isLocked
            && !tab.isSidebarPlaceholder && !isInLiveFolder(tab)
    }

    func setSidebarPin(_ retained: Bool, for tab: Tab) {
        guard canChangeSidebarPin(tab), let owner = sidebarOwner(of: tab),
              retained != tab.isSidebarRetained else { return }
        selectSpace(owner)
        if retained {
            positionSidebarItem(.tab(tab), before: nil, retained: true)
        } else {
            removeSidebarPin(tab, in: owner)
        }
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
        guard let index = today.firstIndex(where: { $0 === tab }) else { return [] }
        return today.enumerated().compactMap { offset, candidate in
            let included: Bool = switch scope {
            case .tab: candidate === tab
            case .other: candidate !== tab
            case .above: offset < index
            case .below: offset > index
            }
            guard included, !candidate.isLocked, scope == .tab || !candidate.isPlayingMedia else { return nil }
            return candidate
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
        selectSpace(owner)
        if tab.pinnedSiteID != nil { unpin(tab); return }
        tab.setKeepsInSidebar(false)
        tab.setGroupID(nil)
        SidebarOrder.place(.tab(tab), before: nil, in: SidebarOrder.items(groups: owner.groups, tabs: owner.sidebarVisibleTabs))
        move(tab, to: nil)
    }
}
