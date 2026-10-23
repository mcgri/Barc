// Modified for Barc: persistent mixed ordering of sidebar folders and tabs, 2026-10-24.
import Foundation

@MainActor
enum SidebarItem {
    case folder(TabGroup)
    case tab(Tab)

    var id: UUID {
        switch self { case .folder(let folder): folder.id; case .tab(let tab): tab.id }
    }
    var position: Int? {
        get {
            switch self { case .folder(let folder): folder.sidebarPosition; case .tab(let tab): tab.sidebarPosition }
        }
        nonmutating set {
            switch self { case .folder(let folder): folder.sidebarPosition = newValue; case .tab(let tab): tab.sidebarPosition = newValue }
        }
    }
    var isRetained: Bool {
        switch self { case .folder: true; case .tab(let tab): tab.keepsInSidebar }
    }
}

@MainActor
enum SidebarOrder {
    /// Folders and retained tabs share the upper section; ordinary tabs stay below New Tab.
    /// Missing ranks retain their existing relative order, including sessions from older builds.
    static func items(groups: [TabGroup], tabs: [Tab], parentID: UUID? = nil) -> [SidebarItem] {
        let folders: [SidebarItem]
        if let parentID {
            folders = groups.filter { $0.parentID == parentID }.map(SidebarItem.folder)
        } else {
            folders = FolderTree.ordered(groups).filter { $0.depth == 0 }.map { .folder($0.folder) }
        }
        let loose = tabs.filter { $0.groupID == parentID }.map(SidebarItem.tab)
        // Old sessions draw a folder's own tabs before its subfolders.
        let seed = parentID == nil ? folders + loose : loose + folders
        return seed.enumerated().sorted { a, b in
            if parentID == nil, a.element.isRetained != b.element.isRetained { return a.element.isRetained }
            switch (a.element.position, b.element.position) {
            case (.some(let x), .some(let y)) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    static func place(_ item: SidebarItem, before target: SidebarItem?, in items: [SidebarItem], separatesOrdinaryTabs: Bool = true) {
        guard target?.id != item.id else { return }
        var ordered = items.filter { $0.id != item.id }
        let requested = target.flatMap { target in ordered.firstIndex { $0.id == target.id } } ?? ordered.count
        let index: Int
        if separatesOrdinaryTabs {
            let sectionEnd = ordered.firstIndex { !$0.isRetained } ?? ordered.count
            index = item.isRetained ? min(requested, sectionEnd) : max(requested, sectionEnd)
        } else {
            index = requested
        }
        ordered.insert(item, at: index)
        for (index, entry) in ordered.enumerated() { entry.position = index }
    }
}
