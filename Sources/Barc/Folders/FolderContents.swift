// Modified for Barc: folder links follow the visible mixed sidebar order, 2026-10-24.
import Foundation

@MainActor
enum FolderContents {
    static func tabs(in folder: TabGroup, space: Space) -> [Tab] {
        guard space.group(withID: folder.id) === folder else { return [] }
        var visited: Set<UUID> = []
        var result: [Tab] = []
        func visit(_ folder: TabGroup) {
            guard visited.insert(folder.id).inserted else { return }
            for item in SidebarOrder.items(groups: space.groups, tabs: space.listedTabs, parentID: folder.id) {
                switch item {
                case .tab(let tab): if !tab.isSidebarPlaceholder { result.append(tab) }
                case .folder(let child): visit(child)
                }
            }
        }
        visit(folder)
        return result
    }

    static func links(in folder: TabGroup, space: Space, markdown: Bool = false) -> String {
        tabs(in: folder, space: space).map { tab in
            guard markdown else { return tab.url.absoluteString }
            let title = tab.displayTitle.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                .components(separatedBy: .newlines).joined(separator: " ")
            let url = tab.url.absoluteString.replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            return "[\(title)](\(url))"
        }.joined(separator: "\n")
    }
}
