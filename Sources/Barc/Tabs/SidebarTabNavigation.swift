// Modified for Barc: traversal respects the collapsed Pinned section, 2026-10-25.
import Foundation

@MainActor
extension Space {
    /// Favorite tiles remain visible when the Space's Pinned list is closed.
    func isInCollapsedPinnedSection(_ tab:Tab) -> Bool {
        look.pinnedSectionCollapsed && tab.pinnedSiteID == nil && tab.isSidebarRetained
    }
}

@MainActor
extension BrowserSession {
    var canSelectAdjacentTab: Bool {
        adjacentTab(offset:1).map { $0 !== activeTab } ?? false
    }

    func selectTab(offsetBy offset:Int) {
        guard let tab = adjacentTab(offset:offset) else { return }
        selectTab(tab)
    }

    /// Keep the existing cycle when expanded. A hidden active pin anchors the
    /// search in that same order, so either direction can leave it naturally.
    private func adjacentTab(offset:Int) -> Tab? {
        let space = activeSpace,all = space.tabs
        guard offset != 0,let current = space.activeTabID,
              let currentIndex = all.firstIndex(where:{ $0.id == current }) else { return nil }
        let eligible = all.indices.filter { !space.isInCollapsedPinnedSection(all[$0]) }
        guard !eligible.isEmpty else { return nil }
        let index:Int
        if let position = eligible.firstIndex(of:currentIndex) {
            index = (position + offset % eligible.count + eligible.count) % eligible.count
        } else {
            let direction = offset > 0 ? 1:-1
            let first = offset > 0
                ? eligible.firstIndex(where:{ $0 > currentIndex }) ?? 0
                : eligible.lastIndex(where:{ $0 < currentIndex }) ?? eligible.count-1
            // Consume the first eligible step without taking abs(Int.min).
            index = (first + (offset-direction) % eligible.count + eligible.count) % eligible.count
        }
        return all[eligible[index]]
    }
}
