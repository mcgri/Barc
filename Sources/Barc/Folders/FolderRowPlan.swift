// Modified for Barc: retain mixed root folder and tab order, 2026-10-24.
import AppKit

/// Turning a Space's folders and tabs into the flat list of rows the sidebar
/// draws, including the one rule that makes collapsing safe: the selected tab
/// escapes its collapsed folder and stays visible.
///
/// This is a pure function of the model. The same idea could instead be
/// implemented as an animation that keeps certain children out of the
/// opacity fade; in an `NSTableView` there is no animation to opt out of,
/// only a row set, so the escape is a filtering rule and nothing else. That
/// also makes it testable without a window.
@MainActor
enum FolderRowPlan {
    enum Row: Equatable {
        /// `escapedTab` is the tab poking out of this collapsed folder, if any.
        /// The header needs to know so it can draw the "has active" treatment
        /// rather than looking closed with a stray row underneath it.
        case folder(TabGroup, depth: Int, showsEscapedTab: Bool)
        /// `isEscaping` marks the tab that is only visible because it is
        /// selected. It is drawn at its true indent so it still reads as nested.
        case tab(Tab, depth: Int, isEscaping: Bool)

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case let (.folder(a, ad, ae), .folder(b, bd, be)):
                return a.id == b.id && ad == bd && ae == be
            case let (.tab(a, ad, ae), .tab(b, bd, be)):
                return a.id == b.id && ad == bd && ae == be
            default:
                return false
            }
        }
    }

    /// Folders and tabs share their saved sibling order. Older sessions keep
    /// their original order until an item is moved.
    static func rows(
        groups: [TabGroup],
        tabs: [Tab],
        activeTabID: Tab.ID?
    ) -> [Row] {
        let activeTab = activeTabID.flatMap { id in tabs.first { $0.id == id } }
        var result: [Row] = []
        var visited: Set<TabGroup.ID> = []

        func append(_ item: SidebarItem, depth: Int) {
            switch item {
            case .tab(let tab):
                result.append(.tab(tab, depth: depth, isEscaping: false))
            case .folder(let folder):
                guard visited.insert(folder.id).inserted else { return }
                if folder.isCollapsed {
                    let escaping = escapedTab(activeTab, under: folder, in: groups)
                    result.append(.folder(folder, depth: depth, showsEscapedTab: escaping != nil))
                    if let escaping {
                        let tabDepth = escaping.groupID
                            .flatMap { FolderTree.folder(withID: $0, in: groups) }
                            .map { FolderTree.depth(of: $0, in: groups) + 1 } ?? depth + 1
                        result.append(.tab(escaping, depth: tabDepth, isEscaping: true))
                    }
                } else {
                    result.append(.folder(folder, depth: depth, showsEscapedTab: false))
                    for child in SidebarOrder.items(groups: groups, tabs: tabs, parentID: folder.id) {
                        append(child, depth: depth + 1)
                    }
                }
            }
        }
        for item in SidebarOrder.items(groups: groups, tabs: tabs) { append(item, depth: 0) }
        return result
    }

    /// The selected tab, if it is somewhere inside this folder's subtree *and*
    /// this folder is the outermost collapsed one above it.
    ///
    /// The second half is what stops the tab being emitted once per collapsed
    /// ancestor when folders are nested three deep and all three are shut.
    private static func escapedTab(
        _ activeTab: Tab?,
        under folder: TabGroup,
        in groups: [TabGroup]
    ) -> Tab? {
        guard let activeTab,
              let owner = FolderTree.folder(withID: activeTab.groupID, in: groups)
        else { return nil }

        let isInside = owner.id == folder.id || FolderTree.isDescendant(owner, of: folder, in: groups)
        guard isInside else { return nil }

        let outermost = FolderTree.rootMostCollapsedAncestor(of: owner, in: groups)
            ?? (owner.isCollapsed ? owner : nil)
        return outermost?.id == folder.id ? activeTab : nil
    }

    /// How far in a row is drawn. Exposed so a row view and the drop indicator
    /// use the same number.
    static func leadingIndent(for row: Row) -> CGFloat {
        switch row {
        case .folder(_, let depth, _): return FolderTree.indent(forDepth: depth)
        case .tab(_, let depth, _): return FolderTree.indent(forDepth: depth)
        }
    }
}
