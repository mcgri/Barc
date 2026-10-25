// Modified for Barc: one visual destination order for sidebar keyboard navigation, 2026-10-25.
import Foundation

@MainActor
enum SidebarNavigationItem {
    case favorite(PinnedSite)
    case tab(Tab)

    func title(in space:Space) -> String {
        switch self {
        case .favorite(let site):site.title.isEmpty ? AddressFormatter.display(site.url):site.title
        case .tab(let tab):space.splits.name(containing:tab.id) ?? tab.displayTitle
        }
    }
    func contains(_ tab:Tab?,in space:Space) -> Bool {
        guard let tab else { return false }
        switch self {
        case .favorite(let site):return tab.pinnedSiteID == site.id
        case .tab(let page):return page === tab || space.splits.layout(containing:page.id)?.tabIDs.contains(tab.id) == true
        }
    }
}

@MainActor
extension Space {
    var sidebarNavigationTabs:[Tab] { sidebarNavigationTabs(includingCollapsedPinned:false) }

    /// Render order, with one remembered destination per workspace split.
    func sidebarNavigationTabs(includingCollapsedPinned:Bool) -> [Tab] {
        let kept = sidebarVisibleTabs.filter { $0.groupID == nil && $0.keepsInSidebar }
        let remaining = sidebarVisibleTabs.filter { $0.groupID != nil || !$0.keepsInSidebar }
        let active = splits.layout(containing:activeTabID)?.tabIDs.first ?? activeTabID
        var units:Set<UUID> = []
        return FolderRowPlan.rows(groups:groups,tabs:kept+remaining,activeTabID:active).compactMap { row in
            guard case .tab(let page,_,_) = row,includingCollapsedPinned || !isInCollapsedPinnedSection(page) else { return nil }
            guard let unit = splits.identifier(containing:page.id) else { return page }
            guard units.insert(unit).inserted else { return nil }
            return splits.preferredTab(containing:page.id).flatMap { id in tabs.first { $0.id == id } } ?? page
        }
    }

    func isInCollapsedPinnedSection(_ tab:Tab) -> Bool {
        look.pinnedSectionCollapsed && tab.pinnedSiteID == nil && tab.isSidebarRetained
    }
}

@MainActor
extension BrowserSession {
    var canSelectAdjacentTab:Bool {
        adjacentSidebarItem(offset:1).map { !$0.contains(activeTab,in:activeSpace) } ?? false
    }

    func selectTab(offsetBy offset:Int) {
        guard let item = adjacentSidebarItem(offset:offset) else { return }
        selectSidebarItem(item)
    }

    func selectSidebarItem(_ item:SidebarNavigationItem) {
        switch item {
        case .favorite(let site):openPinnedSite(site)
        case .tab(let tab):selectTab(tab)
        }
    }

    private func adjacentSidebarItem(offset:Int) -> SidebarNavigationItem? {
        guard offset != 0 else { return nil }
        let space = activeSpace
        // Cycling visits open destinations. Numbered selection also includes
        // unopened Favorite tiles and opens them only when explicitly selected.
        let favorites = space.pinnedSites.filter { site in space.tabs.contains { $0.pinnedSiteID == site.id } }
        let all = favorites.map(SidebarNavigationItem.favorite)
            + space.sidebarNavigationTabs(includingCollapsedPinned:true).map(SidebarNavigationItem.tab)
        let eligible = all.indices.filter {
            if case .tab(let tab) = all[$0] { return !space.isInCollapsedPinnedSection(tab) }
            return true
        }
        guard !eligible.isEmpty else { return nil }
        let currentIndex = all.firstIndex { $0.contains(activeTab,in:space) }
        let index:Int
        if let currentIndex,let position = eligible.firstIndex(of:currentIndex) {
            index = (position + offset % eligible.count + eligible.count) % eligible.count
        } else {
            let direction = offset > 0 ? 1:-1
            let first = offset > 0
                ? eligible.firstIndex(where:{ $0 > (currentIndex ?? -1) }) ?? 0
                : eligible.lastIndex(where:{ $0 < (currentIndex ?? all.count) }) ?? eligible.count-1
            index = (first + (offset-direction) % eligible.count + eligible.count) % eligible.count
        }
        return all[eligible[index]]
    }
}
